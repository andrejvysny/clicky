import Foundation

nonisolated public enum SnippetRestriction: String, Codable, Sendable {
    case any, editorsOnly, terminalOnly
}

/// A user-saved literal text. Inserted verbatim, never sent to a provider and never interpolated.
nonisolated public struct SavedSnippet: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var revision: UInt64
    public var name: String
    public var alias: String
    public var summary: String
    public var body: String
    public var enabled: Bool
    public var restriction: SnippetRestriction

    public var terminalClassification: TerminalPayload.Classification { TerminalPayload.classify(body) }
}

nonisolated public enum SkillOperation: String, Codable, Sendable {
    case draft, rewrite
}

/// A named instruction for the provider. Built-in skills live in `SlashCommandRegistry`, never in storage.
nonisolated public struct CustomSkill: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var revision: UInt64
    public var name: String
    public var alias: String
    public var summary: String
    public var instructions: String
    public var operation: SkillOperation
    public var enabled: Bool
    public var builtIn: Bool
}

nonisolated public enum DefinitionError: LocalizedError, Equatable, Sendable {
    case invalidAlias, aliasReserved(String), aliasTaken(String), emptyName, nameTooLong, summaryTooLong
    case emptyBody, bodyTooLarge, emptyInstructions, instructionsTooLarge
    case notFound, builtInReadOnly, unsupportedVersion

    public var errorDescription: String? {
        switch self {
        case .invalidAlias: return "Use 1-32 lowercase letters, digits or hyphens, starting with a letter or digit."
        case .aliasReserved(let alias): return "/\(alias) is reserved."
        case .aliasTaken(let alias): return "/\(alias) is already used."
        case .emptyName: return "Enter a name."
        case .nameTooLong: return "Name is too long (80 characters max)."
        case .summaryTooLong: return "Summary is too long (160 characters max)."
        case .emptyBody: return "Enter the text to insert."
        case .bodyTooLarge: return "Text is too large (64 KiB max)."
        case .emptyInstructions: return "Enter instructions."
        case .instructionsTooLarge: return "Instructions are too long (4000 bytes max)."
        case .notFound: return "That item no longer exists."
        case .builtInReadOnly: return "Built-in skills cannot be changed."
        case .unsupportedVersion: return "These definitions were saved by a newer version."
        }
    }
}

