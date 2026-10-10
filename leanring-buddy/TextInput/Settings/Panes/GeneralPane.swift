import SwiftUI

struct GeneralPane: View {
    @EnvironmentObject private var context: SettingsContext

    var body: some View {
        SettingsPage(title: "General") {
            Content(controller: context.ask, context: context)
            if let companion = context.companion { CompanionGroup(companion: companion) }
        }
    }

    private struct Content: View {
        @ObservedObject var controller: AskController
        let context: SettingsContext

        var body: some View {
            // Switching providers mid-reply would close the live session, so the assistant group waits.
            SettingsGroup("Assistant") {
                SettingsRow(title: "Backend", subtitle: backendNote) {
                    SettingsSegmented(selection: $controller.provider,
                                      options: AgentProvider.allCases.map { ($0, Self.shortName($0)) })
                }
                if controller.provider.needsExecutable {
                    SettingsDivider()
                    executableRow
                }
                if controller.provider == .local || controller.writingProvider == .local, let runtime = context.runtime {
                    SettingsDivider()
                    LocalModelRow(runtime: runtime, context: context)
                }
                SettingsDivider()
                SettingsRow(title: "Writing skills use", subtitle: "/write, /rewrite and AI skills. Snippets never use a provider.") {
                    Picker("", selection: writingChoice) {
                        Text("Same as backend").tag(WritingChoice.sameAsBackend)
                        Divider()
                        ForEach(AgentProvider.allCases, id: \.self) { Text(Self.shortName($0)).tag(WritingChoice.provider($0)) }
                    }
                    .labelsHidden().frame(width: 170)
                }
                if controller.provider == .preview {
                    SettingsDivider()
                    SettingsRow(title: "Guide demo", subtitle: "Walks through a sample task. Nothing is sent and no AI is used.") {
                        Button("Start demo") { controller.guide.startDemo() }.islandButton(.secondary)
                    }
                }
            }
            .disabled(controller.isBusy)
            SettingsGroup("Conversation") {
                if controller.provider != .local {
                    SettingsRow(title: "Effort", subtitle: "Every prompt starts at Low. ⌥⇧E raises it for that prompt only.") {
                        HStack(spacing: 6) {
                            EffortPips(effort: controller.displayedEffort, size: 3)
                            Text(controller.displayedEffort.displayName).font(.system(size: 12)).foregroundStyle(DS.Colors.textSecondary)
                        }
                    }
                    SettingsDivider()
                }
                SettingsRow(title: "Speak replies") {
                    Picker("", selection: $controller.speechPreference) {
                        ForEach(SpeechReplyPreference.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().frame(width: 170)
                }
                SettingsDivider()
                VStack(alignment: .leading, spacing: 0) {
                    SettingsRow(title: "Current conversation") {
                        Button("New conversation") { controller.newConversation() }.islandButton(.secondary).disabled(controller.isBusy)
                    }
                    Text(controller.session.map { "Clicky-owned task · " + String($0.identifier.prefix(8)) + "…" } ?? "No conversation yet")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(DS.Colors.textTertiary)
                        .padding(.horizontal, 14).padding(.top, -8).padding(.bottom, 10)
                }
            }
        }

        private var backendNote: String {
            switch controller.provider {
            case .claude: return "Haiku 5.5 with your Claude sign-in. Raising effort starts a new conversation."
            case .codex: return "GPT-6 Luna in a separate Clicky-owned Codex profile. Effort applies per prompt."
            case .local: return "The selected vision model in Models, on this Mac. Nothing is sent over the network; there is no cloud fallback."
            default: return "Local preview sends nothing and uses no AI."
            }
        }

        private var executableRow: some View {
            let path = controller.provider == .claude ? $controller.claudeExecutable : $controller.codexExecutable
            let found = FileManager.default.isExecutableFile(atPath: path.wrappedValue)
            return VStack(alignment: .leading, spacing: 8) {
                SettingsRow(title: "Executable") {
                    HStack(spacing: 6) {
                        // Read-only: an editable field would take first responder when the window opens.
                        Text(path.wrappedValue.isEmpty ? "Not set" : path.wrappedValue)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(path.wrappedValue.isEmpty ? DS.Colors.textTertiary : DS.Colors.textSecondary)
                            .lineLimit(1).truncationMode(.middle)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .frame(width: 260, alignment: .leading)
                            .background(DS.Colors.surface1, in: RoundedRectangle(cornerRadius: 5))
                            .help(path.wrappedValue)
                        Button("Choose…") { controller.chooseExecutable() }.islandButton(.secondary).fixedSize()
                    }
                }
                HStack(spacing: 5) {
                    Circle().fill(found ? DS.Colors.success : DS.Colors.warningText).frame(width: 6, height: 6)
                    Text(found ? "Found" : "Not found").font(.system(size: 11)).foregroundStyle(found ? DS.Colors.success : DS.Colors.warningText)
                    if controller.provider == .codex {
                        Spacer()
                        Button("Sign in to Clicky Codex") { controller.signInCodex() }.islandButton(.secondary)
                    }
                }
                .padding(.horizontal, 14).padding(.top, -14).padding(.bottom, 10)
            }
        }

        private static func shortName(_ provider: AgentProvider) -> String {
            switch provider {
            case .preview: return "Preview"
            case .local: return "On-device"
            default: return provider.displayName
            }
        }

        private enum WritingChoice: Hashable { case sameAsBackend, provider(AgentProvider) }

        private var writingChoice: Binding<WritingChoice> {
            Binding(get: { controller.writingFollowsBackend ? .sameAsBackend : .provider(controller.writingProvider) },
                    set: { choice in
                        switch choice {
                        case .sameAsBackend: controller.writingFollowsBackend = true
                        case .provider(let provider):
                            controller.writingFollowsBackend = false
                            controller.writingProvider = provider
                        }
                    })
        }
    }

    /// Which local model answers and whether it is loaded; loading itself stays in Models.
    private struct LocalModelRow: View {
        @ObservedObject var runtime: LocalAIRuntime
        let context: SettingsContext

        var body: some View {
            SettingsRow(title: "On-device model", subtitle: status) {
                Button("Models…") { context.selection = .models }.islandButton(.secondary).fixedSize()
            }
        }

        private var status: String {
            let name = runtime.displayName(.vision)
            guard runtime.installedModel(.vision) != nil else { return "\(name) is not installed. Download it in Models." }
            if runtime.isLoaded(.vision) { return "\(name) · loaded" }
            return runtime.residency[.vision].load == .manual ? "\(name) · not loaded. Load it in Models, or set it to load on demand."
                : "\(name) · loads when you ask"
        }
    }

    private struct CompanionGroup: View {
        @ObservedObject var companion: CompanionManager

        var body: some View {
            SettingsGroup("Companion") {
                SettingsRow(title: "Show blue companion") {
                    SettingsSwitch(isOn: Binding(get: { companion.isClickyCursorEnabled }, set: { companion.setClickyCursorEnabled($0) }),
                                   label: "Show blue companion")
                }
            }
        }
    }
}
