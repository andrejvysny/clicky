import AppKit
import ApplicationServices
import Carbon.HIToolbox
#if canImport(ClickyCore)
import ClickyCore
#endif

/// Small AX and keyboard primitives for host text edits. Reads are bounded by short messaging timeouts;
/// nothing here logs or retains field content beyond the call.
@MainActor
enum WritingAX {

    static func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.2)
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
    }

    static func focusedElement(of processIdentifier: Int32) -> AXUIElement? {
        guard AXIsProcessTrusted(), let raw = value(AXUIElementCreateApplication(processIdentifier), kAXFocusedUIElementAttribute),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    static func selectedRange(_ element: AXUIElement) -> UTF16Range? {
        guard let raw = value(element, kAXSelectedTextRangeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(raw as! AXValue, .cfRange, &range) else { return nil }
        return UTF16Range(location: range.location, length: range.length)
    }

    static func characterCount(_ element: AXUIElement) -> Int? { (value(element, kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue }

    static func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success && settable.boolValue
    }

    static func string(_ element: AXUIElement, range: UTF16Range) -> String? {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &cfRange) else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.3)
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                         parameter, &result) == .success else { return nil }
        return result as? String
    }

    static func select(_ element: AXUIElement, range: UTF16Range) -> Bool {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    static func isSecure(_ element: AXUIElement) -> Bool {
        value(element, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole
    }

    /// Command-V (or Delete) delivered to one process only, tagged as synthetic.
    static func postKey(_ keyCode: CGKeyCode, command: Bool, to processIdentifier: Int32) {
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { continue }
            event.flags = command ? .maskCommand : []
            event.setIntegerValueField(.eventSourceUserData, value: WritingSyntheticInput.eventTag)
            event.postToPid(processIdentifier)
        }
    }

    static func postPaste(to processIdentifier: Int32) { postKey(pasteKeyCode(), command: true, to: processIdentifier) }

    /// The key that types "v" with Command in the current layout (QWERTY position 9 as the fallback).
    static func pasteKeyCode() -> CGKeyCode {
        let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
        let ascii = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
        for input in [source, ascii].compactMap({ $0 }) {
            guard let raw = TISGetInputSourceProperty(input, kTISPropertyUnicodeKeyLayoutData) else { continue }
            let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
            let found: CGKeyCode? = data.withUnsafeBytes { buffer in
                guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
                for code in 0..<128 {
                    var dead: UInt32 = 0, length = 0
                    var characters = [UniChar](repeating: 0, count: 4)
                    let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), UInt32((cmdKey >> 8) & 0xFF),
                                                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &characters)
                    if status == noErr, length == 1, characters[0] == UniChar(118) { return CGKeyCode(code) }
                }
                return nil
            }
            if let found { return found }
        }
        return CGKeyCode(kVK_ANSI_V)
    }

    static var submitKeysUp: Bool {
        !CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_Return))
            && !CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_ANSI_KeypadEnter))
    }

    static func poll(timeout: TimeInterval, interval: UInt64 = 40_000_000, _ condition: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: interval)
        }
        return condition()
    }
}

/// Browser textareas/contenteditable and other AX text controls. Chrome ignores AXSelectedText writes, so
/// the only write path is: select the exact original range, stage the clipboard, Command-V to that process.
@MainActor
final class WritingAXFieldAdapter {
    static let validatedBundles: Set<String> = ["com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary"]
    private static let textRoles: Set<String> = [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole, "AXSearchField"]
    private var elements: [UUID: AXUIElement] = [:]
    private let clipboard = WritingClipboard()

    func capture(_ application: NSRunningApplication) -> TextTargetSnapshot? {
        let pid = application.processIdentifier
        guard let element = WritingAX.focusedElement(of: pid),
              let role = WritingAX.value(element, kAXRoleAttribute) as? String else { return nil }
        let secure = WritingAX.isSecure(element)
        guard secure || Self.textRoles.contains(role), let selection = WritingAX.selectedRange(element) ?? (secure ? .caret(0) : nil)
        else { return nil }
        var blocked: WritingBlockReason?
        if secure { blocked = .secureField }
        else if !Self.validatedBundles.contains(application.bundleIdentifier ?? "") { blocked = .unsupportedTarget }
        else if !WritingAX.isSettable(element, kAXValueAttribute) || !WritingAX.isSettable(element, kAXSelectedTextRangeAttribute) { blocked = .readOnly }
        let snapshot = TextTargetSnapshot(kind: .textField, applicationName: application.localizedName ?? "App",
                                          bundleIdentifier: application.bundleIdentifier ?? "", processIdentifier: pid,
                                          windowIdentifier: WindowSnapshotCapture.target(for: application)?.windowIdentifier, paneIdentity: nil,
                                          selection: selection, contentRevision: secure ? "" : String(WritingAX.characterCount(element) ?? -1),
                                          blockedReason: blocked)
        if !secure { remember(snapshot.token, element) }
        return snapshot
    }

