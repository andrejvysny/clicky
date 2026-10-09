import AppKit
import ApplicationServices
#if canImport(ClickyCore)
import ClickyCore
#endif

@MainActor
final class GuideObserver {
    let environment: GuideEnvironment
    var onEvidence: (() -> Void)?
    var onAction: (() -> Void)?
    var onInteractionBegan: (() -> Void)?
    var onInvalidated: (() -> Void)?
    var onUnavailable: (() -> Void)?
    private var sources: GuideEventSources?
    /// True while observing; tests use it to confirm a stopped observer cannot match late events.
    var isObserving: Bool { target != nil }
    private var axObserver: AXObserver?
    private var observedElements: [AXUIElement] = []
    private var pending: Task<Void, Never>?
    private var matcher: GuideInteractionMatcher?
    private var mouseRelease: GuideMouseReleaseTracker?
    private var target: WindowCaptureTarget?
    private var targetBounds: CGRect?
    private var generation: UInt64 = 0
    private var expectedField: AXUIElement?
    private var expectedFieldFrame: CGRect?
    private var hadFieldFocus = false
    /// Event time of the last accepted attempt, for acknowledgement latency.
    private(set) var lastAttemptTimestamp: Double?

    /// Optional so the default is resolved on the main actor rather than in a nonisolated default argument.
    static let mouseSettleNanoseconds: UInt64 = 300_000_000

    init(environment: GuideEnvironment? = nil) { self.environment = environment ?? .live }

    var isEditingExpectedField: Bool {
        guard let expectedField, let target, let focused = environment.focusedElement(target) else { return false }
        return CFEqual(expectedField, focused)
    }

    var expectedFieldGeometryIsCurrent: Bool {
        guard let expectedField else { return true }
        guard let expectedFieldFrame, let target,
              let current = environment.fieldFrame(expectedField, target) else { return false }
        return current == expectedFieldFrame
    }

    var isPressingExpectedTarget: Bool {
        guard let button = mouseRelease?.pressedButton else { return false }
        return NSEvent.pressedMouseButtons & (1 << button) != 0
    }

    func cancelPendingMousePress() { mouseRelease?.cancel() }

