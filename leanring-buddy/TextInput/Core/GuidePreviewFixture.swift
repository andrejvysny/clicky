import Foundation

nonisolated public struct GuidePreviewFixture: Sendable {
    public static let instructions = ["Open the example panel.", "Enter 12 in the example field, then press Return.", "Save the example changes."]
    public private(set) var index = 0
    public private(set) var paused = false
    public var completed: Bool { index >= Self.instructions.count }
    public var instruction: String { completed ? "Demo checklist finished manually." : Self.instructions[index] }
    public init() {}
    public mutating func next() { guard !paused, !completed else { return }; index += 1 }
    public mutating func pause() { paused = true }
    public mutating func resume() { paused = false }
}
