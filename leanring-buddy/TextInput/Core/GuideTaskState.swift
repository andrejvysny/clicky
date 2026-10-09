import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

nonisolated public struct GuideCaptureContext: Codable, Equatable, Sendable {
    public let captureID: UUID
    public let capturedAt: Date
    public let taskID: UUID
    public let stepRevision: UInt64
    public let contextRevision: UInt64
    public let grantID: UUID
    public let processIdentifier: Int32
    public let applicationIdentifier: String
    public let windowIdentifier: UInt32
    public let displayIdentifier: UInt32
    public let region: GuideRect
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let includedWindows: [WindowCaptureTarget]
    public let pixelToDesktop: GuidePixelTransform

    public init(image: PNGImageAttachment, target: WindowCaptureTarget, task: GuideTaskState,
                relatedTargets: [WindowCaptureTarget] = []) throws {
        guard let grant = task.grant, let identity = image.context, let region = image.capturedRegion,
              identity.windowIdentifier == target.windowIdentifier, identity.applicationIdentifier == target.applicationIdentifier,
              grant.targets.contains(target), relatedTargets.allSatisfy({ grant.targets.contains($0) }) else { throw AttachmentError.targetChanged }
        captureID = UUID(); capturedAt = identity.capturedAt; taskID = task.identifier
        stepRevision = task.stepRevision; contextRevision = task.contextRevision; grantID = grant.identifier
        processIdentifier = target.processIdentifier; applicationIdentifier = target.applicationIdentifier
        windowIdentifier = target.windowIdentifier; displayIdentifier = identity.displayIdentifier
        self.region = GuideRect(region); pixelWidth = image.pixelWidth; pixelHeight = image.pixelHeight
        includedWindows = [target] + relatedTargets
        pixelToDesktop = GuidePixelTransform(scaleX: region.width / Double(image.pixelWidth),
                                            scaleY: region.height / Double(image.pixelHeight), translateX: region.minX, translateY: region.minY)
    }

    public func screenRect(_ target: GuideRect) -> CGRect? {
        GuidePixelMapping.screenRect(target, pixelWidth: pixelWidth, pixelHeight: pixelHeight, region: region.rect)
    }
}

nonisolated public enum GuidePixelMapping {
    /// Outcome evidence must be wholly visible; never clip away part of a claimed result.
    public static func evidenceComparisonRect(_ target: GuideRect, pixelWidth: Int, pixelHeight: Int) -> CGRect? {
        guard target.isValid, pixelWidth > 0, pixelHeight > 0 else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
        guard bounds.contains(target.rect) else { return nil }
        return target.rect.integral.intersection(bounds)
    }

    /// Use the same clipped, integral pixels for both comparisons, including marks at a screen edge.
    public static func comparisonRect(_ target: GuideRect, pixelWidth: Int, pixelHeight: Int) -> CGRect? {
        let bounds = CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
        guard screenRect(target, pixelWidth: pixelWidth, pixelHeight: pixelHeight, region: bounds) != nil else { return nil }
        let rect = target.rect.intersection(bounds).integral.intersection(bounds)
        return rect.isNull || rect.isEmpty ? nil : rect
    }

    /// Models overshoot edge controls by a few pixels, so targets may exceed the image by 2% and are clamped;
    /// a target outside that slack, or with nothing left inside the image, is rejected.
    public static func screenRect(_ target: GuideRect, pixelWidth: Int, pixelHeight: Int, region: CGRect) -> CGRect? {
        guard target.isValid, pixelWidth > 0, pixelHeight > 0 else { return nil }
        let width = Double(pixelWidth), height = Double(pixelHeight)
        let slackX = width * 0.02, slackY = height * 0.02
        let rect = target.rect
        guard rect.minX >= -slackX, rect.minY >= -slackY, rect.maxX <= width + slackX, rect.maxY <= height + slackY else { return nil }
        let clamped = rect.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !clamped.isNull, clamped.width > 0, clamped.height > 0 else { return nil }
        let scaleX = region.width / width, scaleY = region.height / height
        return CGRect(x: region.minX + clamped.minX * scaleX, y: region.minY + clamped.minY * scaleY,
                      width: clamped.width * scaleX, height: clamped.height * scaleY)
    }
}

nonisolated public struct GuidePixelTransform: Codable, Equatable, Sendable {
    public let scaleX: Double
    public let scaleY: Double
    public let translateX: Double
    public let translateY: Double
}

nonisolated public struct GuideSharingGrant: Equatable, Sendable {
    public let identifier = UUID()
    public var targets: [WindowCaptureTarget]
    public var paused = false
    public init(target: WindowCaptureTarget) { targets = [target] }
}

/// Execution-ledger provenance. `satisfied` means fresh state showed the milestone already holds;
/// it never claims the user performed an unseen action.
nonisolated public enum GuideCompletion: String, Codable, Sendable { case verified, manuallyAcknowledged, satisfied }
nonisolated public struct GuideMilestone: Encodable, Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let instruction: String
    public let completion: GuideCompletion
    public var intent: String? = nil
}

