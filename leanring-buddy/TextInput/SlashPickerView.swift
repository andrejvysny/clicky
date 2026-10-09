import SwiftUI

/// Keyboard-first suggestions for a leading "/": kind badge, alias, argument hint and availability.
/// Choosing a row only completes the command in the input; a later explicit Enter invokes it.
struct SlashPickerView: View {
    let suggestions: [SlashCommand]
    let highlighted: Int
    let onComplete: (SlashCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, command in
                Button { onComplete(command) } label: { row(command, selected: index == highlighted) }
                    .buttonStyle(.plain)
                    .clickyPointerCursor()
                    .accessibilityLabel("/\(command.alias), \(command.badge), \(command.summary)")
                    .accessibilityAddTraits(index == highlighted ? .isSelected : [])
            }
            Text("↑↓ choose · Tab or ↩ completes · Esc hides · // sends a literal slash")
                .font(.system(size: 10)).foregroundStyle(DS.Colors.textTertiary)
                .padding(.horizontal, 6).padding(.top, 2)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ghostPill()
        .accessibilityIdentifier("quickAskSlashPicker")
    }

    private func row(_ command: SlashCommand, selected: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("/" + command.alias).font(.system(size: 12, weight: .semibold, design: .monospaced))
            if let hint = command.argumentHint {
                Text(hint).font(.system(size: 11)).foregroundStyle(DS.Colors.textTertiary)
            }
            Spacer(minLength: 4)
            Text(command.available ? command.summary : (command.unavailableReason ?? "Unavailable"))
                .font(.system(size: 11)).foregroundStyle(DS.Colors.textTertiary).lineLimit(1)
            Text(command.badge).font(.system(size: 9, weight: .medium))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(badgeColor(command.kind).opacity(0.25)))
        }
        .opacity(command.available ? 1 : 0.5)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.white.opacity(0.12) : .clear))
        .contentShape(Rectangle())
    }

    private func badgeColor(_ kind: SlashCommandKind) -> Color {
        switch kind {
        case .action: return .white
        case .skill: return ClickyChrome.ask
        case .snippet: return DS.Colors.blue400
        }
    }
}
