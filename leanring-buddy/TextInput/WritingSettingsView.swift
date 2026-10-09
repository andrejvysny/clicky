import AppKit
import SwiftUI

/// Settings for saved snippets, custom AI skills and the VS Code bridge. Edits persist only on explicit Save.
struct WritingSettingsView: View {
    @ObservedObject var store: WritingDefinitionsStore
    @State private var tab = Tab.snippets

    enum Tab: String, CaseIterable { case snippets = "Snippets", skills = "AI skills", bridge = "VS Code" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().clickyPointerCursor()
            switch tab {
            case .snippets: SnippetsSettingsTab(store: store)
            case .skills: SkillsSettingsTab(store: store)
            case .bridge: BridgeSettingsTab(store: store)
            }
            if let error = store.lastError {
                Text(error).font(.system(size: 11)).foregroundStyle(DS.Colors.destructiveText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: tab) { _, _ in store.clearError() }
    }
}

private enum EditorSelection: Equatable {
    case new
    case existing(UUID)
}

// MARK: Snippets

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

private struct SnippetsSettingsTab: View {
    @ObservedObject var store: WritingDefinitionsStore
    @State private var selection: EditorSelection?
    @State private var draft = SnippetDraft()
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                if store.definitions.snippets.isEmpty {
                    WritingNote("No snippets yet. A snippet is saved literal text, inserted as is without AI.")
                }
                ForEach(store.definitions.snippets) { snippet in
                    Button { select(.existing(snippet.id)) } label: { row(snippet) }
                        .buttonStyle(.plain).clickyPointerCursor()
                }
            }
            .accessibilityIdentifier("writingSnippetsList")
            Button("New snippet") { select(.new) }.islandButton(.secondary)
            if selection != nil { editor }
        }
    }

    private func row(_ snippet: SavedSnippet) -> some View {
        let isSelected = selection == .existing(snippet.id)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(snippet.name).font(.system(size: 12, weight: .medium))
                Text("/" + snippet.alias).font(.system(size: 11, design: .monospaced)).foregroundStyle(DS.Colors.textSecondary)
                WritingBadge("Snippet · No AI")
                if !snippet.enabled { WritingBadge("Disabled") }
                Spacer(minLength: 0)
            }
            Text(TerminalPayload.summary(TerminalPayload.hazards(in: snippet.body)))
                .font(.system(size: 10)).foregroundStyle(DS.Colors.textTertiary)
        }
        .opacity(snippet.enabled ? 1 : 0.5)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? DS.Colors.surface3 : DS.Colors.surface1, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            WritingField("Name", text: $draft.name)
            WritingAliasField(alias: $draft.alias)
            WritingField("Description", text: $draft.summary)
            Picker("Restriction", selection: $draft.restriction) {
                Text("Any").tag(SnippetRestriction.any)
                Text("Editors only").tag(SnippetRestriction.editorsOnly)
                Text("Terminal only").tag(SnippetRestriction.terminalOnly)
            }
            .font(.system(size: 12)).clickyPointerCursor()
            Text("Body").font(.system(size: 11)).foregroundStyle(DS.Colors.textSecondary)
            WritingTextEditor(text: $draft.body, identifier: "writingSnippetBody")
                .frame(minHeight: 120, maxHeight: 220)
            Toggle("Enabled", isOn: $draft.enabled).font(.system(size: 12)).clickyPointerCursor()
            HStack(spacing: 6) {
                Button("Save") { save() }.islandButton(.secondary).accessibilityIdentifier("writingSnippetSave")
                Button(draft.id == nil ? "Cancel" : "Revert") { revert() }.islandButton(.quiet)
                if let id = draft.id {
                    Button("Duplicate") { if let copy = store.duplicateSnippet(id) { select(.existing(copy.id)) } }
                        .islandButton(.quiet)
                    Button("Delete") { confirmDelete = true }.islandButton(.quiet)
                }
            }
        }
        .padding(10)
        .background(DS.Colors.surface2, in: RoundedRectangle(cornerRadius: 8))
        .confirmationDialog("Delete snippet?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                if let id = draft.id, store.deleteSnippet(id) { selection = nil }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func select(_ next: EditorSelection) {
        store.clearError()
        selection = next
        draft = loadDraft(next)
    }

    private func loadDraft(_ target: EditorSelection) -> SnippetDraft {
        if case .existing(let id) = target, let snippet = store.definitions.snippets.first(where: { $0.id == id }) {
            return SnippetDraft(snippet)
        }
        return SnippetDraft()
    }

    private func revert() {
        store.clearError()
        if let selection, draft.id != nil { draft = loadDraft(selection) } else { selection = nil }
    }

    private func save() {
        if let id = draft.id, var snippet = store.definitions.snippets.first(where: { $0.id == id }) {
            snippet.name = draft.name; snippet.alias = draft.alias; snippet.summary = draft.summary
            snippet.body = draft.body; snippet.restriction = draft.restriction; snippet.enabled = draft.enabled
            _ = store.saveSnippet(snippet)
        } else if let added = store.addSnippet(name: draft.name, alias: draft.alias, summary: draft.summary,
                                                body: draft.body, restriction: draft.restriction) {
            if !draft.enabled { store.setSnippetEnabled(added.id, false) }
            select(.existing(added.id))
        }
    }
}

