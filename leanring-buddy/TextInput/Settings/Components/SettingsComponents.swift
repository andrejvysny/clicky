import SwiftUI

/// Colors of the Clicky window, on top of the dark design tokens.
enum SettingsColors {
    static let sidebar = DS.Colors.background
    static let content = DS.Colors.surface1
    static let card = DS.Colors.surface2
    static let cardBorder = Color.white.opacity(0.06)
    static let selection = Color.white.opacity(0.09)
    static let link = DS.Colors.blue400
}

/// One pane: large title, optional one-line intro and header accessory, then grouped cards.
struct SettingsPage<Accessory: View, Content: View>: View {
    let title: String
    var subtitle: String?
    var scrolls = true
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 28).padding(.top, 18).padding(.bottom, 14)
            if scrolls {
                ScrollView { column(content) }
            } else {
                column(content)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(DS.Colors.textPrimary)
        .background(SettingsColors.content)
    }

    private func column(_ content: Content) -> some View {
        VStack(alignment: .leading, spacing: 22) { content }
            .padding(.horizontal, 28).padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 20, weight: .semibold))
                if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(DS.Colors.textTertiary) }
            }
            Spacer(minLength: 12)
            accessory
        }
    }
}

extension SettingsPage where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil, scrolls: Bool = true, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, scrolls: scrolls, accessory: { EmptyView() }, content: content)
    }
}

/// Section title above a rounded card of rows.
struct SettingsGroup<Content: View>: View {
    let title: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Colors.textSecondary).padding(.leading, 4) }
            SettingsCard { content }
        }
    }
}

struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SettingsColors.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(SettingsColors.cardBorder, lineWidth: 1))
    }
}

/// Title and optional note on the left, a control on the right.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var subtitleColor: Color = DS.Colors.textTertiary
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(subtitleColor).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(minHeight: 40)
    }
}

extension SettingsRow where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle, trailing: { EmptyView() })
    }
}

struct SettingsDivider: View {
    var body: some View { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).padding(.horizontal, 14) }
}

struct SettingsNote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.system(size: 11)).foregroundStyle(DS.Colors.textTertiary).fixedSize(horizontal: false, vertical: true)
    }
}

/// Plain blue text action such as "Models →".
struct SettingsLink: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) { Text(title).font(.system(size: 12)).foregroundStyle(SettingsColors.link) }
            .buttonStyle(.plain).clickyPointerCursor()
    }
}

struct SettingsSwitch: View {
    @Binding var isOn: Bool
    var label = ""

    var body: some View {
        Toggle(label, isOn: $isOn).toggleStyle(.switch).labelsHidden().controlSize(.small).tint(DS.Colors.accent).clickyPointerCursor()
            .accessibilityLabel(label)
    }
}

/// Segmented control in the dark Clicky style, used in rows and page headers.
struct SettingsSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                Button { selection = option.0 } label: {
                    Text(option.1).font(.system(size: 12))
                        .foregroundStyle(selection == option.0 ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(selection == option.0 ? Color.white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).clickyPointerCursor()
            }
        }
        .padding(2)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
    }
}

/// Status word in a status color, such as "Allowed".
struct SettingsStatus: View {
    let text: String
    var color: Color = DS.Colors.success

    var body: some View { Text(text).font(.system(size: 12)).foregroundStyle(color) }
}
