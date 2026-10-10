import Combine
import SwiftUI

/// Live objects and window state shared by every pane. Creating it starts no worker, capture or recording.
@MainActor
final class SettingsContext: ObservableObject {
    static let lastPaneKey = "settingsLastPane"

    let ask: AskController
    let companion: CompanionManager?
    @Published var selection: SettingsPaneID {
        didSet {
            if oldValue == .playground, selection != .playground { labModel?.speech.cancelRecording() }
            defaults.set(selection.rawValue, forKey: Self.lastPaneKey)
        }
    }

    private let defaults: UserDefaults
    /// Created on first visit to the Playground or Results; lives until the window closes.
    private var labModel: LocalAILabModel?

    var voice: VoiceController? { VoiceController.shared }
    var runtime: LocalAIRuntime? { LocalAIRuntime.shared }

    init(ask: AskController, companion: CompanionManager?) {
        self.ask = ask
        self.companion = companion
        let testing = ProcessInfo.processInfo.arguments.contains("--clicky-ui-test")
        defaults = testing ? (UserDefaults(suiteName: "ClickyUITests") ?? .standard) : .standard
        selection = SettingsPaneID(rawValue: defaults.string(forKey: Self.lastPaneKey) ?? "") ?? .general
    }

    func lab() -> LocalAILabModel? {
        if let labModel { return labModel }
        guard let runtime else { return nil }
        let model = LocalAILabModel(runtime: runtime)
        labModel = model
        return model
    }

    /// Closing the window stops any Playground recording and cancels running jobs; loaded models stay.
    func windowClosed() {
        labModel?.windowClosed()
        labModel = nil
    }
}
