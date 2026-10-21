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
    /// The approved window itself closed or was minimized; a deliberate recovery, not a temporary switch.
    var onClosed: (() -> Void)?
    /// DEBUG trace sink for fixed, content-free codes (reasons, kinds, counts, rounded distances); never key codes.
    var onTrace: ((String) -> Void)?
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
    /// The captured region of the task surface group; clicks outside it are not this task's.
    private var scope: CGRect?
    /// A matched attempt is settling toward verification; surface changes it caused are expected.
    private var evidencePending = false
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

    func start(step: GuidePresentation, target: WindowCaptureTarget, rect: CGRect, scope: CGRect? = nil) {
        stop()
        guard let action = step.action else { return }
        self.target = target; targetBounds = environment.bounds(target); self.scope = scope ?? targetBounds
        matcher = GuideInteractionMatcher(action: action, target: rect)
        mouseRelease = GuideMouseReleaseTracker(target: rect)
        let keys = environment.accessibilityTrusted() && (action.kind == .key || action.kind == .field_commit)
        sources = environment.installEventSources(self, keys)
        expectedField = action.kind == .field_commit ? environment.field(target, rect) : nil
        expectedFieldFrame = expectedField.flatMap { environment.fieldFrame($0, target) }
        if let expectedField, let focused = environment.focusedElement(target) { hadFieldFocus = CFEqual(expectedField, focused) }
        if environment.accessibilityTrusted() { installAX(target) }
        onTrace?("observe start action=\(action.kind.rawValue) rect=\(Int(rect.width))x\(Int(rect.height)) scopeContainsRect=\(self.scope?.contains(rect) ?? false) "
                 + "keys=\(keys) field=\(expectedField != nil) ax=\(axObserver != nil)")
    }
    func stop() {
        generation &+= 1; pending?.cancel(); pending = nil; evidencePending = false; scope = nil
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
        guard environment.focused(target) else { mouseRelease?.cancel(); mouseTrace(event, "not_focused"); return }
        if event.scroll { mouseRelease?.cancel(); onTrace?("observe mouse scroll_invalidates"); onInvalidated?(); return }
        guard environment.bounds(target) == targetBounds else {
            mouseRelease?.cancel(); mouseTrace(event, "bounds_changed"); onInvalidated?(); return
        }
        let point = event.point
        guard scope?.contains(point) == true else { mouseRelease?.cancel(); mouseTrace(event, "outside_scope"); return }
        if event.pressed {
            let began = mouseRelease?.began(button: event.button, count: event.count, point: point, timestamp: event.timestamp) == true
            mouseTrace(event, began ? "press_on_target" : "press_off_target")
            if began { onInteractionBegan?() }
            return
        }
        guard let releaseCount = mouseRelease?.released(button: event.button, count: event.count, point: point, timestamp: event.timestamp) else {
            mouseTrace(event, "release_untracked"); return
        }
        guard matcher?.mouse(button: event.button, count: releaseCount, point: point, timestamp: event.timestamp) == true else {
            mouseTrace(event, "release_mismatch releaseCount=\(releaseCount)"); return
        }
        mouseTrace(event, "matched")
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
        guard matcher?.key(code: code, modifiers: modifiers, timestamp: timestamp, repeated: repeated) == true else {
            // Counted only: the key itself is never logged.
            if !repeated { onTrace?("observe key mismatch expected=\(matcher?.action.kind.rawValue ?? "-")") }
            return
        }
        onTrace?("observe key matched")
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
    /// Where the event fell relative to the expected target (rounded points outside it), not where on screen.
    private func mouseTrace(_ event: GuideMouseEvent, _ reason: String) {
        guard let onTrace else { return }
        let rect = matcher?.target ?? .null
        let dx = rect.isNull ? 0 : max(rect.minX - event.point.x, 0, event.point.x - rect.maxX)
        let dy = rect.isNull ? 0 : max(rect.minY - event.point.y, 0, event.point.y - rect.maxY)
        onTrace("observe mouse \(reason) button=\(event.button) count=\(event.count) expected=\(matcher?.action.kind.rawValue ?? "-") "
                + "outside=\(Int(dx.rounded()))x\(Int(dy.rounded()))pt")
    }
    private func schedule(delay: UInt64) {
        pending?.cancel(); let current = generation
        evidencePending = true
        pending = Task { [weak self] in
            do { try await self?.environment.sleep(delay) } catch { return }
            guard let self, self.generation == current else { return }
            evidencePending = false
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
        if name != kAXValueChangedNotification as String { onTrace?("observe ax " + name + " evidencePending=\(evidencePending)") }
        if [kAXWindowMovedNotification, kAXWindowResizedNotification].contains(name) { mouseRelease?.cancel(); onInvalidated?(); return }
        if name == kAXUIElementDestroyedNotification || name == kAXFocusedWindowChangedNotification {
            mouseRelease?.cancel()
            guard let target else { return }
            if environment.bounds(target) == nil { onClosed?(); return }
            // Focus left the approved surface group: an unrelated window or app (temporary switch).
            guard environment.focused(target) else { onUnavailable?(); return }
            // An established related dialog/sheet/menu opened or closed. After a matched attempt that is the
            // expected transition and verification follows; otherwise the old target geometry is stale.
            if !evidencePending { onInvalidated?() }
            return
        }
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
