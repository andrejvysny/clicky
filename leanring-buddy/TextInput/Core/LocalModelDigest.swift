#if canImport(CryptoKit)
import CryptoKit
import Foundation

/// SHA-256 (always) and git blob SHA-1 (when pinned that way) computed incrementally.
nonisolated struct DigestAccumulator {
    private var sha256 = SHA256()
    private var blob = Insecure.SHA1()
    private let wantsBlob: Bool

    init(for file: LocalModelFile) {
        wantsBlob = file.gitBlobSHA1 != nil
        if wantsBlob { blob.update(data: Data("blob \(file.size)\0".utf8)) }
    }

    mutating func update(_ data: Data) {
        sha256.update(data: data)
        if wantsBlob { blob.update(data: data) }
    }

    func finalize() -> FileDigest {
        FileDigest(sha256: Self.hex(sha256.finalize()), blobSHA1: wantsBlob ? Self.hex(blob.finalize()) : nil)
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated struct FileDigest: Sendable {
    let sha256: String
    let blobSHA1: String?

    func check(against file: LocalModelFile) throws {
        if let expected = file.sha256, expected.lowercased() != sha256 { throw LocalModelInstallError.hashMismatch(file.path) }
        if let expected = file.gitBlobSHA1, expected.lowercased() != blobSHA1 { throw LocalModelInstallError.hashMismatch(file.path) }
    }
}
#endif
