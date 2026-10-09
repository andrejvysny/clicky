import AppKit
import SwiftUI

/// Menu bar panel (component sheet C8): session status first, then modes, last reply and app controls.
struct TextCompanionPanelView: View {
    @ObservedObject var controller: AskController
    @ObservedObject var companionManager: CompanionManager
    let onOpenQuickAsk: (QuickAskPresentation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            sessionCard
            modes
            if let warning = controller.shortcutWarning { Text(warning).font(.caption).foregroundStyle(DS.Colors.warningText) }
            if let error = controller.errorMessage { Text(error).font(.caption).foregroundStyle(DS.Colors.warningText).lineLimit(4) }
            if !controller.response.isEmpty || controller.isBusy {
                divider
                LastReplySection(controller: controller, onOpen: { onOpenQuickAsk(.details(showSettings: false)) })
            }
            divider
            Toggle("Show blue companion", isOn: Binding(get: { companionManager.isClickyCursorEnabled }, set: { companionManager.setClickyCursorEnabled($0) }))
                .toggleStyle(.switch).controlSize(.mini).font(.system(size: 12)).foregroundStyle(DS.Colors.textSecondary)
            HStack(spacing: 14) {
                Button("Settings…") { onOpenQuickAsk(.details(showSettings: true)) }.buttonStyle(.plain).clickyPointerCursor()
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.plain).foregroundStyle(DS.Colors.textTertiary).clickyPointerCursor()
            }
            .font(.system(size: 12)).foregroundStyle(DS.Colors.textSecondary)
            Text("Visual guidance is a development feature pending native acceptance.")
                .font(.system(size: 10)).foregroundStyle(DS.Colors.textTertiary)
        }
        .padding(16)
        .frame(width: 320)
        .foregroundStyle(.white)
        .background(ClickyChrome.panel, in: RoundedRectangle(cornerRadius: 12))
        .preferredColorScheme(.dark)
    }

    private var divider: some View { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }

    private var header: some View {
        HStack(spacing: 8) {
            Triangle().fill(ClickyChrome.ask).frame(width: 18, height: 16).rotationEffect(.degrees(35))
            Text("Clicky").font(.system(size: 13, weight: .semibold))
            Spacer()
            let state = sessionState
            HStack(spacing: 5) {
                StatusDot(color: state.color, outlined: state.outlined)
                Text(state.label)
            }
            .font(.system(size: 11)).foregroundStyle(DS.Colors.textSecondary)
            .accessibilityElement(children: .combine)
        }
    }

    private var sessionState: (label: String, color: Color, outlined: Bool) {
        if controller.isBusy { return ("Working", DS.Colors.blue400, false) }
        if controller.guide.task?.phase == .completed { return ("Finished", DS.Colors.textSecondary, false) }
        if [.waiting, .uncertain].contains(controller.guide.task?.phase) { return ("Waiting for you", ClickyChrome.ask, true) }
        if controller.session != nil { return ("Connected", DS.Colors.success, false) }
        return ("Ready", DS.Colors.textTertiary, false)
    }

    private var sessionCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(controller.provider.displayName).font(.system(size: 12, weight: .medium))
                Text(controller.provider == .preview ? "no AI" : "managed")
                    .font(.system(size: 10)).foregroundStyle(DS.Colors.textSecondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 3))
                Spacer()
                Button("Switch") { onOpenQuickAsk(.details(showSettings: true)) }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(DS.Colors.blue400).clickyPointerCursor()
            }
            Text(controller.session.map { "Clicky-owned task · " + String($0.identifier.prefix(12)) + "…" } ?? "New Clicky-owned task session")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(DS.Colors.textTertiary).lineLimit(1)
            HStack(spacing: 6) {
                Text("Terminal attach").foregroundStyle(DS.Colors.textSecondary)
                Text("Not enabled")
            }
            .font(.system(size: 11)).foregroundStyle(DS.Colors.textTertiary)
        }
        .padding(10)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private var modes: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button { onOpenQuickAsk(.ghost) } label: {
                ModeRow(shortcut: ShortcutLabel.text(keyCode: controller.shortcutKeyCode, modifiers: controller.shortcutModifiers)) {
                    Triangle().fill(ClickyChrome.ask).frame(width: 9, height: 8)
                    Text("Quick Ask")
                }
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain).accessibilityLabel("Ask Clicky").clickyPointerCursor()
            Button { controller.cycleEffort() } label: {
                ModeRow(shortcut: "⌥⇧E in Quick Ask") {
                    EffortPips(effort: controller.displayedEffort, size: 3).frame(width: 9)
                    Text("Effort · \(controller.displayedEffort.displayName), resets each prompt")
                }
            }
            .buttonStyle(.plain).disabled(!controller.effortAdjustable).clickyPointerCursor()
            ModeRow(shortcut: "Not enabled") {
                Triangle().fill(ClickyChrome.ask.opacity(0.4)).frame(width: 9, height: 8)
                Text("Ask by voice")
            }
            .foregroundStyle(DS.Colors.textTertiary)
            ModeRow(shortcut: "Not enabled") {
                RoundedRectangle(cornerRadius: 1).fill(Color(hex: "#F0784A").opacity(0.5)).frame(width: 2, height: 11).frame(width: 9)
                Text("Dictate anywhere")
            }
            .foregroundStyle(DS.Colors.textTertiary)
        }
    }
}

private struct ModeRow<Icon: View>: View {
    let shortcut: String
    @ViewBuilder let icon: Icon

    var body: some View {
        HStack(spacing: 8) {
            icon
            Spacer(minLength: 8)
            Text(shortcut).font(.system(size: 11)).foregroundStyle(DS.Colors.textTertiary)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 8).padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

private struct LastReplySection: View {
    @ObservedObject var controller: AskController
    @ObservedObject var speech: LocalReplySpeech
    let onOpen: () -> Void

    init(controller: AskController, onOpen: @escaping () -> Void) {
        self.controller = controller; speech = controller.replySpeech; self.onOpen = onOpen
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if controller.isBusy {
                HStack(spacing: 6) {
                    SpinnerRing(size: 9)
                    Text("Working on your request").font(.system(size: 11)).foregroundStyle(DS.Colors.textSecondary)
                    Spacer()
                    Button("Stop reply") { controller.stopReply() }.buttonStyle(.plain).font(.system(size: 11)).clickyPointerCursor()
                }
            }
            if !controller.response.isEmpty {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(lastReplyLabel(now: context.date)).font(.system(size: 11)).foregroundStyle(DS.Colors.textTertiary)
                }
                Text(controller.response).font(.system(size: 12)).foregroundStyle(DS.Colors.textSecondary).lineLimit(2)
                HStack(spacing: 6) {
                    pill("Open", action: onOpen).accessibilityLabel("Read last reply")
                    pill("Copy") { controller.copyResponse() }.accessibilityLabel("Copy last reply")
                    if speech.isSpeaking { pill("Stop speaking") { speech.stop() } }
                    else { pill("Speak") { speech.speak(controller.response) }.accessibilityLabel("Speak last reply") }
                }
            }
        }
    }

    private func lastReplyLabel(now: Date) -> String {
        guard let at = controller.lastReplyAt else { return "Last reply" }
        let minutes = Int(now.timeIntervalSince(at) / 60)
        return minutes < 1 ? "Last reply · just now" : "Last reply · \(minutes) min ago"
    }

    private func pill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain).font(.system(size: 12))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
            .clickyPointerCursor()
    }
}
