import CoreGraphics
import CoreText
import ImageIO
import XCTest
import ClickyCore
@testable import ClickyGuideNative

/// A small settings window drawn with CoreGraphics; clicks on its controls change what the next capture shows.
@MainActor
final class FixtureSettingsApp {
    static let width = 1024, height = 640
    enum Pane { case general, appearance }
    var pane = Pane.general
    var darkMode = false
    private(set) var log: [String] = []

    let sidebar: [(String, CGRect)] = [("General", CGRect(x: 16, y: 80, width: 190, height: 40)),
                                       ("Appearance", CGRect(x: 16, y: 128, width: 190, height: 40)),
                                       ("Privacy", CGRect(x: 16, y: 176, width: 190, height: 40))]
    let toggle = CGRect(x: 620, y: 140, width: 64, height: 34)

    /// Applies a click at an image-pixel point, like the real app would.
    func click(_ point: CGPoint) {
        if sidebar[1].1.contains(point) { pane = .appearance; log.append("click Appearance") }
        else if sidebar[0].1.contains(point) { pane = .general; log.append("click General") }
        else if pane == .appearance, toggle.insetBy(dx: -8, dy: -8).contains(point) { darkMode.toggle(); log.append("toggle Dark Mode -> \(darkMode)") }
        else { log.append("click missed at \(Int(point.x)),\(Int(point.y))") }
    }

    func png() -> Data {
        let context = CGContext(data: nil, width: Self.width, height: Self.height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.translateBy(x: 0, y: CGFloat(Self.height)); context.scaleBy(x: 1, y: -1)
        fill(context, CGRect(x: 0, y: 0, width: Self.width, height: Self.height), gray: 0.97)
        fill(context, CGRect(x: 0, y: 0, width: Self.width, height: 44), gray: 0.88)
        text(context, "Fixture Settings", at: CGPoint(x: 430, y: 28), size: 17, bold: true)
        fill(context, CGRect(x: 0, y: 44, width: 222, height: Self.height - 44), gray: 0.92)
        for (index, (label, rect)) in sidebar.enumerated() {
            let selected = (index == 0 && pane == .general) || (index == 1 && pane == .appearance)
            if selected { context.setFillColor(CGColor(red: 0.2, green: 0.45, blue: 0.95, alpha: 1)); context.fill(rect) }
            text(context, label, at: CGPoint(x: rect.minX + 14, y: rect.midY + 6), size: 16, bold: false, white: selected)
        }
        switch pane {
        case .general:
            text(context, "General", at: CGPoint(x: 250, y: 96), size: 24, bold: true)
            text(context, "Language: English", at: CGPoint(x: 250, y: 150), size: 16, bold: false)
            text(context, "Start at login: Off", at: CGPoint(x: 250, y: 190), size: 16, bold: false)
        case .appearance:
            text(context, "Appearance", at: CGPoint(x: 250, y: 96), size: 24, bold: true)
            text(context, "Dark Mode", at: CGPoint(x: 250, y: 164), size: 18, bold: false)
            context.setFillColor(darkMode ? CGColor(red: 0.2, green: 0.75, blue: 0.3, alpha: 1) : CGColor(gray: 0.7, alpha: 1))
            context.addPath(CGPath(roundedRect: toggle, cornerWidth: 17, cornerHeight: 17, transform: nil)); context.fillPath()
            let knobX = darkMode ? toggle.maxX - 31 : toggle.minX + 3
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fillEllipse(in: CGRect(x: knobX, y: toggle.minY + 3, width: 28, height: 28))
            text(context, darkMode ? "On" : "Off", at: CGPoint(x: 700, y: 164), size: 16, bold: false)
        }
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil); CGImageDestinationFinalize(destination)
        return data as Data
    }

    private func fill(_ context: CGContext, _ rect: CGRect, gray: CGFloat) { context.setFillColor(CGColor(gray: gray, alpha: 1)); context.fill(rect) }

