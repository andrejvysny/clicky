//
//  leanring_buddyApp.swift
//  leanring-buddy
//
//  Menu bar-only companion app. No dock icon, no main window — just an
//  always-available status item in the macOS menu bar. Clicking the icon
//  opens a floating panel with Quick Ask and response controls.
//

import ServiceManagement
import SwiftUI
import Sparkle

@main
struct leanring_buddyApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        // The app lives entirely in the menu bar panel managed by the AppDelegate.
        // This empty Settings scene satisfies SwiftUI's requirement for at least
        // one scene but is never shown (LSUIElement=true removes the app menu).
        Settings {
            EmptyView()
        }
    }
}

/// Manages the companion lifecycle: creates the menu bar panel and starts
/// the text-first companion on launch.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarPanelManager: MenuBarPanelManager?
    private let companionManager = CompanionManager()
    private let askController = AskController()
    private var quickAskPanelManager: QuickAskPanelManager?
    private let quickAskHotkey = QuickAskHotkey()
    private var sparkleUpdaterController: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🎯 Clicky: Starting...")
        print("🎯 Clicky: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        quickAskPanelManager = QuickAskPanelManager(controller: askController)
        menuBarPanelManager = MenuBarPanelManager(companionManager: companionManager, askController: askController) { [weak self] settings in
            self?.quickAskPanelManager?.show(settings: settings)
        }
        if ProcessInfo.processInfo.arguments.contains("--clicky-ui-test") {
            quickAskPanelManager?.show()
            return
        }
        quickAskHotkey.onPressed = { [weak self] in self?.quickAskPanelManager?.show() }
        askController.onShortcutChanged = { [weak self] in self?.registerQuickAskShortcut() }
        registerQuickAskShortcut()
        companionManager.startTextMode()
        menuBarPanelManager?.showPanelOnLaunch()
        // startSparkleUpdater()
    }

    func applicationWillTerminate(_ notification: Notification) {
        askController.stopReply()
        quickAskHotkey.unregister()
        quickAskPanelManager?.close(restoreFocus: false)
        companionManager.stopTextMode()
    }

    private func registerQuickAskShortcut() {
        let registered = quickAskHotkey.register(keyCode: askController.shortcutKeyCode, modifiers: askController.shortcutModifiers)
        askController.shortcutWarning = registered ? nil : "Quick Ask shortcut is unavailable. Rebind it in Settings or use the menu bar."
    }

    /// Registers the app as a login item so it launches automatically on
    /// startup. Uses SMAppService which shows the app in System Settings >
    /// General > Login Items, letting the user toggle it off if they want.
    private func registerAsLoginItemIfNeeded() {
        let loginItemService = SMAppService.mainApp
        if loginItemService.status != .enabled {
            do {
                try loginItemService.register()
                print("🎯 Clicky: Registered as login item")
            } catch {
                print("⚠️ Clicky: Failed to register as login item: \(error)")
            }
        }
    }

    private func startSparkleUpdater() {
        let updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.sparkleUpdaterController = updaterController

        do {
            try updaterController.updater.start()
        } catch {
            print("⚠️ Clicky: Sparkle updater failed to start: \(error)")
        }
    }
}
