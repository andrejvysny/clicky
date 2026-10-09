import ClickyCore
import Foundation

/// Offline replay of rendered fixture states through a real clean provider session, using the host's own messages
/// and task state. Measures locate hits and verdict distributions against the fixture oracle; prints counts only
/// unless --show-text is given for synthetic fixtures. Nothing is saved.
enum GuideReplay {
    struct Manifest: Decodable {
        struct State: Decodable { let png: String; let boxes: [String: [Double]] }
        struct Case: Decodable { let after: String; let truth: String }
        struct Step: Decodable { let from: String; let target: String; let gesture: String?; let cases: [Case] }
        struct GoalCase: Decodable { let state: String; let truth: String; var after: String { state } }
        let goal: String
        let states: [String: State]
        let steps: [Step]
        let goal_cases: [GoalCase]
    }

    static let target = WindowCaptureTarget(processIdentifier: 1, windowIdentifier: 1,
                                            applicationIdentifier: "fixture.replay", applicationName: "Fixture")

    struct Tally {
        var located = 0, hits = 0, steps = 0, turns = 0, corrections = 0
        /// truth -> observed outcome state -> count
        var verdicts: [String: [String: Int]] = [:]
        var falseConfirms = 0
        mutating func record(truth: String, observed: String, matches: Bool) {
            verdicts[truth, default: [:]][observed, default: 0] += 1
            if !truth.hasSuffix("confirmed"), matches || observed == "confirmed" { falseConfirms += 1 }
        }
    }

