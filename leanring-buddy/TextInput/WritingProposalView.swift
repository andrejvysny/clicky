import SwiftUI

/// The writing result under Quick Ask's input: destination, editable preview, optional before/after
/// comparison and the explicit controls. Nothing here writes to another application except the
/// Replace selection / Insert button, which goes through the coordinator's guarded apply.
struct WritingProposalView: View {
    @ObservedObject var writing: WritingCoordinator
    @State private var comparing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if let clarification = writing.clarification {
                Text(clarification).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("writingClarification")
            }
            if writing.proposal != nil {
                if let subject = writing.proposal?.subject {
                    Text("Subject suggestion (not inserted): " + subject).font(.system(size: 11))
                        .foregroundStyle(DS.Colors.textTertiary).textSelection(.enabled)
                }
                if comparing, let source = writing.source {
                    Text("Before").font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.Colors.textTertiary)
                    ScrollView { Text(source.text).font(.system(size: 12, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 90)
                    Text("After").font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.Colors.textTertiary)
                }
                WritingTextEditor(text: $writing.previewText, identifier: "writingPreview", monospaced: monospaced)
                    .frame(minHeight: 70, maxHeight: 180)
                    .disabled(writing.isBusy)
            }
            if let message = writing.invalidation ?? writing.notice {
                Text(message).font(.system(size: 11))
                    .foregroundStyle(writing.invalidation != nil ? DS.Colors.destructiveText : DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("writingStatus")
            }
            controls
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ghostPill()
    }

    private var monospaced: Bool { writing.target?.kind == .terminal || writing.target?.kind == .vscodeEditor || writing.proposal?.intent == .snippet }

    private var header: some View {
        HStack(spacing: 6) {
            if writing.phase == .generating || writing.phase == .applying { SpinnerRing(size: 9) }
            Text(title).font(.system(size: 11, weight: .semibold))
            Spacer(minLength: 4)
            if let target = writing.target {
                Text("→ " + destination(target)).font(.system(size: 10)).foregroundStyle(DS.Colors.textTertiary).lineLimit(1)
            }
            if writing.alternateTarget != nil, !writing.isBusy {
                Button("Switch") { writing.switchDestination() }.buttonStyle(.plain).font(.system(size: 10, weight: .medium))
                    .help("Choose VS Code's editor or integrated terminal").clickyPointerCursor()
                    .accessibilityIdentifier("writingSwitchDestination")
            }
        }
    }

    private var title: String {
        switch writing.phase {
        case .generating: return "Writing…"
        case .applying: return "Inserting…"
        case .finished: return writing.notice ?? "Done"
        default:
            if writing.canRetry { return "Writing failed" }
            if writing.clarification != nil, writing.proposal == nil { return "Question" }
            if writing.proposal?.intent == .snippet { return "Snippet · No AI" }
            return writing.proposal?.intent == .rewrite ? "Rewrite preview" : "Draft preview"
        }
    }

    private func destination(_ target: TextTargetSnapshot) -> String {
        switch target.kind {
        case .terminal: return target.applicationName + " prompt"
        case .vscodeEditor: return target.applicationName + " editor"
        case .textField: return target.applicationName + (target.hasSelection ? " selection" : " caret")
        }
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: 10) {
            if writing.canApply {
                button(writing.target?.pasteOnly == true ? "Paste" : writing.replacesSelection ? "Replace selection" : "Insert",
                       id: "writingApply", primary: true) { writing.apply() }
                    .help("↩ in an empty input also applies")
            }
            if writing.isBusy {
                button("Stop", id: "writingStop") { writing.stop() }
            } else if writing.hasProposal {
                button("Copy", id: "writingCopy") { writing.copyProposal() }
                if writing.source != nil { button(comparing ? "Hide before" : "Compare", id: "writingCompare") { comparing.toggle() } }
                if writing.lastEdit != nil, writing.phase == .finished {
                    button("Restore original", id: "writingRestore") { writing.restoreOriginal() }
                }
                button("Discard", id: "writingDiscard") { writing.discard() }
            } else if writing.canRetry {
                button("Retry", id: "writingRetry", primary: true) { writing.retry() }
                button("Discard", id: "writingDiscard") { writing.discard() }
            }
            Spacer(minLength: 0)
            if writing.canRefine, writing.proposal == nil {
                Text("Type your answer").font(.system(size: 10)).foregroundStyle(DS.Colors.textTertiary)
            } else if writing.canRefine { Text("Type to refine").font(.system(size: 10)).foregroundStyle(DS.Colors.textTertiary) }
        }
    }

    private func button(_ title: String, id: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: primary ? .semibold : .regular))
                .foregroundStyle(primary ? Color.black : Color.white)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(primary ? ClickyChrome.ask : Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain).clickyPointerCursor().accessibilityIdentifier(id)
    }
}
