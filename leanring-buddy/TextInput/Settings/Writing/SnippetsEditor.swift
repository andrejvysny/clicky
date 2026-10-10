import SwiftUI

private struct SnippetDraft {
    var id: UUID?
    var name = ""
    var alias = ""
    var summary = ""
    var body = ""
    var restriction = SnippetRestriction.any
    var enabled = true

    init() {}
    init(_ snippet: SavedSnippet) {
        id = snippet.id; name = snippet.name; alias = snippet.alias; summary = snippet.summary
        body = snippet.body; restriction = snippet.restriction; enabled = snippet.enabled
    }
}

/// Snippets: the list on the left, the selected snippet's editor on the right.
struct SnippetsEditor: View {
    @ObservedObject var store: WritingDefinitionsStore
    @State private var editing = false
    @State private var draft = SnippetDraft()
    @State private var confirmDelete = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            DefinitionList(items: store.definitions.snippets.map { Self.item($0) }, selection: editing ? draft.id : nil,
                           newTitle: "+ New snippet", identifier: "writingSnippetsList",
                           onSelect: { select($0) }, onNew: { startNew() })
            if editing { editor } else { placeholder }
        }
        .onAppear { if !editing, let first = store.definitions.snippets.first { select(first.id) } }
        .confirmationDialog("Delete snippet?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { if let id = draft.id, store.deleteSnippet(id) { editing = false } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private static func item(_ snippet: SavedSnippet) -> DefinitionListItem {
        DefinitionListItem(id: snippet.id, title: snippet.name, alias: snippet.alias,
                           detail: "Snippet · No AI · " + restrictionLabel(snippet.restriction), enabled: snippet.enabled)
    }

    static func restrictionLabel(_ restriction: SnippetRestriction) -> String {
        switch restriction {
        case .any: return "Any app"
        case .editorsOnly: return "Editors only"
        case .terminalOnly: return "Terminal only"
        }
    }

    private var placeholder: some View {
        SettingsNote("No snippets yet. A snippet is saved text you insert with /alias, as is and without AI.")
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
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
                SettingsRow(title: "Restriction") {
                    Picker("", selection: $draft.restriction) {
                        ForEach([SnippetRestriction.any, .editorsOnly, .terminalOnly], id: \.self) { Text(Self.restrictionLabel($0)).tag($0) }
                    }
                    .labelsHidden().frame(width: 150)
                }
                SettingsDivider()
                SettingsRow(title: "Enabled") { SettingsSwitch(isOn: $draft.enabled, label: "Enabled") }
            }
            Text("Body").font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Colors.textSecondary).padding(.leading, 4)
            WritingTextEditor(text: $draft.body, identifier: "writingSnippetBody")
                .frame(minHeight: 120, maxHeight: 220)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(SettingsColors.cardBorder, lineWidth: 1))
            SettingsNote(TerminalPayload.summary(TerminalPayload.hazards(in: draft.body)) + " Inserted exactly as written. No AI, nothing sent.")
            DefinitionActions(isNew: draft.id == nil, saveIdentifier: "writingSnippetSave", onSave: save, onRevert: revert,
                              onDuplicate: { if let id = draft.id, let copy = store.duplicateSnippet(id) { select(copy.id) } },
                              onDelete: { confirmDelete = true })
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func select(_ id: UUID) {
        guard let snippet = store.definitions.snippets.first(where: { $0.id == id }) else { return }
        store.clearError()
        draft = SnippetDraft(snippet)
        editing = true
    }

    private func startNew() {
        store.clearError()
        draft = SnippetDraft()
        editing = true
    }

    private func revert() {
        store.clearError()
        if let id = draft.id { select(id) } else { editing = false }
    }

    private func save() {
        if let id = draft.id, var snippet = store.definitions.snippets.first(where: { $0.id == id }) {
            snippet.name = draft.name; snippet.alias = draft.alias; snippet.summary = draft.summary
            snippet.body = draft.body; snippet.restriction = draft.restriction; snippet.enabled = draft.enabled
            _ = store.saveSnippet(snippet)
        } else if let added = store.addSnippet(name: draft.name, alias: draft.alias, summary: draft.summary,
                                                body: draft.body, restriction: draft.restriction) {
            if !draft.enabled { store.setSnippetEnabled(added.id, false) }
            select(added.id)
        }
    }
}
