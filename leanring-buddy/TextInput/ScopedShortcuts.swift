import Carbon

/// Global Option+Shift shortcuts that exist only while their surface is on screen, so they never shadow
/// app bindings (e.g. Option+Shift+Arrow word selection) outside a walkthrough or a visible reply.
@MainActor
final class ScopedShortcuts {
    private static let optionShift = UInt32(optionKey | shiftKey)
    private let next = QuickAskHotkey(identifier: 2)
    private let retry = QuickAskHotkey(identifier: 3)
    private let copy = QuickAskHotkey(identifier: 4)
    private let speak = QuickAskHotkey(identifier: 5)
    private let toggleReply = QuickAskHotkey(identifier: 6)
    private var guideActive = false
    private var replyActive = false

    var onNext: (() -> Void)? { didSet { next.onPressed = onNext } }
    var onRetry: (() -> Void)? { didSet { retry.onPressed = onRetry } }
    var onCopy: (() -> Void)? { didSet { copy.onPressed = onCopy } }
    var onSpeak: (() -> Void)? { didSet { speak.onPressed = onSpeak } }
    var onToggleReply: (() -> Void)? { didSet { toggleReply.onPressed = onToggleReply } }

    /// Option+Shift+Right (Next/skip) and Option+Shift+R (retry or re-check) while a guide step is shown.
    func setGuideActive(_ active: Bool) {
        guard active != guideActive else { return }
        guideActive = active
        if active {
            _ = next.register(keyCode: UInt32(kVK_RightArrow), modifiers: Self.optionShift)
            _ = retry.register(keyCode: UInt32(kVK_ANSI_R), modifiers: Self.optionShift)
        } else { next.unregister(); retry.unregister() }
    }

    /// Option+Shift+C (copy), Option+Shift+V (speak) and Option+Shift+Down (show/hide) while the reply is expanded.
    func setReplyActive(_ active: Bool) {
        guard active != replyActive else { return }
        replyActive = active
        if active {
            _ = copy.register(keyCode: UInt32(kVK_ANSI_C), modifiers: Self.optionShift)
            _ = speak.register(keyCode: UInt32(kVK_ANSI_V), modifiers: Self.optionShift)
            _ = toggleReply.register(keyCode: UInt32(kVK_DownArrow), modifiers: Self.optionShift)
        } else { copy.unregister(); speak.unregister(); toggleReply.unregister() }
    }

    func unregisterAll() { setGuideActive(false); setReplyActive(false) }
}