// MARK: AI skills

private struct SkillDraft {
    var id: UUID?
    var name = ""
    var alias = ""
    var summary = ""
    var instructions = ""
    var operation = SkillOperation.draft
    var enabled = true

    init() {}
    init(_ skill: CustomSkill) {
        id = skill.id; name = skill.name; alias = skill.alias; summary = skill.summary
        instructions = skill.instructions; operation = skill.operation; enabled = skill.enabled
    }
}

private struct SkillsSettingsTab: View {
    @ObservedObject var store: WritingDefinitionsStore
    @State private var selection: EditorSelection?
    @State private var draft = SkillDraft()
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(SlashCommandRegistry.builtInSkills) { skill in
                    row(skill, name: skill.name, alias: skill.alias, builtIn: true, enabled: true, selected: false)
                }
                ForEach(store.definitions.skills) { skill in
                    Button { select(.existing(skill.id)) } label: {
                        row(skill, name: skill.name, alias: skill.alias, builtIn: false, enabled: skill.enabled,
                            selected: selection == .existing(skill.id))
                    }
                    .buttonStyle(.plain).clickyPointerCursor()
                }
            }
            .accessibilityIdentifier("writingSkillsList")
            WritingNote("AI skills send their instructions and your selected text to the chosen provider. Built-in skills cannot be changed.")
            Button("New skill") { select(.new) }.islandButton(.secondary)
            if selection != nil { editor }
        }
    }

    private func row(_ skill: CustomSkill, name: String, alias: String, builtIn: Bool, enabled: Bool, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(name).font(.system(size: 12, weight: .medium))
                Text("/" + alias).font(.system(size: 11, design: .monospaced)).foregroundStyle(DS.Colors.textSecondary)
                if builtIn { WritingBadge("Built-in") } else if !enabled { WritingBadge("Disabled") }
                Spacer(minLength: 0)
            }
            Text(skill.summary).font(.system(size: 10)).foregroundStyle(DS.Colors.textTertiary)
        }
        .opacity(enabled ? 1 : 0.5)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? DS.Colors.surface3 : DS.Colors.surface1, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            WritingField("Name", text: $draft.name)
            WritingAliasField(alias: $draft.alias)
            WritingField("Description", text: $draft.summary)
            Picker("Operation", selection: $draft.operation) {
                Text("Draft new text").tag(SkillOperation.draft)
                Text("Rewrite selection").tag(SkillOperation.rewrite)
            }
            .font(.system(size: 12)).clickyPointerCursor()
            HStack {
                Text("Instructions").font(.system(size: 11)).foregroundStyle(DS.Colors.textSecondary)
                Spacer()
                let used = draft.instructions.utf8.count
                Text("\(used) / \(WritingDefinitions.maxInstructionBytes) bytes").font(.system(size: 10))
                    .foregroundStyle(used > WritingDefinitions.maxInstructionBytes ? DS.Colors.destructiveText : DS.Colors.textTertiary)
            }
            WritingTextEditor(text: $draft.instructions, identifier: "writingSkillInstructions", monospaced: false)
                .frame(minHeight: 120, maxHeight: 220)
            Toggle("Enabled", isOn: $draft.enabled).font(.system(size: 12)).clickyPointerCursor()
            HStack(spacing: 6) {
                Button("Save") { save() }.islandButton(.secondary).accessibilityIdentifier("writingSkillSave")
                Button(draft.id == nil ? "Cancel" : "Revert") { revert() }.islandButton(.quiet)
                if let id = draft.id {
                    Button("Duplicate") { if let copy = store.duplicateSkill(id) { select(.existing(copy.id)) } }
                        .islandButton(.quiet)
                    Button("Delete") { confirmDelete = true }.islandButton(.quiet)
                }
            }
        }
        .padding(10)
        .background(DS.Colors.surface2, in: RoundedRectangle(cornerRadius: 8))
        .confirmationDialog("Delete skill?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                if let id = draft.id, store.deleteSkill(id) { selection = nil }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func select(_ next: EditorSelection) {
        store.clearError()
        selection = next
        draft = loadDraft(next)
    }

    private func loadDraft(_ target: EditorSelection) -> SkillDraft {
        if case .existing(let id) = target, let skill = store.definitions.skills.first(where: { $0.id == id }) {
            return SkillDraft(skill)
        }
        return SkillDraft()
    }

    private func revert() {
        store.clearError()
        if let selection, draft.id != nil { draft = loadDraft(selection) } else { selection = nil }
    }

    private func save() {
        if let id = draft.id, var skill = store.definitions.skills.first(where: { $0.id == id }) {
            skill.name = draft.name; skill.alias = draft.alias; skill.summary = draft.summary
            skill.instructions = draft.instructions; skill.operation = draft.operation; skill.enabled = draft.enabled
            _ = store.saveSkill(skill)
        } else if let added = store.addSkill(name: draft.name, alias: draft.alias, summary: draft.summary,
                                              instructions: draft.instructions, operation: draft.operation) {
            if !draft.enabled { store.setSkillEnabled(added.id, false) }
            select(.existing(added.id))
        }
    }
}

