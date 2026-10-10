import AppKit

/// App wiring: the real Quick Ask, native writing targets and local AI runtime.
extension VoiceController {
    convenience init(askController: AskController, quickAskPanelManager: QuickAskPanelManager, runtime: LocalAIRuntime,
                     defaults: UserDefaults = .standard) {
        // The coordinator's environment closures hold their targets weakly, so this controller keeps them alive.
        let targets = WritingNativeTargets()
        self.init(host: askController, quickAsk: quickAskPanelManager, environment: .live(runtime: runtime),
                  writingEnvironment: targets.environment, defaults: defaults)
        retained.append(targets)
    }
}

extension AskController: VoiceAskHost {}

extension QuickAskPanelManager: VoiceQuickAskPresenting {
    var isShowing: Bool {
        NSApp.windows.contains { $0.isVisible && $0.accessibilityIdentifier() == "quickAskPanel" }
    }

    func showQuickAsk() { show(.ghost) }
}
