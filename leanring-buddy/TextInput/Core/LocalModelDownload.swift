#if canImport(CryptoKit)
import CryptoKit
import Foundation

nonisolated extension LocalModelStore {
    public func download(_ entry: LocalModelCatalogEntry, session: URLSession = .shared,
                         progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> InstalledLocalModel {
        do {
            return try await downloadUnmapped(entry, session: session, progress: progress)
        } catch { throw Self.mapped(error) }
    }

    // MARK: Download

    private func downloadUnmapped(_ entry: LocalModelCatalogEntry, session: URLSession,
                                  progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> InstalledLocalModel {
        try Self.validate(entry)
        guard acquire(entry.id) else { throw LocalModelInstallError.inProgress }
        defer { release(entry.id) }
        try prepareRoot(for: entry)
        let staging = stagingRoot.appendingPathComponent("\(entry.id)-\(entry.revision)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try requireCapacity(remaining: remainingBytes(entry, staging: staging))

        let total = entry.totalBytes
        var completed: Int64 = 0
        var streamed: [String: FileDigest] = [:]
        for file in entry.files {
            try Task.checkCancellation()
            let base = completed
            if let digest = try await fetch(file, of: entry, into: staging, session: session, onBytes: { progress(base + $0, total) }) {
                streamed[entry.installPath(for: file)] = digest
            }
            completed += file.size
            progress(completed, total)
        }
        return try publish(entry, staging: staging, source: .download, streamed: streamed)
    }

    /// Returns the digest computed while streaming, or nil when the file was already complete or resumed from a
    /// finished partial (publish then hashes it from disk).
    private func fetch(_ file: LocalModelFile, of entry: LocalModelCatalogEntry, into staging: URL, session: URLSession,
                       onBytes: @escaping @Sendable (Int64) -> Void) async throws -> FileDigest? {
        let fileManager = FileManager.default
        let destination = staging.appendingPathComponent(entry.installPath(for: file))
        let partial = URL(fileURLWithPath: destination.path + ".partial")
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if Self.fileSize(destination) == file.size { onBytes(file.size); return nil }
        try? fileManager.removeItem(at: destination)
        guard let url = entry.remoteURL(for: file), Self.isAllowedSource(url) else { throw LocalModelInstallError.unsafePath(file.path) }

        for _ in 0..<2 {
            var offset = Self.fileSize(partial) ?? 0
            if offset > file.size { try? fileManager.removeItem(at: partial); offset = 0 }
            if offset == file.size { try finishPartial(partial, as: destination); onBytes(file.size); return nil }

            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.httpShouldHandleCookies = false
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }

            // Delegate-driven chunks: AsyncBytes iterates per byte and was an order of magnitude slower.
            let download = ChunkDownload(partial: partial, requestedOffset: offset, file: file, chunkBytes: writeChunkBytes, onBytes: onBytes)
            let task = session.dataTask(with: request)
            task.delegate = download
            let outcome = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ChunkDownload.Outcome, Error>) in
                    download.start(task, continuation)
                }
            } onCancel: { download.cancel() }
            switch outcome {
            case .restart: continue
            case let .completed(digest):
                try finishPartial(partial, as: destination)
                return digest
            }
        }
        throw LocalModelInstallError.network("range not satisfiable")
    }

    private func finishPartial(_ partial: URL, as destination: URL) throws {
        guard Self.fileSize(partial) != nil else { throw LocalModelInstallError.missingFile(destination.lastPathComponent) }
        try FileManager.default.moveItem(at: partial, to: destination)
    }

    private func remainingBytes(_ entry: LocalModelCatalogEntry, staging: URL) -> Int64 {
        entry.files.reduce(0) { total, file in
            let destination = staging.appendingPathComponent(entry.installPath(for: file))
            let have = Self.fileSize(destination) ?? min(Self.fileSize(URL(fileURLWithPath: destination.path + ".partial")) ?? 0, file.size)
            return total + max(0, file.size - have)
        }
    }
}