    private func text(_ context: CGContext, _ string: String, at point: CGPoint, size: CGFloat, bold: Bool, white: Bool = false) {
        let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
        let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: white ? 1 : 0.1, alpha: 1)] as CFDictionary
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, string as CFString, attributes))
        context.saveGState(); context.textMatrix = CGAffineTransform(scaleX: 1, y: -1); context.textPosition = point
        CTLineDraw(line, context); context.restoreGState()
    }
}

/// Opt-in end-to-end run of the production walkthrough coordinator on the real on-device model:
/// `CLICKY_LIVE_MODEL=<catalog id> CLICKY_LOCAL_WORKER=<path to clicky-local-worker> bash scripts/test-core.sh --filter LocalLiveWorkflowTests`.
/// The screen, clicks and clock are simulated; the model, worker, runtime, agent and coordinator are real.
@MainActor
final class LocalLiveWorkflowTests: XCTestCase {
    private var runtime: LocalAIRuntime?

    override func tearDown() async throws {
        if let runtime { await runtime.unload(.vision) }
        LocalAIRuntime.shared = nil
    }

    private func liveRuntime() async throws -> LocalAIRuntime {
        guard let model = ProcessInfo.processInfo.environment["CLICKY_LIVE_MODEL"] else {
            throw XCTSkip("Set CLICKY_LIVE_MODEL and CLICKY_LOCAL_WORKER to run the live on-device workflow.")
        }
        let runtime = LocalAIRuntime(environment: .live, preferences: UserDefaults(suiteName: "clicky.live." + UUID().uuidString)!)
        await runtime.select(model, for: .vision)
        try await runtime.load(.vision)
        LocalAIRuntime.shared = runtime
        self.runtime = runtime
        return runtime
    }

