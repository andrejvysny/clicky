import Foundation

public struct HybridRecordingGesture {
    public enum Phase: Equatable { case idle, held(InputMode), latched(InputMode) }
    public enum Effect: Equatable { case none, start(InputMode), finalize(InputMode), discard(InputMode) }
    public private(set) var phase: Phase = .idle
    public let tapThreshold: TimeInterval
    private var pressedAt: TimeInterval?
    private var suppressNextRelease = false

    public init(tapThreshold: TimeInterval = 0.25) { self.tapThreshold = max(0.05, min(1, tapThreshold)) }

    public mutating func keyDown(mode: InputMode, time: TimeInterval, isRepeat: Bool = false) -> Effect {
        guard !isRepeat else { return .none }
        switch phase {
        case .idle:
            suppressNextRelease = false
            pressedAt = time
            phase = .held(mode)
            return .start(mode)
        case .latched(let currentMode) where currentMode == mode:
            phase = .idle
            pressedAt = nil
            suppressNextRelease = true
            return .finalize(mode)
        default: return .none
        }
    }

    public mutating func keyUp(mode: InputMode, time: TimeInterval) -> Effect {
        if suppressNextRelease { suppressNextRelease = false; return .none }
        guard case .held(let currentMode) = phase, currentMode == mode, let pressedAt else { return .none }
        self.pressedAt = nil
        if time - pressedAt < tapThreshold { phase = .latched(mode); return .none }
        phase = .idle
        return .finalize(mode)
    }

    public mutating func cancel() -> Effect {
        let effect: Effect
        switch phase {
        case .held(let mode), .latched(let mode): effect = .discard(mode)
        case .idle: effect = .none
        }
        phase = .idle
        pressedAt = nil
        suppressNextRelease = false
        return effect
    }
}
