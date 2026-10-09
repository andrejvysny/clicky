import SwiftUI

/// Application-menu Settings shares the same controller and controls as companion Settings.
struct AppSettingsView: View {
    @ObservedObject var controller: AskController

    var body: some View {
        ScrollView {
            AskSettingsView(controller: controller)
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 440, height: 620)
        .background(ClickyChrome.panel)
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("clickyAppSettings")
    }
}
