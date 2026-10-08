import Foundation
// Darwin Foundation does not re-export CGRect geometry members to this module.
#if canImport(CoreGraphics)
import CoreGraphics
#endif

nonisolated public struct GuidanceVerification {
    public enum ExpectedAction: Equatable { case click(button: Int), key(code: UInt16, modifiers: UInt64) }
    public enum ObservedAction: Equatable { case click(button: Int, point: CGPoint), key(code: UInt16, modifiers: UInt64) }
    public private(set) var phase: GuidancePhase = .waiting
    public let identifier: UUID
    public let windowIdentifier: UInt32
    public let displayIdentifier: UInt32
    public let target: CGRect
    public let expectedAction: ExpectedAction
    private let generation: UInt64

    public init(identifier: UUID = UUID(), windowIdentifier: UInt32, displayIdentifier: UInt32, target: CGRect, expectedAction: ExpectedAction, generation: UInt64) throws {
        guard target.origin.x.isFinite, target.origin.y.isFinite, target.width.isFinite, target.height.isFinite,
              target.width > 0, target.height > 0 else { throw AskError.protocolFailure("Guidance target has invalid geometry.") }
        self.identifier = identifier
        self.windowIdentifier = windowIdentifier
        self.displayIdentifier = displayIdentifier
        self.target = target
        self.expectedAction = expectedAction
        self.generation = generation
    }

    @discardableResult
    public mutating func observe(_ action: ObservedAction, windowIdentifier: UInt32, displayIdentifier: UInt32, targetIsFresh: Bool) -> Bool {
        guard phase == .waiting || phase == .uncertain else { return false }
        guard windowIdentifier == self.windowIdentifier, displayIdentifier == self.displayIdentifier, targetIsFresh else { return false }
        let matches: Bool
        switch (expectedAction, action) {
        case (.click(let expectedButton), .click(let button, let point)): matches = expectedButton == button && target.contains(point)
        case (.key(let expectedCode, let expectedModifiers), .key(let code, let modifiers)): matches = code == expectedCode && modifiers == expectedModifiers
        default: matches = false
        }
        if matches { phase = .verifying }
        return matches
    }

    public mutating func verify(outcomeMatches: Bool, generation: UInt64) {
        guard phase == .verifying, generation == self.generation else { return }
        phase = outcomeMatches ? .completed : .uncertain
    }

    public mutating func manualNext(explicitOverride: Bool) {
        guard explicitOverride, phase == .waiting || phase == .uncertain else { return }
        phase = .completed
    }

    public mutating func cancel() { phase = .canceled }
}

nonisolated public struct DictationDestination: Equatable, Sendable {
    public let processIdentifier: Int32
    public let windowIdentifier: UInt32
    public let elementIdentifier: String
    public let selection: NSRange
    public let secure: Bool
    public let supportsInsertion: Bool

    public init(processIdentifier: Int32, windowIdentifier: UInt32, elementIdentifier: String, selection: NSRange, secure: Bool, supportsInsertion: Bool) {
        self.processIdentifier = processIdentifier
        self.windowIdentifier = windowIdentifier
        self.elementIdentifier = elementIdentifier
        self.selection = selection
        self.secure = secure
        self.supportsInsertion = supportsInsertion
    }

    public func permitsInsertion(current: DictationDestination) -> Bool {
        !secure && !current.secure && supportsInsertion && current.supportsInsertion && self == current
    }
}
