import Foundation
import Combine
#if canImport(ClickyCore)
import ClickyCore
#endif

/// Host-owned writing transactions beside the walkthrough coordinator: bind the original destination,
/// resolve a snippet or generate text in a clean provider process, then apply at most once after
/// revalidating the destination. Providers produce text only; they never choose targets or trigger edits.
@MainActor
final class WritingCoordinator: ObservableObject {
    enum Phase: Equatable { case idle, generating, review, applying, finished }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var proposal: WritingProposal?
    @Published private(set) var plan: WritingApplyPlan?
    @Published private(set) var source: ExactSource?
    @Published private(set) var target: TextTargetSnapshot?
    @Published private(set) var alternateTarget: TextTargetSnapshot?
    /// Why the bound destination can no longer receive this proposal; the preview stays for Copy.
    @Published private(set) var invalidation: String?
    @Published private(set) var notice: String?
    @Published private(set) var clarification: String?
    @Published private(set) var lastEdit: WritingAppliedEdit?
    /// The destination of `lastEdit`; kept even after Quick Ask rebinds so Restore targets the same control.
    private var editedTarget: TextTargetSnapshot?
    /// Editable preview; a change creates a new proposal revision when applied.
    @Published var previewText = ""
    /// Visible per-request opt-in for bounded text around the selection; resets after each request.
    @Published var includeSurrounding = false

    var provider = AgentProvider.preview
    var executable: URL?
    var profileRoot = FileManager.default.temporaryDirectory
    var definitions: () -> WritingDefinitions = { .empty }
    /// Orders Quick Ask out without restoring focus; the coordinator restores the bound control itself.
    var closeComposer: () -> Void = {}
    var showNotice: (String) -> Void = { _ in }
    /// Called after an application attempt ends, so held guide observation can reconcile.
    var onApplyFinished: () -> Void = {}

    private let environment: WritingEnvironment
    private var operation: UUID?
    private var generation: UInt64 = 0
    private var claims = WritingApplyClaims()
    private var work: Task<Void, Never>?
    private var agent: (any GuideAgentRunning)?
    private var request: (instruction: String, skill: CustomSkill?, intent: WritingIntent, effort: AskEffort)?
    private var stopRequested = false
    private var bindTask: Task<Void, Never>?
    private var bindGeneration: UInt64 = 0
    /// True when the binding offered two plausible destinations (VS Code editor and terminal) and focus is unknown.
    private var targetsAmbiguous = false
    /// The destination this operation was bound to. Later Quick Ask bindings change `target` for explicit use
    /// only; they never inherit this operation's automatic authority.
    private var operationTarget: TextTargetSnapshot?
    /// The destination `source` was read from; a rewrite replaces only that selection.
    private var sourceTargetToken: UUID?
    private var snippetRestriction = SnippetRestriction.any
    /// Visible attachments (pasted text, selection quote) sent with this request as reference material.
    private var reference: String?
    /// The last generation failed before a proposal existed; Retry repeats the same request explicitly.
    @Published private(set) var failed = false

    init(environment: WritingEnvironment) { self.environment = environment }

    var isBusy: Bool { phase == .generating || phase == .applying }
    var hasProposal: Bool { proposal != nil || clarification != nil }
    var canRetry: Bool { phase == .review && failed && request != nil }
    var canApply: Bool {
        guard phase == .review, invalidation == nil, let proposal else { return false }
        // An emptied preview would delete the selection; snippets may be whitespace but never empty.
        guard !previewText.isEmpty, proposal.intent == .snippet || previewText.contains(where: { !$0.isWhitespace }) else { return false }
        if case .review? = plan { return true }
        return plan == .automatic
    }
    /// A plain follow-up refines the reviewed draft or answers a clarification (snippets are literal and never refined).
    var canRefine: Bool {
        guard phase == .review, let request, request.intent != .snippet else { return false }
        return proposal != nil || clarification != nil
    }
    var replacesSelection: Bool { if case .review(true)? = plan { return true }; return false }

    // MARK: Binding

    /// Called before Quick Ask takes focus. A retained proposal keeps its text but a new destination needs
    /// an explicit Insert/Replace: automatic application never moves to a different target.
    func bind(processIdentifier: Int32?) async {
        beginBinding(processIdentifier: processIdentifier)
        await bindTask?.value
    }