    /// Real model turns take seconds, so fake time advances with real time while waiting (capture settles,
    /// verification delays); the status is printed every few seconds for diagnosis.
    private func wait(_ what: String, _ harness: GuideHarness, seconds: TimeInterval = 180, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        var ticks = 0
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out: \(what) status=\(harness.controller.status) phase=\(String(describing: harness.controller.task?.phase))")
                throw CancellationError()
            }
            try await Task.sleep(nanoseconds: 50_000_000)
            await harness.clock.advance(0.05)
            ticks += 1
            if ticks % 100 == 0 {
                print("LIVE-WAIT \(what): busy=\(harness.controller.isBusy) status=\(harness.controller.status) phase=\(String(describing: harness.controller.task?.phase))")
            }
        }
    }

    func testMultiStepDarkModeWalkthrough() async throws {
        _ = try await liveRuntime()
        let app = FixtureSettingsApp()
        let harness = GuideHarness(localModel: LocalAIRuntime.assistantClient)
        harness.screen.bounds = CGRect(x: 100, y: 100, width: FixtureSettingsApp.width, height: FixtureSettingsApp.height)
        harness.screen.render = { app.png() }
        let controller = harness.controller
        var transcript: [String] = []
        let started = Date()

        try controller.ask("Turn on Dark Mode in Fixture Settings", target: harness.screen.target)
        var lastRevision: UInt64 = .max
        for round in 1...6 {
            try await wait("step \(round)", harness) {
                !controller.isBusy && ((controller.task?.phase == .waiting && controller.task?.stepRevision != lastRevision)
                                       || controller.task?.phase == .completed
                                       || controller.task?.phase == .uncertain || controller.error != nil)
            }
            if let error = controller.error { transcript.append("error: \(error)"); break }
            guard let task = controller.task else { break }
            if task.phase == .completed { transcript.append("completed: \(task.milestones.map { "\($0.completion)" })"); break }
            if task.phase == .uncertain { transcript.append("uncertain: \(controller.status)"); break }
            guard let step = task.step, let target = step.target, task.stepRevision != lastRevision else { break }
            lastRevision = task.stepRevision
            transcript.append("step \(round): \(step.text) [\(step.action?.kind.rawValue ?? "-")] target \(Int(target.x)),\(Int(target.y)) "
                              + "\(Int(target.width))x\(Int(target.height)) outcome: \(step.outcome?.description ?? "-")")
            let center = CGPoint(x: target.x + target.width / 2, y: target.y + target.height / 2)
            app.click(center)
            harness.click(at: center, count: step.action?.kind == .double_click ? 2 : 1, time: Double(round) * 10)
        }
        transcript.append("app: " + app.log.joined(separator: "; "))
        transcript.append(String(format: "elapsed %.1f s", Date().timeIntervalSince(started)))
        print("LIVE-WORKFLOW\n" + transcript.joined(separator: "\n"))
        XCTAssertTrue(app.darkMode, "Dark Mode should end up on")
        XCTAssertEqual(controller.task?.phase, .completed)
    }

    /// Starts the walkthrough and waits for its first step; returns the harness.
    private func firstStep(_ app: FixtureSettingsApp) async throws -> GuideHarness {
        let harness = GuideHarness(localModel: LocalAIRuntime.assistantClient)
        harness.screen.bounds = CGRect(x: 100, y: 100, width: FixtureSettingsApp.width, height: FixtureSettingsApp.height)
        harness.screen.render = { app.png() }
        try harness.controller.ask("Turn on Dark Mode in Fixture Settings", target: harness.screen.target)
        try await wait("first step", harness) { !harness.controller.isBusy && harness.controller.task?.phase == .waiting }
        return harness
    }

    func testSideQuestionKeepsTheStepAndDifferentGoalIsProposed() async throws {
        _ = try await liveRuntime()
        let app = FixtureSettingsApp()
        let harness = try await firstStep(app)
        let controller = harness.controller
        let step = try XCTUnwrap(controller.task?.step?.text)
        let revision = controller.task?.stepRevision
        try controller.ask("What else can I change in Fixture Settings?", target: harness.screen.target)
        try await wait("side answer", harness) { !controller.isBusy }
        print("LIVE-SIDE answer: \(harness.responses.last ?? "-") error: \(controller.error ?? "-")")
        XCTAssertNil(controller.error)
        XCTAssertEqual(controller.task?.step?.text, step)
        XCTAssertEqual(controller.task?.stepRevision, revision)
        try controller.ask("Actually, change the language to German instead", target: harness.screen.target)
        try await wait("proposal", harness) { !controller.isBusy }
        print("LIVE-PROPOSAL \(controller.proposal?.kind.rawValue ?? "-"): \(controller.proposal?.proposedGoal ?? "-") error: \(controller.error ?? "-")")
        XCTAssertEqual(controller.proposal?.kind, .task_proposal)
    }

    func testWritingDraftAndRewrite() async throws {
        _ = try await liveRuntime()
        let world = FakeWritingWorld()
        world.localModel = LocalAIRuntime.assistantClient
        let drafting = await world.makeCoordinator(provider: .local, executable: false)
        drafting.start(.write(instruction: "a two sentence thank-you note to Anna for the book", skill: nil))
        try await waitWriting { drafting.phase == .finished || drafting.phase == .review }
        print("LIVE-DRAFT \(world.applyCalls.first?.text ?? drafting.previewText) notice: \(drafting.notice ?? "-") clarification: \(drafting.clarification ?? "-")")
        XCTAssertEqual(world.applyCalls.count, 1)
        XCTAssertTrue(world.applyCalls.first?.text.contains("Anna") == true)

        let selected = "hey can u send me the report by tmrw thx"
        let rewriting = FakeWritingWorld(primary: FakeWritingWorld.field(selection: FakeWritingWorld.range(0, selected.utf16.count)))
        rewriting.sourceText = selected
        rewriting.localModel = LocalAIRuntime.assistantClient
        let coordinator = await rewriting.makeCoordinator(provider: .local, executable: false)
        coordinator.start(.rewrite(instruction: "make it polite and professional", skill: nil))
        try await waitWriting { coordinator.proposal != nil }
        print("LIVE-REWRITE \(coordinator.previewText) notice: \(coordinator.notice ?? "-")")
        XCTAssertEqual(coordinator.plan, .review(replacesSelection: true))
        XCTAssertTrue(coordinator.previewText.lowercased().contains("report"))
    }

    private func waitWriting(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(120)
        while !condition() {
            guard Date() < deadline else { XCTFail("writing timed out"); throw CancellationError() }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
