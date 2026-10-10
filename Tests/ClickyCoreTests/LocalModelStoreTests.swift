import XCTest
@testable import ClickyCore
#if canImport(CryptoKit)
import CryptoKit
#endif

final class LocalModelCatalogTests: XCTestCase {
    func testEveryPinnedEntryIsWellFormed() {
        XCTAssertFalse(LocalModelCatalog.entries.isEmpty)
        XCTAssertEqual(Set(LocalModelCatalog.entries.map(\.id)).count, LocalModelCatalog.entries.count)
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        for entry in LocalModelCatalog.entries {
            XCTAssertFalse(entry.files.isEmpty, entry.id)
            XCTAssertEqual(Set(entry.files.map(\.path)).count, entry.files.count, entry.id)
            XCTAssertNil(LocalModelPathPolicy.violation(in: entry), entry.id)
            XCTAssertGreaterThan(entry.totalBytes, 0, entry.id)
            XCTAssertEqual(entry.revision.count, 40, entry.id)
            for file in entry.files {
                XCTAssertTrue((file.sha256 == nil) != (file.gitBlobSHA1 == nil), "\(entry.id)/\(file.path)")
                if let sha = file.sha256 { XCTAssertEqual(sha.count, 64); XCTAssertTrue(sha.unicodeScalars.allSatisfy(hex.contains)) }
                if let sha = file.gitBlobSHA1 { XCTAssertEqual(sha.count, 40); XCTAssertTrue(sha.unicodeScalars.allSatisfy(hex.contains)) }
                XCTAssertGreaterThanOrEqual(file.size, 0)
                XCTAssertEqual(entry.remoteURL(for: file)?.host, "huggingface.co", "\(entry.id)/\(file.path)")
            }
        }
    }

    func testPinnedLayouts() throws {
        let parakeet = try XCTUnwrap(LocalModelCatalog.entry(id: "parakeet-tdt-0.6b-v3-coreml"))
        XCTAssertEqual(parakeet.installSubdirectory, "parakeet-tdt-0.6b-v3-coreml")
        let paths = Set(parakeet.files.map(\.path))
        for required in ["parakeet_vocab.json", "Preprocessor.mlmodelc/coremldata.bin", "Encoder.mlmodelc/weights/weight.bin",
                         "Decoder.mlmodelc/weights/weight.bin", "JointDecisionv3.mlmodelc/weights/weight.bin"] {
            XCTAssertTrue(paths.contains(required), required)
        }
        XCTAssertFalse(paths.contains { $0.hasPrefix("EncoderInt4") || $0.hasPrefix("Encoder_v2") || $0.hasPrefix("JointDecisionv2") })
        for id in ["whisper-large-v3-turbo-632mb", "whisper-small-en-217mb"] {
            let whisper = try XCTUnwrap(LocalModelCatalog.entry(id: id))
            let tokenizer = try XCTUnwrap(whisper.files.first { $0.path == "tokenizer.json" })
            XCTAssertTrue(tokenizer.repository?.hasPrefix("openai/whisper-") == true)
            let config = try XCTUnwrap(whisper.files.first { $0.path == "config.json" })
            XCTAssertEqual(whisper.remoteURL(for: config)?.path.contains("/resolve/\(whisper.revision)/\(whisper.sourceSubdirectory!)/config.json"), true)
            XCTAssertEqual(whisper.remoteURL(for: tokenizer)?.path.hasSuffix("/resolve/\(tokenizer.revision!)/tokenizer.json"), true)
        }
        XCTAssertTrue(try XCTUnwrap(LocalModelCatalog.entry(id: "s1-mini")).files.contains { $0.path == "LICENSE" })
    }

    func testPathPolicy() {
        for bad in ["", "/etc/passwd", "../x", "a/../b", "a//b", "a/./b", "a\\b", "x.py", "d/run.SH", "lib.dylib", "x.app/y", "a\0b"] {
            XCTAssertFalse(LocalModelPathPolicy.isSafeRelativePath(bad), bad)
        }
        for good in ["config.json", "Encoder.mlmodelc/weights/weight.bin", "a b/ü.txt"] {
            XCTAssertTrue(LocalModelPathPolicy.isSafeRelativePath(good), good)
        }
        XCTAssertFalse(LocalModelPathPolicy.isSafeIdentifier(".hidden"))
        XCTAssertFalse(LocalModelPathPolicy.isSafeIdentifier("a/b"))
    }
}

