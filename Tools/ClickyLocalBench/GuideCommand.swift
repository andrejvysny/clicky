#if canImport(CoreGraphics) && canImport(ImageIO) && canImport(CoreText)
import ClickyCore
import CoreGraphics
import Foundation

/// `guide` subcommand: the app's `LocalMLXAgent` (same prompt, normalization and one-repair policy) against the
/// worker, on seeded synthetic screens. It measures what the assistant path needs beyond raw grounding: an
/// accepted presentation of an allowed kind, repairs used, target hit/IoU and latency. Synthetic buttons are not
/// evidence for real applications; nothing is written except the optional --out summary.
enum GuideCommand {
    static let valued: Set<String> = ["model", "count", "seed", "priority", "worker", "models-root", "out"]

    struct CaseResult: Encodable {
        let id: String
        let request: String
        var accepted = false
        var kind: String?
        var modelCalls = 0
        var targetHit = false
        var intersectionOverUnion = 0.0
        var milliseconds = 0.0
        var error: String?
        /// Raw model text per call; synthetic screens only, so nothing personal is recorded.
        var outputs: [String] = []
    }

    struct Summary: Encodable {
        let model: String
        let promptVersion: String
        let cases: Int
        let acceptedRate: Double
        let repairRate: Double
        let targetHitRate: Double
        let meanIntersectionOverUnion: Double
        let meanMilliseconds: Double
        let results: [CaseResult]
    }

    /// Counts model calls so repairs are visible; the agent itself never reports them.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var values: [String] = []
        func record(_ output: String) { lock.lock(); values.append(output); lock.unlock() }
        func take() -> [String] { lock.lock(); defer { values = []; lock.unlock() }; return values }
    }

    static func run(_ arguments: [String]) async throws {
        let options = try Options(arguments, valued: valued)
        let store = LocalModelStore(root: BenchPaths.modelsRoot(options))
        let model = try SpeechCommand.installed(options.one("model"), "--model", .vision, store)
        let count = try options.integer("count", default: 5, minimum: 1) ?? 5
        let seed = UInt64(try options.integer("seed", default: 42) ?? 42)
        let executable = try BenchRuntime.workerURL(options)
        let started = try await BenchRuntime.start(.inference, executable: executable, priority: try SpeechCommand.parsePriority(options))
        defer { started.connection.shutdown() }
        _ = try await BenchRuntime.load(started.connection, model: model.model.reference)
        let connection = started.connection, identifier = model.model.reference.identifier, counter = Counter()
        let client: LocalInferenceClient = { request in
            let command = LocalWorkerCommand.generate(request: UUID(), modelIdentifier: identifier, messages: request.messages,
                                                      parameters: request.parameters, hasImage: request.image != nil)
            var final: String?
            for try await event in connection.request(command, payload: request.image ?? Data()) {
                if case .completed(_, _, let text, _) = event { final = text }
            }
            guard let final else { throw CLIError("The worker ended a request without a result.") }
            counter.record(final)
            return final
        }
        var results: [CaseResult] = []
        for index in 0..<count {
            var generator = SyntheticVision.Generator(state: seed &+ UInt64(index) &* 7919)
            let buttons = SyntheticVision.layout(&generator)
            let target = buttons[generator.int(0...(buttons.count - 1))]
            let png = try SyntheticVision.render(buttons)
            for (suffix, message) in [("point", "Where is the \(target.label) button?"), ("step", "Help me press \(target.label).")] {
                var result = CaseResult(id: "synthetic-\(seed)-\(index)-\(suffix)", request: message)
                let agent = LocalMLXAgent(contract: .guide, client: client)
                let clock = ContinuousClock(), start = clock.now
                do {
                    let (image, context) = try capture(png)
                    // Same order as the app: the goal goes first as text; the screen follows a context_request.
                    var task = GuideTaskState(goal: message)
                    task.authorize(WindowCaptureTarget(processIdentifier: 1, windowIdentifier: 1, applicationIdentifier: "bench.synthetic", applicationName: "Synthetic"))
                    var value = try await agent.turn(GuideAgentTurn(message: GuideHostMessages.userGoal(message), taskContext: GuideHostTaskContext(task)))
                    if value.kind == .context_request {
                        value = try await agent.turn(GuideAgentTurn(message: GuideHostMessages.requestedContext(task), image: image, context: context,
                                                                    purpose: .continuation, taskContext: GuideHostTaskContext(task)))
                    }
                    result.accepted = true; result.kind = value.kind.rawValue
                    if let box = value.target?.rect { score(box, against: target.rect, into: &result) }
                } catch { result.error = String(describing: error) }
                let elapsed = clock.now - start
                result.milliseconds = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
                result.outputs = counter.take(); result.modelCalls = result.outputs.count
                await agent.close()
                FileHandle.standardError.write(Data(".".utf8))
                results.append(result)
            }
        }
        FileHandle.standardError.write(Data("\n".utf8))
        let total = Double(results.count)
        let summary = Summary(model: model.entry.id, promptVersion: LocalPrompt.guideVersion, cases: results.count,
                              acceptedRate: Double(results.filter(\.accepted).count) / total,
                              repairRate: Double(results.filter { $0.modelCalls > 1 }.count) / total,
                              targetHitRate: Double(results.filter(\.targetHit).count) / total,
                              meanIntersectionOverUnion: results.map(\.intersectionOverUnion).reduce(0, +) / total,
                              meanMilliseconds: results.map(\.milliseconds).reduce(0, +) / total, results: results)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(summary)
        if let out = options.one("out") { try data.write(to: URL(fileURLWithPath: (out as NSString).expandingTildeInPath)) }
        print(String(format: "guide %@: accepted %.2f, repairs %.2f, target hit %.2f, IoU %.2f, %.0f ms/case",
                     summary.model, summary.acceptedRate, summary.repairRate, summary.targetHitRate,
                     summary.meanIntersectionOverUnion, summary.meanMilliseconds))
    }

    /// A capture context equivalent to an approved window capture of the synthetic screen.
    static func capture(_ png: Data) throws -> (PNGImageAttachment, GuideCaptureContext) {
        let region = CGRect(x: 0, y: 0, width: SyntheticVision.width, height: SyntheticVision.height)
        let image = try PNGImageAttachment(data: png, displayName: "synthetic",
            context: ScreenContextIdentity(applicationIdentifier: "bench.synthetic", windowIdentifier: 1, displayIdentifier: 1, capturedAt: Date()),
            capturedRegion: region)
        let window = WindowCaptureTarget(processIdentifier: 1, windowIdentifier: 1, applicationIdentifier: "bench.synthetic", applicationName: "Synthetic")
        var task = GuideTaskState(goal: "Benchmark"); task.authorize(window)
        return (image, try GuideCaptureContext(image: image, target: window, task: task))
    }

    static func score(_ predicted: CGRect, against expected: CGRect, into result: inout CaseResult) {
        result.targetHit = expected.contains(CGPoint(x: predicted.midX, y: predicted.midY))
        let intersection = predicted.intersection(expected)
        let overlap = intersection.isNull ? 0 : intersection.width * intersection.height
        let union = predicted.width * predicted.height + expected.width * expected.height - overlap
        result.intersectionOverUnion = union > 0 ? overlap / union : 0
    }
}
#endif
