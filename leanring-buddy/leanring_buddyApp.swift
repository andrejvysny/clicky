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
import os

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
    private let pointingPresenter = PointingPresenter()
    private let scopedShortcuts = ScopedShortcuts()
    private lazy var island = IslandController(ask: askController)
    private var sparkleUpdaterController: SPUStandardUpdaterController?
    #if DEBUG
    private let guidanceStepController = GuidanceStepController()
    private let guidanceLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "clicky", category: "guidance")
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🎯 Clicky: Starting...")
        print("🎯 Clicky: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        askController.onPointTarget = { [weak self] rect, label in
            // The island shows progress; the label at the target carries only the instruction.
            self?.pointingPresenter.show(rect: rect, label: label, persistent: true)
        }
        askController.onPointingCleared = { [weak self] in
            self?.pointingPresenter.hide(); self?.companionManager.clearDetectedElementLocation()
        }
        pointingPresenter.onFlyCompanion = { [weak self] point, screenFrame, label in
            guard let manager = self?.companionManager, manager.detectedElementScreenLocation == nil else { return }
            manager.detectedElementBubbleText = label.isEmpty ? nil : label
            manager.detectedElementDisplayFrame = screenFrame
            manager.detectedElementScreenLocation = point
        }
        askController.guide.onAnnotate = { [weak self] rect, label in self?.pointingPresenter.show(rect: rect, label: label) }
        quickAskPanelManager = QuickAskPanelManager(controller: askController)
        island.refresh()
        menuBarPanelManager = MenuBarPanelManager(companionManager: companionManager, askController: askController) { [weak self] presentation in
            self?.quickAskPanelManager?.show(presentation)
        }
        if ProcessInfo.processInfo.arguments.contains("--clicky-ui-test") {
            if ProcessInfo.processInfo.arguments.contains("--clicky-guide-demo") { askController.guide.startDemo() }
            else { quickAskPanelManager?.show() }
            return
        }
        quickAskHotkey.onPressed = { [weak self] in self?.quickAskPanelManager?.show() }
        installScopedShortcuts()
        askController.onShortcutChanged = { [weak self] in self?.registerQuickAskShortcut() ?? false }
        registerQuickAskShortcut()
        companionManager.startTextMode()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--clicky-show-settings") {
            quickAskPanelManager?.show(.details(showSettings: true))
            return
        }
        #endif
        menuBarPanelManager?.showPanelOnLaunch()
        // startSparkleUpdater()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        #if DEBUG
        for url in urls {
            do { guidanceStepController.handle(try GuidanceDebugRequest.parse(url)) }
            catch { guidanceLogger.error("guidance request rejected: \(error.localizedDescription, privacy: .public)") }
        }
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        askController.shutdown()
        pointingPresenter.hide()
        quickAskHotkey.unregister()
        scopedShortcuts.unregisterAll()
        quickAskPanelManager?.close(restoreFocus: false)
        companionManager.stopTextMode()
    }

    private func installScopedShortcuts() {
        scopedShortcuts.onNext = { [weak self] in self?.askController.guideNextShortcut() }
        scopedShortcuts.onRetry = { [weak self] in self?.askController.guideRetryShortcut() }
        scopedShortcuts.onCopy = { [weak self] in self?.askController.copyResponse() }
        scopedShortcuts.onSpeak = { [weak self] in self?.askController.speakResponse() }
        askController.onGuideStateChanged = { [weak self] in
            guard let self else { return }
            scopedShortcuts.setGuideActive(askController.guideStepActive)
        }
        scopedShortcuts.onToggleReply = { [weak self] in self?.island.toggleReply() }
        island.onReplyAvailabilityChanged = { [weak self] available in self?.scopedShortcuts.setReplyActive(available) }
    }

    @discardableResult
    private func registerQuickAskShortcut() -> Bool {
        let registered = quickAskHotkey.register(keyCode: askController.shortcutKeyCode, modifiers: askController.shortcutModifiers)
        askController.shortcutWarning = registered ? nil : "Quick Ask shortcut is unavailable. Rebind it in Settings or use the menu bar."
        return registered
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