    func live(_ bound: TextTargetSnapshot) -> TextTargetSnapshot? {
        guard let element = elements[bound.token], let application = NSRunningApplication(processIdentifier: bound.processIdentifier),
              let selection = WritingAX.selectedRange(element), let count = WritingAX.characterCount(element) else { return nil }
        // Focus moving to another control (even in the same window) is a different destination.
        let focusedHere = WritingAX.focusedElement(of: bound.processIdentifier).map { CFEqual($0, element) } ?? false
        return TextTargetSnapshot(token: bound.token, kind: .textField, applicationName: bound.applicationName,
                                  bundleIdentifier: bound.bundleIdentifier, processIdentifier: bound.processIdentifier,
                                  windowIdentifier: WindowSnapshotCapture.target(for: application)?.windowIdentifier,
                                  paneIdentity: focusedHere ? nil : "focus-moved", selection: selection, contentRevision: String(count))
    }

    func readSource(_ bound: TextTargetSnapshot) throws -> ExactSource {
        guard let element = elements[bound.token], !WritingAX.isSecure(element),
              let text = WritingAX.string(element, range: bound.selection) else { throw WritingContractError.sourceMismatch }
        return try ExactSource(text: text, range: bound.selection)
    }

    func readSurrounding(_ bound: TextTargetSnapshot, limit: Int = 1_000) -> WritingHostPayload.Surrounding? {
        guard let element = elements[bound.token], let count = WritingAX.characterCount(element) else { return nil }
        let start = max(0, bound.selection.location - limit)
        let afterLength = max(0, min(count, bound.selection.end + limit) - bound.selection.end)
        let before = UTF16Range(location: start, length: bound.selection.location - start).flatMap { WritingAX.string(element, range: $0) } ?? ""
        let after = UTF16Range(location: bound.selection.end, length: afterLength).flatMap { WritingAX.string(element, range: $0) } ?? ""
        return WritingHostPayload.Surrounding(before: before, after: after)
    }

    func focusRestored(_ bound: TextTargetSnapshot) -> Bool {
        // Keystrokes reach only the active application's key window, so the app must be frontmost too.
        guard let element = elements[bound.token],
              NSWorkspace.shared.frontmostApplication?.processIdentifier == bound.processIdentifier else { return false }
        return WritingAX.focusedElement(of: bound.processIdentifier).map { CFEqual($0, element) } ?? false
    }

    func apply(_ bound: TextTargetSnapshot, range: UTF16Range, text: String, expectedSource: String) async -> WritingApplyOutcome {
        guard let element = elements[bound.token], let before = WritingAX.characterCount(element) else { return .notApplied(.targetUnavailable) }
        if !range.isEmpty, WritingAX.string(element, range: range) != expectedSource { return .notApplied(.sourceChanged) }
        // Chrome applies AX selection asynchronously; wait for the exact range to read back before pasting.
        guard WritingAX.select(element, range: range),
              await WritingAX.poll(timeout: 0.5, { WritingAX.selectedRange(element) == range }) else { return .notApplied(.selectionChanged) }
        // No suspension from here to the keystroke: focus, clipboard snapshot and staging are one synchronous step.
        guard focusRestored(bound) else { return .notApplied(.focusChanged) }
        guard let snapshot = clipboard.snapshot() else { return .notApplied(.clipboardUnavailable) }
        guard let staged = clipboard.stage(text, preserving: snapshot) else { return .notApplied(.clipboardUnavailable) }
        WritingAX.postPaste(to: bound.processIdentifier)
        let inserted = range.replaced(by: text)
        let expectedCount = before - range.length + text.utf16.count
        var latestCount = before
        let landed = await WritingAX.poll(timeout: 2.0) {
            latestCount = WritingAX.characterCount(element) ?? latestCount
            return latestCount == expectedCount && WritingAX.selectedRange(element) == .caret(inserted.end)
        }
        guard landed, WritingAX.string(element, range: inserted) == text else {
            // Unconsumed or transformed: never retry; the clipboard returns only after a late paste could land.
            clipboard.restoreLater(staged)
            return .deliveryUnknown
        }
        clipboard.restore(staged)
        return .applied(WritingAppliedEdit(targetToken: bound.token, insertedRange: inserted, insertedText: text,
                                           replacedText: expectedSource, postRevision: String(latestCount)))
    }

    /// Guarded inverse: only while the inserted text still sits unchanged where Clicky put it.
    func restore(_ bound: TextTargetSnapshot, _ edit: WritingAppliedEdit) async -> Bool {
        guard edit.targetToken == bound.token, let element = elements[bound.token],
              String(WritingAX.characterCount(element) ?? -1) == edit.postRevision,
              WritingAX.string(element, range: edit.insertedRange) == edit.insertedText else { return false }
        guard focusRestored(bound) else { return false }
        if edit.replacedText.isEmpty {
            guard WritingAX.select(element, range: edit.insertedRange),
                  await WritingAX.poll(timeout: 0.5, { WritingAX.selectedRange(element) == edit.insertedRange }) else { return false }
            let before = WritingAX.characterCount(element) ?? 0
            guard focusRestored(bound) else { return false }
            WritingAX.postKey(CGKeyCode(kVK_Delete), command: false, to: bound.processIdentifier)
            return await WritingAX.poll(timeout: 1.5) { WritingAX.characterCount(element) == before - edit.insertedRange.length }
        }
        if case .applied = await apply(bound, range: edit.insertedRange, text: edit.replacedText, expectedSource: edit.insertedText) { return true }
        return false
    }

    /// Only the most recent bindings keep AX references; older destinations can no longer be applied anyway.
    private var order: [UUID] = []
    private func remember(_ token: UUID, _ element: AXUIElement) {
        elements[token] = element; order.append(token)
        while order.count > 8 { elements.removeValue(forKey: order.removeFirst()) }
    }
}
