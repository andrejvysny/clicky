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

nonisolated public enum GuideCompletion: String, Codable, Sendable { case verified, manuallyAcknowledged }
nonisolated public struct GuideMilestone: Encodable, Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let instruction: String
    public let completion: GuideCompletion
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
        step = presentation; phase = .waiting; verificationChecks = 0; actionDetected = false
    }
    public mutating func recordAttempt() { if phase == .waiting || phase == .uncertain { actionDetected = true } }
    public mutating func beginVerification() -> Bool {
        guard step != nil, phase == .waiting || phase == .uncertain, grant?.paused == false else { return false }
        phase = .verifying; verificationChecks = 0; lastVerificationCaptureID = nil; invalidate(); return true
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
    public mutating func finish(matches: Bool, captureID: UUID?) -> Bool {
        guard matches, step == nil, let capture, isCurrent(capture), capture.captureID == captureID,
              grant?.paused == false else { return false }
        phase = .completed; generation &+= 1; return true
    }
    public mutating func finishManually() {
        if step != nil { advance(.manuallyAcknowledged) }
        phase = .completed; invalidate(); grant?.paused = true
    }
    public mutating func pause() { phase = .paused; invalidate(); grant?.paused = true }
    public mutating func resume() { grant?.paused = false; phase = step == nil ? .locating : .uncertain; invalidate() }
    public mutating func changed() { invalidate(); if phase == .waiting { phase = .uncertain } }
    public mutating func cancel() { phase = .canceled; invalidate(); grant = nil; step = nil }
    private mutating func advance(_ completion: GuideCompletion) {
        if let step { milestones.append(GuideMilestone(instruction: step.text, completion: completion)) }
        step = nil; stepRevision &+= 1; phase = .locating; invalidate()
    }
    private mutating func invalidate() { generation &+= 1; contextRevision &+= 1; captureLease = nil; capture = nil }
}
