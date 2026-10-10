import SwiftUI

/// Runs saved from the Playground, kept in memory until exported or the window closes.
struct ResultsPane: View {
    @EnvironmentObject private var context: SettingsContext

    var body: some View {
        SettingsPage(title: "Results", subtitle: "Saved Playground runs. They stay in memory until you export them.") {
            if let lab = context.lab() { LabResultsTab(results: lab.results) } else { SettingsNote("Local AI is not available in this build.") }
        }
    }
}
