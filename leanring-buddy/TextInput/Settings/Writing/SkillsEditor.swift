import SwiftUI

private struct SkillDraft {
    var id: UUID?
    var name = ""
    var alias = ""
    var summary = ""
    var instructions = ""
    var operation = SkillOperation.draft
    var enabled = true
    var builtIn = false

    init() {}
    init(_ skill: CustomSkill) {
        id = skill.id; name = skill.name; alias = skill.alias; summary = skill.summary
        instructions = skill.instructions; operation = skill.operation; enabled = skill.enabled; builtIn = skill.builtIn
    }
}

/// AI skills: built-in and custom skills on the left, the selected skill on the right. Built-ins are read-only.
struct SkillsEditor: View {
    @ObservedObject var store: WritingDefinitionsStore
    @State private var editing = false
    @State private var draft = SkillDraft()
    @State private var confirmDelete = false

    private var allSkills: [CustomSkill] { SlashCommandRegistry.builtInSkills + store.definitions.skills }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            DefinitionList(items: allSkills.map { Self.item($0) }, selection: editing ? draft.id : nil,
                           newTitle: "+ New skill", identifier: "writingSkillsList",
                           onSelect: { select($0) }, onNew: { startNew() })
            if editing { editor }
        }
        .onAppear { if !editing, let first = allSkills.first { select(first.id) } }
        .confirmationDialog("Delete skill?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { if let id = draft.id, store.deleteSkill(id) { editing = false } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private static func item(_ skill: CustomSkill) -> DefinitionListItem {
        let kind = skill.operation == .rewrite ? "Rewrites selection" : "Drafts text"
        return DefinitionListItem(id: skill.id, title: skill.name, alias: skill.alias,
                                  detail: (skill.builtIn ? "Built-in · " : "AI skill · ") + kind, enabled: skill.enabled)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsCard {
                SettingsRow(title: "Name") { DefinitionTextField(text: $draft.name) }
                SettingsDivider()
                SettingsRow(title: "Alias") { DefinitionTextField(text: $draft.alias, alias: true) }
                SettingsDivider()
                SettingsRow(title: "Description") { DefinitionTextField(text: $draft.summary) }
                SettingsDivider()
                SettingsRow(title: "Operation") {
                    Picker("", selection: $draft.operation) {
                        Text("Draft new text").tag(SkillOperation.draft)
                        Text("Rewrite selection").tag(SkillOperation.rewrite)
                    }
                    .labelsHidden().frame(width: 170)
                }
                SettingsDivider()
                SettingsRow(title: "Enabled") { SettingsSwitch(isOn: $draft.enabled, label: "Enabled") }
            }
            .disabled(draft.builtIn)
            HStack {
                Text("Instructions").font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Colors.textSecondary)
                Spacer()
                let used = draft.instructions.utf8.count
                Text("\(used) / \(WritingDefinitions.maxInstructionBytes) bytes").font(.system(size: 10))
                    .foregroundStyle(used > WritingDefinitions.maxInstructionBytes ? DS.Colors.destructiveText : DS.Colors.textTertiary)
            }
            .padding(.horizontal, 4)
            WritingTextEditor(text: $draft.instructions, identifier: "writingSkillInstructions", monospaced: false)
                .frame(minHeight: 120, maxHeight: 220)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(SettingsColors.cardBorder, lineWidth: 1))
                .disabled(draft.builtIn)
            SettingsNote(draft.builtIn
                         ? "Built-in skills cannot be changed. Duplicate one to make your own."
                         : "AI skills send these instructions and your selected text to the writing provider.")
            if draft.builtIn {
                Button("Duplicate as a new skill") { duplicateBuiltIn() }.islandButton(.secondary)
            } else {
                DefinitionActions(isNew: draft.id == nil, saveIdentifier: "writingSkillSave", onSave: save, onRevert: revert,
                                  onDuplicate: { if let id = draft.id, let copy = store.duplicateSkill(id) { select(copy.id) } },
                                  onDelete: { confirmDelete = true })
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func select(_ id: UUID) {
        guard let skill = allSkills.first(where: { $0.id == id }) else { return }
        store.clearError()
        draft = SkillDraft(skill)
        editing = true
    }

    private func startNew() {
        store.clearError()
        draft = SkillDraft()
        editing = true
    }

    /// Built-ins are read-only; a copy starts as an unsaved new skill with a free alias for the user to pick.
    private func duplicateBuiltIn() {
        var copy = draft
        copy.id = nil
        copy.builtIn = false
        copy.name += " copy"
        copy.alias += "-copy"
        store.clearError()
        draft = copy
    }

    private func revert() {
        store.clearError()
        if let id = draft.id { select(id) } else { editing = false }
    }

    private func save() {
        if let id = draft.id, var skill = store.definitions.skills.first(where: { $0.id == id }) {
            skill.name = draft.name; skill.alias = draft.alias; skill.summary = draft.summary
            skill.instructions = draft.instructions; skill.operation = draft.operation; skill.enabled = draft.enabled
            _ = store.saveSkill(skill)
        } else if let added = store.addSkill(name: draft.name, alias: draft.alias, summary: draft.summary,
                                              instructions: draft.instructions, operation: draft.operation) {
            if !draft.enabled { store.setSkillEnabled(added.id, false) }
            select(added.id)
        }
    }
}
