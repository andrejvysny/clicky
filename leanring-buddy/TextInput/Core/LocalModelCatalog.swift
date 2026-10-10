import Foundation

nonisolated public enum LocalModelGroup: String, Codable, Sendable, CaseIterable {
    case vision, cleanup, speech
}

/// One pinned file. Exactly one of `sha256` (Git LFS files) or `gitBlobSHA1` (small files) is set; both come from the
/// Hugging Face revision API. `repository`/`revision` override the entry's source for files that live elsewhere (for
/// example a tokenizer from another repository); such files are fetched from the repository root, not from
/// `sourceSubdirectory`.
nonisolated public struct LocalModelFile: Codable, Equatable, Hashable, Sendable {
    public let path: String
    public let size: Int64
    public let sha256: String?
    public let gitBlobSHA1: String?
    public let repository: String?
    public let revision: String?

    public init(path: String, size: Int64, sha256: String? = nil, gitBlobSHA1: String? = nil,
                repository: String? = nil, revision: String? = nil) {
        self.path = path; self.size = size; self.sha256 = sha256; self.gitBlobSHA1 = gitBlobSHA1
        self.repository = repository; self.revision = revision
    }
}

nonisolated public struct LocalModelCatalogEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let kind: LocalModelKind
    public let group: LocalModelGroup
    public let repository: String
    public let revision: String
    /// Path prefix inside the repository; file paths are relative to it and installed without it.
    public let sourceSubdirectory: String?
    /// Layout inside the install directory that the runtime expects (files land at `<install>/<installSubdirectory>/<path>`).
    public let installSubdirectory: String?
    public let license: String
    public let quantization: String
    public let notes: String
    public let files: [LocalModelFile]

    public init(id: String, displayName: String, kind: LocalModelKind, group: LocalModelGroup, repository: String,
                revision: String, sourceSubdirectory: String?, installSubdirectory: String?, license: String,
                quantization: String, notes: String, files: [LocalModelFile]) {
        self.id = id; self.displayName = displayName; self.kind = kind; self.group = group
        self.repository = repository; self.revision = revision; self.sourceSubdirectory = sourceSubdirectory
        self.installSubdirectory = installSubdirectory; self.license = license; self.quantization = quantization
        self.notes = notes; self.files = files
    }

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    /// HTTPS download location. Path segments are percent-encoded; the repository path keeps its slash.
    public func remoteURL(for file: LocalModelFile) -> URL? {
        let overridden = file.repository != nil
        let repo = file.repository ?? repository
        let rev = file.revision ?? revision
        var path = file.path
        if !overridden, let sourceSubdirectory { path = sourceSubdirectory + "/" + path }
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encoded = path.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "" }
            .joined(separator: "/")
        return URL(string: "https://huggingface.co/\(repo)/resolve/\(rev)/\(encoded)")
    }

    /// Where `file` sits under an install root.
    public func installPath(for file: LocalModelFile) -> String {
        installSubdirectory.map { $0 + "/" + file.path } ?? file.path
    }
}

/// Pinned catalog of downloadable local models. Entries live in the generated `LocalModelCatalog+Pins.swift`
/// (`scripts/generate-model-catalog.py`).
nonisolated public enum LocalModelCatalog {
    public static func entry(id: String) -> LocalModelCatalogEntry? { entries.first { $0.id == id } }
}

/// Path policy shared by the installer and the catalog tests. Everything that becomes a path under the install
/// root must pass: relative, no `..`, no empty components, no NUL or backslash, no executable-code extension.
nonisolated public enum LocalModelPathPolicy {
    public static let executableExtensions: Set<String> = ["py", "sh", "dylib", "so", "bundle", "app", "command", "js"]
    public static let receiptFileName = ".clicky-receipt.json"
    private static let identifierCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._")

    public static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.unicodeScalars.contains("\0"), !path.contains("\\") else { return false }
        for component in path.split(separator: "/", omittingEmptySubsequences: false) {
            if component.isEmpty || component == "." || component == ".." { return false }
            let ext = (String(component) as NSString).pathExtension.lowercased()
            if executableExtensions.contains(ext) { return false }
        }
        return true
    }

    /// Single directory-name component (entry id, revision): no separators, no leading dot.
    public static func isSafeIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("."), value.unicodeScalars.allSatisfy(identifierCharacters.contains) else { return false }
        return isSafeRelativePath(value)
    }

    /// First problem found in an entry, or nil when it is safe to stage and publish.
    public static func violation(in entry: LocalModelCatalogEntry) -> String? {
        guard isSafeIdentifier(entry.id) else { return entry.id }
        guard isSafeIdentifier(entry.revision) else { return entry.revision }
        for subdirectory in [entry.sourceSubdirectory, entry.installSubdirectory] {
            if let subdirectory, !isSafeRelativePath(subdirectory) { return subdirectory }
        }
        var seen = Set<String>()
        var directories = Set<String>()
        for file in entry.files {
            let installPath = entry.installPath(for: file)
            guard isSafeRelativePath(file.path), isSafeRelativePath(installPath), file.size >= 0 else { return file.path }
            guard installPath.lowercased() != receiptFileName else { return file.path }
            guard (file.sha256 == nil) != (file.gitBlobSHA1 == nil) else { return file.path }
            guard seen.insert(installPath.lowercased()).inserted else { return file.path }
            var prefix = ""
            for component in installPath.split(separator: "/").dropLast() {
                prefix += (prefix.isEmpty ? "" : "/") + component.lowercased()
                directories.insert(prefix)
            }
        }
        // A file may not also be a directory of another file.
        if let clash = seen.first(where: directories.contains) { return clash }
        return nil
    }
}
