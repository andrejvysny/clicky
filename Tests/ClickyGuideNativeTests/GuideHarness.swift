import AppKit
import ImageIO
import XCTest
import ClickyCore
@testable import ClickyGuideNative

/// Deterministic monotonic clock. Sleepers resume only when a test advances time; no real-time waits.
final class FakeClock: @unchecked Sendable {
    private struct Sleeper { let id: UUID; let deadline: Date; let continuation: CheckedContinuation<Void, Error> }
    private let lock = NSLock()
    private static let start = Date(timeIntervalSince1970: 1_000_000)
    private var current = FakeClock.start
    private var sleepers: [Sleeper] = []
    /// Wall-clock adjustment (NTP, manual change); moves `now` but never the monotonic `uptime` or sleepers.
    var wallSkew: TimeInterval { get { lock.withLock { skew } } set { lock.withLock { skew = newValue } } }
    private var skew: TimeInterval = 0
    var now: Date { lock.withLock { current.addingTimeInterval(skew) } }
    var uptime: TimeInterval { lock.withLock { current.timeIntervalSince(FakeClock.start) } }
    var pendingSleepers: Int { lock.withLock { sleepers.count } }

    func sleep(_ nanoseconds: UInt64) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock {
                    sleepers.append(Sleeper(id: id, deadline: current.addingTimeInterval(Double(nanoseconds) / 1e9),
                                            continuation: continuation))
                }
            }
        } onCancel: {
            let cancelled = lock.withLock { () -> Sleeper? in
                guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return sleepers.remove(at: index)
            }
            cancelled?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward and resumes due sleepers in deadline order.
    @MainActor func advance(_ seconds: TimeInterval) async {
        // Let freshly scheduled tasks register their sleeps against the current time first.
        await settle()
        let due = lock.withLock { () -> [Sleeper] in
            current = current.addingTimeInterval(seconds)
            let ready = sleepers.filter { $0.deadline <= current }.sorted { $0.deadline < $1.deadline }
            sleepers.removeAll { sleeper in ready.contains { $0.id == sleeper.id } }
            return ready
        }
        for sleeper in due { sleeper.continuation.resume() }
        await settle()
    }
}

