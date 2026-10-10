import ClickyCore
import Foundation

enum ModelsCommand {
    static func run(_ arguments: [String]) async throws {
        guard let subcommand = arguments.first else { throw CLIError("models needs list|download|import|verify|remove.") }
        let options = try Options(Array(arguments.dropFirst()), valued: ["models-root"], boolean: ["yes"])
        let store = LocalModelStore(root: BenchPaths.modelsRoot(options))
        if subcommand == "list" { list(store); return }
        guard let id = options.positional.first else { throw CLIError("models \(subcommand) needs an <entry-id>.") }
        guard let entry = LocalModelCatalog.entry(id: id) else {
            throw CLIError("Unknown catalog entry \(id). Known: " + LocalModelCatalog.entries.map(\.id).joined(separator: ", "))
        }
        switch subcommand {
        case "download": try await download(entry, store)
        case "import":
            guard options.positional.count >= 2 else { throw CLIError("models import <entry-id> <folder>") }
            let folder = URL(fileURLWithPath: (options.positional[1] as NSString).expandingTildeInPath, isDirectory: true)
            let model = try await mapped { try await store.importFolder(folder, as: entry) }
            print("Imported \(model.entryID) \(model.revision) fingerprint \(model.fingerprint)")
        case "verify":
            guard let model = store.installed(entry.id) else { throw CLIError("\(entry.id) is not installed.") }
            try await mapped { try await store.verify(model) }
            print("Verified \(model.entryID) \(model.revision) fingerprint \(model.fingerprint)")
        case "remove":
            guard store.installed(entry.id) != nil else { throw CLIError("\(entry.id) is not installed.") }
            if !options.flag("yes") {
                print("Remove \(entry.id) from \(store.root.path)? [y/N] ", terminator: "")
                guard let answer = readLine(), answer.lowercased().hasPrefix("y") else { print("Kept."); return }
            }
            try store.remove(entry.id)
            print("Removed \(entry.id)")
        default: throw CLIError("Unknown models subcommand \(subcommand).")
        }
    }

    private static func list(_ store: LocalModelStore) {
        print("store: \(store.root.path)")
        let installed = store.installed()
        for entry in LocalModelCatalog.entries {
            let present = installed.filter { $0.entryID == entry.id }
            let status: String
            if present.contains(where: { $0.revision == entry.revision }) { status = "installed" }
            else if let other = present.first { status = "installed (other revision \(other.revision.prefix(8)))" }
            else { status = "not installed" }
            let size = String(format: "%.0f MB", Double(entry.totalBytes) / 1_048_576)
            print("\(entry.id)  [\(entry.group.rawValue)/\(entry.kind.rawValue)]  \(size)  \(entry.quantization)  \(status)")
        }
    }

    private static func download(_ entry: LocalModelCatalogEntry, _ store: LocalModelStore) async throws {
        let task = Task { try await store.download(entry) { done, total in
            let percent = total > 0 ? Int(Double(done) / Double(total) * 100) : 0
            FileHandle.standardError.write(Data("\r\(entry.id): \(done / 1_048_576) / \(total / 1_048_576) MB (\(percent)%)   ".utf8))
        } }
        let interrupt = InterruptHandler { task.cancel() }
        defer { _ = interrupt }
        let model = try await mapped { try await task.value }
        FileHandle.standardError.write(Data("\n".utf8))
        print("Installed \(model.entryID) \(model.revision) fingerprint \(model.fingerprint)")
    }

    private static func mapped<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() }
        catch let error as LocalModelInstallError { throw CLIError("Model operation failed: \(error)") }
    }
}
