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
        Settings {
            AppSettingsView(controller: appDelegate.askController)
        }
    }
}

/// Manages the companion lifecycle: creates the menu bar panel and starts
/// the text-first companion on launch.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarPanelManager: MenuBarPanelManager?
    private let companionManager = CompanionManager()
    let askController = AskController()
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

        askController.onPointTarget = { [weak self] mark in
            // The target carries one short action (or consequence warning); the island keeps full status.
            // A walkthrough step needs the user in their app, so Quick Ask steps aside.
            self?.quickAskPanelManager?.close(restoreFocus: true)
            self?.pointingPresenter.show(Self.spec(mark), persistent: true, tone: mark.warning ? .warning : .waiting)
        }
        askController.onPointingCleared = { [weak self] in self?.pointingPresenter.hide() }
        pointingPresenter.onHidden = { [weak self] in self?.companionManager.clearDetectedElementLocation() }
        pointingPresenter.onFlyCompanion = { [weak self] point, screenFrame, label in
            guard let manager = self?.companionManager, manager.detectedElementScreenLocation == nil else { return }
            manager.detectedElementBubbleText = label.isEmpty ? nil : label
            manager.detectedElementDisplayFrame = screenFrame
            manager.detectedElementScreenLocation = point
        }
        askController.guide.onAnnotate = { [weak self] mark in self?.pointingPresenter.show(Self.spec(mark), persistent: false) }
        askController.guide.onClearAnnotation = { [weak self] in self?.pointingPresenter.hide() }
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
        WindowSnapshotCapture.trackExternalActivation()
        WindowSnapshotCapture.runFirstLaunchSetup { [weak self] shareScreen in
            self?.askController.screenInclusion = shareScreen ? .always : .off
        }
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

    private static func spec(_ mark: GuideMark) -> AnnotationOverlay.AnnotationSpec {
        AnnotationOverlay.AnnotationSpec(mark: mark.mark, target: mark.target, label: mark.label,
                                         value: mark.value, ghost: mark.ghost, within: mark.within,
                                         avoidRects: mark.avoidRects)
    }

    private func installScopedShortcuts() {
        scopedShortcuts.onNext = { [weak self] in self?.askController.guideNextShortcut() }
        scopedShortcuts.onRetry = { [weak self] in self?.askController.guideRetryShortcut() }
        scopedShortcuts.onBack = { [weak self] in self?.askController.guideBackShortcut() }
        scopedShortcuts.onEnd = { [weak self] in self?.askController.guideEndShortcut() }
        scopedShortcuts.onCopy = { [weak self] in self?.askController.copyResponse() }
        scopedShortcuts.onSpeak = { [weak self] in self?.askController.speakResponse() }
        askController.onGuideStateChanged = { [weak self] in
            guard let self else { return }
            scopedShortcuts.setGuideActive(askController.guideStepActive)
        }
        island.onReplyAvailabilityChanged = { [weak self] available in self?.scopedShortcuts.setReplyActive(available) }
        island.onCompanionState = { [weak self] working, failed in self?.companionManager.setTextActivity(working: working, failed: failed) }
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