/// One HTTP attempt for one file: buffers delegate chunks, writes them to the `.partial` in `chunkBytes` pieces,
/// hashes while writing, refuses redirects that leave Hugging Face's hosts and reports what to do next.
nonisolated final class ChunkDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Outcome { case completed(FileDigest), restart }

    private let partial: URL
    private let requestedOffset: Int64
    private let file: LocalModelFile
    private let chunkBytes: Int
    private let onBytes: @Sendable (Int64) -> Void

    // Shared between the caller's task and the session's serial delegate queue.
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Outcome, Error>?
    private var task: URLSessionTask?
    private var canceled = false
    private var failure: Error?
    private var restart = false
    private var rejectedHost: String?

    // Touched only on the delegate queue.
    private var handle: FileHandle?
    private var digest: DigestAccumulator
    private var buffer = Data()
    private var written: Int64 = 0

    init(partial: URL, requestedOffset: Int64, file: LocalModelFile, chunkBytes: Int, onBytes: @escaping @Sendable (Int64) -> Void) {
        self.partial = partial; self.requestedOffset = requestedOffset; self.file = file
        self.chunkBytes = max(1, chunkBytes); self.onBytes = onBytes
        digest = DigestAccumulator(for: file)
    }

    func start(_ task: URLSessionTask, _ continuation: CheckedContinuation<Outcome, Error>) {
        let alreadyCanceled: Bool = lock.withLock {
            self.task = task; self.continuation = continuation
            return canceled
        }
        if alreadyCanceled { task.cancel() }
        task.resume()
    }

    func cancel() {
        let current: URLSessionTask? = lock.withLock { canceled = true; return task }
        current?.cancel()
    }

    private var shouldStop: Bool { lock.withLock { canceled || failure != nil || restart || rejectedHost != nil } }

    private func fail(_ error: Error, stopping task: URLSessionTask) {
        lock.withLock { if failure == nil { failure = error } }
        task.cancel()
    }

    // MARK: URLSessionTaskDelegate

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if let url = request.url, LocalModelStore.isAllowedSource(url) {
            completionHandler(request)
        } else {
            lock.withLock { rejectedHost = request.url?.host ?? "unknown" }
            completionHandler(nil)
            task.cancel()
        }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, let url = http.url, LocalModelStore.isAllowedSource(url) else {
            fail(LocalModelInstallError.network("unexpected response"), stopping: dataTask)
            return completionHandler(.cancel)
        }
        if http.statusCode == 416 {
            requestRestart(dataTask)
            return completionHandler(.cancel)
        }
        guard http.statusCode == 200 || http.statusCode == 206 else {
            fail(LocalModelInstallError.network("HTTP \(http.statusCode)"), stopping: dataTask)
            return completionHandler(.cancel)
        }
        var startOffset = requestedOffset
        if http.statusCode == 200 {
            // A 200 to a ranged request means the server ignored Range: restart the file.
            startOffset = 0
        } else if http.value(forHTTPHeaderField: "Content-Range")?.lowercased().hasPrefix("bytes \(requestedOffset)-") != true {
            requestRestart(dataTask)
            return completionHandler(.cancel)
        }
        do { try openFile(at: startOffset) } catch {
            fail(error, stopping: dataTask)
            return completionHandler(.cancel)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if shouldStop || handle == nil { dataTask.cancel(); return }
        var remaining = data
        while !remaining.isEmpty {
            let piece = remaining.prefix(max(1, chunkBytes - buffer.count))
            buffer.append(piece)
            remaining = remaining.dropFirst(piece.count)
            if written + Int64(buffer.count) > file.size {
                fail(LocalModelInstallError.sizeMismatch(file.path), stopping: dataTask)
                return
            }
            if buffer.count >= chunkBytes {
                do { try flush() } catch { fail(error, stopping: dataTask); return }
                if shouldStop { dataTask.cancel(); return }
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let oversized: Bool = lock.withLock { (failure as? LocalModelInstallError) == .sizeMismatch(file.path) }
        if oversized { buffer.removeAll() } else { try? flush() }
        try? handle?.close()
        handle = nil
        if oversized { try? FileManager.default.removeItem(at: partial) }

        let result: Result<Outcome, Error> = lock.withLock {
            if let rejectedHost { return .failure(LocalModelInstallError.network("redirect host not allowed: \(rejectedHost)")) }
            if restart { return .success(.restart) }
            if let failure { return .failure(failure) }
            if canceled { return .failure(CancellationError()) }
            if let error { return .failure(error) }
            guard written == file.size else { return .failure(LocalModelInstallError.network("incomplete: \(file.path)")) }
            return .success(.completed(digest.finalize()))
        }
        let pending: CheckedContinuation<Outcome, Error>? = lock.withLock { defer { continuation = nil }; return continuation }
        pending?.resume(with: result)
    }

    // MARK: Helpers

    private func requestRestart(_ task: URLSessionTask) {
        try? FileManager.default.removeItem(at: partial)
        lock.withLock { restart = true }
        task.cancel()
    }

    /// Opens the partial at `offset` (0 truncates) and seeds the hash with the bytes already on disk.
    private func openFile(at offset: Int64) throws {
        let fileManager = FileManager.default
        if offset == 0 { fileManager.createFile(atPath: partial.path, contents: nil) }
        digest = DigestAccumulator(for: file)
        if offset > 0 {
            let reader = try FileHandle(forReadingFrom: partial)
            defer { try? reader.close() }
            var remaining = offset
            while remaining > 0, let chunk = try reader.read(upToCount: Int(min(remaining, 1 << 20))), !chunk.isEmpty {
                digest.update(chunk)
                remaining -= Int64(chunk.count)
            }
            guard remaining == 0 else { throw LocalModelInstallError.sizeMismatch(file.path) }
        }
        let writer = try FileHandle(forWritingTo: partial)
        if offset == 0 { try writer.truncate(atOffset: 0) } else { try writer.seek(toOffset: UInt64(offset)) }
        handle = writer
        written = offset
    }

    private func flush() throws {
        guard let handle, !buffer.isEmpty else { return }
        try handle.write(contentsOf: buffer)
        digest.update(buffer)
        written += Int64(buffer.count)
        buffer.removeAll(keepingCapacity: true)
        onBytes(written)
    }
}
#endif