/// Automatic recovery for one semantic step, reset only when the step advances, so noise, duplicate
/// callbacks and re-located targets cannot reset the bounds indefinitely. Explicit user actions are not budgeted.
nonisolated public struct GuideStepBudget: Equatable, Sendable {
    /// Automatic verification episodes (initial check plus one fresh recheck each) started by attempts or AX evidence.
    public static let episodes = 3
    /// Automatic re-grounding after genuine target movement or replacement.
    public static let relocations = 2
    /// Automatic re-planning after a contradicted outcome (detour or user ahead).
    public static let recoveries = 1
    public private(set) var episodesUsed = 0
    public private(set) var relocationsUsed = 0
    public private(set) var recoveriesUsed = 0
    mutating func spendEpisode() -> Bool { guard episodesUsed < Self.episodes else { return false }; episodesUsed += 1; return true }
    mutating func spendRelocation() -> Bool { guard relocationsUsed < Self.relocations else { return false }; relocationsUsed += 1; return true }
    mutating func spendRecovery() -> Bool { guard recoveriesUsed < Self.recoveries else { return false }; recoveriesUsed += 1; return true }
}

nonisolated public struct GuideTaskState: Sendable {
    public enum Phase: String, Sendable { case locating, waiting, verifying, uncertain, paused, completed, canceled }
    public let identifier = UUID()
    public let goal: String
    public private(set) var phase: Phase = .locating
    public private(set) var step: GuidePresentation?
    public private(set) var stepRevision: UInt64 = 0
    public private(set) var contextRevision: UInt64 = 0
    public private(set) var generation: UInt64 = 0
    public private(set) var grant: GuideSharingGrant?
    public private(set) var capture: GuideCaptureContext?
    public private(set) var milestones: [GuideMilestone] = []
    public private(set) var contextRequests = 0
    public private(set) var verificationChecks = 0
    public private(set) var actionDetected = false
    /// Increments once per accepted attempt; an attempt is never success by itself.
    public private(set) var attemptEpoch: UInt64 = 0
    public private(set) var budget = GuideStepBudget()
    /// One automatic continuation after the stored goal checks fail final verification.
    public private(set) var goalRecoveriesUsed = 0
    public private(set) var plan = GuidePlan()
    /// Every reason guidance is held. Only temporary reasons may clear without a deliberate user action.
    public private(set) var interruptions: Set<GuideInterruption> = []
    private var captureLease: UUID?
    private var lastVerificationCaptureID: UUID?

    public init(goal: String) { self.goal = goal }
    public mutating func authorize(_ target: WindowCaptureTarget, replace: Bool = false) {
        invalidate()
        if replace || grant == nil { grant = GuideSharingGrant(target: target) }
        else if grant?.targets.contains(target) == false { grant?.targets.append(target) }
        grant?.paused = false
    }
    public mutating func beginRequest() { contextRequests = 0 }
    public mutating func authorizeRelated(_ target: WindowCaptureTarget) {
        guard grant?.targets.contains(target) == false else { return }
        grant?.targets.append(target)
    }
    public mutating func requestContext() throws {
        guard contextRequests < 2 else { phase = .uncertain; throw AskError.protocolFailure("Context limit reached. Choose Retry or manual Next.") }
        contextRequests += 1
    }
    public mutating func beginCapture() throws -> UUID {
        guard let grant, !grant.paused, phase != .canceled, phase != .completed, captureLease == nil else { throw AttachmentError.noTarget }
        let lease = UUID(); captureLease = lease; return lease
    }
    public mutating func accept(_ context: GuideCaptureContext, lease: UUID) -> Bool {
        guard captureLease == lease, isCurrent(context), grant?.paused == false else { return false }
        captureLease = nil; capture = context; return true
    }
    public func isCurrent(_ context: GuideCaptureContext) -> Bool {
        context.taskID == identifier && context.stepRevision == stepRevision && context.contextRevision == contextRevision
            && context.grantID == grant?.identifier && grant?.targets.contains(where: {
                $0.processIdentifier == context.processIdentifier && $0.windowIdentifier == context.windowIdentifier
                    && $0.applicationIdentifier == context.applicationIdentifier
            }) == true
    }
    public mutating func show(_ presentation: GuidePresentation) throws {
        guard presentation.kind == .guide_step, let capture, isCurrent(capture), grant?.paused == false,
              presentation.captureID == capture.captureID, let rect = presentation.target,
              capture.screenRect(rect) != nil else { throw AttachmentError.targetChanged }
        try presentation.validate()
        plan.adopt(milestone: presentation.milestone, route: presentation.plan, goalChecks: presentation.goalChecks)
        step = presentation; phase = .waiting; verificationChecks = 0; actionDetected = false
    }
    @discardableResult
    public mutating func recordAttempt() -> Bool {
        guard step != nil, phase == .waiting || phase == .uncertain else { return false }
        actionDetected = true; attemptEpoch &+= 1; return true
    }
    /// Starts a verification episode. Automatic episodes (attempts, AX evidence) are budgeted per step;
    /// an explicit Re-check is the user's choice and always allowed.
    public mutating func beginVerification(automatic: Bool = false) -> Bool {
        guard step != nil, phase == .waiting || phase == .uncertain, grant?.paused == false else { return false }
        if automatic, !budget.spendEpisode() { return false }
        phase = .verifying; verificationChecks = 0; lastVerificationCaptureID = nil; invalidate(); return true
    }
    /// Fresh, directly bound Accessibility state established the outcome without a capture.
    public mutating func confirmLocally() -> Bool {
        guard phase == .verifying, step != nil, grant?.paused == false else { return false }
        advance(.verified); return true
    }
    public mutating func spendRelocation() -> Bool { budget.spendRelocation() }
    /// After a contradicted outcome, look again from the current state while keeping the step's context.
    public mutating func beginRecovery() -> Bool {
        guard step != nil, phase == .uncertain || phase == .verifying, budget.spendRecovery() else { return false }
        phase = .locating; contextRequests = 0; invalidate(); return true
    }
    /// The provider proposed completion; the stored goal checks are verified against fresh evidence first.
    public mutating func beginGoalVerification() -> Bool {
        guard phase == .locating || phase == .waiting || phase == .uncertain, grant?.paused == false else { return false }
        phase = .verifying; verificationChecks = 0; lastVerificationCaptureID = nil; invalidate(); return true
    }
    /// Final verification failed. True when one automatic continuation toward the remaining checks is allowed.
    public mutating func goalVerificationFailed() -> Bool {
        guard phase == .verifying else { return false }
        if goalRecoveriesUsed < 1 { goalRecoveriesUsed += 1; phase = .locating; contextRequests = 0; invalidate(); return true }
        phase = .uncertain; return false
    }
    public mutating func checked(matches: Bool, context: GuideCaptureContext) -> Bool {
        guard phase == .verifying, isCurrent(context), capture?.captureID == context.captureID,
              lastVerificationCaptureID != context.captureID else { return false }
        lastVerificationCaptureID = context.captureID
        verificationChecks += 1
        if matches { advance(.verified); return true }
        if verificationChecks >= 2 { phase = .uncertain }
        return false
    }
    public mutating func manualNext() {
        guard step != nil, phase == .waiting || phase == .uncertain || phase == .paused else { return }
        advance(.manuallyAcknowledged)
    }
    /// Completion only after the stored goal checks were verified on this exact fresh capture. A step still
    /// shown at that point is recorded as satisfied by the present state, not as an observed action.
    public mutating func finish(matches: Bool, captureID: UUID?) -> Bool {
        guard matches, phase == .verifying, let capture, isCurrent(capture), capture.captureID == captureID,
              grant?.paused == false else { return false }
        if let step {
            milestones.append(GuideMilestone(instruction: step.text, completion: .satisfied, intent: plan.current?.intent ?? step.milestone))
            plan.completeCurrent(); self.step = nil
        }
        phase = .completed; generation &+= 1; return true
    }
    public mutating func finishManually() {
        if step != nil { advance(.manuallyAcknowledged) }
        phase = .completed; invalidate(); grant?.paused = true
    }
    public mutating func pause(_ reason: GuideInterruption = .explicitPause) {
        interruptions.insert(reason); phase = .paused; invalidate(); grant?.paused = true
    }
    /// Clears one temporary reason. True when nothing else holds the task, so the host may revalidate
    /// fresh state and resume; a deliberate reason (explicit pause, revoke, closure, failure) keeps it held.
    public mutating func clearTemporaryInterruption(_ reason: GuideInterruption) -> Bool {
        guard reason.isTemporary, phase == .paused else { return false }
        interruptions.remove(reason)
        return interruptions.isEmpty
    }
    /// Deliberate resume: the user explicitly chose to continue, which clears every reason.
    public mutating func resume() {
        interruptions = []; grant?.paused = false; phase = step == nil ? .locating : .uncertain; invalidate()
    }
    /// Fresh state shows the current milestone already holds; recorded without claiming an action happened.
    public mutating func satisfyCurrent() {
        guard step != nil, phase == .verifying || phase == .waiting || phase == .uncertain else { return }
        advance(.satisfied)
    }
    public mutating func changed() { invalidate(); if phase == .waiting { phase = .uncertain } }
    public mutating func cancel() { phase = .canceled; invalidate(); grant = nil; step = nil }
    private mutating func advance(_ completion: GuideCompletion) {
        if let step { milestones.append(GuideMilestone(instruction: step.text, completion: completion, intent: plan.current?.intent ?? step.milestone)) }
        plan.completeCurrent()
        step = nil; stepRevision &+= 1; phase = .locating; budget = GuideStepBudget(); invalidate()
    }
    private mutating func invalidate() { generation &+= 1; contextRevision &+= 1; captureLease = nil; capture = nil }
}
