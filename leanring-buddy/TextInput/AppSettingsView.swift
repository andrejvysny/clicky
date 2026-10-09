import SwiftUI

/// Application-menu Settings shares the same controller and controls as companion Settings.
struct AppSettingsView: View {
    @ObservedObject var controller: AskController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                AskSettingsView(controller: controller)
                Divider()
                Text("WRITING").font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(DS.Colors.textTertiary)
                WritingSettingsView(store: controller.writingDefinitions)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(DS.Colors.textPrimary)
        }
        .frame(width: 440, height: 620)
        .background(ClickyChrome.panel)
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("clickyAppSettings")
    }
}