/// A provider conversation whose replies the test supplies one turn at a time.
/// By default it ignores cancellation, so a late reply after Pause/End is delivered and must be rejected by the host.
actor ScriptedAgent: GuideAgentRunning {
    private(set) var turns: [GuideAgentTurn] = []
    private(set) var closed = false
    private var pending: CheckedContinuation<GuidePresentation, Error>?

    func turn(_ request: GuideAgentTurn) async throws -> GuidePresentation {
        guard !closed else { throw AskError.incompleteTurn }
        turns.append(request)
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func identifier() -> String? { "scripted" }
    func close() { closed = true }

    var hasPendingTurn: Bool { pending != nil }
    var lastTurn: GuideAgentTurn? { turns.last }
    func reply(_ presentation: GuidePresentation) {
        let continuation = pending; pending = nil
        continuation?.resume(returning: presentation)
    }
    func reply(_ make: (GuideAgentTurn) -> GuidePresentation) {
        guard let last = turns.last else { return }
        reply(make(last))
    }
}

/// One synthetic window: a bounded RGBA canvas captured as PNG with its real identity and region.
@MainActor
final class FakeScreen {
    let target = WindowCaptureTarget(processIdentifier: 4242, windowIdentifier: 77,
                                     applicationIdentifier: "fixture.clicky", applicationName: "Fixture")
    var bounds: CGRect? = CGRect(x: 100, y: 100, width: 64, height: 48)
    var focused = true
    var frontmost: Int32? = 4242
    var related: [WindowCaptureTarget] = []
    var outcome: Bool?
    /// Global pointer position; far from every target unless a test hovers.
    var pointer = CGPoint(x: -500, y: -500)
    /// Content-free counters for capture cost and ordering.
    private(set) var captures = 0
    var captureGate: CheckedContinuation<Void, Never>?
    var holdCaptures = false
    private var pixels: [UInt8]
    let width = 64, height = 48

    init() { pixels = [UInt8](repeating: 255, count: 64 * 48 * 4) }

    /// Paints an opaque rectangle in image pixels so freshness fingerprints actually change.
    func paint(_ rect: CGRect, value: UInt8) {
        for y in Int(rect.minY)..<min(height, Int(rect.maxY)) {
            for x in Int(rect.minX)..<min(width, Int(rect.maxX)) {
                let offset = (y * width + x) * 4
                pixels[offset] = value; pixels[offset + 1] = value; pixels[offset + 2] = value; pixels[offset + 3] = 255
            }
        }
    }

    /// When set, captures return this PNG instead of the painted canvas; its pixel size must match `bounds`.
    var render: (() -> Data)?

    /// Runs before every capture so tests can assert what was on screen (e.g. Clicky's selection UI).
    var beforeCapture: (() -> Void)?

    func capture(_ requested: WindowCaptureTarget? = nil) async throws -> PNGImageAttachment {
        let target = requested ?? self.target
        beforeCapture?()
        captures += 1
        if holdCaptures { await withCheckedContinuation { captureGate = $0 } }
        guard let bounds else { throw AttachmentError.targetChanged }
        let identityFor = ScreenContextIdentity(applicationIdentifier: target.applicationIdentifier,
                                                windowIdentifier: target.windowIdentifier, displayIdentifier: 1, capturedAt: Date())
        if let rendered = render?() {
            return try PNGImageAttachment(data: rendered, displayName: "Rendered fixture", context: identityFor, capturedRegion: bounds)
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let png = NSMutableData()
        let destination = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        let identity = ScreenContextIdentity(applicationIdentifier: target.applicationIdentifier,
                                             windowIdentifier: target.windowIdentifier, displayIdentifier: 1, capturedAt: Date())
        return try PNGImageAttachment(data: png as Data, displayName: "Synthetic fixture", context: identity, capturedRegion: bounds)
    }

    func releaseCapture() { let gate = captureGate; captureGate = nil; gate?.resume() }

    /// Screen point for an image-pixel point (1 pixel = 1 point in this fixture).
    func point(_ pixel: CGPoint) -> CGPoint { CGPoint(x: (bounds?.minX ?? 0) + pixel.x, y: (bounds?.minY ?? 0) + pixel.y) }
}

/// Stands in for the interactive Wrong-target surface; records whether it was closed before any capture.
@MainActor
final class SelectionScript {
    final class Surface: GuideSelectionSurface {
        var closed = false
        func close() { closed = true }
    }
    var available = true
    private(set) var surface: Surface?
    private(set) var region: CGRect?
    private var onSelect: ((CGPoint) -> Void)?
    private var onCancel: (() -> Void)?

    func open(_ region: CGRect, _ select: @escaping (CGPoint) -> Void, _ cancel: @escaping () -> Void) -> GuideSelectionSurface? {
        guard available else { return nil }
        let surface = Surface(); self.surface = surface; self.region = region; onSelect = select; onCancel = cancel
        return surface
    }
    func select(_ point: CGPoint) { onSelect?(point) }
    func cancel() { onCancel?() }
}

/// Scripted answers to the session display-consent prompt.
@MainActor
final class ConsentScript {
    /// Display bound when Quick Ask has no originating window; nil means none is under the pointer.
    var display: WindowCaptureTarget?
    var answer = true
    var prompts = 0
}

/// Builds a `VisualGuideController` wired to fakes. Everything else is the production coordinator.
@MainActor
final class GuideHarness {
    let clock = FakeClock()
    let screen = FakeScreen()
    let agent = ScriptedAgent()
    let controller: VisualGuideController
    private(set) var agentLaunches = 0
    private(set) var shownTargets: [CGRect] = []
    private(set) var clearedTargets = 0
    private(set) var responses: [String] = []
    let defaults: UserDefaults
    let consent = ConsentScript()
    let selection = SelectionScript()
    private let suite = "ClickyGuideHarness." + UUID().uuidString

    /// With `localModel`, the controller runs the real on-device `LocalMLXAgent` over that scripted client instead.
    init(localModel: LocalInferenceClient? = nil) {
        defaults = UserDefaults(suiteName: suite)!
        let clock = clock, screen = screen, agent = agent
        var environment = GuideEnvironment.live
        environment.now = { clock.now }
        environment.uptime = { clock.uptime }
        environment.sleep = { try await clock.sleep($0) }
        environment.capture = { target, _, _, _ in try await screen.capture(target) }
        environment.focused = { _ in screen.focused }
        environment.waitForFocus = { _ in screen.focused }
        environment.bounds = { _ in screen.bounds }
        environment.related = { _ in screen.related }
        environment.outcomeMatches = { _, _ in screen.outcome }
        environment.annotationObstacles = { _, _ in [] }
        let consent = consent
        environment.displayTarget = { _ in consent.display }
        environment.requestDisplayConsent = { _, _ in consent.prompts += 1; return consent.answer }
        environment.pointer = { screen.pointer }
        environment.accessibilityTrusted = { false }
        environment.field = { _, _ in nil }
        environment.focusedElement = { _ in nil }
        environment.fieldFrame = { _, _ in nil }
        environment.frontmostProcess = { screen.frontmost }
        environment.makeAgent = { provider, _, _, _, _ in
            if let localModel, provider == .local { return LocalMLXAgent(contract: .guide, client: localModel) }
            return agent
        }
        environment.installEventSources = { _, _ in nil }
        environment.watchActivation = { _ in nil }
        let selection = selection
        environment.beginSelection = { region, select, cancel in selection.open(region, select, cancel) }
        controller = VisualGuideController(environment: environment)
        controller.defaults = defaults
        controller.provider = localModel == nil ? .claude : .local
        controller.executable = localModel == nil ? URL(fileURLWithPath: "/nonexistent/scripted-agent") : nil
        controller.sharingPreference = .always
        controller.onTarget = { [weak self] mark in self?.shownTargets.append(mark.target) }
        controller.onClearTarget = { [weak self] in self?.clearedTargets += 1 }
        controller.onResponse = { [weak self] text in self?.responses.append(text) }
    }

    deinit { UserDefaults().removePersistentDomain(forName: suite) }

    var turnCount: Int { get async { await agent.turns.count } }

    /// Waits (by yielding, never sleeping) until the scripted agent has an unanswered turn.
    func nextTurn(file: StaticString = #filePath, line: UInt = #line) async throws -> GuideAgentTurn {
        for _ in 0..<2_000 {
            if await agent.hasPendingTurn, let turn = await agent.lastTurn { return turn }
            await Task.yield()
        }
        XCTFail("No provider turn arrived", file: file, line: line)
        throw CancellationError()
    }

    func reply(_ make: (GuideAgentTurn) -> GuidePresentation) async throws {
        _ = try await nextTurn()
        await agent.reply(make)
        await settle()
    }

    /// Starts a task and answers planning turns until the first step is waiting.
    func startStep(action: GuideAction.Kind = .click, pixel: CGRect = CGRect(x: 10, y: 10, width: 12, height: 8)) async throws {
        try controller.ask("Open the fixture settings", target: screen.target)
        try await reply { _ in Self.contextRequest() }
        try await reply { Self.step($0, pixel: pixel, action: action) }
    }

    func click(at pixel: CGPoint, count: Int = 1, time: Double) {
        let point = screen.point(pixel)
        controller.observer.receiveMouse(GuideMouseEvent(point: point, button: 0, count: count, timestamp: time, pressed: true))
        controller.observer.receiveMouse(GuideMouseEvent(point: point, button: 0, count: count, timestamp: time + 0.05))
    }

    /// Click (or double-click), let the observer settle, and answer the verification with a verdict.
    func act(_ count: Int = 1, at pixel: CGPoint = CGPoint(x: 15, y: 14), time: Double,
             verdict state: GuidePresentation.OutcomeState = .confirmed) async throws {
        click(at: pixel, count: count, time: time)
        await clock.advance(0.5)
        try await reply { GuideHarness.verdict($0, matches: state == .confirmed, state: state) }
    }

    /// Two undecidable checks spend the step's one recovery look (answered with the same step), then two more
    /// leave the step uncertain.
    func reachUncertainty(time: Double) async throws {
        try await act(time: time, verdict: .unknown)
        await clock.advance(GuideHarnessTiming.settle)
        try await reply { GuideHarness.verdict($0, matches: false, state: .unknown) }
        guard controller.task?.phase != .uncertain else { return }
        try await reply { GuideHarness.step($0) }
        try await act(time: time + 5, verdict: .unknown)
        await clock.advance(GuideHarnessTiming.settle)
        try await reply { GuideHarness.verdict($0, matches: false, state: .unknown) }
    }

    static func contextRequest() -> GuidePresentation { GuidePresentation(kind: .context_request, text: "Need the window") }

    static func step(_ turn: GuideAgentTurn, pixel: CGRect = CGRect(x: 10, y: 10, width: 12, height: 8),
                     action: GuideAction.Kind = .click, text: String = "Click Settings") -> GuidePresentation {
        GuidePresentation(kind: .guide_step, text: text, captureID: turn.context?.captureID, target: GuideRect(pixel),
                          action: GuideAction(kind: action), outcome: GuideOutcome(description: "Settings panel is open"),
                          milestone: text, plan: [text], goalChecks: ["Settings panel is open"])
    }

    static func verdict(_ turn: GuideAgentTurn, matches: Bool, state: GuidePresentation.OutcomeState? = nil,
                        evidence: CGRect = CGRect(x: 30, y: 20, width: 20, height: 20)) -> GuidePresentation {
        GuidePresentation(kind: .verification_result, text: matches ? "Opened" : "Not opened", captureID: turn.context?.captureID,
                          matches: matches, evidence: "Panel title visible", evidenceTarget: GuideRect(evidence),
                          outcomeState: state ?? (matches ? .confirmed : .contradicted))
    }

    static func completed(_ turn: GuideAgentTurn, evidence: CGRect = CGRect(x: 30, y: 20, width: 20, height: 20)) -> GuidePresentation {
        GuidePresentation(kind: .task_completed, text: "Done", captureID: turn.context?.captureID,
                          matches: true, evidence: "Requested setting shown", evidenceTarget: GuideRect(evidence))
    }
}

/// Lets queued main-actor tasks run without real-time sleeps.
@MainActor func settle(_ rounds: Int = 200) async {
    for _ in 0..<rounds { await Task.yield() }
}
