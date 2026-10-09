import AppKit
import ApplicationServices
#if canImport(ClickyCore)
import ClickyCore
#endif

@MainActor
enum ScopedAccessibility {
    private static var deadline: CFAbsoluteTime?

    private static func read<T>(_ operation: () -> T?) -> T? {
        let previous = deadline
        let limit = previous ?? (CFAbsoluteTimeGetCurrent() + 0.25)
        deadline = limit
        defer { deadline = previous }
        let result = operation()
        return CFAbsoluteTimeGetCurrent() <= limit ? result : nil
    }
    static func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        if let deadline, CFAbsoluteTimeGetCurrent() > deadline { return nil }
        AXUIElementSetMessagingTimeout(element, 0.03)
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success
            ? result : nil
    }
    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = value(element, kAXPositionAttribute),
            let size = value(element, kAXSizeAttribute),
            CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
            AXValueGetValue(size as! AXValue, .cgSize, &dimensions)
        else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
    static func bounds(_ target: WindowCaptureTarget) -> CGRect? {
        // CGDisplayBounds is already global top-left points, like window bounds.
        if let display = target.displayIdentifier { return CGDisplayBounds(display).isEmpty ? nil : CGDisplayBounds(display) }
        let windows =
            CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        guard
            let window = windows.first(where: {
                ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == target.windowIdentifier
                    && ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == target.processIdentifier
            }), let raw = window[kCGWindowBounds as String] as? NSDictionary
        else { return nil }
        return CGRect(dictionaryRepresentation: raw as CFDictionary)
    }
    static func window(_ target: WindowCaptureTarget) -> AXUIElement? {
        // A display has no AX window, so related UI, AX outcomes and field reads all stay off for it.
        if target.displayIdentifier != nil { return nil }
        return read {
            guard AXIsProcessTrusted(), let bounds = bounds(target) else { return nil }
            let application = AXUIElementCreateApplication(target.processIdentifier)
            let windows = value(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
            let matches = windows.filter { frame($0).map { near($0, bounds) } ?? false }
            if matches.count == 1 { return matches[0] }
            // Same-frame windows (e.g. stacked tabs): the focused one is the only unambiguous choice.
            guard matches.count > 1, let raw = value(application, kAXFocusedWindowAttribute),
                CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
            return matches.first { CFEqual($0, raw) }
        }
    }
    static func focused(_ target: WindowCaptureTarget) -> Bool {
        // A display cannot lose focus; changes on it are caught by the target guard's pixel comparison.
        if target.displayIdentifier != nil { return bounds(target) != nil }
        return read {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier
            else { return false }
            guard AXIsProcessTrusted() else {
                return WindowSnapshotCapture.target(for: NSWorkspace.shared.frontmostApplication) == target
            }
            let app = AXUIElementCreateApplication(target.processIdentifier)
            guard let expected = window(target), let focused = value(app, kAXFocusedWindowAttribute)
            else { return false }
            return CFEqual(expected, focused)
        } ?? false
    }
    /// The approved window, or an established related surface of it (an AX child sheet, dialog or menu
    /// window matched by Window Server identity), has focus. Same process alone is not enough.
    static func surfaceFocused(_ target: WindowCaptureTarget) -> Bool {
        if focused(target) { return true }
        guard target.displayIdentifier == nil,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else { return false }
        let focusedFrame: CGRect? = read {
            guard AXIsProcessTrusted(), let raw = value(AXUIElementCreateApplication(target.processIdentifier), kAXFocusedWindowAttribute),
                  CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
            return frame(raw as! AXUIElement)
        }
        guard let focusedFrame else { return false }
        return related(target).contains { bounds($0).map { near($0, focusedFrame) } ?? false }
    }
    static func waitForSurfaceFocus(_ target: WindowCaptureTarget, timeout: TimeInterval = 1.0) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if surfaceFocused(target) { return true }
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
    }
    /// Focus returns asynchronously after Quick Ask closes; wait briefly instead of failing the request.
    static func waitForFocus(_ target: WindowCaptureTarget, timeout: TimeInterval = 1.0) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if focused(target) { return true }
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
    }
    static func related(_ target: WindowCaptureTarget) -> [WindowCaptureTarget] {
        read {
            guard let root = window(target) else { return [] }
            var frames = descendants(root).elements.filter {
                !CFEqual($0, root) && [kAXSheetRole, kAXMenuRole, kAXWindowRole].contains(role($0))
            }.compactMap(frame)
            // A menu bar is app-scoped; only its open menus with this exact window focused are eligible.
            if focused(target),
                let bar = value(
                    AXUIElementCreateApplication(target.processIdentifier), kAXMenuBarAttribute),
                CFGetTypeID(bar) == AXUIElementGetTypeID()
            {
                frames += descendants(bar as! AXUIElement).elements.filter { role($0) == kAXMenuRole }
                    .compactMap(frame)
            }
            let windows =
                CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] ?? []
            return windows.compactMap { entry in
                guard let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                    pid == target.processIdentifier,
                    let id = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                    id != target.windowIdentifier,
                    let raw = entry[kCGWindowBounds as String] as? NSDictionary,
                    let rect = CGRect(dictionaryRepresentation: raw as CFDictionary),
                    frames.contains(where: { near($0, rect) })
                else { return nil }
                return WindowCaptureTarget(
                    processIdentifier: pid, windowIdentifier: id,
                    applicationIdentifier: target.applicationIdentifier,
                    applicationName: target.applicationName)
            }
        } ?? []
    }
    static func matches(_ outcome: GuideOutcome, target: WindowCaptureTarget) -> Bool? {
        read {
            guard let role = outcome.axRole, let title = outcome.axTitle, !title.isEmpty,
                let root = window(target)
            else { return nil }
            let tree = descendants(root)
            guard tree.complete else { return nil }
            let matches = tree.elements.filter {
                self.role($0) == role
                    && (value($0, kAXTitleAttribute) as? String == title
                        || value($0, kAXDescriptionAttribute) as? String == title)
            }
            guard matches.count == 1, let element = matches.first, !secure(element) else { return nil }
            if let expected = outcome.axValue {
                let actual = value(element, kAXValueAttribute)
                return GuideAXValue.matches(expected: expected, string: actual as? String, number: (actual as? NSNumber)?.doubleValue)
            }
            return true
        }
    }
    static func secure(_ element: AXUIElement) -> Bool {
        value(element, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole
    }
    static func focusedElement(_ target: WindowCaptureTarget) -> AXUIElement? {
        read {
            guard focused(target), let root = window(target),
                let raw = value(
                    AXUIElementCreateApplication(target.processIdentifier), kAXFocusedUIElementAttribute),
                CFGetTypeID(raw) == AXUIElementGetTypeID()
            else { return nil }
            let element = raw as! AXUIElement
            guard let owner = value(element, kAXWindowAttribute), CFGetTypeID(owner) == AXUIElementGetTypeID(),
                  CFEqual(owner, root), !secure(element)
            else { return nil }
            return element
        }
    }
    /// Selected text in the target window's focused, non-secure element. Never prompts for Accessibility.
    static func selectedText(_ target: WindowCaptureTarget) -> String? {
        read {
            // Match by owning window rather than a bounded tree walk: deep web/document views exceed 200 nodes.
            guard AXIsProcessTrusted(), focused(target), let root = window(target),
                let raw = value(AXUIElementCreateApplication(target.processIdentifier), kAXFocusedUIElementAttribute),
                CFGetTypeID(raw) == AXUIElementGetTypeID()
            else { return nil }
            let element = raw as! AXUIElement
            guard !secure(element), let owner = value(element, kAXWindowAttribute),
                CFGetTypeID(owner) == AXUIElementGetTypeID(), CFEqual(owner, root),
                let text = value(element, kAXSelectedTextAttribute) as? String,
                text.utf8.count <= 262_144
            else { return nil }
            return text
        }
    }
    static func field(_ target: WindowCaptureTarget, rect: CGRect) -> AXUIElement? {
        read {
            guard let root = window(target) else { return nil }
            let point = CGPoint(x: rect.midX, y: rect.midY)
            var hit: AXUIElement?
            let application = AXUIElementCreateApplication(target.processIdentifier)
            AXUIElementSetMessagingTimeout(application, 0.03)
            if AXUIElementCopyElementAtPosition(application, Float(point.x), Float(point.y), &hit) == .success,
               let hit, let field = enclosingField(hit, in: root, point: point) { return field }
            let tree = descendants(root)
            guard tree.complete else { return nil }
            let candidates = tree.elements.filter {
                [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, kAXIncrementorRole].contains(role($0)) && !secure($0)
                    && frame($0)?.contains(CGPoint(x: rect.midX, y: rect.midY)) == true
            }
            return candidates.count == 1 ? candidates.first : nil
        }
    }

    /// Read only the original field's geometry; loss of its exact window binding fails closed.
    static func fieldFrame(_ element: AXUIElement, target: WindowCaptureTarget) -> CGRect? {
        read {
            guard let root = window(target), !secure(element),
                  [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, kAXIncrementorRole].contains(role(element)),
                  let owner = value(element, kAXWindowAttribute), CFGetTypeID(owner) == AXUIElementGetTypeID(),
                  CFEqual(owner, root), let rect = frame(element), rect.width > 0, rect.height > 0,
                  [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy(\.isFinite) else { return nil }
            return rect
        }
    }

    private static func enclosingField(_ hit: AXUIElement, in window: AXUIElement, point: CGPoint) -> AXUIElement? {
        var element = hit
        // A bounded owner/ancestor walk handles deep web pages without traversing unrelated controls.
        for _ in 0..<16 {
            guard !secure(element), let owner = value(element, kAXWindowAttribute),
                  CFGetTypeID(owner) == AXUIElementGetTypeID(), CFEqual(owner, window) else { return nil }
            if [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, kAXIncrementorRole].contains(role(element)),
               frame(element)?.contains(point) == true { return element }
            guard let parent = value(element, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID(),
                  !CFEqual(parent, element), !CFEqual(parent, window) else { return nil }
            element = parent as! AXUIElement
        }
        return nil
    }

    /// Geometry only, from the exact approved window. Values, titles and unrelated windows are not read.
    static func annotationObstacles(_ target: WindowCaptureTarget, within region: CGRect) -> [CGRect] {
        read {
            guard let root = window(target) else { return [] }
            let roles = [kAXButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXStaticTextRole,
                         kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, kAXPopUpButtonRole,
                         kAXIncrementorRole, kAXSliderRole, kAXMenuItemRole, "AXLink", "AXHeading"]
            var rectangles: [CGRect] = []
            for element in descendants(root).elements where roles.contains(role(element)) {
                guard let frame = frame(element), !frame.isEmpty, !frame.isInfinite, !frame.isNull else { continue }
                let clipped = frame.intersection(region)
                guard !clipped.isNull, !clipped.isEmpty, !rectangles.contains(clipped) else { continue }
                rectangles.append(clipped)
            }
            return rectangles
        } ?? []
    }
    private static func role(_ element: AXUIElement) -> String {
        value(element, kAXRoleAttribute) as? String ?? ""
    }
    private static func descendants(_ root: AXUIElement) -> (elements: [AXUIElement], complete: Bool)
    {
        var queue = [root]
        var result: [AXUIElement] = []
        var truncated = false
        while !queue.isEmpty, result.count < 200 {
            if let deadline, CFAbsoluteTimeGetCurrent() > deadline { return (result, false) }
            let element = queue.removeFirst()
            result.append(element)
            guard !secure(element) else { continue }
            let children = value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
            let remaining = max(0, 200 - result.count - queue.count)
            if children.count > remaining { truncated = true }
            queue += children.prefix(remaining)
        }
        return (result, queue.isEmpty && !truncated)
    }
    private static func near(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        // AX and the Window Server round differently on scaled displays.
        abs(lhs.minX - rhs.minX) < 2 && abs(lhs.minY - rhs.minY) < 2 && abs(lhs.width - rhs.width) < 2
            && abs(lhs.height - rhs.height) < 2
    }
}
