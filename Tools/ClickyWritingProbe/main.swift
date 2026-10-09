import AppKit
import ApplicationServices

// Native adapter probe: drives the production WritingNativeTargets/adapters against real Chrome, Terminal and VS Code.
// Built by scripts/probe-writing-native.sh with swiftc (not SwiftPM: the adapters are app sources). Not GUI evidence for Quick Ask.
@MainActor func run() async {
    let targets = WritingNativeTargets()
    let env = targets.environment
    let mode = CommandLine.arguments.dropFirst().first ?? ""
    func pid(_ bundle: String) -> Int32? { NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.processIdentifier }
    // The harness activates through osascript: a background tool's NSRunningApplication.activate can be ignored.
    func activate(_ bundle: String) async {
        let script = Process(); script.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        script.arguments = ["-e", "tell application id \"\(bundle)\" to activate"]
        try? script.run(); script.waitUntilExit()
        _ = await WritingAX.poll(timeout: 2) { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundle }
    }
    func field() -> AXUIElement { WritingAX.focusedElement(of: pid("com.google.Chrome")!)! }
    func value() -> String { (WritingAX.value(field(), kAXValueAttribute) as? String) ?? "<nil>" }
    func report(_ label: String, _ ok: Bool) { print((ok ? "PASS " : "FAIL ") + label) }

    switch mode {
    case "chrome":
        await activate("com.google.Chrome")
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem(); item.setString("user clipboard ✓", forType: .string); item.setData(Data([1, 2, 3]), forType: NSPasteboard.PasteboardType("com.example.custom"))
        pb.writeObjects([item])
        let original = value()
        _ = WritingAX.select(field(), range: UTF16Range(location: 0, length: 0)!); try? await Task.sleep(nanoseconds: 300_000_000)
        var captured: TextTargetSnapshot?
        for _ in 0..<15 where captured == nil {
            captured = await env.captureTargets(pid("com.google.Chrome")).primary
            if captured == nil { try? await Task.sleep(nanoseconds: 200_000_000) }
        }
        guard var bound = captured else { return report("chrome capture", false) }
        report("chrome focus gate", await env.restoreFocus(bound))
        report("chrome capture kind=\(bound.kind) blocked=\(String(describing: bound.blockedReason)) sel=\(bound.selection)", bound.kind == .textField && bound.blockedReason == nil)
        let insert = "Héllo 😀 e\u{301} ťžč\n\n  indented\t$(x) `y`\n"
        let outcome = await env.apply(bound, bound.selection, insert, "", { true })
        report("chrome insert applied=\(outcome.applied != nil)", outcome.applied != nil && value() == insert + original)
        report("chrome clipboard restored", pb.string(forType: .string) == "user clipboard ✓" && pb.data(forType: NSPasteboard.PasteboardType("com.example.custom")) == Data([1, 2, 3]))
        if let edit = outcome.applied {
            let restored = await env.restore(bound, edit, { true })
            report("chrome guarded restore", restored && value() == original)
        }
        // Rewrite one exact substring: "paragraph" in "First paragraph stays."
        _ = WritingAX.select(field(), range: UTF16Range(location: 6, length: 9)!); try? await Task.sleep(nanoseconds: 300_000_000)
        bound = await env.captureTargets(pid("com.google.Chrome")).primary!
        let source = try? await env.readSource(bound)
        report("chrome exact source '\(source?.text ?? "nil")'", source?.text == "paragraph")
        let replaced = await env.apply(bound, bound.selection, "PARAGRAPH 😀", source?.text ?? "", { true })
        report("chrome replace only range", replaced.applied != nil && value() == original.replacingOccurrences(of: "First paragraph", with: "First PARAGRAPH 😀"))
        if let edit = replaced.applied { _ = await env.restore(bound, edit, { true }) }
        report("chrome restored after replace", value() == original)
        // Changed caret invalidates.
        bound = await env.captureTargets(pid("com.google.Chrome")).primary!
        _ = WritingAX.select(field(), range: UTF16Range(location: 3, length: 0)!); try? await Task.sleep(nanoseconds: 300_000_000)
        let change = bound.change(comparedWith: await env.liveTarget(bound))
        report("chrome caret move detected (\(String(describing: change)))", change == .selectionChanged)
        // Stale expected source refuses.
        _ = WritingAX.select(field(), range: UTF16Range(location: 0, length: 5)!); try? await Task.sleep(nanoseconds: 300_000_000)
        bound = await env.captureTargets(pid("com.google.Chrome")).primary!
        let stale = await env.apply(bound, bound.selection, "X", "Nope!", { true })
        report("chrome stale source refused (\(stale))", stale == .notApplied(.sourceChanged) && value() == original)
        // Promised/unreadable clipboard: simulate oversized snapshot is not possible here; check snapshot works.
        report("chrome clipboard intact at end", pb.string(forType: .string) == "user clipboard ✓")
    case "chrome-rich":
        await activate("com.google.Chrome")
        // Focus the fixture's contenteditable (aria-label "Contenteditable") through AX; the textarea is also AXTextArea.
        func find(_ root: AXUIElement, depth: Int = 0) -> AXUIElement? {
            if WritingAX.value(root, kAXDescriptionAttribute) as? String == "Contenteditable" { return root }
            guard depth < 40 else { return nil }
            for child in (WritingAX.value(root, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                if let found = find(child, depth: depth + 1) { return found }
            }
            return nil
        }
        let chrome = AXUIElementCreateApplication(pid("com.google.Chrome")!)
        guard let window = WritingAX.value(chrome, kAXFocusedWindowAttribute).map({ $0 as! AXUIElement }), let rich = find(window) else {
            return report("contenteditable located", false)
        }
        AXUIElementSetAttributeValue(rich, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        report("contenteditable focused", await WritingAX.poll(timeout: 1.5) { WritingAX.value(field(), kAXDescriptionAttribute) as? String == "Contenteditable" })
        _ = WritingAX.select(field(), range: UTF16Range(location: 0, length: 0)!); try? await Task.sleep(nanoseconds: 300_000_000)
        var captured: TextTargetSnapshot?
        for _ in 0..<15 where captured == nil {
            captured = await env.captureTargets(pid("com.google.Chrome")).primary
            if captured == nil { try? await Task.sleep(nanoseconds: 200_000_000) }
        }
        guard var bound = captured else { return report("contenteditable capture", false) }
        report("contenteditable capture role=\(WritingAX.value(field(), kAXRoleAttribute) as? String ?? "-") blocked=\(String(describing: bound.blockedReason))", bound.blockedReason == nil)
        report("contenteditable focus gate (front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-"))", await env.restoreFocus(bound))
        let original = value()
        let inserted = await env.apply(bound, bound.selection, "Ahoj 😀 ", "", { true })
        report("contenteditable insert (\(inserted))", inserted.applied != nil && value() == "Ahoj 😀 " + original)
        if let edit = inserted.applied { report("contenteditable guarded restore", await env.restore(bound, edit, { true }) && value() == original) }
        let middle = (original as NSString).range(of: "Middle")
        let wanted = UTF16Range(location: middle.location, length: middle.length)!
        _ = WritingAX.select(field(), range: wanted)
        report("contenteditable test selection set", await WritingAX.poll(timeout: 1.5) { WritingAX.selectedRange(field()) == wanted })
        bound = await env.captureTargets(pid("com.google.Chrome")).primary!
        let source = try? await env.readSource(bound)
        let replaced = await env.apply(bound, bound.selection, "Stred ťž", source?.text ?? "", { true })
        report("contenteditable replace only 'Middle' (\(replaced))", replaced.applied != nil && value() == original.replacingOccurrences(of: "Middle", with: "Stred ťž"))
        report("duplicate passages untouched", value().components(separatedBy: "Duplicate passage").count == 3)
        if let edit = replaced.applied { _ = await env.restore(bound, edit, { true }) }
    case "terminal":
        let marker = CommandLine.arguments[2]
        let expectedTTY = CommandLine.arguments[3]
        await activate("com.apple.Terminal")
        guard let bound = await env.captureTargets(pid("com.apple.Terminal")).primary, bound.paneIdentity == expectedTTY else {
            return report("terminal capture of the scratch tab", false)
        }
        report("terminal focus gate", await env.restoreFocus(bound))
        report("terminal capture kind=\(bound.kind) blocked=\(String(describing: bound.blockedReason)) pane=\(bound.paneIdentity ?? "-")", bound.kind == .terminal && bound.blockedReason == nil)
        let command = "touch '\(marker)' && echo \"$(date) `whoami`\" | tr a-z A-Z; true"
        let plan = WritingApplyPlan.decide(intent: .snippet, target: bound, text: command, provenance: .snippet(id: UUID(), revision: 1))
        report("terminal plan automatic", plan == .automatic)
        let outcome = await env.apply(bound, .caret(0)!, command, "", { true })
        try? await Task.sleep(nanoseconds: 800_000_000)
        report("terminal inserted (\(outcome))", outcome.applied != nil)
        report("terminal NOT executed (marker absent)", !FileManager.default.fileExists(atPath: marker))
        let multiline = await env.apply(bound, .caret(0)!, "echo a\necho b", "", { true })
        report("terminal multiline refused (\(multiline))", multiline == .notApplied(.rejectedByTarget))
        report("terminal multiline plan previewOnly", WritingApplyPlan.decide(intent: .snippet, target: bound, text: "echo a\n", provenance: .snippet(id: UUID(), revision: 1)) == .previewOnly(.terminalMultiline))
    case "tester-enter":
        // Simulates the tester's own Return, only into the scratch tab after the same focus gate Clicky uses.
        await activate("com.apple.Terminal")
        guard let bound = await env.captureTargets(pid("com.apple.Terminal")).primary, bound.paneIdentity == CommandLine.arguments[2],
              await env.restoreFocus(bound) else { return report("tester Enter target is the scratch tab", false) }
        // A HID-level Return like a physical key (Terminal ignores pid-targeted Return); the focus gate above
        // proved the scratch tab is frontmost and focused.
        for down in [true, false] { CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: 36, keyDown: down)?.post(tap: .cghidEventTap) }
        try? await Task.sleep(nanoseconds: 300_000_000)
        print("tester Enter posted to the scratch tab")
    case "terminal-busy":
        await activate("com.apple.Terminal")
        let bound = await env.captureTargets(pid("com.apple.Terminal")).primary
        report("busy terminal blocked (\(String(describing: bound?.blockedReason)))", bound?.blockedReason == .terminalNotReady)
    case "vscode", "vscode-terminal":
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.microsoft.VSCode")
        guard let app = apps.max(by: { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }) else { return report("vscode running", false) }
        app.activate(options: []); try? await Task.sleep(nanoseconds: 800_000_000)
        let bound = await env.captureTargets(app.processIdentifier)
        guard let editor = bound.primary else { return report("vscode capture", false) }
        report("vscode capture kind=\(editor.kind) blocked=\(String(describing: editor.blockedReason)) sel=\(editor.selection) rev=\(editor.contentRevision) alt=\(String(describing: bound.alternate?.kind)) altBlocked=\(String(describing: bound.alternate?.blockedReason))", editor.kind == .vscodeEditor && editor.blockedReason == nil)
        if mode == "vscode" {
            let text = "Ťest 😀 e\u{301}\n\tindent $(x)\n"
            let outcome = await env.apply(editor, editor.selection, text, "", { true })
            report("vscode insert (\(outcome))", outcome.applied != nil)
            if let edit = outcome.applied {
                let live = await env.liveTarget(editor)
                report("vscode version advanced \(editor.contentRevision)->\(live?.contentRevision ?? "-")", live?.contentRevision != editor.contentRevision)
                let stale = await env.apply(editor, editor.selection, "SHOULD NOT LAND", "", { true })
                report("vscode stale version refused (\(stale))", stale == .notApplied(.contentChanged))
                report("vscode guarded restore", await env.restore(editor, edit, { true }))
            }
        } else if let terminal = bound.alternate {
            let marker = CommandLine.arguments[2]
            let outcome = await env.apply(terminal, .caret(0)!, "touch '\(marker)'", "", { true })
            try? await Task.sleep(nanoseconds: 800_000_000)
            report("vscode terminal inserted (\(outcome))", outcome.applied != nil)
            report("vscode terminal NOT executed", !FileManager.default.fileExists(atPath: marker))
            let multi = await env.apply(terminal, .caret(0)!, "echo a\necho b", "", { true })
            report("vscode terminal multiline refused (\(multi))", multi == .notApplied(.rejectedByTarget))
        } else { report("vscode terminal present", false) }
    default: print("usage: probe chrome|terminal <marker>|terminal-busy")
    }
}
Task { @MainActor in await run(); exit(0) }
RunLoop.main.run()