// MARK: VS Code bridge

private struct BridgeSettingsTab: View {
    @ObservedObject var store: WritingDefinitionsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Allow the Clicky VS Code bridge", isOn: Binding(
                get: { store.bridgeEnabled }, set: { store.setBridgeEnabled($0) }))
                .font(.system(size: 12)).clickyPointerCursor()
            WritingNote("The bridge is a local opt-in VS Code extension. It can only report the active editor and terminal, apply one versioned edit, and insert (never run) one line into the active terminal. It uses a private local socket; nothing leaves your Mac.")
            WritingNote("Install, from the Clicky repository root:")
            Text("ln -s \"$PWD/Tools/clicky-vscode-bridge\" ~/.vscode/extensions/clicky-local.clicky-bridge-0.1.0")
                .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.Colors.surface1, in: RoundedRectangle(cornerRadius: 6))
            WritingNote("Then run \"Developer: Reload Window\" in VS Code. Turning the bridge off deletes the token; the extension closes its socket within 5 seconds.")
            WritingNote("Choose Editor or Terminal in Quick Ask; Clicky cannot see which one had focus.")
        }
        .onAppear { store.refreshBridge() }
    }
}

// MARK: Shared pieces

private struct WritingNote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 11)).foregroundStyle(DS.Colors.textTertiary).fixedSize(horizontal: false, vertical: true)
    }
}

private struct WritingBadge: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 9, weight: .medium)).foregroundStyle(DS.Colors.textSecondary)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(DS.Colors.surface4, in: Capsule())
    }
}

private struct WritingField: View {
    let label: String
    @Binding var text: String
    init(_ label: String, text: Binding<String>) { self.label = label; _text = text }
    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11)).foregroundStyle(DS.Colors.textSecondary).frame(width: 74, alignment: .leading)
            TextField("", text: $text).textFieldStyle(.roundedBorder).font(.system(size: 12))
        }
    }
}

private struct WritingAliasField: View {
    @Binding var alias: String
    var body: some View {
        HStack(spacing: 8) {
            Text("Alias").font(.system(size: 11)).foregroundStyle(DS.Colors.textSecondary).frame(width: 74, alignment: .leading)
            Text("/").font(.system(size: 12, design: .monospaced)).foregroundStyle(DS.Colors.textSecondary)
            TextField("", text: $alias).textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
        }
    }
}

/// Plain NSTextView: no smart quotes, dashes, replacement or spelling correction, and the text is never trimmed.
struct WritingTextEditor: NSViewRepresentable {
    @Binding var text: String
    var identifier: String
    var monospaced = true

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView(frame: .zero)
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(DS.Colors.surface1)
        scrollView.borderType = .noBorder
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 120))
        editor.delegate = context.coordinator
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticTextCompletionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.isAutomaticDataDetectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.smartInsertDeleteEnabled = false
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: 6, height: 6)
        editor.font = monospaced ? .monospacedSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 12)
        editor.textColor = .white
        editor.insertionPointColor = .white
        editor.drawsBackground = false
        editor.string = text
        editor.setAccessibilityIdentifier(identifier)
        scrollView.documentView = editor
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scrollView.documentView as? NSTextView, editor.string != text else { return }
        editor.string = text
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: WritingTextEditor
        init(_ parent: WritingTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
    }
}