    /// Clears the previous destination synchronously, so a fast submit can never reuse it; requests started
    /// before the capture finishes wait for it.
    func beginBinding(processIdentifier: Int32?) {
        guard phase != .applying else { return }
        target = nil; alternateTarget = nil; targetsAmbiguous = false
        bindGeneration &+= 1
        let expected = bindGeneration
        isBinding = true
        bindTask = Task { [weak self] in
            guard let self else { return }
            let targets = await environment.captureTargets(processIdentifier)
            guard expected == bindGeneration else { return }
            adopt(targets)
            isBinding = false
        }
    }

    /// True until the latest binding resolved; routing a submission must wait for it.
    @Published private(set) var isBinding = false

    /// Runs `action` once the binding that is current now has resolved.
    func whenBound(_ action: @escaping @MainActor () -> Void) {
        let binding = bindTask
        Task { @MainActor in
            await binding?.value
            action()
        }
    }

    private func adopt(_ targets: WritingTargets) {
        // A request waiting for this binding is .generating; only an in-flight write keeps its destination.
        guard phase != .applying else { return }
        target = targets.primary; alternateTarget = targets.alternate; targetsAmbiguous = targets.ambiguous
        notice = nil
        if proposal != nil { replan(autoApply: false) }
    }

    /// Swaps between VS Code's document editor and its integrated terminal; the user's explicit choice.
    func switchDestination() {
        guard !isBusy, let alternateTarget else { return }
        self.alternateTarget = target; target = alternateTarget
        // Choosing explicitly resolves an ambiguous binding; the result still needs an explicit Insert.
        targetsAmbiguous = false
        if proposal != nil { replan(autoApply: false) }
    }

    // MARK: Requests

    /// Starts a writing route. Returns false for routes the conversation path handles.
    @discardableResult
    func start(_ route: QuickAskRoute, effort: AskEffort = .low, reference: String? = nil) -> Bool {
        switch route {
        case .snippet(let snippet):
            beginOperation()
            let expected = generation
            phase = .generating
            work = Task { [weak self] in
                await self?.bindTask?.value
                guard let self, expected == generation else { return }
                phase = .idle; insertSnippet(snippet)
            }
            return true
        case .write(let instruction, let skill):
            beginOperation(); self.reference = reference
            generate(instruction: instruction, skill: skill, intent: .draft, effort: effort); return true
        case .rewrite(let instruction, let skill):
            beginOperation(); self.reference = reference
            generate(instruction: instruction, skill: skill, intent: .rewrite, effort: effort); return true
        case .chat, .localError: return false
        }
    }

    private func beginOperation() {
        cancelWork(); closeAgent()
        operation = UUID(); proposal = nil; plan = nil; source = nil; invalidation = nil
        notice = nil; clarification = nil; previewText = ""; stopRequested = false; failed = false
        operationTarget = nil; sourceTargetToken = nil; snippetRestriction = .any; reference = nil
    }

    private func insertSnippet(_ snippet: SavedSnippet) {
        guard let operation else { return }
        snippetRestriction = snippet.restriction
        preferTarget(for: snippet.restriction)
        operationTarget = target
        let resolved = WritingProposal(operationID: operation, revision: 1, intent: .snippet, text: snippet.body,
                                       provenance: .snippet(id: snippet.id, revision: snippet.revision))
        present(resolved, autoApply: true)
    }

    /// Delivers finalized dictation to the destination bound when recording started. With `autoApply` it is
    /// inserted only through the same plan as Write (unchanged empty caret, matching process); otherwise, or
    /// when anything changed, it stays an editable preview.
    @discardableResult
    func startDictation(_ text: String, session: UUID, autoApply: Bool) -> Bool {
        guard phase != .applying else { return false }
        beginOperation()
        let expected = generation
        phase = .generating
        work = Task { [weak self] in
            await self?.bindTask?.value
            guard let self, expected == generation, let operation else { return }
            phase = .idle
            operationTarget = target
            let proposal = WritingProposal(operationID: operation, revision: 1, intent: .dictation, text: text,
                                           provenance: .dictation(session: session))
            present(proposal, autoApply: autoApply)
        }
        return true
    }

    private func preferTarget(for restriction: SnippetRestriction) {
        let wantsTerminal = restriction == .terminalOnly
        guard restriction != .any, (target?.kind == .terminal) != wantsTerminal,
              let alternateTarget, (alternateTarget.kind == .terminal) == wantsTerminal else { return }
        self.alternateTarget = target; target = alternateTarget
    }

