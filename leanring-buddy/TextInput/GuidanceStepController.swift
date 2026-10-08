#if DEBUG
import AppKit
import ApplicationServices
import os

/// Debug-only guide step: shows the overlay and verifies one click or key combo via GuidanceVerification.
/// Uses passive global NSEvent monitors only; no event taps, synthesis, AX inspection or screenshots.
@MainActor
final class GuidanceStepController {
    private struct WindowInfo { let number: UInt32; let pid: Int32; let bounds: CGRect }

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "clicky", category: "guidance")
    private let overlay = GuidanceOverlay()
    private var verification: GuidanceVerification?
    private var generation: UInt64 = 0
    private var targetRect: CGRect = .zero
    private var targetWindowBounds: CGRect?
    private var targetWindowNumber: UInt32 = 0
    private var targetDisplay: UInt32 = 0
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private var timeoutTask: Task<Void, Never>?
    private var missCount = 0
    private var ignoredKeyCount = 0
    private var didPromptAccessibility = false

    func handle(_ request: GuidanceDebugRequest) {
        switch request {
        case .cancel: cancel(reason: "canceled")
        case .show(let target, let instruction, let expected): start(target: target, instruction: instruction, expected: expected)
        }
    }

    private func start(target: CGRect, instruction: String, expected: GuidanceVerification.ExpectedAction) {
        cancel(reason: "replaced")
        generation &+= 1
        let current = generation
        let center = CGPoint(x: target.midX, y: target.midY)
        let window = topWindow(at: center)
        targetRect = target
        targetWindowNumber = window?.number ?? 0
        targetWindowBounds = window?.bounds
        targetDisplay = display(at: center)
        missCount = 0
        ignoredKeyCount = 0
        do {
            verification = try GuidanceVerification(windowIdentifier: targetWindowNumber, displayIdentifier: targetDisplay,
                                                    target: target, expectedAction: expected, generation: current)
        } catch {
            logger.error("guidance start failed: invalid geometry")
            return
        }
        let prompt: String
        switch expected {
        case .click(let button): prompt = button == 1 ? "Waiting for your right-click…" : "Waiting for your click…"
        case .key(let code, let modifiers): prompt = "Press \(Self.combo(code: code, modifiers: modifiers))…"
        }
        overlay.show(target: target, instruction: instruction)
        overlay.update(status: prompt, tone: .waiting)
        logger.info("\(self.stepID, privacy: .public) started textLength=\(instruction.count, privacy: .public) rect=\(NSStringFromRect(target), privacy: .public) window=\(self.targetWindowNumber, privacy: .public) display=\(self.targetDisplay, privacy: .public)")

        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            let button = event.type == .rightMouseDown ? 1 : 0
            MainActor.assumeIsolated { self?.observeClick(button: button, generation: current) }
        }
        if case .key = expected { installKeyMonitor(generation: current) }
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            guard !Task.isCancelled, let self, self.generation == current else { return }
            self.logger.info("\(self.stepID, privacy: .public) timeout")
            self.cancel(reason: "timed out")
        }
    }

    func cancel(reason: String) {
        let hadStep = verification != nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        clickMonitor = nil
        keyMonitor = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        if hadStep { logger.info("\(self.stepID, privacy: .public) canceled reason=\(reason, privacy: .public)") }
        verification?.cancel()
        verification = nil
        overlay.hide()
    }

    // MARK: - Click

    private func observeClick(button: Int, generation current: UInt64) {
        guard current == generation, verification != nil else { return }
        let location = NSEvent.mouseLocation
        let point = CGPoint(x: location.x, y: primaryHeight - location.y)
        let window = topWindow(at: point)
        let matched = verification?.observe(.click(button: button, point: point), windowIdentifier: window?.number ?? 0,
                                            displayIdentifier: display(at: point), targetIsFresh: targetIsFresh()) ?? false
        let distance = distance(from: point, to: targetRect)
        logger.info("\(self.stepID, privacy: .public) click phase=\(self.phaseName, privacy: .public) x=\(Int(point.x.rounded()), privacy: .public) y=\(Int(point.y.rounded()), privacy: .public) matched=\(matched, privacy: .public) distance=\(Int(distance.rounded()), privacy: .public)")
        if matched {
            finishMatched(status: "✓ Click detected inside the circle")
            return
        }
        missCount += 1
        logger.info("\(self.stepID, privacy: .public) miss missCount=\(self.missCount, privacy: .public)")
        if distance == 0 {
            overlay.update(status: "Clicked the circle, but the target window changed or moved", tone: .miss)
        } else {
            overlay.update(status: "Missed by \(Int(distance.rounded())) pt — click inside the circle", tone: .miss)
        }
    }

    // MARK: - Key

    private func installKeyMonitor(generation current: UInt64) {
        guard AXIsProcessTrusted() else {
            if !didPromptAccessibility {
                didPromptAccessibility = true
                _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
            }
            overlay.update(status: "Grant Accessibility to Clicky in System Settings, then rerun this step", tone: .warning)
            logger.info("\(self.stepID, privacy: .public) accessibilityRequired")
            return
        }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.isARepeat { return }
            let code = event.keyCode
            let modifiers = UInt64(event.modifierFlags.intersection([.command, .shift, .option, .control]).rawValue)
            MainActor.assumeIsolated { self?.observeKey(code: code, modifiers: modifiers, generation: current) }
        }
    }

    private func observeKey(code: UInt16, modifiers: UInt64, generation current: UInt64) {
        guard current == generation, verification != nil else { return }
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let window = onScreenWindows().first { $0.pid == pid }
        let displayID = window.map { display(at: CGPoint(x: $0.bounds.midX, y: $0.bounds.midY)) } ?? targetDisplay
        let matched = verification?.observe(.key(code: code, modifiers: modifiers), windowIdentifier: window?.number ?? 0,
                                            displayIdentifier: displayID, targetIsFresh: targetIsFresh()) ?? false
        // Privacy: keystrokes outside the expected combo are only counted; never store, log or show them.
        guard matched else { ignoredKeyCount += 1; return }
        logger.info("\(self.stepID, privacy: .public) key phase=\(self.phaseName, privacy: .public) matched=true ignoredKeyCount=\(self.ignoredKeyCount, privacy: .public)")
        finishMatched(status: "✓ Expected keys detected")
    }

    // MARK: - Shared

    private func finishMatched(status: String) {
        overlay.update(status: status, tone: .success)
        logger.info("\(self.stepID, privacy: .public) matched phase=\(self.phaseName, privacy: .public) missCount=\(self.missCount, privacy: .public) ignoredKeyCount=\(self.ignoredKeyCount, privacy: .public)")
        let current = generation
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self, self.generation == current else { return }
            self.cancel(reason: "completed")
        }
    }

    private var stepID: String { verification.map { String($0.identifier.uuidString.prefix(8)) } ?? "--------" }
    private var phaseName: String { verification?.phase.rawValue ?? "none" }

    private var primaryHeight: CGFloat {
        (NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.screens.first)?.frame.height ?? 0
    }

    private func onScreenWindows() -> [WindowInfo] {
        let own = ProcessInfo.processInfo.processIdentifier
        let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return raw.compactMap(Self.windowInfo).filter { $0.pid != own }
    }

    private static func windowInfo(_ entry: [String: Any]) -> WindowInfo? {
        guard (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              let number = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict) else { return nil }
        return WindowInfo(number: number, pid: pid, bounds: bounds)
    }

    private func topWindow(at point: CGPoint) -> WindowInfo? { onScreenWindows().first { $0.bounds.contains(point) } }

    private func display(at point: CGPoint) -> UInt32 {
        var id: CGDirectDisplayID = 0
        var count: UInt32 = 0
        return CGGetDisplaysWithPoint(point, 1, &id, &count) == .success && count > 0 ? id : 0
    }

    private func targetIsFresh() -> Bool {
        guard let expected = targetWindowBounds else { return true }
        let raw = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(targetWindowNumber)) as? [[String: Any]] ?? []
        guard let current = raw.first.flatMap(Self.windowInfo)?.bounds else { return false }
        return abs(current.minX - expected.minX) <= 1 && abs(current.minY - expected.minY) <= 1
            && abs(current.width - expected.width) <= 1 && abs(current.height - expected.height) <= 1
    }

    private func distance(from point: CGPoint, to rect: CGRect) -> Double {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return Double((dx * dx + dy * dy).squareRoot())
    }

    private static func combo(code: UInt16, modifiers: UInt64) -> String {
        let symbols: [(String, String)] = [("ctrl", "⌃"), ("opt", "⌥"), ("shift", "⇧"), ("cmd", "⌘")]
        let prefix = symbols.filter { (modifiers & (GuidanceKeyNames.modifierBits[$0.0] ?? 0)) != 0 }.map(\.1).joined()
        let names = ["return", "tab", "space", "delete", "escape", "left", "right", "down", "up"]
            + "abcdefghijklmnopqrstuvwxyz0123456789".map(String.init)
        return prefix + (names.first { GuidanceKeyNames.keyCode(for: $0) == code } ?? "?").uppercased()
    }
}
#endif
