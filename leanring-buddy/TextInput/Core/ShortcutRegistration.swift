import Foundation

nonisolated public struct ShortcutBinding: Equatable, Sendable {
    public let keyCode: UInt32
    public let modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

/// A failed replacement must leave the previously working shortcut registered.
nonisolated public struct ShortcutRegistration<Resource> {
    public private(set) var binding: ShortcutBinding?
    private var resource: Resource?

    public init() {}

    @discardableResult
    public mutating func register(_ candidate: ShortcutBinding, acquire: (ShortcutBinding) -> Resource?, release: (Resource) -> Void) -> Bool {
        if binding == candidate { return true }
        guard let replacement = acquire(candidate) else { return false }
        if let resource { release(resource) }
        resource = replacement
        binding = candidate
        return true
    }

    public mutating func unregister(release: (Resource) -> Void) {
        if let resource { release(resource) }
        resource = nil
        binding = nil
    }
}
