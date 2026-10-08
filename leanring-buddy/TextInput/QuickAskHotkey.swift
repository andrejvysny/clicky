import AppKit
import Carbon
import SwiftUI

@MainActor
final class QuickAskHotkey {
    private var hotkey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var onPressed: (() -> Void)?

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
            Task { @MainActor in monitor.onPressed?() }
            return noErr
        }, 1, &eventType, userData, &handler)
        guard installed == noErr else { return false }
        let registered = RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: 0x434C514B, id: 1), GetApplicationEventTarget(), 0, &hotkey)
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
