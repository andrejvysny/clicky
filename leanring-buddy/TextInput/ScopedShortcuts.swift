import Carbon

/// Global Option+Shift shortcuts that exist only while their surface is on screen, so they never shadow
/// app bindings (e.g. Option+Shift+Arrow word selection) outside a walkthrough or a visible reply.
@MainActor
final class ScopedShortcuts {
    private static let optionShift = UInt32(optionKey | shiftKey)
    private let next = QuickAskHotkey(identifier: 2)
    private let retry = QuickAskHotkey(identifier: 3)
    private let back = QuickAskHotkey(identifier: 6)
    private let end = QuickAskHotkey(identifier: 7)
    private let copy = QuickAskHotkey(identifier: 4)
    private let speak = QuickAskHotkey(identifier: 5)
    private var guideActive = false
    private var replyActive = false

    var onNext: (() -> Void)? { didSet { next.onPressed = onNext } }
    var onRetry: (() -> Void)? { didSet { retry.onPressed = onRetry } }
    var onBack: (() -> Void)? { didSet { back.onPressed = onBack } }
    var onEnd: (() -> Void)? { didSet { end.onPressed = onEnd } }
    var onCopy: (() -> Void)? { didSet { copy.onPressed = onCopy } }
    var onSpeak: (() -> Void)? { didSet { speak.onPressed = onSpeak } }

    /// Option+Shift+Left (back), Right (Next/skip), R (retry or re-check) and Delete (end) while a guide step is shown.
    func setGuideActive(_ active: Bool) {
        guard active != guideActive else { return }
        guideActive = active
        if active {
            _ = next.register(keyCode: UInt32(kVK_RightArrow), modifiers: Self.optionShift)
            _ = retry.register(keyCode: UInt32(kVK_ANSI_R), modifiers: Self.optionShift)
            _ = back.register(keyCode: UInt32(kVK_LeftArrow), modifiers: Self.optionShift)
            _ = end.register(keyCode: UInt32(kVK_Delete), modifiers: Self.optionShift)
        } else { next.unregister(); retry.unregister(); back.unregister(); end.unregister() }
    }

    /// Option+Shift+C (copy) and Option+Shift+V (speak) while Quick Ask shows a reply.
    func setReplyActive(_ active: Bool) {
        guard active != replyActive else { return }
        replyActive = active
        if active {
            _ = copy.register(keyCode: UInt32(kVK_ANSI_C), modifiers: Self.optionShift)
            _ = speak.register(keyCode: UInt32(kVK_ANSI_V), modifiers: Self.optionShift)
        } else { copy.unregister(); speak.unregister() }
    }

    func unregisterAll() { setGuideActive(false); setReplyActive(false) }
}