    private func generate(instruction: String, skill: CustomSkill?, intent: WritingIntent, effort: AskEffort,
                          previousDraft: String? = nil, refinement: String? = nil) {
        guard let operation else { return }
        let expected = generation
        let surroundingRequested = includeSurrounding
        includeSurrounding = false
        request = (instruction, skill, intent, effort)
        stopRequested = false; invalidation = nil; failed = false
        phase = .generating
        let binding = bindTask
        work = Task { [weak self] in
            await binding?.value
            guard let self, expected == generation else { return }
            // Pinned once, when this operation's own binding resolves; a refinement keeps the original pin.
            if operationTarget == nil { operationTarget = target }
            do {
                let reply = try await produce(instruction: instruction, skill: skill, intent: intent, effort: effort,
                                              surrounding: surroundingRequested, previousDraft: previousDraft, refinement: refinement)
                guard expected == generation, self.operation == operation else { return }
                switch reply {
                case .clarification(let text): clarification = text; phase = .review
                case .draft(let text, let subject):
                    let revision = (proposal?.revision ?? 0) + 1
                    let provenance: WritingProvenance = provider == .preview ? .preview
                        : .generated(provider: provider, skillID: skill?.id, skillRevision: skill?.revision)
                    present(WritingProposal(operationID: operation, revision: revision, intent: intent, text: text,
                                            subject: subject, provenance: provenance), autoApply: previousDraft == nil)
                }
            } catch {
                guard expected == generation else { return }
                // Stays visible with Retry; the submitted request is kept, never silently dropped.
                phase = .review; failed = proposal == nil
                notice = (error as? LocalizedError)?.errorDescription ?? "The writing request failed. Retry explicitly."
                closeAgent()
            }
            work = nil
        }
    }

    private func produce(instruction: String, skill: CustomSkill?, intent: WritingIntent, effort: AskEffort, surrounding: Bool,
                         previousDraft: String?, refinement: String?) async throws -> WritingReply {
        let bound = operationTarget
        if intent == .rewrite, source == nil {
            guard let bound, bound.mayHaveSelection else { throw WritingRequestError.noSelection }
            source = try await environment.readSource(bound)
            sourceTargetToken = bound.token
        }
        if provider == .preview {
            let text = intent == .rewrite ? source?.text ?? "" : "Preview draft (no AI): " + instruction
            return .draft(text: text, subject: nil)
        }
        if provider.needsExecutable, executable == nil { throw AskError.missingExecutable(provider.displayName) }
        let context = surrounding ? await bound.asyncMap(environment.readSurrounding) : nil
        let payload = WritingHostPayload(operation: intent, skill: skill.map { .init(name: $0.name, instructions: $0.instructions) },
                                         source: source?.text, reference: reference, surrounding: context ?? nil,
                                         destination: WritingHostPayload.destination(for: bound?.kind),
                                         previousDraft: previousDraft, refinement: refinement)
        if agent == nil { agent = try environment.makeAgent(provider, executable, profileRoot, effort) }
        guard let agent else { throw AskError.incompleteTurn }
        let turn = GuideAgentTurn(message: refinement ?? instruction, purpose: .writing, effort: effort, writing: payload)
        return try WritingReply(try await agent.turnAllowingOneCorrection(turn).0)
    }

    private func present(_ proposal: WritingProposal, autoApply: Bool) {
        self.proposal = proposal; previewText = proposal.text; clarification = nil
        phase = .review
        replan(autoApply: autoApply)
        guard plan == .automatic else { return }
        // A deliberate switch to another app during generation keeps the result as a preview.
        if let target, environment.frontmostProcess() != target.processIdentifier {
            invalidation = WritingNotAppliedReason.focusChanged.message; return
        }
        apply()
    }

    /// Decides how the current proposal may reach the current destination. Automatic application requires the
    /// operation's own, unambiguous destination; a rewrite only ever replaces the selection it was made from.
    private func replan(autoApply: Bool) {
        guard let proposal else { return }
        var decided = WritingApplyPlan.decide(intent: proposal.intent, target: target, text: previewText, provenance: proposal.provenance)
        if case .previewOnly = decided {} else if let blocked = restrictionBlock(proposal) {
            decided = .previewOnly(blocked)
        }
        let ownDestination = target != nil && target?.token == operationTarget?.token
        // A restricted snippet names its destination kind itself, which resolves the editor/terminal ambiguity.
        let ambiguous = targetsAmbiguous && !(proposal.intent == .snippet && snippetRestriction != .any)
        plan = autoApply && ownDestination && !ambiguous ? decided : Self.explicitOnly(decided)
        if case .previewOnly(let reason)? = plan { invalidation = reason.message } else { invalidation = nil }
    }

