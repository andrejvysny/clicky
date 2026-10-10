import Foundation

struct CLIError: Error { let message: String; init(_ message: String) { self.message = message } }

/// Minimal `--flag value` / `--flag=value` parser (swift-argument-parser is not a dependency).
struct Options {
    var positional: [String] = []
    private var values: [String: [String]] = [:]
    private var flags: Set<String> = []

    init(_ arguments: [String], valued: Set<String>, boolean: Set<String> = []) throws {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            guard argument.hasPrefix("--") else { positional.append(argument); continue }
            var name = String(argument.dropFirst(2))
            var inline: String?
            if let equals = name.firstIndex(of: "=") { inline = String(name[name.index(after: equals)...]); name = String(name[..<equals]) }
            if boolean.contains(name) { flags.insert(name); continue }
            guard valued.contains(name) else { throw CLIError("Unknown option --\(name).") }
            if let inline { values[name, default: []].append(inline); continue }
            guard index < arguments.count else { throw CLIError("Option --\(name) needs a value.") }
            values[name, default: []].append(arguments[index])
            index += 1
        }
    }

    func one(_ name: String) -> String? { values[name]?.last }
    func many(_ name: String) -> [String] { values[name] ?? [] }
    func flag(_ name: String) -> Bool { flags.contains(name) }

    func integer(_ name: String, default fallback: Int? = nil, minimum: Int = 0) throws -> Int? {
        guard let text = one(name) else { return fallback }
        guard let value = Int(text), value >= minimum else { throw CLIError("--\(name) must be an integer >= \(minimum).") }
        return value
    }
}
