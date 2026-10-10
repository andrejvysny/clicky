import SwiftUI

/// Saved snippets, AI skills and the VS Code bridge. Edits persist only on explicit Save.
struct WritingPane: View {
    @EnvironmentObject private var context: SettingsContext
    @State private var section = WritingSection.snippets

    enum WritingSection: Hashable { case snippets, skills, bridge }

    var body: some View {
        let store = context.ask.writingDefinitions
        SettingsPage(title: "Writing", subtitle: "Saved snippets, AI skills and the VS Code bridge.") {
            SettingsSegmented(selection: $section, options: [(.snippets, "Snippets"), (.skills, "AI skills"), (.bridge, "VS Code")])
        } content: {
            switch section {
            case .snippets: SnippetsEditor(store: store)
            case .skills: SkillsEditor(store: store)
            case .bridge: BridgeSettings(store: store)
            }
            WritingStoreError(store: store)
        }
        .onChange(of: section) { _, _ in store.clearError() }
        .onDisappear { store.clearError() }
    }
}

private struct WritingStoreError: View {
    @ObservedObject var store: WritingDefinitionsStore

    var body: some View {
        if let error = store.lastError {
            Text(error).font(.system(size: 11)).foregroundStyle(DS.Colors.destructiveText).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: Shared master-detail pieces

/// One row in the left list of a writing editor.
struct DefinitionListItem: Identifiable {
    let id: UUID
    let title: String
    let alias: String
    let detail: String
    let enabled: Bool
}

struct DefinitionList: View {
    let items: [DefinitionListItem]
    let selection: UUID?
    let newTitle: String
    let identifier: String
    let onSelect: (UUID) -> Void
    let onNew: () -> Void

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(items) { item in
                    Button { onSelect(item.id) } label: { row(item) }.buttonStyle(.plain).clickyPointerCursor()
                }
                Button(newTitle, action: onNew).islandButton(.secondary).padding(.top, 6).padding(.leading, 4)
                    .accessibilityIdentifier(identifier + "New")
            }
            .padding(6)
        }
        .frame(width: 228)
        .accessibilityIdentifier(identifier)
    }

    private func row(_ item: DefinitionListItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(item.title).font(.system(size: 13)).lineLimit(1)
                Text("/" + item.alias).font(.system(size: 11, design: .monospaced)).foregroundStyle(DS.Colors.textSecondary).lineLimit(1)
            }
            Text(item.enabled ? item.detail : "Disabled").font(.system(size: 10)).foregroundStyle(DS.Colors.textTertiary).lineLimit(1)
        }
        .opacity(item.enabled ? 1 : 0.55)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selection == item.id ? SettingsColors.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }
}

struct DefinitionTextField: View {
    @Binding var text: String
    var alias = false

    var body: some View {
        HStack(spacing: 6) {
            if alias { Text("/").font(.system(size: 12, design: .monospaced)).foregroundStyle(DS.Colors.textSecondary) }
            TextField("", text: $text).textFieldStyle(.roundedBorder)
                .font(alias ? .system(size: 12, design: .monospaced) : .system(size: 12))
        }
        .frame(width: 280)
    }
}

/// Save, Revert on the left; Duplicate and Delete on the right for saved items.
struct DefinitionActions: View {
    let isNew: Bool
    let saveIdentifier: String
    let onSave: () -> Void
    let onRevert: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button("Save", action: onSave).islandButton(.primary).accessibilityIdentifier(saveIdentifier)
            Button(isNew ? "Cancel" : "Revert", action: onRevert).islandButton(.quiet)
            Spacer()
            if !isNew {
                Button("Duplicate", action: onDuplicate).islandButton(.quiet)
                Button("Delete", action: onDelete).islandButton(.quiet)
            }
        }
    }
}

// MARK: VS Code bridge

private struct BridgeSettings: View {
    @ObservedObject var store: WritingDefinitionsStore

    var body: some View {
        SettingsGroup {
            SettingsRow(title: "Allow the Clicky VS Code bridge",
                        subtitle: "A local opt-in extension. It can report the active editor and terminal, apply one versioned edit, and insert (never run) one line into the active terminal. Nothing leaves your Mac.") {
                SettingsSwitch(isOn: Binding(get: { store.bridgeEnabled }, set: { store.setBridgeEnabled($0) }), label: "VS Code bridge")
            }
        }
        SettingsGroup("Install") {
            VStack(alignment: .leading, spacing: 8) {
                SettingsNote("From the Clicky repository root:")
                Text("ln -s \"$PWD/Tools/clicky-vscode-bridge\" ~/.vscode/extensions/clicky-local.clicky-bridge-0.1.0")
                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.Colors.surface1, in: RoundedRectangle(cornerRadius: 6))
                SettingsNote("Then run \"Developer: Reload Window\" in VS Code. Turning the bridge off deletes the token; the extension closes its socket within 5 seconds. Choose Editor or Terminal in Quick Ask; Clicky cannot see which one had focus.")
            }
            .padding(14)
        }
        .onAppear { store.refreshBridge() }
    }
}