    private func restrictionBlock(_ proposal: WritingProposal) -> WritingBlockReason? {
        if proposal.intent == .rewrite, target?.token != sourceTargetToken { return .rewriteTargetChanged }
        guard proposal.intent == .snippet else { return nil }
        let isTerminal = target?.kind == .terminal
        if snippetRestriction == .terminalOnly, !isTerminal { return .snippetTerminalOnly }
        if snippetRestriction == .editorsOnly, isTerminal { return .snippetEditorsOnly }
        return nil
    }

    // MARK: Application

    /// Applies the current preview once: automatically for Write/snippets, or after an explicit Replace/Insert.
    func apply() {
        guard canApply, let proposal, let target, let operation else { return }
        var claimed = proposal
        if previewText != proposal.text { claimed = proposal.editing(previewText); self.proposal = claimed }
        guard claims.claim(operationID: operation, revision: claimed.revision) else { return }
        let expected = generation
        let range = target.kind == .terminal ? UTF16Range.caret(0)! : target.selection
        stopRequested = false
        phase = .applying
        let authorized = authorization(expected: expected, operation: operation)
        work = Task { [weak self] in
            guard let self else { return }
            let outcome = await performApply(claimed, target: target, range: range, authorized: authorized)
            guard expected == generation else { onApplyFinished(); return }
            finish(outcome, target: target)
            work = nil
        }
    }

    /// Valid while this operation is current and nobody pressed Stop, revoked or replaced it.
    private func authorization(expected: UInt64, operation: UUID) -> WritingAuthorization {
        { [weak self] in
            guard let self else { return false }
            return !stopRequested && generation == expected && self.operation == operation
        }
    }

    /// Quick Ask keeps keyboard ownership (and its Stop control) until the submitting Return is fully released,
    /// so neither the key-up nor auto-repeat can reach the destination after focus returns there.
    private func handOffKeyboard(_ authorized: WritingAuthorization) async -> WritingNotAppliedReason? {
        guard await environment.waitForSubmitKeyRelease() else { return .keyStillHeld }
        guard authorized() else { return .canceled }
        closeComposer()
        return nil
    }

    private func performApply(_ proposal: WritingProposal, target: TextTargetSnapshot, range: UTF16Range,
                              authorized: @escaping WritingAuthorization) async -> WritingApplyOutcome {
        if let reason = await handOffKeyboard(authorized) { return .notApplied(reason) }
        guard definitionStillCurrent(proposal.provenance) else { return .notApplied(.definitionChanged) }
        var expectedSource = ""
        if !range.isEmpty, target.kind != .terminal, !target.pasteOnly {
            if let source, source.range == range, sourceTargetToken == target.token { expectedSource = source.text }
            else if proposal.intent == .rewrite { return .notApplied(.sourceChanged) }
            else {
                // An explicit Replace selection of a draft/snippet replaces whatever is selected now, read exactly.
                guard let current = try? await environment.readSource(target) else { return .notApplied(.sourceChanged) }
                expectedSource = current.text
            }
        }
        guard authorized() else { return .notApplied(.canceled) }
        guard await environment.restoreFocus(target) else { return .notApplied(.focusChanged) }
        if let change = target.change(comparedWith: await environment.liveTarget(target)) { return .notApplied(change) }
        guard authorized() else { return .notApplied(.canceled) }
        guard definitionStillCurrent(proposal.provenance) else { return .notApplied(.definitionChanged) }
        return await environment.apply(target, range, proposal.text, expectedSource, authorized)
    }

    private func definitionStillCurrent(_ provenance: WritingProvenance) -> Bool {
        switch provenance {
        case .snippet(let id, let revision):
            return definitions().snippets.contains { $0.id == id && $0.revision == revision && $0.enabled }
        case .generated(_, let skillID?, let revision):
            let skills = SlashCommandRegistry.builtInSkills + definitions().skills
            return skills.contains { $0.id == skillID && $0.revision == revision && $0.enabled }
        default: return true
        }
    }

    private func finish(_ outcome: WritingApplyOutcome, target: TextTargetSnapshot) {
        let terminal = target.kind == .terminal
        switch outcome {
        case .applied(let edit):
            lastEdit = terminal ? nil : edit; editedTarget = terminal ? nil : target; phase = .finished
            notice = terminal ? "Inserted — not executed" : (replacesSelection ? "Replaced selection" : "Inserted")
        case .acknowledged:
            // Delivered without read-back: the VS Code terminal API, or a plain paste at an app's cursor.
            lastEdit = nil; phase = .finished
            if target.pasteOnly {
                notice = terminal ? "Pasted at the prompt — not executed"
                    : proposal?.intent == .rewrite ? "Replaced the selection — ⌘Z in the app undoes it" : "Pasted at the cursor"
            }
            else { notice = "Sent to the terminal — not executed, not verified" }
        case .notApplied(let reason):
            phase = .review; invalidation = reason.message; notice = "Not inserted: " + reason.message
        case .deliveryUnknown:
            phase = .review; invalidation = "Delivery unconfirmed"
            notice = "Delivery unconfirmed — check the field. Clicky will not retry; the clipboard still holds this text."
        }
        if let notice { showNotice(notice) }
        onApplyFinished()
    }

