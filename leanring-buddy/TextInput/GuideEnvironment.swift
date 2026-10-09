import AppKit
import ApplicationServices
#if canImport(ClickyCore)
// The SwiftPM coordinator harness compiles these app files against ClickyCore; the app compiles Core directly.
import ClickyCore
#endif

/// Native effects the walkthrough coordinator and observer depend on.
/// The app uses `.live`; coordinator tests inject a fake clock, capture, Accessibility and provider
/// while exercising the same `VisualGuideController` and `GuideObserver` code paths.
struct GuideEnvironment {
    var now: () -> Date
    /// Suspends for the given nanoseconds; throws CancellationError when the waiting task is cancelled.
    var sleep: (UInt64) async throws -> Void
    var capture: (_ target: WindowCaptureTarget, _ region: CGRect?, _ related: [WindowCaptureTarget],
                  _ outputSize: CGSize?) async throws -> PNGImageAttachment
    var focused: (WindowCaptureTarget) -> Bool
    var waitForFocus: (WindowCaptureTarget) async -> Bool
    var bounds: (WindowCaptureTarget) -> CGRect?
    var related: (WindowCaptureTarget) -> [WindowCaptureTarget]
    var outcomeMatches: (GuideOutcome, WindowCaptureTarget) -> Bool?
    var annotationObstacles: (WindowCaptureTarget, CGRect) -> [CGRect]
    var displayTarget: (CGPoint) -> WindowCaptureTarget?
    var pointer: () -> CGPoint
    var accessibilityTrusted: () -> Bool
    var field: (WindowCaptureTarget, CGRect) -> AXUIElement?
    var focusedElement: (WindowCaptureTarget) -> AXUIElement?
    var fieldFrame: (AXUIElement, WindowCaptureTarget) -> CGRect?
    var frontmostProcess: () -> Int32?
    /// Installs the system event sources for one observation; returns a token that removes them.
    var installEventSources: (GuideObserver, _ keys: Bool) -> GuideEventSources?
    var makeAgent: (_ provider: AgentProvider, _ executable: URL, _ root: URL, _ effort: AskEffort,
                    _ onUnexpectedExit: @escaping @Sendable (String) -> Void) throws -> any GuideAgentRunning

    static let live = GuideEnvironment(
        now: { Date() },
        sleep: { try await Task.sleep(nanoseconds: $0) },
        capture: { target, region, related, outputSize in
            try await WindowSnapshotCapture.capture(target, region: region, relatedTargets: related, outputSize: outputSize)
        },
        focused: { ScopedAccessibility.focused($0) },
        waitForFocus: { await ScopedAccessibility.waitForFocus($0) },
        bounds: { ScopedAccessibility.bounds($0) },
        related: { ScopedAccessibility.related($0) },
        outcomeMatches: { ScopedAccessibility.matches($0, target: $1) },
        annotationObstacles: { ScopedAccessibility.annotationObstacles($0, within: $1) },
        displayTarget: { WindowSnapshotCapture.displayTarget(containing: $0) },
        pointer: {
            let pointer = NSEvent.mouseLocation
            let height = (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first)?.frame.height ?? 0
            return CGPoint(x: pointer.x, y: height - pointer.y)
        },
        accessibilityTrusted: { AXIsProcessTrusted() },
        field: { ScopedAccessibility.field($0, rect: $1) },
        focusedElement: { ScopedAccessibility.focusedElement($0) },
        fieldFrame: { ScopedAccessibility.fieldFrame($0, target: $1) },
        frontmostProcess: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
        installEventSources: { GuideEventSources.installSystem(for: $0, keys: $1) },
        makeAgent: { provider, executable, root, effort, onUnexpectedExit in
            let profile = try GuideAgentProfile(provider: provider, root: root, taskID: UUID(), effort: effort)
            return GuideAgentSession(profile: profile, executable: executable, onUnexpectedExit: onUnexpectedExit)
        })
}

/// System monitors feeding one `GuideObserver`. Only event metadata leaves the monitor closures; typed characters never do.
@MainActor
final class GuideEventSources {
    private var tokens: [Any] = []
    private var workspaceTokens: [NSObjectProtocol] = []

    static func installSystem(for observer: GuideObserver, keys: Bool) -> GuideEventSources {
        let sources = GuideEventSources()
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .leftMouseUp, .rightMouseUp,
                                                                      .leftMouseDragged, .rightMouseDragged, .scrollWheel], handler: { [weak observer] event in
            let position = event.locationInWindow
            let button = event.type == .rightMouseUp || event.type == .rightMouseDown || event.type == .rightMouseDragged ? 1 : 0
            let scroll = event.type == .scrollWheel
            let dragged = event.type == .leftMouseDragged || event.type == .rightMouseDragged
            let pressed = event.type == .leftMouseDown || event.type == .rightMouseDown
            let count = scroll ? 0 : event.clickCount; let time = event.timestamp
            let primary = (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first)?.frame.height ?? 0
            let point = CGPoint(x: position.x, y: primary - position.y)
            MainActor.assumeIsolated {
                observer?.receiveMouse(GuideMouseEvent(point: point, button: button, count: count, timestamp: time,
                                                       scroll: scroll, pressed: pressed, dragged: dragged))
            }
        }) { sources.tokens.append(monitor) }
        if keys, let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak observer] event in
            // Extract no characters; unrelated key metadata is discarded synchronously by the observer.
            let code = event.keyCode, time = event.timestamp, repeated = event.isARepeat
            let modifiers = UInt64(event.modifierFlags.intersection([.command, .option, .shift, .control]).rawValue)
            MainActor.assumeIsolated {
                observer?.receiveKey(code: code, modifiers: modifiers, timestamp: time, repeated: repeated)
            }
        }) { sources.tokens.append(monitor) }
        sources.workspaceTokens.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak observer] _ in
            MainActor.assumeIsolated { observer?.receiveActivation() }
        })
        return sources
    }

    func remove() {
        for token in tokens { NSEvent.removeMonitor(token) }
        for token in workspaceTokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        tokens = []; workspaceTokens = []
    }
}

/// Mouse metadata in global top-left points; no window contents or unrelated event payload.
struct GuideMouseEvent {
    let point: CGPoint
    let button: Int
    let count: Int
    let timestamp: Double
    var scroll = false
    var pressed = false
    var dragged = false
}