#if canImport(CryptoKit)
final class LocalModelStoreTests: XCTestCase {
    private var root: URL!
    private let revision = "0123456789abcdef0123456789abcdef01234567"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalModelStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        StubProtocol.reset()
    }

    override func tearDownWithError() throws {
        StubProtocol.reset()
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Fixtures

    private let contents: [String: Data] = [
        "config.json": Data("{\"a\":1}".utf8),
        "weights/model.bin": Data((0..<200).map { UInt8($0 % 251) }),
        "tokenizer.json": Data("tokens ü 👋\n".utf8),
    ]

    private func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 { digest.map { String(format: "%02x", $0) }.joined() }

    private func entry(id: String = "test-model", files: [String: Data]? = nil, installSubdirectory: String? = nil,
                       sourceSubdirectory: String? = nil) -> LocalModelCatalogEntry {
        let files = files ?? contents
        let pinned = files.keys.sorted().map { path -> LocalModelFile in
            let data = files[path]!
            // Alternate pinning styles so both hash paths run.
            if data.count > 100 { return LocalModelFile(path: path, size: Int64(data.count), sha256: hex(SHA256.hash(data: data))) }
            var blob = Data("blob \(data.count)\0".utf8); blob.append(data)
            return LocalModelFile(path: path, size: Int64(data.count), gitBlobSHA1: hex(Insecure.SHA1.hash(data: blob)))
        }
        return LocalModelCatalogEntry(id: id, displayName: "Test", kind: .mlxLLM, group: .cleanup, repository: "test/model",
                                      revision: revision, sourceSubdirectory: sourceSubdirectory, installSubdirectory: installSubdirectory,
                                      license: "mit", quantization: "none", notes: "", files: pinned)
    }

    private func source(_ files: [String: Data]? = nil, under subdirectory: String? = nil) throws -> URL {
        let folder = root.appendingPathComponent("source-\(UUID().uuidString)")
        var base = folder
        if let subdirectory { base = folder.appendingPathComponent(subdirectory) }
        for (path, data) in files ?? contents {
            let url = base.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        return folder
    }

    private func store(capacity: Int64? = Int64.max) -> LocalModelStore {
        LocalModelStore(root: root.appendingPathComponent("Models")) { _ in capacity }
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func installError(_ body: () async throws -> Void) async -> LocalModelInstallError? {
        do { try await body(); return nil } catch let error as LocalModelInstallError { return error } catch { XCTFail("\(error)"); return nil }
    }

    // MARK: Import

    func testImportPublishesReceiptFingerprintAndIgnoresExtras() async throws {
        let store = store()
        var files = contents
        files["extra-not-in-catalog.txt"] = Data("ignored".utf8)
        let model = try await store.importFolder(try source(files), as: entry())
        XCTAssertEqual(model.source, .import)
        XCTAssertEqual(model.directory, store.root.appendingPathComponent("test-model/\(revision)"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.directory.appendingPathComponent("extra-not-in-catalog.txt").path))
        XCTAssertEqual(try Data(contentsOf: model.directory.appendingPathComponent("weights/model.bin")), contents["weights/model.bin"])
        XCTAssertEqual(store.installed(), [model])
        XCTAssertEqual(store.installed("test-model"), model)
        XCTAssertEqual(model.reference, LocalModelReference(identifier: "test-model", revision: revision, kind: .mlxLLM,
                                                            directory: model.directory.path, fingerprint: model.fingerprint))
        let lines = contents.keys.sorted().map { "\($0)\t\(contents[$0]!.count)\t\(hex(SHA256.hash(data: contents[$0]!)))\n" }.joined()
        XCTAssertEqual(model.fingerprint, hex(SHA256.hash(data: Data(lines.utf8))))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.root.appendingPathComponent(".staging").path).isEmpty)
        let permissions = try FileManager.default.attributesOfItem(atPath: model.directory.appendingPathComponent("config.json").path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions.map { $0 & 0o111 }, 0)
    }

    func testFingerprintIsStableAcrossStores() async throws {
        let first = try await store().importFolder(try source(), as: entry())
        let other = LocalModelStore(root: root.appendingPathComponent("Other")) { _ in Int64.max }
        let second = try await other.importFolder(try source(), as: entry())
        XCTAssertEqual(first.fingerprint, second.fingerprint)
    }

    func testImportInstallSubdirectoryAndSourceSubdirectory() async throws {
        let entry = entry(installSubdirectory: "layout", sourceSubdirectory: "nested")
        let model = try await store().importFolder(try source(under: "nested"), as: entry)
        XCTAssertEqual(model.runtimeDirectory, model.directory.appendingPathComponent("layout"))
        XCTAssertEqual(model.reference.directory, model.runtimeDirectory.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.runtimeDirectory.appendingPathComponent("config.json").path))
    }

    func testImportHashSizeAndMissingFailures() async throws {
        let store = store()
        var tampered = contents
        tampered["weights/model.bin"] = Data(repeating: 7, count: 200)
        var error = await installError { _ = try await store.importFolder(try source(tampered), as: entry()) }
        XCTAssertEqual(error, .hashMismatch("weights/model.bin"))

        var shorter = contents
        shorter["config.json"] = Data("{}".utf8)
        error = await installError { _ = try await store.importFolder(try source(shorter), as: entry()) }
        XCTAssertEqual(error, .sizeMismatch("config.json"))

        var missing = contents
        missing["tokenizer.json"] = nil
        error = await installError { _ = try await store.importFolder(try source(missing), as: entry()) }
        XCTAssertEqual(error, .missingFile("tokenizer.json"))

        XCTAssertTrue(store.installed().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.appendingPathComponent("test-model").path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.root.appendingPathComponent(".staging").path).isEmpty)
    }

    func testUnsafeEntriesAreRejectedBeforeAnyWork() async throws {
        let store = store()
        for path in ["../escape.txt", "/abs.txt", "tool.py", "dir/run.sh", "a/../b.txt"] {
            let bad = entry(files: [path: Data("x".utf8)])
            let error = await installError { _ = try await store.importFolder(try source(), as: bad) }
            XCTAssertEqual(error, .unsafePath(path))
            let downloadError = await installError { _ = try await store.download(bad, session: session()) { _, _ in } }
            XCTAssertEqual(downloadError, .unsafePath(path))
        }
        let badID = entry(id: "../evil")
        let error = await installError { _ = try await store.importFolder(try source(), as: badID) }
        XCTAssertEqual(error, .unsafePath("../evil"))
        XCTAssertThrowsError(try store.remove("../evil"))
    }

    func testSymlinkToRegularFileIsFollowedAndToDirectoryRejected() async throws {
        let store = store()
        let folder = try source()
        let blobs = root.appendingPathComponent("blobs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        let blob = blobs.appendingPathComponent("abc123")
        try contents["config.json"]!.write(to: blob)
        let link = folder.appendingPathComponent("config.json")
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: blob)
        let model = try await store.importFolder(folder, as: entry())
        let installed = model.directory.appendingPathComponent("config.json")
        XCTAssertEqual(try Data(contentsOf: installed), contents["config.json"])
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: installed.path))

        let other = LocalModelStore(root: root.appendingPathComponent("Other")) { _ in Int64.max }
        let directoryFolder = try source()
        try FileManager.default.removeItem(at: directoryFolder.appendingPathComponent("config.json"))
        try FileManager.default.createSymbolicLink(at: directoryFolder.appendingPathComponent("config.json"), withDestinationURL: blobs)
        let error = await installError { _ = try await other.importFolder(directoryFolder, as: entry()) }
        XCTAssertEqual(error, .unsafePath("config.json"))
    }

    func testAlreadyInstalledRemoveAndReinstall() async throws {
        let store = store()
        _ = try await store.importFolder(try source(), as: entry())
        let error = await installError { _ = try await store.importFolder(try source(), as: entry()) }
        XCTAssertEqual(error, .alreadyInstalled)
        try store.remove("test-model")
        XCTAssertTrue(store.installed().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.appendingPathComponent("test-model").path))
        _ = try await store.importFolder(try source(), as: entry())
        XCTAssertNotNil(store.installed("test-model"))
        try store.remove("missing-entry")
    }

    func testCleanStagingRemovesInterruptedDirectories() throws {
        let store = store()
        let leftover = store.root.appendingPathComponent(".staging/test-model-\(revision)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: leftover.appendingPathComponent("a.partial"))
        try store.cleanStaging()
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
        try store.cleanStaging()
    }

    func testInstalledIgnoresCorruptOrMismatchedReceipts() async throws {
        let store = store()
        let model = try await store.importFolder(try source(), as: entry())
        let receipt = model.directory.appendingPathComponent(LocalModelPathPolicy.receiptFileName)
        let original = try Data(contentsOf: receipt)

        try Data("not json".utf8).write(to: receipt)
        XCTAssertTrue(store.installed().isEmpty)

        var text = try XCTUnwrap(String(data: original, encoding: .utf8))
        text = text.replacingOccurrences(of: model.fingerprint, with: String(repeating: "0", count: 64))
        try Data(text.utf8).write(to: receipt)
        XCTAssertNil(store.installed("test-model"))

        try FileManager.default.removeItem(at: receipt)
        XCTAssertTrue(store.installed().isEmpty)
        // A stale directory without a valid receipt does not block a fresh install.
        let reinstalled = try await store.importFolder(try source(), as: entry())
        XCTAssertEqual(reinstalled.fingerprint, model.fingerprint)
    }

    func testVerifyDetectsTamperingAndExtraFiles() async throws {
        let store = store()
        let model = try await store.importFolder(try source(), as: entry())
        try await store.verify(model)

        let file = model.directory.appendingPathComponent("weights/model.bin")
        try Data(repeating: 9, count: 200).write(to: file)
        var error = await installError { try await store.verify(model) }
        XCTAssertEqual(error, .hashMismatch("weights/model.bin"))

        try contents["weights/model.bin"]!.write(to: file)
        try await store.verify(model)
        try Data("x".utf8).write(to: model.directory.appendingPathComponent("injected.txt"))
        error = await installError { try await store.verify(model) }
        XCTAssertEqual(error, .unexpectedFile("injected.txt"))
    }

    func testInsufficientDiskIsCheckedBeforeWork() async throws {
        let store = store(capacity: 10)
        let total = entry().totalBytes
        let importError = await installError { _ = try await store.importFolder(try source(), as: entry()) }
        XCTAssertEqual(importError, .insufficientDisk(required: total + LocalModelStore.headroomBytes, available: 10))
        let downloadError = await installError { _ = try await store.download(entry(), session: session()) { _, _ in } }
        XCTAssertEqual(downloadError, .insufficientDisk(required: total + LocalModelStore.headroomBytes, available: 10))
        XCTAssertTrue(store.installed().isEmpty)
    }

    // MARK: Download

    private func serveContents(record: LockedBox<[URLRequest]>? = nil) {
        let revision = self.revision
        let contents = self.contents
        StubProtocol.handler = { request in
            record?.mutate { $0.append(request) }
            let path = String(request.url!.path.components(separatedBy: "/resolve/\(revision)/").last!)
            guard let data = contents[path] else { return .response(404, [:], Data()) }
            return .response(200, [:], data)
        }
    }

    func testDownloadVerifiesAndPublishes() async throws {
        let store = store()
        let last = LockedBox<[Int64]>([0, 0])
        let requests = LockedBox<[URLRequest]>([])
        serveContents(record: requests)
        let entry = entry()
        let model = try await store.download(entry, session: session()) { last.set([$0, $1]) }
        XCTAssertEqual(model.source, .download)
        XCTAssertEqual(last.get(), [entry.totalBytes, entry.totalBytes])
        XCTAssertEqual(requests.get().count, 3)
        XCTAssertTrue(requests.get().allSatisfy { $0.value(forHTTPHeaderField: "Range") == nil && $0.url?.host == "huggingface.co" })
        XCTAssertEqual(try Data(contentsOf: model.directory.appendingPathComponent("weights/model.bin")), contents["weights/model.bin"])
        XCTAssertEqual(store.installed("test-model")?.fingerprint, model.fingerprint)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.appendingPathComponent(".staging/test-model-\(revision)").path))
        let again = await installError { _ = try await store.download(entry, session: session()) { _, _ in } }
        XCTAssertEqual(again, .alreadyInstalled)
    }

    func testChunkedDeliveryIsHashedAcrossBoundaries() async throws {
        let store = store()
        store.writeChunkBytes = 1000
        let big = Data((0..<5000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let small = Data("git blob pinned, delivered seven bytes at a time".utf8)
        let files = ["big.bin": big, "small.txt": small]
        StubProtocol.handler = { request in
            let data = request.url!.lastPathComponent == "big.bin" ? big : small
            // Uneven sizes that straddle the 1000-byte write boundary.
            let sizes = data.count > 100 ? [1, 999, 1001, 7, 1500, 3000] : [7]
            var parts: [Data] = []
            var index = 0
            var turn = 0
            while index < data.count {
                let size = min(sizes[turn % sizes.count], data.count - index)
                parts.append(data.subdata(in: index..<index + size)); index += size; turn += 1
            }
            return .chunks(200, [:], parts)
        }
        let entry = entry(files: files)
        let progress = LockedBox<[Int64]>([])
        let model = try await store.download(entry, session: session()) { done, _ in progress.mutate { $0.append(done) } }
        XCTAssertEqual(try Data(contentsOf: model.directory.appendingPathComponent("big.bin")), big)
        XCTAssertEqual(try Data(contentsOf: model.directory.appendingPathComponent("small.txt")), small)
        XCTAssertEqual(progress.get().last, entry.totalBytes)
        XCTAssertEqual(progress.get(), progress.get().sorted())
        try await store.verify(model)
    }

    func testDownloadRejectsCorruptBodyAndKeepsNothingPublished() async throws {
        let store = store()
        StubProtocol.handler = { _ in .response(200, [:], Data(repeating: 1, count: 200)) }
        let entry = entry(files: ["weights/model.bin": contents["weights/model.bin"]!])
        let error = await installError { _ = try await store.download(entry, session: session()) { _, _ in } }
        XCTAssertEqual(error, .hashMismatch("weights/model.bin"))
        XCTAssertTrue(store.installed().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.appendingPathComponent("test-model").path))
        // The corrupt file is dropped so a retry downloads it again.
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.appendingPathComponent(".staging/test-model-\(revision)/weights/model.bin").path))
    }

    func testDownloadRejectsOversizedAndHttpErrors() async throws {
        let store = store()
        let entry = entry(files: ["config.json": contents["config.json"]!])
        StubProtocol.handler = { _ in .response(200, [:], Data(repeating: 1, count: 500)) }
        var error = await installError { _ = try await store.download(entry, session: session()) { _, _ in } }
        XCTAssertEqual(error, .sizeMismatch("config.json"))
        StubProtocol.handler = { _ in .response(503, [:], Data()) }
        error = await installError { _ = try await store.download(entry, session: session()) { _, _ in } }
        XCTAssertEqual(error, .network("HTTP 503"))
        XCTAssertTrue(store.installed().isEmpty)
    }

    func testDownloadResumesFromPartialWithRange() async throws {
        let store = store()
        let entry = entry(files: ["weights/model.bin": contents["weights/model.bin"]!])
        let full = contents["weights/model.bin"]!
        let partial = store.root.appendingPathComponent(".staging/test-model-\(revision)/weights/model.bin.partial")
        try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        try full.prefix(80).write(to: partial)
        let requests = LockedBox<[URLRequest]>([])
        StubProtocol.handler = { request in
            requests.mutate { $0.append(request) }
            guard request.value(forHTTPHeaderField: "Range") == "bytes=80-" else { return .response(200, [:], full) }
            return .response(206, ["Content-Range": "bytes 80-199/200"], full.suffix(from: 80))
        }
        let first = LockedBox<Int64>(-1)
        let model = try await store.download(entry, session: session()) { done, _ in if first.get() < 0 { first.set(done) } }
        XCTAssertEqual(requests.get().count, 1)
        XCTAssertEqual(requests.get().first?.value(forHTTPHeaderField: "Range"), "bytes=80-")
        XCTAssertEqual(try Data(contentsOf: model.directory.appendingPathComponent("weights/model.bin")), full)
        XCTAssertGreaterThanOrEqual(first.get(), 80)
    }

    func testDownloadRestartsWhenServerIgnoresRange() async throws {
        let store = store()
        let full = contents["weights/model.bin"]!
        let entry = entry(files: ["weights/model.bin": full])
        let partial = store.root.appendingPathComponent(".staging/test-model-\(revision)/weights/model.bin.partial")
        try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xEE, count: 50).write(to: partial)
        StubProtocol.handler = { _ in .response(200, [:], full) }
        let model = try await store.download(entry, session: session()) { _, _ in }
        XCTAssertEqual(try Data(contentsOf: model.directory.appendingPathComponent("weights/model.bin")), full)
    }

    func testRedirectToOtherHostIsRejectedAndToHuggingFaceCDNFollowed() async throws {
        let entry = entry(files: ["config.json": contents["config.json"]!])
        StubProtocol.handler = { _ in .redirect(URL(string: "https://evil.example.com/config.json")!) }
        let rejecting = store()
        let error = await installError { _ = try await rejecting.download(entry, session: session()) { _, _ in } }
        XCTAssertEqual(error, .network("redirect host not allowed: evil.example.com"))
        XCTAssertTrue(rejecting.installed().isEmpty)

        let data = contents["config.json"]!
        StubProtocol.handler = { request in
            request.url?.host == "huggingface.co" ? .redirect(URL(string: "https://cdn-lfs-us-1.hf.co/blob")!) : .response(200, [:], data)
        }
        let following = LocalModelStore(root: root.appendingPathComponent("Other")) { _ in Int64.max }
        let model = try await following.download(entry, session: session()) { _, _ in }
        XCTAssertNotNil(following.installed(model.entryID))

        XCTAssertTrue(LocalModelStore.isAllowedSource(URL(string: "https://huggingface.co/a")!))
        XCTAssertTrue(LocalModelStore.isAllowedSource(URL(string: "https://cas-bridge.xethub.hf.co/a")!))
        XCTAssertFalse(LocalModelStore.isAllowedSource(URL(string: "https://evilhf.co/a")!))
        XCTAssertFalse(LocalModelStore.isAllowedSource(URL(string: "http://huggingface.co/a")!))
        XCTAssertFalse(LocalModelStore.isAllowedSource(URL(string: "https://huggingface.co.evil.com/a")!))
    }

    func testCancellationLeavesNothingPublished() async throws {
        let store = store()
        store.writeChunkBytes = 4
        serveContents()
        let box = CancelBox()
        let entry = entry()
        let storeCopy = store
        let sessionCopy = session()
        let task = Task { try await storeCopy.download(entry, session: sessionCopy) { done, _ in if done > 0 { box.cancel() } } }
        box.set(task)
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertEqual(error as? LocalModelInstallError, .canceled)
        }
        XCTAssertTrue(store.installed().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.appendingPathComponent("test-model").path))
        // Staging survives for resume until it is cleaned explicitly.
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.root.appendingPathComponent(".staging/test-model-\(revision)").path))
        try store.cleanStaging()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.appendingPathComponent(".staging/test-model-\(revision)").path))
    }
}