    static func run(_ options: [String]) async throws {
        let flags = Set(options.filter { $0.hasPrefix("--") && !$0.hasPrefix("--runs=") })
        let runs = options.first { $0.hasPrefix("--runs=") }.flatMap { Int($0.dropFirst(7)) } ?? 1
        let positional = options.filter { !$0.hasPrefix("--") }
        guard positional.count == 4, let provider = AgentProvider(rawValue: positional[0]), provider != .preview else {
            throw AskError.protocolFailure("Usage: clicky-guide replay claude|codex EXECUTABLE CLICKY_PROFILE_ROOT MANIFEST [--runs=N] [--show-text] [--recovery]")
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: positional[3])))
        let showText = flags.contains("--show-text")
        var tally = Tally()
        for run in 1...runs {
            print("run \(run)")
            let profile = try GuideAgentProfile(provider: provider, root: URL(fileURLWithPath: positional[2]), taskID: UUID())
            let session = GuideAgentSession(profile: profile, executable: URL(fileURLWithPath: positional[1]))
            do { try await replay(manifest, session: session, options: Options(showText: showText, recoveryProbe: flags.contains("--recovery")),
                                  tally: &tally) }
            catch { print("  run aborted: \(error.localizedDescription)") }
            await session.close()
        }
        print("summary located=\(tally.located)/\(tally.steps) targetHits=\(tally.hits) providerTurns=\(tally.turns) corrections=\(tally.corrections) falseConfirms=\(tally.falseConfirms)")
        for (truth, observed) in tally.verdicts.sorted(by: { $0.key < $1.key }) {
            print("  truth=\(truth) " + observed.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        }
    }

    struct Options { let showText: Bool; let recoveryProbe: Bool }

    private static func replay(_ manifest: Manifest, session: GuideAgentSession, options: Options, tally: inout Tally) async throws {
        let showText = options.showText
        var task = GuideTaskState(goal: manifest.goal)
        task.authorize(target)
        func send(_ turn: GuideAgentTurn) async throws -> GuidePresentation {
            tally.turns += 1
            let (result, corrected) = try await session.turnAllowingOneCorrection(turn)
            if corrected { tally.turns += 1; tally.corrections += 1; print("    corrected wrong purpose for \(turn.purpose.rawValue)") }
            guard turn.purpose.permits(result.kind) else { throw AskError.protocolFailure("\(result.kind.rawValue) not allowed for \(turn.purpose.rawValue)") }
            return result
        }
        // The app's first turn is text only; the provider then asks for the approved window.
        let planning = try await send(GuideAgentTurn(message: GuideHostMessages.userGoal(manifest.goal), purpose: .planning,
                                                     taskContext: GuideHostTaskContext(task)))
        print("  planning kind=\(planning.kind.rawValue)")
        for (index, step) in manifest.steps.enumerated() {
            tally.steps += 1
            task.beginRequest()
            let message = index == 0 ? GuideHostMessages.requestedContext(task)
                : GuideHostMessages.next(task, note: "Host verified the outcome.")
            let (image, context) = try capture(&task, manifest.states[step.from])
            let located = try await send(GuideAgentTurn(message: message, image: image, context: context, purpose: .continuation,
                                                        taskContext: GuideHostTaskContext(task)))
            guard located.kind == .guide_step, let outcome = located.outcome else {
                print("  step \(index + 1) kind=\(located.kind.rawValue) (expected guide_step)"); return
            }
            try task.show(located)
            tally.located += 1
            let hit = hits(located.target, box: manifest.states[step.from]?.boxes[step.target])
            if hit { tally.hits += 1 }
            print("  step \(index + 1) target=\(step.target) hit=\(hit) action=\(located.action?.kind.rawValue ?? "-")")
            if showText { print("    text: \(located.text)\n    outcome: \(outcome.description)\n    goalChecks: \(task.plan.goalChecks)") }
            // Negatives first, as in the app the provider may be asked before the user has acted.
            for item in step.cases.sorted(by: { ($0.truth == "confirmed" ? 1 : 0) < ($1.truth == "confirmed" ? 1 : 0) }) {
                var probe = task
                _ = probe.recordAttempt(); _ = probe.beginVerification()
                let (after, verifyContext) = try capture(&probe, manifest.states[item.after])
                let verdict = try await send(GuideAgentTurn(message: GuideHostMessages.verification(instruction: located.text, outcome: outcome.description),
                                                            image: after, context: verifyContext, purpose: .verification,
                                                            taskContext: GuideHostTaskContext(probe)))
                let observed = verdict.outcomeState?.rawValue ?? "none"
                tally.record(truth: item.truth, observed: observed, matches: verdict.matches == true)
                print("    case \(item.after) truth=\(item.truth) got=\(observed) matches=\(verdict.matches.map(String.init) ?? "-")")
                if showText { print("      evidence: \(verdict.evidence ?? "-")") }
            }
            // Recovery probe: the user's gesture produced no visible response (the from state again).
            if options.recoveryProbe {
                var probe = task
                _ = probe.recordAttempt(); _ = probe.beginVerification(); _ = probe.beginRecovery()
                let (still, stillContext) = try capture(&probe, manifest.states[step.from])
                let recovered = try await send(GuideAgentTurn(
                    message: GuideHostMessages.recovery(probe, evidence: "No change is visible after the action."),
                    image: still, context: stillContext, purpose: .continuation, taskContext: GuideHostTaskContext(probe)))
                let same = (recovered.milestone ?? recovered.text) == (located.milestone ?? located.text)
                print("    recovery kind=\(recovered.kind.rawValue) action=\(recovered.action?.kind.rawValue ?? "-") sameMilestone=\(same) "
                      + "expected=\(step.gesture ?? "-")")
                if showText { print("      text: \(recovered.text)") }
            }
            // Advance as a host-verified step on the true outcome state.
            guard let positive = step.cases.first(where: { $0.truth == "confirmed" }) else { return }
            _ = task.recordAttempt(); _ = task.beginVerification()
            let (_, confirmed) = try capture(&task, manifest.states[positive.after])
            _ = task.checked(matches: true, context: confirmed)
        }
        let finalState = manifest.steps.last.flatMap { $0.cases.first { $0.truth == "confirmed" }?.after }
        task.beginRequest()
        let (image, context) = try capture(&task, manifest.states[finalState ?? ""])
        let proposal = try await send(GuideAgentTurn(message: GuideHostMessages.next(task, note: "Host verified the outcome."), image: image,
                                                     context: context, purpose: .continuation, taskContext: GuideHostTaskContext(task)))
        print("  completion kind=\(proposal.kind.rawValue)")
        let checks = task.plan.goalChecks.isEmpty ? [task.goal] : task.plan.goalChecks
        if showText { print("    goalChecks: \(checks)") }
        for item in manifest.goal_cases {
            var probe = task
            guard probe.beginGoalVerification() else { print("  goal check could not start"); return }
            let (after, goalContext) = try capture(&probe, manifest.states[item.after])
            let verdict = try await send(GuideAgentTurn(message: GuideHostMessages.goalCheck(checks), image: after, context: goalContext,
                                                        purpose: .verification, taskContext: GuideHostTaskContext(probe)))
            let observed = verdict.outcomeState?.rawValue ?? "none"
            tally.record(truth: "goal_" + item.truth, observed: observed, matches: verdict.matches == true)
            print("    goal \(item.after) truth=\(item.truth) got=\(observed) matches=\(verdict.matches.map(String.init) ?? "-")")
            if showText { print("      evidence: \(verdict.evidence ?? "-")") }
        }
    }

    private static func capture(_ task: inout GuideTaskState, _ state: Manifest.State?) throws -> (PNGImageAttachment, GuideCaptureContext) {
        guard let state else { throw AskError.protocolFailure("Unknown replay state.") }
        let data = try Data(contentsOf: URL(fileURLWithPath: state.png))
        let size = try PNGImageAttachment(data: data)
        let image = try PNGImageAttachment(data: data, context: ScreenContextIdentity(applicationIdentifier: target.applicationIdentifier,
                                                                                    windowIdentifier: target.windowIdentifier,
                                                                                    displayIdentifier: 1, capturedAt: Date()),
                                           capturedRegion: CGRect(x: 0, y: 0, width: size.pixelWidth, height: size.pixelHeight))
        let lease = try task.beginCapture()
        let context = try GuideCaptureContext(image: image, target: target, task: task)
        guard task.accept(context, lease: lease) else { throw AskError.protocolFailure("Replay capture was not accepted.") }
        return (image, context)
    }

    /// The located target's centre lies on the oracle element (6 px slack for model rounding).
    private static func hits(_ located: GuideRect?, box: [Double]?) -> Bool {
        guard let rect = located?.rect, let box, box.count == 4, box[2] > 0, box[3] > 0 else { return false }
        return CGRect(x: box[0], y: box[1], width: box[2], height: box[3]).insetBy(dx: -6, dy: -6)
            .contains(CGPoint(x: rect.midX, y: rect.midY))
    }
}
