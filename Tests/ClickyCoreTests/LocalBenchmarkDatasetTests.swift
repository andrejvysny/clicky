import XCTest
@testable import ClickyCore

final class LocalBenchmarkDatasetTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clicky-dataset-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testWAVRoundTripAndHeaderFields() throws {
        let url = try temporaryDirectory().appendingPathComponent("a.wav")
        let samples: [Int16] = [0, 1, -1, 32767, -32768, 1234]
        try WAVFile.write(samples, to: url)
        let decoded = try WAVFile.read(url)
        XCTAssertEqual(decoded.samples, samples)
        XCTAssertEqual(decoded.sampleRate, 16000)
        XCTAssertEqual(decoded.channels, 1)
        let bytes = [UInt8](try Data(contentsOf: url))
        XCTAssertEqual(bytes.count, 44 + samples.count * 2)
        XCTAssertEqual(String(decoding: bytes[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(Int(bytes[4]) | Int(bytes[5]) << 8, 36 + samples.count * 2)
        XCTAssertEqual(bytes[20], 1)   // PCM
        XCTAssertEqual(bytes[22], 1)   // mono
        XCTAssertEqual(bytes[34], 16)  // bits per sample
    }

    func testReadRejectsNonPCM16() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("a.wav")
        try WAVFile.write([1, 2, 3], to: url)
        var bytes = [UInt8](try Data(contentsOf: url))
        bytes[20] = 3   // IEEE float
        try Data(bytes).write(to: url)
        XCTAssertThrowsError(try WAVFile.read(url))
        bytes[20] = 1; bytes[34] = 8
        try Data(bytes).write(to: url)
        XCTAssertThrowsError(try WAVFile.read(url))
        try Data("not a wav file at all".utf8).write(to: url)
        XCTAssertThrowsError(try WAVFile.read(url))
    }

    func testPersonalDatasetLifecycle() throws {
        let root = try temporaryDirectory().appendingPathComponent("personal")
        let dataset = LocalPersonalDataset(root: root)
        XCTAssertEqual(try dataset.samples(), [])
        let audio = [Int16](repeating: 7, count: 160)
        var sample = try dataset.add(audio, rawReference: "uh hello", cleanReference: nil, split: .development, tags: ["note"])
        XCTAssertTrue(sample.id.hasPrefix("p-"))
        XCTAssertEqual(sample.id.count, 10)
        XCTAssertEqual(sample.audioFile, sample.id + ".wav")
        XCTAssertNil(sample.approvedAt)
        XCTAssertEqual(try dataset.audio(for: sample), audio)
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        XCTAssertEqual((attributes[.posixPermissions] as? Int ?? 0) & 0o777, 0o700)

        XCTAssertThrowsError(try dataset.approve(sample.id, at: Date()))   // clean reference missing
        sample.cleanReference = "hello"
        try dataset.update(sample)
        try dataset.approve(sample.id, at: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(try dataset.samples().first?.approvedAt, Date(timeIntervalSince1970: 100))
        XCTAssertTrue(try dataset.samples()[0].isApproved)

        var tampered = try dataset.samples()[0]
        tampered.audioFile = "other.wav"
        XCTAssertThrowsError(try dataset.update(tampered))
        var blank = try dataset.samples()[0]
        blank.cleanReference = "  "
        XCTAssertThrowsError(try dataset.update(blank))   // approved sample cannot lose a reference

        XCTAssertEqual(try LocalPersonalDataset(root: root).samples().count, 1)
        try dataset.delete(sample.id)
        XCTAssertEqual(try dataset.samples(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dataset.url(for: sample).path))
        XCTAssertThrowsError(try dataset.delete(sample.id))
    }

    func testTraversalNamesAreNeverResolved() throws {
        let root = try temporaryDirectory().appendingPathComponent("personal")
        let dataset = LocalPersonalDataset(root: root)
        _ = try dataset.add([1, 2], rawReference: "a", cleanReference: "a", split: .heldOut, tags: [])
        let evil = LocalBenchmarkSample(id: "p-evil", audioFile: "../../etc/passwd", rawReference: "a", cleanReference: "a", split: .heldOut)
        XCTAssertEqual(dataset.url(for: evil).deletingLastPathComponent().path, root.path)
        XCTAssertThrowsError(try dataset.audio(for: evil))
        // A hand-edited index with an unsafe entry drops it.
        let index = #"[{"id":"p-1","audioFile":"../x.wav","split":"heldOut","tags":[]}]"#
        try Data(index.utf8).write(to: root.appendingPathComponent("index.json"))
        XCTAssertEqual(try dataset.samples(), [])
    }

    private func seedCorruptIndex(_ root: URL) throws -> Data {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bytes = Data("{ not json".utf8)
        try bytes.write(to: root.appendingPathComponent("index.json"))
        return bytes
    }

    func testCorruptIndexIsRefusedAndNeverOverwritten() throws {
        let root = try temporaryDirectory().appendingPathComponent("personal")
        let bytes = try seedCorruptIndex(root)
        let dataset = LocalPersonalDataset(root: root)
        XCTAssertThrowsError(try dataset.samples()) { XCTAssertEqual($0 as? LocalDatasetError, .indexCorrupt) }
        XCTAssertThrowsError(try dataset.add([1, 2], rawReference: nil, cleanReference: nil, split: .development, tags: [])) {
            XCTAssertEqual($0 as? LocalDatasetError, .indexCorrupt)
        }
        XCTAssertThrowsError(try dataset.delete("p-1"))
        XCTAssertThrowsError(try dataset.approve("p-1", at: Date()))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("index.json")), bytes)
        let wavs = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".wav") }
        XCTAssertEqual(wavs, [])
    }

    func testMissingIndexIsEmptyWithoutCreatingRoot() throws {
        let root = try temporaryDirectory().appendingPathComponent("personal")
        XCTAssertEqual(try LocalPersonalDataset(root: root).samples(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testConcurrentAddsFromTwoInstancesKeepEverySample() throws {
        let root = try temporaryDirectory().appendingPathComponent("personal")
        let instances = [LocalPersonalDataset(root: root), LocalPersonalDataset(root: root)]
        let failures = NSLock()
        var errors: [Error] = []
        DispatchQueue.concurrentPerform(iterations: 40) { iteration in
            do { _ = try instances[iteration % 2].add([Int16(iteration)], rawReference: nil, cleanReference: nil, split: .development, tags: []) }
            catch { failures.lock(); errors.append(error); failures.unlock() }
        }
        XCTAssertTrue(errors.isEmpty, "\(errors)")
        let all = try instances[0].samples()
        XCTAssertEqual(all.count, 40)
        XCTAssertEqual(Set(all.map(\.id)).count, 40)
    }

    func testSaveAndDeleteOverlapKeepIndexConsistent() throws {
        let root = try temporaryDirectory().appendingPathComponent("personal")
        let dataset = LocalPersonalDataset(root: root)
        let doomed = try (0..<10).map { _ in try dataset.add([1], rawReference: nil, cleanReference: nil, split: .development, tags: []) }
        let other = LocalPersonalDataset(root: root)
        DispatchQueue.concurrentPerform(iterations: 20) { iteration in
            if iteration % 2 == 0 { _ = try? other.add([2], rawReference: nil, cleanReference: nil, split: .development, tags: []) }
            else { try? dataset.delete(doomed[iteration / 2].id) }
        }
        let remaining = try dataset.samples()
        XCTAssertEqual(remaining.count, 10)
        XCTAssertTrue(remaining.allSatisfy { sample in doomed.allSatisfy { $0.id != sample.id } })
        for sample in remaining { XCTAssertTrue(FileManager.default.fileExists(atPath: dataset.url(for: sample).path)) }
    }

    func testBackUpCorruptIndexRenamesAndKeepsAudio() throws {
        let root = try temporaryDirectory().appendingPathComponent("personal")
        let dataset = LocalPersonalDataset(root: root)
        let sample = try dataset.add([5, 6], rawReference: nil, cleanReference: nil, split: .development, tags: [])
        let bytes = Data("garbage".utf8)
        try bytes.write(to: root.appendingPathComponent("index.json"))
        let now = Date(timeIntervalSince1970: 1_000_000)
        let first = try dataset.backUpCorruptIndex(now: now)
        XCTAssertTrue(first.lastPathComponent.hasPrefix("index.corrupt-"))
        XCTAssertEqual(try Data(contentsOf: first), bytes)
        XCTAssertEqual(try dataset.samples(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dataset.url(for: sample).path))
        try Data("again".utf8).write(to: root.appendingPathComponent("index.json"))
        let second = try dataset.backUpCorruptIndex(now: now)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: first), bytes)
        XCTAssertThrowsError(try dataset.backUpCorruptIndex(now: now))   // nothing left to back up
    }

    func testLeftoverTempFileDoesNotBreakLoading() throws {
        let root = try temporaryDirectory().appendingPathComponent("personal")
        let dataset = LocalPersonalDataset(root: root)
        _ = try dataset.add([1], rawReference: nil, cleanReference: nil, split: .development, tags: [])
        try Data("partial".utf8).write(to: root.appendingPathComponent("index.json.tmp.1234"))
        XCTAssertEqual(try dataset.samples().count, 1)
        _ = try dataset.add([2], rawReference: nil, cleanReference: nil, split: .development, tags: [])
        XCTAssertEqual(try dataset.samples().count, 2)
    }

    func testCSVQuotingAndPublicLoad() throws {
        let directory = try temporaryDirectory()
        let audio = directory.appendingPathComponent("data/audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        try WAVFile.write([1, 2, 3], to: audio.appendingPathComponent("t-1.wav"))
        let manifest = directory.appendingPathComponent("data/full_manifest.csv")
        let csv = "id,audio_path,raw_reference,clean_reference,duration_seconds\r\n"
            + "t-1,data/audio/t-1.wav,\"Well, \"\"hello\"\", uh, there\",\"Hello, there\",1.5\n"
            + "t-2,data/audio/t-2.wav,plain,plain,2.0\n"
        try Data(csv.utf8).write(to: manifest)
        try Data(#"{"dataset":"disfluency_speech","revision":"abc123"}"#.utf8).write(to: directory.appendingPathComponent("data/dataset_info.json"))
        let dataset = try LocalPublicDataset.loadDisfluency(manifest: manifest)
        XCTAssertEqual(dataset.samples.map(\.id), ["t-1", "t-2"])
        XCTAssertEqual(dataset.samples[0].rawReference, "Well, \"hello\", uh, there")
        XCTAssertEqual(dataset.samples[0].cleanReference, "Hello, there")
        XCTAssertEqual(dataset.revision, "abc123")
        XCTAssertEqual(dataset.root.standardizedFileURL.path, directory.standardizedFileURL.path)
        XCTAssertTrue(dataset.samples.allSatisfy { $0.split == .heldOut && $0.approvedAt == Date(timeIntervalSince1970: 0) && $0.isApproved })
        XCTAssertEqual(try WAVFile.read(dataset.url(for: dataset.samples[0])).samples, [1, 2, 3])

        let bad = "id,audio_path,raw_reference,clean_reference\nx,../../secret.wav,a,b\n"
        try Data(bad.utf8).write(to: manifest)
        XCTAssertThrowsError(try LocalPublicDataset.loadDisfluency(manifest: manifest))
    }

    func testSelectionIsDeterministic() {
        let samples = (0..<30).map { LocalBenchmarkSample(id: "s-\($0)", audioFile: "a/\($0).wav", rawReference: "r", cleanReference: "c", split: .heldOut) }
        let dataset = LocalPublicDataset(name: "d", revision: nil, samples: samples, root: URL(fileURLWithPath: "/tmp"))
        let first = dataset.select(ids: nil, count: 10, seed: 42)
        XCTAssertEqual(first, dataset.select(ids: nil, count: 10, seed: 42))
        XCTAssertEqual(first.count, 10)
        XCTAssertEqual(Set(first.map(\.id)).count, 10)
        XCTAssertNotEqual(first.map(\.id), dataset.select(ids: nil, count: 10, seed: 43).map(\.id))
        XCTAssertEqual(dataset.select(ids: ["s-5", "nope", "s-2"], count: 3, seed: 1).map(\.id), ["s-5", "s-2"])
        XCTAssertEqual(dataset.select(ids: nil, count: nil, seed: 1).count, 30)
    }

    func testRunOneSubsetLoadsWhenPresent() throws {
        let manifest = URL(fileURLWithPath: "/Users/andrejvysny/workspace/voice-benchmark/data/disfluency_speech/test/full_manifest.csv")
        guard FileManager.default.fileExists(atPath: manifest.path) else { throw XCTSkip("voice-benchmark dataset not present") }
        let dataset = try LocalPublicDataset.loadDisfluency(manifest: manifest)
        XCTAssertEqual(dataset.samples.count, 250)
        XCTAssertNotNil(dataset.revision)
        let ids = ["test-0044", "test-0098", "test-0184", "test-0123", "test-0121", "test-0167", "test-0009", "test-0176", "test-0197", "test-0113"]
        let subset = dataset.select(ids: ids, count: nil, seed: 0)
        XCTAssertEqual(subset.map(\.id), ids)
        let decoded = try WAVFile.read(dataset.url(for: subset[0]))
        XCTAssertEqual(decoded.sampleRate, 16000)
    }
}
