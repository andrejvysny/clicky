#if canImport(CryptoKit)
import CryptoKit
import Foundation

nonisolated public struct InstalledLocalModel: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case download, `import` }

    public let entryID: String
    public let revision: String
    public let kind: LocalModelKind
    /// Published install root `<store>/<entryID>/<revision>`.
    public let directory: URL
    public let installSubdirectory: String?
    public let fingerprint: String
    public let installedAt: Date
    public let source: Source

    /// Directory the runtime loads (the install root plus the layout the runtime expects).
    public var runtimeDirectory: URL {
        installSubdirectory.map { directory.appendingPathComponent($0, isDirectory: true) } ?? directory
    }

    public var reference: LocalModelReference {
        LocalModelReference(identifier: entryID, revision: revision, kind: kind, directory: runtimeDirectory.path, fingerprint: fingerprint)
    }
}

nonisolated public enum LocalModelInstallError: Error, Equatable {
    case insufficientDisk(required: Int64, available: Int64)
    case unsafePath(String)
    case missingFile(String)
    case sizeMismatch(String)
    case hashMismatch(String)
    case unexpectedFile(String)
    case canceled
    case network(String)
    case alreadyInstalled
    /// Another install or removal of the same entry is running in this store.
    case inProgress
}

/// Verified local model storage. Nothing is downloaded or imported unless a caller asks; every file is size- and
/// hash-checked in a staging directory before one rename publishes the whole install. Never logs.
nonisolated public final class LocalModelStore: @unchecked Sendable {
    public static let headroomBytes: Int64 = 1 << 30

    public let root: URL
    private let capacityProvider: @Sendable (URL) -> Int64?
    private let lock = NSLock()
    private var active = Set<String>()
    /// Bytes buffered before a disk write, progress report and cancellation check.
    var writeChunkBytes = 1 << 20

    public init(root: URL, capacityProvider: @escaping @Sendable (URL) -> Int64? = LocalModelStore.systemCapacity) {
        self.root = root
        self.capacityProvider = capacityProvider
    }

    public static func systemCapacity(_ url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    // MARK: Queries

    public func installed() -> [InstalledLocalModel] {
        var models: [InstalledLocalModel] = []
        // Directories are rebuilt from names so they match the URLs publish returns (no /private/var rewriting).
        for entryID in subdirectoryNames(of: root) where !entryID.hasPrefix(".") {
            let entryDirectory = root.appendingPathComponent(entryID, isDirectory: true)
            for revision in subdirectoryNames(of: entryDirectory) {
                if let loaded = loadReceipt(at: installDirectory(entryID, revision)) { models.append(loaded.model) }
            }
        }
        return models.sorted { ($0.entryID, $0.revision) < ($1.entryID, $1.revision) }
    }

    public func installed(_ entryID: String) -> InstalledLocalModel? {
        installed().filter { $0.entryID == entryID }.max { $0.installedAt < $1.installedAt }
    }

    // MARK: Install

    public func importFolder(_ folder: URL, as entry: LocalModelCatalogEntry) async throws -> InstalledLocalModel {
        do {
            return try await importUnmapped(folder, entry: entry)
        } catch { throw Self.mapped(error) }
    }

    public func verify(_ model: InstalledLocalModel) async throws {
        do {
            guard let loaded = loadReceipt(at: model.directory), loaded.model.fingerprint == model.fingerprint else {
                throw LocalModelInstallError.hashMismatch(LocalModelPathPolicy.receiptFileName)
            }
            for file in loaded.manifest {
                try Self.verifyFile(model.directory.appendingPathComponent(file.path), expected: file.asCatalogFile)
            }
            try Self.rejectUnexpected(in: model.directory, expected: Set(loaded.manifest.map(\.path)).union([LocalModelPathPolicy.receiptFileName]))
        } catch { throw Self.mapped(error) }
    }

    public func remove(_ entryID: String) throws {
        guard LocalModelPathPolicy.isSafeIdentifier(entryID) else { throw LocalModelInstallError.unsafePath(entryID) }
        guard acquire(entryID) else { throw LocalModelInstallError.inProgress }
        defer { release(entryID) }
        let directory = root.appendingPathComponent(entryID, isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    /// Removes interrupted staging directories, except those of installs running in this store.
    public func cleanStaging() throws {
        let staging = stagingRoot
        guard FileManager.default.fileExists(atPath: staging.path) else { return }
        let running = lock.withLock { active }
        for child in try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil) {
            if running.contains(where: { child.lastPathComponent.hasPrefix($0 + "-") }) { continue }
            try FileManager.default.removeItem(at: child)
        }
    }

    // MARK: Import

    private func importUnmapped(_ folder: URL, entry: LocalModelCatalogEntry) async throws -> InstalledLocalModel {
        try Self.validate(entry)
        guard acquire(entry.id) else { throw LocalModelInstallError.inProgress }
        defer { release(entry.id) }
        try prepareRoot(for: entry)
        try requireCapacity(remaining: entry.totalBytes)
        let fileManager = FileManager.default
        let staging = stagingRoot.appendingPathComponent("\(entry.id)-\(entry.revision)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            for file in entry.files {
                try Task.checkCancellation()
                let source = try Self.resolveImportSource(for: file, of: entry, in: folder)
                let destination = staging.appendingPathComponent(entry.installPath(for: file))
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.copyItem(at: source, to: destination)
                try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destination.path)
            }
            return try publish(entry, staging: staging, source: .import)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    private static func resolveImportSource(for file: LocalModelFile, of entry: LocalModelCatalogEntry, in folder: URL) throws -> URL {
        var candidates = [folder.appendingPathComponent(file.path)]
        if file.repository == nil, let sub = entry.sourceSubdirectory {
            candidates.append(folder.appendingPathComponent(sub).appendingPathComponent(file.path))
        }
        for candidate in candidates {
            // Hugging Face cache snapshots are symlinks into ../../blobs: follow them, but the target must be a regular file.
            let resolved = candidate.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory) else { continue }
            let regular = (try? resolved.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            guard !isDirectory.boolValue, regular else { throw LocalModelInstallError.unsafePath(file.path) }
            return resolved
        }
        throw LocalModelInstallError.missingFile(file.path)
    }

    // MARK: Verify and publish

    func publish(_ entry: LocalModelCatalogEntry, staging: URL, source: InstalledLocalModel.Source,
                         streamed: [String: FileDigest] = [:]) throws -> InstalledLocalModel {
        var manifest: [ReceiptFile] = []
        for file in entry.files {
            let installPath = entry.installPath(for: file)
            let url = staging.appendingPathComponent(installPath)
            do {
                let digest: String
                if let known = streamed[installPath], Self.fileSize(url) == file.size {
                    try known.check(against: file)
                    digest = known.sha256
                } else {
                    digest = try Self.verifyFile(url, expected: file)
                }
                manifest.append(ReceiptFile(path: installPath, size: file.size, sha256: digest))
            } catch let error as LocalModelInstallError {
                // A corrupt staged file must not survive into a resumed download.
                if case .hashMismatch = error { try? FileManager.default.removeItem(at: url) }
                throw error
            }
        }
        manifest.sort { $0.path < $1.path }
        try Self.rejectUnexpected(in: staging, expected: Set(manifest.map(\.path)))

        let receipt = Receipt(schema: 1, entryID: entry.id, revision: entry.revision, kind: entry.kind,
                              installSubdirectory: entry.installSubdirectory, fingerprint: Self.fingerprint(of: manifest),
                              installedAt: Date(), source: source, files: manifest)
        try JSONEncoder().encode(receipt).write(to: staging.appendingPathComponent(LocalModelPathPolicy.receiptFileName), options: .atomic)

        let final = installDirectory(entry.id, entry.revision)
        try FileManager.default.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: final.path) else { throw LocalModelInstallError.alreadyInstalled }
        try FileManager.default.moveItem(at: staging, to: final)
        return receipt.model(directory: final)
    }

    /// Streams the file once: size, SHA-256 (always) and git blob SHA-1 (when pinned that way). Returns the SHA-256.
    @discardableResult
    private static func verifyFile(_ url: URL, expected file: LocalModelFile) throws -> String {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { throw LocalModelInstallError.missingFile(file.path) }
        guard values.isSymbolicLink != true else { throw LocalModelInstallError.unsafePath(file.path) }
        guard values.isRegularFile == true else { throw LocalModelInstallError.missingFile(file.path) }
        guard Int64(values.fileSize ?? -1) == file.size else { throw LocalModelInstallError.sizeMismatch(file.path) }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var accumulator = DigestAccumulator(for: file)
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            try Task.checkCancellation()
            accumulator.update(chunk)
        }
        let digest = accumulator.finalize()
        try digest.check(against: file)
        return digest.sha256
    }

    /// Every file under `directory` must be expected; symlinks are never allowed in an install.
    private static func rejectUnexpected(in directory: URL, expected: Set<String>) throws {
        let fileManager = FileManager.default
        for relative in (try? fileManager.subpathsOfDirectory(atPath: directory.path)) ?? [] {
            // attributesOfItem uses lstat, so a symlink reports as one.
            let type = try? fileManager.attributesOfItem(atPath: directory.appendingPathComponent(relative).path)[.type] as? FileAttributeType
            if type == .typeSymbolicLink { throw LocalModelInstallError.unsafePath(relative) }
            if type == .typeRegular, !expected.contains(relative) { throw LocalModelInstallError.unexpectedFile(relative) }
        }
    }

    private static func fingerprint(of manifest: [ReceiptFile]) -> String {
        let lines = manifest.sorted { $0.path < $1.path }.map { "\($0.path)\t\($0.size)\t\($0.sha256)\n" }.joined()
        return hex(SHA256.hash(data: Data(lines.utf8)))
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Receipts

    nonisolated private struct ReceiptFile: Codable {
        let path: String
        let size: Int64
        let sha256: String
        var asCatalogFile: LocalModelFile { LocalModelFile(path: path, size: size, sha256: sha256) }
    }

    nonisolated private struct Receipt: Codable {
        let schema: Int
        let entryID: String
        let revision: String
        let kind: LocalModelKind
        let installSubdirectory: String?
        let fingerprint: String
        let installedAt: Date
        let source: InstalledLocalModel.Source
        let files: [ReceiptFile]

        func model(directory: URL) -> InstalledLocalModel {
            InstalledLocalModel(entryID: entryID, revision: revision, kind: kind, directory: directory,
                                installSubdirectory: installSubdirectory, fingerprint: fingerprint,
                                installedAt: installedAt, source: source)
        }
    }

    /// Valid only when it decodes, names its own directory and its fingerprint matches its manifest.
    private func loadReceipt(at directory: URL) -> (model: InstalledLocalModel, manifest: [ReceiptFile])? {
        let url = directory.appendingPathComponent(LocalModelPathPolicy.receiptFileName)
        guard let data = try? Data(contentsOf: url), let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
              receipt.schema == 1,
              receipt.revision == directory.lastPathComponent,
              receipt.entryID == directory.deletingLastPathComponent().lastPathComponent,
              receipt.fingerprint == Self.fingerprint(of: receipt.files),
              receipt.files.allSatisfy({ LocalModelPathPolicy.isSafeRelativePath($0.path) })
        else { return nil }
        return (receipt.model(directory: directory), receipt.files)
    }

    // MARK: Helpers

    var stagingRoot: URL { root.appendingPathComponent(".staging", isDirectory: true) }

    private func installDirectory(_ entryID: String, _ revision: String) -> URL {
        root.appendingPathComponent(entryID, isDirectory: true).appendingPathComponent(revision, isDirectory: true)
    }

    private func subdirectoryNames(of directory: URL) -> [String] {
        let children = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return children.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }.map(\.lastPathComponent)
    }

    func acquire(_ entryID: String) -> Bool { lock.withLock { active.insert(entryID).inserted } }
    func release(_ entryID: String) { lock.withLock { _ = active.remove(entryID) } }

    static func validate(_ entry: LocalModelCatalogEntry) throws {
        if let violation = LocalModelPathPolicy.violation(in: entry) { throw LocalModelInstallError.unsafePath(violation) }
    }

    /// Creates the root, rejects an existing valid install and clears an invalid leftover at the final path.
    func prepareRoot(for entry: LocalModelCatalogEntry) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let final = installDirectory(entry.id, entry.revision)
        guard FileManager.default.fileExists(atPath: final.path) else { return }
        if loadReceipt(at: final) != nil { throw LocalModelInstallError.alreadyInstalled }
        try FileManager.default.removeItem(at: final)
    }

    func requireCapacity(remaining: Int64) throws {
        let required = remaining + Self.headroomBytes
        if let available = capacityProvider(root), available < required {
            throw LocalModelInstallError.insufficientDisk(required: required, available: available)
        }
    }

    static func fileSize(_ url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true else { return nil }
        return values.fileSize.map(Int64.init)
    }

    /// Hugging Face and its redirect CDNs only, over HTTPS.
    static func isAllowedSource(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host == "huggingface.co" || host == "hf.co" || host.hasSuffix(".huggingface.co") || host.hasSuffix(".hf.co")
    }

    static func mapped(_ error: Error) -> Error {
        if error is CancellationError { return LocalModelInstallError.canceled }
        if let urlError = error as? URLError {
            return urlError.code == .cancelled ? LocalModelInstallError.canceled : LocalModelInstallError.network(urlError.localizedDescription)
        }
        return error
    }
}
#endif
