import Foundation

nonisolated public enum AttachmentError: Error, LocalizedError, Equatable {
    case noTarget, targetChanged, permissionRequired, invalidImage, imageTooLarge, captureFailed

    public var errorDescription: String? {
        switch self {
        case .noTarget: return "Open Quick Ask while the window you want to attach is active."
        case .targetChanged: return "The original window is no longer available. Reopen Quick Ask in that window."
        case .permissionRequired: return "Allow Screen Recording for Clicky in System Settings, then reopen Quick Ask."
        case .invalidImage: return "The attachment must be a PNG image with dimensions up to 4096 pixels."
        case .imageTooLarge: return "The screenshot exceeds the 3 MiB limit. Try a smaller window or attach a smaller PNG."
        case .captureFailed: return "The window could not be captured. Check Screen Recording access and try again."
        }
    }
}

/// An immutable snapshot, never a handle that permits later screen reads.
nonisolated public struct PNGImageAttachment: Equatable, Sendable {
    public static let maximumBytes = 3 * 1024 * 1024
    public let data: Data
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let displayName: String
    public let context: ScreenContextIdentity?
    public var mediaType: String { "image/png" }
    public var dataURL: String { "data:image/png;base64," + data.base64EncodedString() }

    public init(data: Data, displayName: String = "PNG attachment", context: ScreenContextIdentity? = nil) throws {
        guard data.count <= Self.maximumBytes else { throw AttachmentError.imageTooLarge }
        // Validate the bounded PNG header here; native capture uses ImageIO to produce the image.
        let header = Array(data.prefix(24))
        guard data.count >= 45, Array(data.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10],
              Array(header[8..<16]) == [0, 0, 0, 13, 73, 72, 68, 82],
              Array(data.suffix(12)) == [0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130] else { throw AttachmentError.invalidImage }
        func dimension(_ offset: Int) -> Int {
            header[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
        }
        let width = dimension(16), height = dimension(20)
        guard (1...4096).contains(width), (1...4096).contains(height) else { throw AttachmentError.invalidImage }
        self.data = data
        pixelWidth = width
        pixelHeight = height
        self.displayName = String(displayName.replacingOccurrences(of: "\n", with: " ").prefix(120))
        self.context = context
    }
}

nonisolated public struct WindowCaptureTarget: Equatable, Sendable {
    public let processIdentifier: Int32
    public let windowIdentifier: UInt32
    public let applicationIdentifier: String
    public let applicationName: String

    public init(processIdentifier: Int32, windowIdentifier: UInt32, applicationIdentifier: String, applicationName: String) {
        self.processIdentifier = processIdentifier
        self.windowIdentifier = windowIdentifier
        self.applicationIdentifier = applicationIdentifier
        self.applicationName = applicationName
    }
}

nonisolated public struct WindowCaptureLease: Equatable, Sendable {
    public let identifier: UUID
    public let target: WindowCaptureTarget
}

/// A capture belongs to one explicit button press in one popup presentation.
nonisolated public struct WindowAttachmentState: Sendable {
    public private(set) var target: WindowCaptureTarget?
    public private(set) var pending: WindowCaptureLease?
    public private(set) var attachment: PNGImageAttachment?

    public init() {}

    public mutating func beginPresentation(target: WindowCaptureTarget?) {
        self.target = target
        pending = nil
        attachment = nil
    }

    public mutating func beginCapture() throws -> WindowCaptureLease {
        guard let target else { throw AttachmentError.noTarget }
        guard pending == nil else { throw AskError.busy }
        let lease = WindowCaptureLease(identifier: UUID(), target: target)
        pending = lease
        attachment = nil
        return lease
    }

    @discardableResult
    public mutating func accept(_ image: PNGImageAttachment, lease: WindowCaptureLease) -> Bool {
        guard pending == lease, target == lease.target,
              let context = image.context,
              context.windowIdentifier == lease.target.windowIdentifier,
              context.applicationIdentifier == lease.target.applicationIdentifier else { return false }
        pending = nil
        attachment = image
        return true
    }

    @discardableResult
    public mutating func fail(lease: WindowCaptureLease) -> Bool {
        guard pending == lease else { return false }
        pending = nil
        return true
    }

    public mutating func discard() { pending = nil; attachment = nil }
    public mutating func endPresentation() { beginPresentation(target: nil) }
}