// MARK: Test doubles

private final class LockedBox<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func set(_ new: Value) { lock.withLock { value = new } }
    func mutate(_ change: (inout Value) -> Void) { lock.withLock { change(&value) } }
}

private final class CancelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<InstalledLocalModel, Error>?
    private var pending = false
    func set(_ task: Task<InstalledLocalModel, Error>) {
        lock.lock(); defer { lock.unlock() }
        self.task = task
        if pending { task.cancel() }
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        pending = true
        task?.cancel()
    }
}

private enum StubResult {
    case response(Int, [String: String], Data)
    case chunks(Int, [String: String], [Data])
    case redirect(URL)
}

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedHandler: (@Sendable (URLRequest) -> StubResult)?
    static var handler: (@Sendable (URLRequest) -> StubResult)? {
        get { lock.withLock { storedHandler } }
        set { lock.withLock { storedHandler = newValue } }
    }
    static func reset() { handler = nil }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let result = Self.handler?(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        switch result {
        case let .response(status, headers, body):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case let .chunks(status, headers, parts):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for part in parts { client?.urlProtocol(self, didLoad: part) }
            client?.urlProtocolDidFinishLoading(self)
        case let .redirect(target):
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            var next = URLRequest(url: target)
            next.allHTTPHeaderFields = request.allHTTPHeaderFields
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
        }
    }

    override func stopLoading() {}
}
#endif