nonisolated public struct WritingDefinitions: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public static let maxAliasLength = 32
    public static let maxNameLength = 80
    public static let maxSummaryLength = 160
    public static let maxBodyBytes = 65_536
    public static let maxInstructionBytes = 4_000

    public var version: Int
    public var snippets: [SavedSnippet]
    public var skills: [CustomSkill]

    public static var empty: WritingDefinitions { WritingDefinitions(version: schemaVersion, snippets: [], skills: []) }

    // MARK: Persistence

    private struct VersionProbe: Decodable { let version: Int }

    public static func decode(_ data: Data) throws -> WritingDefinitions {
        let probe = try JSONDecoder().decode(VersionProbe.self, from: data)
        guard probe.version == schemaVersion else { throw DefinitionError.unsupportedVersion }
        return try JSONDecoder().decode(WritingDefinitions.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    // MARK: Validation

    /// ^[a-z0-9][a-z0-9-]{0,31}$ in lowercase ASCII only.
    public static func isValidAlias(_ alias: String) -> Bool {
        let bytes = Array(alias.utf8)
        guard (1...maxAliasLength).contains(bytes.count) else { return false }
        func alnum(_ b: UInt8) -> Bool { (0x61...0x7A).contains(b) || (0x30...0x39).contains(b) }
        return alnum(bytes[0]) && bytes.dropFirst().allSatisfy { alnum($0) || $0 == 0x2D }
    }

    private func validateAlias(_ alias: String, excluding id: UUID?) throws {
        guard Self.isValidAlias(alias) else { throw DefinitionError.invalidAlias }
        if SlashCommandRegistry.reservedAliases.contains(alias) { throw DefinitionError.aliasReserved(alias) }
        if isAliasUsed(alias, excluding: id) { throw DefinitionError.aliasTaken(alias) }
    }

    private func isAliasUsed(_ alias: String, excluding id: UUID?) -> Bool {
        snippets.contains { $0.alias == alias && $0.id != id } || skills.contains { $0.alias == alias && $0.id != id }
    }

    private func validateCommon(name: String, summary: String) throws {
        guard name.contains(where: { !$0.isWhitespace }) else { throw DefinitionError.emptyName }
        guard name.count <= Self.maxNameLength else { throw DefinitionError.nameTooLong }
        guard summary.count <= Self.maxSummaryLength else { throw DefinitionError.summaryTooLong }
    }

    private func validate(_ snippet: SavedSnippet) throws {
        try validateAlias(snippet.alias, excluding: snippet.id)
        try validateCommon(name: snippet.name, summary: snippet.summary)
        guard !snippet.body.isEmpty else { throw DefinitionError.emptyBody }
        guard snippet.body.utf8.count <= Self.maxBodyBytes else { throw DefinitionError.bodyTooLarge }
    }

    private func validate(_ skill: CustomSkill) throws {
        try validateAlias(skill.alias, excluding: skill.id)
        try validateCommon(name: skill.name, summary: skill.summary)
        guard skill.instructions.contains(where: { !$0.isWhitespace }) else { throw DefinitionError.emptyInstructions }
        guard skill.instructions.utf8.count <= Self.maxInstructionBytes else { throw DefinitionError.instructionsTooLarge }
    }

    private func isBuiltIn(_ id: UUID) -> Bool { SlashCommandRegistry.builtInSkills.contains { $0.id == id } }

    // MARK: Snippets

    @discardableResult
    public mutating func addSnippet(name: String, alias: String, summary: String, body: String,
                                    restriction: SnippetRestriction = .any) throws -> SavedSnippet {
        let snippet = SavedSnippet(id: UUID(), revision: 1, name: name, alias: alias, summary: summary,
                                   body: body, enabled: true, restriction: restriction)
        try validate(snippet)
        snippets.append(snippet)
        return snippet
    }

    @discardableResult
    public mutating func updateSnippet(_ updated: SavedSnippet) throws -> SavedSnippet {
        guard let index = snippets.firstIndex(where: { $0.id == updated.id }) else { throw DefinitionError.notFound }
        try validate(updated)
        let stored = snippets[index]
        var next = updated
        next.revision = stored.revision
        if next == stored { return stored }
        next.revision = stored.revision + 1
        snippets[index] = next
        return next
    }

    @discardableResult
    public mutating func duplicateSnippet(id: UUID) throws -> SavedSnippet {
        guard let source = snippets.first(where: { $0.id == id }) else { throw DefinitionError.notFound }
        var copy = source
        copy.id = UUID(); copy.revision = 1; copy.enabled = true
        copy.name = Self.copyName(source.name)
        copy.alias = freeCopyAlias(for: source.alias)
        try validate(copy)
        snippets.append(copy)
        return copy
    }

    public mutating func setSnippetEnabled(id: UUID, enabled: Bool) throws {
        guard let index = snippets.firstIndex(where: { $0.id == id }) else { throw DefinitionError.notFound }
        guard snippets[index].enabled != enabled else { return }
        snippets[index].enabled = enabled
        snippets[index].revision += 1
    }

    public mutating func deleteSnippet(id: UUID) throws {
        guard let index = snippets.firstIndex(where: { $0.id == id }) else { throw DefinitionError.notFound }
        snippets.remove(at: index)
    }

    // MARK: Skills

    @discardableResult
    public mutating func addSkill(name: String, alias: String, summary: String, instructions: String,
                                  operation: SkillOperation) throws -> CustomSkill {
        let skill = CustomSkill(id: UUID(), revision: 1, name: name, alias: alias, summary: summary,
                                instructions: instructions, operation: operation, enabled: true, builtIn: false)
        try validate(skill)
        skills.append(skill)
        return skill
    }

    @discardableResult
    public mutating func updateSkill(_ updated: CustomSkill) throws -> CustomSkill {
        if updated.builtIn || isBuiltIn(updated.id) { throw DefinitionError.builtInReadOnly }
        guard let index = skills.firstIndex(where: { $0.id == updated.id }) else { throw DefinitionError.notFound }
        try validate(updated)
        let stored = skills[index]
        var next = updated
        next.revision = stored.revision
        if next == stored { return stored }
        next.revision = stored.revision + 1
        skills[index] = next
        return next
    }

    @discardableResult
    public mutating func duplicateSkill(id: UUID) throws -> CustomSkill {
        if isBuiltIn(id) { throw DefinitionError.builtInReadOnly }
        guard let source = skills.first(where: { $0.id == id }) else { throw DefinitionError.notFound }
        var copy = source
        copy.id = UUID(); copy.revision = 1; copy.enabled = true
        copy.name = Self.copyName(source.name)
        copy.alias = freeCopyAlias(for: source.alias)
        try validate(copy)
        skills.append(copy)
        return copy
    }

    public mutating func setSkillEnabled(id: UUID, enabled: Bool) throws {
        if isBuiltIn(id) { throw DefinitionError.builtInReadOnly }
        guard let index = skills.firstIndex(where: { $0.id == id }) else { throw DefinitionError.notFound }
        guard skills[index].enabled != enabled else { return }
        skills[index].enabled = enabled
        skills[index].revision += 1
    }

    public mutating func deleteSkill(id: UUID) throws {
        if isBuiltIn(id) { throw DefinitionError.builtInReadOnly }
        guard let index = skills.firstIndex(where: { $0.id == id }) else { throw DefinitionError.notFound }
        skills.remove(at: index)
    }

    // MARK: Duplicate naming

    private static func copyName(_ name: String) -> String {
        let suffix = " copy"
        return String(name.prefix(maxNameLength - suffix.count)) + suffix
    }

    /// "<alias>-copy", "<alias>-copy-2", ... truncating the stem so the whole alias stays within 32.
    private func freeCopyAlias(for alias: String) -> String {
        var number = 1
        while true {
            let suffix = number == 1 ? "-copy" : "-copy-\(number)"
            let candidate = String(alias.prefix(Self.maxAliasLength - suffix.count)) + suffix
            if !SlashCommandRegistry.reservedAliases.contains(candidate), !isAliasUsed(candidate, excluding: nil) {
                return candidate
            }
            number += 1
        }
    }
}
