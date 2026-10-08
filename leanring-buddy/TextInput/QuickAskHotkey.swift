import AppKit
import Carbon
import SwiftUI

@MainActor
final class QuickAskHotkey {
    private var hotkey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    /// Distinguishes several registrations; each handler only consumes its own identifier.
    private let identifier: UInt32
    var onPressed: (() -> Void)?

    init(identifier: UInt32 = 1) { self.identifier = identifier }

    func register(keyCode: UInt32, modifiers: UInt32) -> Bool {
        unregister()
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                  identifier.signature == 0x434C514B else { return OSStatus(eventNotHandledErr) }
            let monitor = Unmanaged<QuickAskHotkey>.fromOpaque(userData).takeUnretainedValue()
            guard identifier.id == monitor.identifier else { return OSStatus(eventNotHandledErr) }
            Task { @MainActor in monitor.onPressed?() }
            return noErr
        }, 1, &eventType, userData, &handler)
        guard installed == noErr else { return false }
        let registered = RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: 0x434C514B, id: identifier), GetApplicationEventTarget(), 0, &hotkey)
        if registered != noErr { unregister() }
        return registered == noErr
    }

    func unregister() {
        if let hotkey { UnregisterEventHotKey(hotkey) }
        if let handler { RemoveEventHandler(handler) }
        hotkey = nil
        handler = nil
    }

    deinit {
        if let hotkey { UnregisterEventHotKey(hotkey) }
        if let handler { RemoveEventHandler(handler) }
    }
}

struct ShortcutCaptureView: NSViewRepresentable {
    let onCaptured: (UInt32?, UInt32?) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = ShortcutCaptureField()
        view.onCaptured = onCaptured
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}

private final class ShortcutCaptureField: NSView {
    var onCaptured: ((UInt32?, UInt32?) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCaptured?(nil, nil); return }
        guard !event.isARepeat else { return }
        var modifiers: UInt32 = 0
        if event.modifierFlags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if event.modifierFlags.contains(.option) { modifiers |= UInt32(optionKey) }
        if event.modifierFlags.contains(.control) { modifiers |= UInt32(controlKey) }
        guard modifiers != 0 else { return }
        onCaptured?(UInt32(event.keyCode), modifiers)
    }
}

/// Human-readable Carbon shortcut, e.g. "⌥⇧Space".
enum ShortcutLabel {
    private static let keys: [UInt32: String] = [
        49: "Space", 36: "Return", 48: "Tab", 53: "Esc", 123: "←", 124: "→", 125: "↓", 126: "↑",
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K", 37: "L", 46: "M",
        45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
    ]

    static func parts(keyCode: UInt32, modifiers: UInt32) -> [String] {
        var result: [String] = []
        if modifiers & UInt32(controlKey) != 0 { result.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { result.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { result.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { result.append("⌘") }
        result.append(keys[keyCode] ?? "Key \(keyCode)")
        return result
    }

    static func text(keyCode: UInt32, modifiers: UInt32) -> String { parts(keyCode: keyCode, modifiers: modifiers).joined() }
}
