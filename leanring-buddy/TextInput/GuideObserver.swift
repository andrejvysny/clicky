import AppKit
import ApplicationServices

@MainActor
final class GuideObserver {
    var onEvidence: (() -> Void)?
    var onAction: (() -> Void)?
    var onInvalidated: (() -> Void)?
    var onUnavailable: (() -> Void)?
    private var mouseMonitor: Any?
    private var keyMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var axObserver: AXObserver?
    private var observedElements: [AXUIElement] = []
    private var pending: Task<Void, Never>?
    private var matcher: GuideInteractionMatcher?
    private var target: WindowCaptureTarget?
    private var targetBounds: CGRect?
    private var generation: UInt64 = 0
    private var expectedField: AXUIElement?
    private var hadFieldFocus = false

    func start(step: GuidePresentation, target: WindowCaptureTarget, rect: CGRect) {
        stop(); self.target = target; targetBounds = ScopedAccessibility.bounds(target)
        guard let action = step.action else { return }
        matcher = GuideInteractionMatcher(action: action, target: rect)
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp, .scrollWheel]) { [weak self] event in
            let position = event.locationInWindow
            let button = event.type == .rightMouseUp ? 1 : 0
            let scroll = event.type == .scrollWheel
            let count = scroll ? 0 : event.clickCount; let time = event.timestamp
            MainActor.assumeIsolated { self?.mouse(position: position, button: button, count: count, time: time, scroll: scroll) }
        }
        if AXIsProcessTrusted(), action.kind == .key || action.kind == .field_commit {
            keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // Extract no characters; unrelated key metadata is discarded synchronously.
                MainActor.assumeIsolated { self?.key(event) }
            }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                              object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.activationChanged() }
        }
        expectedField = action.kind == .field_commit ? ScopedAccessibility.field(target, rect: rect) : nil
        if let expectedField, let focused = ScopedAccessibility.focusedElement(target) { hadFieldFocus = CFEqual(expectedField, focused) }
        installAX(target)
    }
    func stop() {
        generation &+= 1; pending?.cancel(); pending = nil
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        if let axObserver { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .commonModes) }
        mouseMonitor = nil; keyMonitor = nil; activationObserver = nil; axObserver = nil
        observedElements = []; matcher = nil; target = nil
        expectedField = nil; hadFieldFocus = false
    }
    private func mouse(position: CGPoint, button: Int, count: Int, time: Double, scroll: Bool) {
        guard let target, ScopedAccessibility.focused(target) else { return }
        if scroll { onInvalidated?(); return }
        guard ScopedAccessibility.bounds(target) == targetBounds else { onInvalidated?(); return }
        let primary = (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first)?.frame.height ?? 0
        let point = CGPoint(x: position.x, y: primary - position.y)
        guard targetBounds?.contains(point) == true else { return }
        if matcher?.action.kind == .double_click, count == 1 { return }
        if matcher?.mouse(button: button, count: count, point: point, timestamp: time) == true { onAction?() }
        schedule(delay: UInt64((NSEvent.doubleClickInterval + 0.15) * 1_000_000_000))
    }
    private func key(_ event: NSEvent) {
        guard let target, ScopedAccessibility.focused(target) else { return }
        let modifiers = UInt64(event.modifierFlags.intersection([.command, .option, .shift, .control]).rawValue)
        guard matcher?.key(code: event.keyCode, modifiers: modifiers, timestamp: event.timestamp, repeated: event.isARepeat) == true else { return }
        onAction?()
        schedule(delay: 350_000_000)
    }
    private func activationChanged() {
        // Clicking the desktop activates Finder; a display target is not tied to any app.
        guard let target, target.displayIdentifier == nil,
              NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier else { return }
        onUnavailable?()
    }
    private func schedule(delay: UInt64) {
        pending?.cancel(); let current = generation
        pending = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            guard let self, self.generation == current else { return }
            self.onEvidence?()
        }
    }
    private func installAX(_ target: WindowCaptureTarget) {
        guard let window = ScopedAccessibility.window(target) else { return }
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, notification, pointer in
            guard let pointer else { return }
            let owner = Unmanaged<GuideObserver>.fromOpaque(pointer).takeUnretainedValue()
            MainActor.assumeIsolated { owner.axChanged(notification as String) }
        }
        guard AXObserverCreate(target.processIdentifier, callback, &observer) == .success, let observer else { return }
        axObserver = observer; observedElements = [window, AXUIElementCreateApplication(target.processIdentifier)]
        if let field = ScopedAccessibility.focusedElement(target) { observedElements.append(field) }
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
    private func axChanged(_ name: String) {
        if [kAXWindowMovedNotification, kAXWindowResizedNotification].contains(name) { onInvalidated?(); return }
        if name == kAXUIElementDestroyedNotification || name == kAXFocusedWindowChangedNotification { onUnavailable?(); return }
        // Value changes invalidate geometry but do not initiate screenshots per keystroke.
        if name == kAXValueChangedNotification { onInvalidated?(); return }
        if name == kAXFocusedUIElementChangedNotification, let expectedField, let target {
            let focused = ScopedAccessibility.focusedElement(target).map { CFEqual($0, expectedField) } ?? false
            if focused { hadFieldFocus = true; return }
            guard hadFieldFocus else { return }
            hadFieldFocus = false
        }
        schedule(delay: 350_000_000)
    }
}
