import Combine
import Foundation

/// Persisted snippets and custom skills plus the VS Code bridge opt-in. Every mutation is applied to a copy,
/// encoded and stored first; the published value changes only after the write succeeded.
@MainActor
final class WritingDefinitionsStore: ObservableObject {
    static let defaultsKey = "writingDefinitions"

    @Published private(set) var definitions: WritingDefinitions = .empty
    @Published private(set) var lastError: String?
    @Published private(set) var bridgeEnabled: Bool

    private let defaults: UserDefaults
    /// True when stored data exists but could not be read; edits are refused so it is never overwritten.
    private var loadFailed = false

    var bridgeDirectory: URL { WritingVSCodeAdapter.bridgeDirectory }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        bridgeEnabled = false
        if let data = defaults.data(forKey: Self.defaultsKey) {
            do { definitions = try WritingDefinitions.decode(data) } catch {
                loadFailed = true
                lastError = "Saved writing definitions could not be read; nothing was changed."
            }
        }
        refreshBridge()
    }

    func clearError() { lastError = nil }

    private func apply<T>(_ mutate: (inout WritingDefinitions) throws -> T) -> T? {
        guard !loadFailed else {
            lastError = "Saved writing definitions could not be read; nothing was changed."
            return nil
        }
        lastError = nil
        var copy = definitions
        do {
            let result = try mutate(&copy)
            defaults.set(try copy.encoded(), forKey: Self.defaultsKey)
            definitions = copy
            return result
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    // MARK: Snippets

    @discardableResult
    func addSnippet(name: String, alias: String, summary: String, body: String, restriction: SnippetRestriction) -> SavedSnippet? {
        apply { try $0.addSnippet(name: name, alias: alias, summary: summary, body: body, restriction: restriction) }
    }

    @discardableResult
    func saveSnippet(_ snippet: SavedSnippet) -> Bool { apply { try $0.updateSnippet(snippet) } != nil }

    @discardableResult
    func duplicateSnippet(_ id: UUID) -> SavedSnippet? { apply { try $0.duplicateSnippet(id: id) } }

    @discardableResult
    func setSnippetEnabled(_ id: UUID, _ enabled: Bool) -> Bool {
        apply { try $0.setSnippetEnabled(id: id, enabled: enabled) } != nil
    }

    @discardableResult
    func deleteSnippet(_ id: UUID) -> Bool { apply { try $0.deleteSnippet(id: id) } != nil }

    // MARK: Skills

    @discardableResult
    func addSkill(name: String, alias: String, summary: String, instructions: String, operation: SkillOperation) -> CustomSkill? {
        apply { try $0.addSkill(name: name, alias: alias, summary: summary, instructions: instructions, operation: operation) }
    }

    @discardableResult
    func saveSkill(_ skill: CustomSkill) -> Bool { apply { try $0.updateSkill(skill) } != nil }

    @discardableResult
    func duplicateSkill(_ id: UUID) -> CustomSkill? { apply { try $0.duplicateSkill(id: id) } }

    @discardableResult
    func setSkillEnabled(_ id: UUID, _ enabled: Bool) -> Bool {
        apply { try $0.setSkillEnabled(id: id, enabled: enabled) } != nil
    }

    @discardableResult
    func deleteSkill(_ id: UUID) -> Bool { apply { try $0.deleteSkill(id: id) } != nil }

    // MARK: VS Code bridge

    func refreshBridge() { bridgeEnabled = VSCodeBridgeClient(directory: bridgeDirectory).tokenExists() }

    func setBridgeEnabled(_ on: Bool) {
        lastError = nil
        if on {
            do { try VSCodeBridgeClient.createToken(directory: bridgeDirectory) } catch {
                lastError = "Could not enable the VS Code bridge."
            }
        } else {
            VSCodeBridgeClient.removeToken(directory: bridgeDirectory)
        }
        refreshBridge()
        if !on, bridgeEnabled { lastError = "Could not disable the VS Code bridge." }
    }
}
