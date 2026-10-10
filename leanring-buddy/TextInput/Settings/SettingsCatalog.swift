import SwiftUI

/// Every pane of the Clicky window. Adding a feature: add a case, a pane view, and one descriptor below.
enum SettingsPaneID: String, CaseIterable, Identifiable {
    case general, shortcuts, voice, writing, privacy
    case models, playground, results
    var id: String { rawValue }
}

enum SettingsSidebarSection: String, CaseIterable, Identifiable {
    case clicky, localAI
    var id: String { rawValue }
    var title: String { self == .clicky ? "Clicky" : "Local AI" }
}

struct SettingsPaneDescriptor: Identifiable {
    let id: SettingsPaneID
    let title: String
    let section: SettingsSidebarSection
    let makeView: @MainActor () -> AnyView
}

enum SettingsCatalog {
    static let panes: [SettingsPaneDescriptor] = [
        pane(.general, "General", .clicky) { GeneralPane() },
        pane(.shortcuts, "Shortcuts", .clicky) { ShortcutsPane() },
        pane(.voice, "Voice", .clicky) { VoicePane() },
        pane(.writing, "Writing", .clicky) { WritingPane() },
        pane(.privacy, "Screen & privacy", .clicky) { PrivacyPane() },
        pane(.models, "Models", .localAI) { ModelsPane() },
        pane(.playground, "Playground", .localAI) { PlaygroundPane() },
        pane(.results, "Results", .localAI) { ResultsPane() },
    ]

    static func descriptor(_ id: SettingsPaneID) -> SettingsPaneDescriptor? { panes.first { $0.id == id } }

    private static func pane<Content: View>(_ id: SettingsPaneID, _ title: String, _ section: SettingsSidebarSection,
                                            @ViewBuilder _ view: @escaping @MainActor () -> Content) -> SettingsPaneDescriptor {
        SettingsPaneDescriptor(id: id, title: title, section: section) { AnyView(view()) }
    }
}