    /// Guarded inverse of Clicky's own last edit, through the same key-release and focus gates as applying.
    func restoreOriginal() {
        guard phase == .finished, let edit = lastEdit, let target = editedTarget, edit.targetToken == target.token else { return }
        guard let operation else { return }
        lastEdit = nil
        stopRequested = false
        phase = .applying
        let expected = generation
        let authorized = authorization(expected: expected, operation: operation)
        work = Task { [weak self] in
            guard let self else { return }
            var restored = false
            let handOff = await handOffKeyboard(authorized)
            if handOff == nil, await environment.restoreFocus(target), authorized() {
                restored = await environment.restore(target, edit, authorized)
            }
            guard expected == generation else { onApplyFinished(); return }
            phase = .finished
            if restored { notice = "Restored the original text" }
            else if handOff == .canceled || stopRequested { notice = "Stopped"; lastEdit = edit }
            else { notice = "Not restored: the field changed or lost focus after Clicky edited it." }
            showNotice(notice!)
            onApplyFinished()
            work = nil
        }
    }

    // MARK: Preview controls

    func refine(_ instruction: String) {
        guard !isBusy, let request, proposal != nil || clarification != nil, request.intent != .snippet else { return }
        if proposal == nil {
            // Answering a clarification continues the same request in the same provider conversation.
            generate(instruction: request.instruction, skill: request.skill, intent: request.intent, effort: request.effort,
                     refinement: instruction)
            return
        }
        if phase == .finished {
            // A refinement after insertion is a new transaction against freshly re-read metadata.
            operation = UUID(); lastEdit = nil
            Task { [weak self] in
                guard let self, let target else { return }
                let live = await environment.liveTarget(target)
                self.target = live; self.operationTarget = live
                self.invalidation = live == nil ? WritingNotAppliedReason.targetUnavailable.message : nil
                generate(instruction: request.instruction, skill: request.skill, intent: request.intent, effort: request.effort,
                         previousDraft: previewText, refinement: instruction)
            }
            return
        }
        generate(instruction: request.instruction, skill: request.skill, intent: request.intent, effort: request.effort,
                 previousDraft: previewText, refinement: instruction)
    }

    /// Repeats a request whose generation failed before any proposal, with the same instruction and inputs.
    func retry() {
        guard canRetry, let request else { return }
        generate(instruction: request.instruction, skill: request.skill, intent: request.intent, effort: request.effort)
    }

    /// Copies text the caller already holds (voice "Copy original") through the same clipboard path.
    func copyText(_ text: String) { environment.copy(text) }

    func copyProposal() {
        let text = previewText.isEmpty ? (clarification ?? "") : previewText
        guard !text.isEmpty else { return }
        environment.copy(text); notice = "Copied"
    }

    /// Stop invalidates pending generation and application authority; an in-flight external write is not
    /// interrupted, but nothing new starts after it.
    func stop() {
        guard isBusy else { return }
        stopRequested = true
        if phase == .generating {
            cancelWork(); closeAgent()
            phase = proposal == nil ? .idle : .review; notice = "Stopped"
        }
    }

    func discard() {
        // An external write in flight cannot be interrupted; its outcome must still be recorded.
        guard phase != .applying else { return }
        cancelWork(); closeAgent()
        operation = nil; proposal = nil; plan = nil; source = nil; previewText = ""; clarification = nil
        invalidation = nil; notice = nil; lastEdit = nil; request = nil; phase = .idle; failed = false
        operationTarget = nil; sourceTargetToken = nil; snippetRestriction = .any; reference = nil
    }

    /// Provider/executable changes and app shutdown end the clean writing process and revoke any write
    /// that has not committed yet.
    func reset() { stopRequested = true; discard() }

    private func cancelWork() { generation &+= 1; work?.cancel(); work = nil }

    private func closeAgent() {
        guard let agent else { return }
        self.agent = nil
        Task { await agent.close() }
    }

    private static func explicitOnly(_ plan: WritingApplyPlan) -> WritingApplyPlan {
        plan == .automatic ? .review(replacesSelection: false) : plan
    }
}


private extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async -> T) async -> T? {
        guard let value = self else { return nil }
        return await transform(value)
    }
}
