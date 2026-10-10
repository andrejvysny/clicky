import AppKit
import Carbon
import SwiftUI
import os
#if canImport(ClickyCore)
import ClickyCore
#endif

@MainActor
final class QuickAskHotkey {
    private var registration = ShortcutRegistration<EventHotKeyRef>()
    private var handler: EventHandlerRef?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "clicky", category: "shortcut")
    /// Distinguishes several registrations; each handler only consumes its own identifier.
    private let identifier: UInt32
    var onPressed: (() -> Void)?
    /// Key-up of the registered key (hybrid tap/hold recording). Unused by the Quick Ask shortcut itself.
    var onReleased: (() -> Void)?

    init(identifier: UInt32 = 1) { self.identifier = identifier }

    func register(keyCode: UInt32, modifiers: UInt32) -> Bool {
        guard installHandler() else { return false }
        let registered = registration.register(ShortcutBinding(keyCode: keyCode, modifiers: modifiers), acquire: { binding in
            var replacement: EventHotKeyRef?
            let status = RegisterEventHotKey(binding.keyCode, binding.modifiers,
                                            EventHotKeyID(signature: 0x434C514B, id: identifier),
                                            GetApplicationEventTarget(), 0, &replacement)
            guard status == noErr, let replacement else {
                logger.error("Carbon shortcut registration failed: status \(status, privacy: .public), identifier \(self.identifier, privacy: .public)")
                return nil
            }
            return replacement
        }, release: { UnregisterEventHotKey($0) })
        if !registered, registration.binding == nil { removeHandler() }
        return registered
    }

    private func installHandler() -> Bool {
        if handler != nil { return true }
        var eventTypes = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                          EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                  identifier.signature == 0x434C514B else { return OSStatus(eventNotHandledErr) }
            let monitor = Unmanaged<QuickAskHotkey>.fromOpaque(userData).takeUnretainedValue()
            guard identifier.id == monitor.identifier else { return OSStatus(eventNotHandledErr) }
            if GetEventKind(event) == UInt32(kEventHotKeyReleased) {
                Task { @MainActor in monitor.onReleased?() }
            } else {
                Task { @MainActor in monitor.onPressed?() }
            }
            return noErr
        }, eventTypes.count, &eventTypes, userData, &handler)
        guard installed == noErr else {
            logger.error("Carbon shortcut handler installation failed: status \(installed, privacy: .public), identifier \(self.identifier, privacy: .public)")
            removeHandler()
            return false
        }
        return true
    }

    func unregister() {
        registration.unregister { UnregisterEventHotKey($0) }
        removeHandler()
    }

    private func removeHandler() {
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    deinit {
        registration.unregister { UnregisterEventHotKey($0) }
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
