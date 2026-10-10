import Foundation

nonisolated public enum LocalDatasetError: Error, Equatable, Sendable {
    case unsafeName(String)
    case unsupportedAudio(String)
    case unknownSample(String)
    case notApprovable(String)
    case audioFileChanged(String)
    case invalidManifest(String)
    case io(String)
    case indexCorrupt
}

extension LocalDatasetError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsafeName(let name): return "Unsafe file name: \(name)."
        case .unsupportedAudio(let message), .invalidManifest(let message), .io(let message): return message
        case .unknownSample(let id): return "Unknown sample \(id)."
        case .notApprovable(let id): return "Sample \(id) needs both references before approval."
        case .audioFileChanged(let id): return "The audio file of sample \(id) cannot change."
        case .indexCorrupt: return "The dataset index is damaged. Back it up and start a new index to continue."
        }
    }
}

/// PCM16 RIFF/WAVE reader and writer. Only 16-bit integer PCM is accepted; callers downmix stereo themselves.
nonisolated public enum WAVFile {
    public static func write(_ samples: [Int16], sampleRate: Int = 16000, to url: URL) throws {
        let dataBytes = samples.count * 2
        guard dataBytes <= Int(UInt32.max) - 36, sampleRate > 0, sampleRate <= Int(UInt32.max) else {
            throw LocalDatasetError.unsupportedAudio("Audio is too large or has an invalid sample rate.")
        }
        var data = Data(capacity: 44 + dataBytes)
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append32(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append32(16)
        append16(1); append16(1); append32(UInt32(sampleRate)); append32(UInt32(sampleRate * 2)); append16(2); append16(16)
        data.append(contentsOf: Array("data".utf8)); append32(UInt32(dataBytes))
        for sample in samples { append16(UInt16(bitPattern: sample)) }
        do { try data.write(to: url, options: .atomic) } catch { throw LocalDatasetError.io("Could not write the audio file.") }
    }

    public static func read(_ url: URL) throws -> (samples: [Int16], sampleRate: Int, channels: Int) {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw LocalDatasetError.io("Could not read the audio file.") }
        let bytes = [UInt8](data)
        func u16(_ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
        func u32(_ offset: Int) -> Int { u16(offset) | u16(offset + 2) << 16 }
        guard bytes.count >= 12, Array(bytes[0..<4]) == Array("RIFF".utf8), Array(bytes[8..<12]) == Array("WAVE".utf8) else {
            throw LocalDatasetError.unsupportedAudio("Not a RIFF/WAVE file.")
        }
        var format: (tag: Int, channels: Int, rate: Int, bits: Int)?
        var offset = 12
        while offset + 8 <= bytes.count {
            let id = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
            let size = u32(offset + 4)
            let body = offset + 8
            if id == "fmt " {
                guard size >= 16, body + 16 <= bytes.count else { throw LocalDatasetError.unsupportedAudio("Truncated format chunk.") }
                format = (u16(body), u16(body + 2), u32(body + 4), u16(body + 14))
            } else if id == "data" {
                guard let format else { throw LocalDatasetError.unsupportedAudio("Data chunk before format chunk.") }
                guard format.tag == 1, format.bits == 16 else { throw LocalDatasetError.unsupportedAudio("Only 16-bit PCM WAV is supported.") }
                guard format.channels == 1 || format.channels == 2, format.rate > 0 else {
                    throw LocalDatasetError.unsupportedAudio("Only mono or stereo WAV is supported.")
                }
                // Tolerate a data size that overruns the file (streamed writers): use what is present.
                let available = min(size, bytes.count - body)
                let count = available / 2
                var samples = [Int16](repeating: 0, count: count)
                for index in 0..<count { samples[index] = Int16(bitPattern: UInt16(u16(body + index * 2))) }
                return (samples, format.rate, format.channels)
            }
            offset = body + size + (size & 1)
        }
        throw LocalDatasetError.unsupportedAudio("No audio data chunk.")
    }
}

nonisolated enum DatasetNames {
    /// Single path component made of letters, digits, '-', '_' and inner dots; never starts with a dot.
    static func isSafe(_ name: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._")
        return !name.isEmpty && name.count <= 128 && !name.hasPrefix(".") && name.unicodeScalars.allSatisfy(allowed.contains)
    }
}

/// Personal dataset under `root` (normally ~/Library/Application Support/Clicky/Benchmarks/personal): `index.json`
/// plus one WAV per sample. Directory mode is 0700. Nothing here is ever committed or uploaded.
nonisolated public final class LocalPersonalDataset: @unchecked Sendable {
    public let root: URL
    private let lock = NSLock()

    public init(root: URL) { self.root = root }

    private var indexURL: URL { root.appendingPathComponent("index.json") }

    /// In-process NSLock plus an flock on `<root>/.lock` so the Lab and the CLI never interleave read-modify-write cycles.
    private func withLock<T>(createRoot: Bool, _ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        if createRoot { try prepareRoot() }
        let descriptor = open(root.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw LocalDatasetError.io("Could not lock the dataset.") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw LocalDatasetError.io("Could not lock the dataset.") }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    public func samples() throws -> [LocalBenchmarkSample] {
        // Reading must not create the directory.
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try withLock(createRoot: false) { try loadIndex() }
    }

    public func add(_ audio: [Int16], rawReference: String?, cleanReference: String?, split: LocalBenchmarkSample.Split,
                    tags: [String]) throws -> LocalBenchmarkSample {
        try withLock(createRoot: true) {
            var index = try loadIndex()
            var id = ""
            repeat { id = "p-" + String(format: "%08x", UInt32.random(in: .min ... .max)) }
            while index.contains { $0.id == id }
            let sample = LocalBenchmarkSample(id: id, audioFile: id + ".wav", rawReference: rawReference, cleanReference: cleanReference,
                                              split: split, tags: tags, approvedAt: nil)
            try WAVFile.write(audio, to: root.appendingPathComponent(sample.audioFile))
            index.append(sample)
            do { try saveIndex(index) } catch {
                try? FileManager.default.removeItem(at: root.appendingPathComponent(sample.audioFile))
                throw error
            }
            return sample
        }
    }

    public func update(_ sample: LocalBenchmarkSample) throws {
        try withLock(createRoot: true) {
            var index = try loadIndex()
            guard let position = index.firstIndex(where: { $0.id == sample.id }) else { throw LocalDatasetError.unknownSample(sample.id) }
            guard index[position].audioFile == sample.audioFile else { throw LocalDatasetError.audioFileChanged(sample.id) }
            if sample.approvedAt != nil, !Self.hasBothReferences(sample) { throw LocalDatasetError.notApprovable(sample.id) }
            index[position] = sample
            try saveIndex(index)
        }
    }

    public func approve(_ id: String, at date: Date) throws {
        try withLock(createRoot: true) {
            var index = try loadIndex()
            guard let position = index.firstIndex(where: { $0.id == id }) else { throw LocalDatasetError.unknownSample(id) }
            guard Self.hasBothReferences(index[position]) else { throw LocalDatasetError.notApprovable(id) }
            index[position].approvedAt = date
            try saveIndex(index)
        }
    }

    public func delete(_ id: String) throws {
        try withLock(createRoot: true) {
            var index = try loadIndex()
            guard let position = index.firstIndex(where: { $0.id == id }) else { throw LocalDatasetError.unknownSample(id) }
            let sample = index.remove(at: position)
            try saveIndex(index)
            try? FileManager.default.removeItem(at: root.appendingPathComponent(sample.audioFile))
        }
    }

    /// Moves a damaged index aside so a new one can start. WAV files stay; an existing backup is never overwritten.
    public func backUpCorruptIndex(now: Date) throws -> URL {
        try withLock(createRoot: true) {
            guard FileManager.default.fileExists(atPath: indexURL.path) else { throw LocalDatasetError.io("There is no dataset index to back up.") }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let stamp = formatter.string(from: now)
            var backup = root.appendingPathComponent("index.corrupt-\(stamp).json")
            var suffix = 0
            while FileManager.default.fileExists(atPath: backup.path) {
                suffix += 1
                backup = root.appendingPathComponent("index.corrupt-\(stamp)-\(suffix).json")
            }
            do { try FileManager.default.moveItem(at: indexURL, to: backup) } catch { throw LocalDatasetError.io("Could not back up the dataset index.") }
            return backup
        }
    }

    public func audio(for sample: LocalBenchmarkSample) throws -> [Int16] {
        guard DatasetNames.isSafe(sample.audioFile) else { throw LocalDatasetError.unsafeName(sample.audioFile) }
        let decoded = try WAVFile.read(url(for: sample))
        guard decoded.channels == 1, decoded.sampleRate == LocalWorkerProtocol.audioSampleRate else {
            throw LocalDatasetError.unsupportedAudio("Expected 16 kHz mono audio.")
        }
        return decoded.samples
    }

    public func url(for sample: LocalBenchmarkSample) -> URL {
        // A tampered index entry resolves to a name that cannot exist rather than escaping the root.
        root.appendingPathComponent(DatasetNames.isSafe(sample.audioFile) ? sample.audioFile : "invalid.wav")
    }

    private static func hasBothReferences(_ sample: LocalBenchmarkSample) -> Bool {
        [sample.rawReference, sample.cleanReference].allSatisfy { !($0 ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func prepareRoot() throws {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        } catch { throw LocalDatasetError.io("Could not create the dataset directory.") }
    }

    /// Absent file is an empty dataset; anything unreadable or undecodable is refused so a mutation never overwrites it.
    private func loadIndex() throws -> [LocalBenchmarkSample] {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: indexURL), let all = try? decoder.decode([LocalBenchmarkSample].self, from: data) else {
            throw LocalDatasetError.indexCorrupt
        }
        return all.filter { DatasetNames.isSafe($0.id) && DatasetNames.isSafe($0.audioFile) }
    }

    private func saveIndex(_ samples: [LocalBenchmarkSample]) throws {
        try prepareRoot()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(samples).write(to: indexURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: indexURL.path)
        } catch { throw LocalDatasetError.io("Could not write the dataset index.") }
    }
}

/// BenchmarkSplitMix64: tiny, fixed-sequence generator so a seed selects the same subset on every machine and release.
nonisolated struct BenchmarkSplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Read-only public dataset (voice-benchmark DisfluencySpeech test manifest). Audio paths are relative to `root`.
nonisolated public struct LocalPublicDataset: Sendable {
    public let name: String
    public let revision: String?
    public let samples: [LocalBenchmarkSample]
    public let root: URL

    public init(name: String, revision: String?, samples: [LocalBenchmarkSample], root: URL) {
        self.name = name; self.revision = revision; self.samples = samples; self.root = root
    }

    public static func loadDisfluency(manifest: URL) throws -> LocalPublicDataset {
        guard let text = try? String(contentsOf: manifest, encoding: .utf8) else { throw LocalDatasetError.invalidManifest("Manifest is unreadable.") }
        let rows = parseCSV(text)
        guard let header = rows.first, let idColumn = header.firstIndex(of: "id"), let pathColumn = header.firstIndex(of: "audio_path"),
              let rawColumn = header.firstIndex(of: "raw_reference"), let cleanColumn = header.firstIndex(of: "clean_reference") else {
            throw LocalDatasetError.invalidManifest("Manifest columns must include id, audio_path, raw_reference, clean_reference.")
        }
        let approved = Date(timeIntervalSince1970: 0)
        var samples: [LocalBenchmarkSample] = []
        var seen = Set<String>()
        for row in rows.dropFirst() where row.count > max(idColumn, pathColumn, rawColumn, cleanColumn) {
            let id = row[idColumn], path = row[pathColumn]
            guard DatasetNames.isSafe(id), LocalModelPathPolicy.isSafeRelativePath(path), seen.insert(id).inserted else {
                throw LocalDatasetError.invalidManifest("Unsafe or duplicate sample entry.")
            }
            samples.append(LocalBenchmarkSample(id: id, audioFile: path, rawReference: row[rawColumn], cleanReference: row[cleanColumn],
                                                split: .heldOut, tags: [], approvedAt: approved))
        }
        guard let first = samples.first else { throw LocalDatasetError.invalidManifest("Manifest has no samples.") }
        // audio_path is relative to the dataset repository root, which sits some levels above the manifest.
        var candidate = manifest.deletingLastPathComponent()
        var root = candidate
        for _ in 0..<6 {
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent(first.audioFile).path) { root = candidate; break }
            candidate = candidate.deletingLastPathComponent()
        }
        var name = "disfluency_speech", revision: String?
        for directory in [manifest.deletingLastPathComponent(), manifest.deletingLastPathComponent().deletingLastPathComponent()] {
            if let data = try? Data(contentsOf: directory.appendingPathComponent("dataset_info.json")),
               let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                name = (info["dataset"] as? String) ?? name
                revision = info["revision"] as? String
                break
            }
        }
        return LocalPublicDataset(name: name, revision: revision, samples: samples, root: root)
    }

    public func url(for sample: LocalBenchmarkSample) -> URL { root.appendingPathComponent(sample.audioFile) }

    /// `ids` wins (manifest order, unknown ids ignored); otherwise a BenchmarkSplitMix64 Fisher-Yates shuffle takes `count`
    /// (all samples when nil); the result keeps shuffle order.
    public func select(ids: [String]?, count: Int?, seed: UInt64) -> [LocalBenchmarkSample] {
        if let ids {
            let byID = Dictionary(uniqueKeysWithValues: samples.map { ($0.id, $0) })
            return ids.compactMap { byID[$0] }
        }
        var shuffled = samples
        var generator = BenchmarkSplitMix64(seed: seed)
        if shuffled.count > 1 {
            for position in stride(from: shuffled.count - 1, to: 0, by: -1) {
                let other = Int(generator.next() % UInt64(position + 1))
                shuffled.swapAt(position, other)
            }
        }
        guard let count else { return shuffled }
        return Array(shuffled.prefix(max(0, count)))
    }

    /// RFC 4180: quoted fields may hold commas, doubled quotes and newlines; CRLF or LF row ends.
    static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = ""
        var inQuotes = false, pending = false
        let scalars = Array(text.unicodeScalars)
        var index = 0
        func endField() { row.append(field); field = ""; pending = false }
        while index < scalars.count {
            let scalar = scalars[index]
            if inQuotes {
                if scalar == "\"" {
                    if index + 1 < scalars.count, scalars[index + 1] == "\"" { field.unicodeScalars.append("\""); index += 1 } else { inQuotes = false }
                } else { field.unicodeScalars.append(scalar) }
            } else if scalar == "\"" { inQuotes = true; pending = true }
            else if scalar == "," { endField(); pending = true }
            else if scalar == "\r" || scalar == "\n" {
                if scalar == "\r", index + 1 < scalars.count, scalars[index + 1] == "\n" { index += 1 }
                if pending || !field.isEmpty || !row.isEmpty { endField(); rows.append(row) }
                row = []
            } else { field.unicodeScalars.append(scalar); pending = true }
            index += 1
        }
        if pending || !field.isEmpty || !row.isEmpty { endField(); rows.append(row) }
        return rows
    }
}