    func start(step: GuidePresentation, target: WindowCaptureTarget, rect: CGRect) {
        stop()
        guard let action = step.action else { return }
        self.target = target; targetBounds = environment.bounds(target)
        matcher = GuideInteractionMatcher(action: action, target: rect)
        mouseRelease = GuideMouseReleaseTracker(target: rect)
        let keys = environment.accessibilityTrusted() && (action.kind == .key || action.kind == .field_commit)
        sources = environment.installEventSources(self, keys)
        expectedField = action.kind == .field_commit ? environment.field(target, rect) : nil
        expectedFieldFrame = expectedField.flatMap { environment.fieldFrame($0, target) }
        if let expectedField, let focused = environment.focusedElement(target) { hadFieldFocus = CFEqual(expectedField, focused) }
        if environment.accessibilityTrusted() { installAX(target) }
    }
    func stop() {
        generation &+= 1; pending?.cancel(); pending = nil
        sources?.remove(); sources = nil
        if let axObserver { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .commonModes) }
        axObserver = nil
        observedElements = []; matcher = nil; target = nil
        mouseRelease = nil
        expectedField = nil; expectedFieldFrame = nil; hadFieldFocus = false
    }
    /// Mouse metadata from the installed event source (or a test), in global top-left points.
    func receiveMouse(_ event: GuideMouseEvent) {
        guard let target else { return }
        if event.dragged { mouseRelease?.cancel(); return }
        guard environment.focused(target) else { mouseRelease?.cancel(); return }
        if event.scroll { mouseRelease?.cancel(); onInvalidated?(); return }
        guard environment.bounds(target) == targetBounds else { mouseRelease?.cancel(); onInvalidated?(); return }
        let point = event.point
        guard targetBounds?.contains(point) == true else { mouseRelease?.cancel(); return }
        if event.pressed {
            if mouseRelease?.began(button: event.button, count: event.count, point: point, timestamp: event.timestamp) == true { onInteractionBegan?() }
            return
        }
        guard let releaseCount = mouseRelease?.released(button: event.button, count: event.count, point: point, timestamp: event.timestamp),
              matcher?.mouse(button: event.button, count: releaseCount, point: point, timestamp: event.timestamp) == true else { return }
        lastAttemptTimestamp = event.timestamp
        onAction?()
        // The matched release already completes the gesture (a double-click arrives as one count-2 release),
        // so only a short settle for the application's own response precedes verification.
        schedule(delay: Self.mouseSettleNanoseconds)
    }
    func receiveKey(code: UInt16, modifiers: UInt64, timestamp: Double, repeated: Bool) {
        guard let target, environment.focused(target) else { return }
        if matcher?.action.kind == .field_commit, expectedField != nil,
           !hadFieldFocus, !isEditingExpectedField { return }
        guard matcher?.key(code: code, modifiers: modifiers, timestamp: timestamp, repeated: repeated) == true else { return }
        lastAttemptTimestamp = timestamp
        onAction?()
        schedule(delay: 350_000_000)
    }
    func receiveActivation() {
        // Clicking the desktop activates Finder; a display target is not tied to any app.
        guard let target, target.displayIdentifier == nil,
              environment.frontmostProcess() != target.processIdentifier else { return }
        mouseRelease?.cancel()
        onUnavailable?()
    }
    private func schedule(delay: UInt64) {
        pending?.cancel(); let current = generation
        pending = Task { [weak self] in
            do { try await self?.environment.sleep(delay) } catch { return }
            guard let self, self.generation == current else { return }
            self.onEvidence?()
        }
    }
    private func installAX(_ target: WindowCaptureTarget) {
        guard let window = ScopedAccessibility.window(target) else { return }
        // Bubbled AX notifications only schedule coalesced checks; tests drive `receiveAccessibility` directly.
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, pointer in
            guard let pointer else { return }
            let owner = Unmanaged<GuideObserver>.fromOpaque(pointer).takeUnretainedValue()
            MainActor.assumeIsolated { owner.receiveAccessibility(notification as String) }
        }
        guard AXObserverCreate(target.processIdentifier, callback, &observer) == .success, let observer else { return }
        axObserver = observer; observedElements = [window, AXUIElementCreateApplication(target.processIdentifier)]
        if let field = environment.focusedElement(target) { observedElements.append(field) }
        if let expectedField { observedElements.append(expectedField) }
        let notifications = [kAXWindowMovedNotification, kAXWindowResizedNotification, kAXUIElementDestroyedNotification,
                             kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification, kAXValueChangedNotification,
                             kAXSelectedChildrenChangedNotification, kAXMenuOpenedNotification, kAXMenuClosedNotification]
        for element in observedElements {
            for name in notifications {
                AXObserverAddNotification(observer, element, name as CFString, Unmanaged.passUnretained(self).toOpaque())
            }
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }
    func receiveAccessibility(_ name: String) {
        if [kAXWindowMovedNotification, kAXWindowResizedNotification].contains(name) { mouseRelease?.cancel(); onInvalidated?(); return }
        if name == kAXUIElementDestroyedNotification || name == kAXFocusedWindowChangedNotification { mouseRelease?.cancel(); onUnavailable?(); return }
        // Web controls can bubble these notifications from an ancestor, not the edited field.
        // Neither typing nor selecting text is a field commit, regardless of the sender.
        if matcher?.action.kind == .field_commit,
           [kAXValueChangedNotification, kAXSelectedChildrenChangedNotification].contains(name) { return }
        if name == kAXFocusedUIElementChangedNotification {
            guard let expectedField, let target else { return }
            let focused = environment.focusedElement(target).map { CFEqual($0, expectedField) } ?? false
            if focused { hadFieldFocus = true; return }
            guard hadFieldFocus else { return }
            hadFieldFocus = false
            onAction?()
        }
        schedule(delay: 350_000_000)
    }
}
