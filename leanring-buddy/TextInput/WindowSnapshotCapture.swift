import AppKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

@MainActor
enum WindowSnapshotCapture {
    /// Resolve the originating app's frontmost normal window before showing Quick Ask.
    /// Window enumeration does not capture pixels or request permissions.
    static func target(for application: NSRunningApplication?) -> WindowCaptureTarget? {
        guard let application, !application.isTerminated,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let window = windows.first(where: {
                  ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == application.processIdentifier &&
                  ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
              }), let identifier = window[kCGWindowNumber as String] as? NSNumber else { return nil }
        return WindowCaptureTarget(processIdentifier: application.processIdentifier, windowIdentifier: identifier.uint32Value,
                                   applicationIdentifier: application.bundleIdentifier ?? "pid:\(application.processIdentifier)",
                                   applicationName: application.localizedName ?? "Original application")
    }

    static func capture(_ target: WindowCaptureTarget) async throws -> PNGImageAttachment {
        guard target.processIdentifier != ProcessInfo.processInfo.processIdentifier else { throw AttachmentError.noTarget }
        // This method is reached only through the explicit Attach button.
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
            guard CGPreflightScreenCaptureAccess() else { throw AttachmentError.permissionRequired }
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            try Task.checkCancellation()
            guard let window = content.windows.first(where: {
                $0.windowID == target.windowIdentifier && $0.owningApplication?.processID == target.processIdentifier && $0.isOnScreen
            }), let owner = window.owningApplication,
                target.applicationIdentifier == owner.bundleIdentifier || target.applicationIdentifier == "pid:\(owner.processID)" else {
                throw AttachmentError.targetChanged
            }
            let frame = window.frame
            guard frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0 else { throw AttachmentError.targetChanged }
            // SCDisplay frames and SCWindow frames share global Core Graphics point coordinates.
            let display = content.displays.max { lhs, rhs in
                area(lhs.frame.intersection(frame)) < area(rhs.frame.intersection(frame))
            }
            guard let display, area(display.frame.intersection(frame)) > 0 else { throw AttachmentError.targetChanged }
            let pixelSize = CaptureSizing.pixelSize(forPointSize: frame.size, backingScale: backingScale(for: display.displayID))
            let configuration = SCStreamConfiguration()
            configuration.width = Int(pixelSize.width)
            configuration.height = Int(pixelSize.height)
            configuration.showsCursor = false
            // Captures this window only, independent of overlapping Clicky panels and other apps.
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            try Task.checkCancellation()
            // Recheck the PID/window binding after the await; never fall back to a display capture.
            guard let current = CGWindowListCopyWindowInfo([.optionIncludingWindow], target.windowIdentifier) as? [[String: Any]],
                  let currentWindow = current.first(where: {
                      ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == target.windowIdentifier &&
                      ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == target.processIdentifier
                  }), let bounds = currentWindow[kCGWindowBounds as String] as? NSDictionary,
                  let currentFrame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  abs(currentFrame.origin.x - frame.origin.x) < 1,
                  abs(currentFrame.origin.y - frame.origin.y) < 1,
                  abs(currentFrame.width - frame.width) < 1,
                  abs(currentFrame.height - frame.height) < 1 else { throw AttachmentError.targetChanged }
            let context = ScreenContextIdentity(applicationIdentifier: target.applicationIdentifier,
                                                windowIdentifier: target.windowIdentifier,
                                                displayIdentifier: display.displayID, capturedAt: Date())
            // Compress away from the UI thread. No screenshot file is created.
            return try await Task.detached(priority: .userInitiated) {
                guard let data = CFDataCreateMutable(nil, 0),
                      let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw AttachmentError.captureFailed }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else { throw AttachmentError.captureFailed }
                return try PNGImageAttachment(data: data as Data, displayName: target.applicationName + " window", context: context, capturedRegion: frame)
            }.value
        } catch is CancellationError { throw CancellationError() }
        catch let error as AttachmentError { throw error }
        catch { throw AttachmentError.captureFailed }
    }

    /// `pointer` is in global top-left points. Captures the whole display under it, minus Clicky's own windows.
    static func captureDisplay(containing pointer: CGPoint) async throws -> PNGImageAttachment {
        // This method is reached only through the explicit screen-inclusion action or the Always preference.
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
            guard CGPreflightScreenCaptureAccess() else { throw AttachmentError.permissionRequired }
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            try Task.checkCancellation()
            guard let display = content.displays.first(where: { $0.frame.contains(pointer) }) ?? content.displays.first else {
                throw AttachmentError.captureFailed
            }
            let own = content.applications.first { $0.processID == ProcessInfo.processInfo.processIdentifier }
            // Excluding our own app hides Clicky's companion, popup and bubble from the capture.
            let filter = SCContentFilter(display: display, excludingApplications: own.map { [$0] } ?? [], exceptingWindows: [])
            let pixelSize = CaptureSizing.pixelSize(forPointSize: display.frame.size, backingScale: backingScale(for: display.displayID))
            let configuration = SCStreamConfiguration()
            configuration.width = Int(pixelSize.width)
            configuration.height = Int(pixelSize.height)
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            try Task.checkCancellation()
            let context = ScreenContextIdentity(applicationIdentifier: "screen", windowIdentifier: 0,
                                                displayIdentifier: display.displayID, capturedAt: Date())
            let region = display.frame
            return try await Task.detached(priority: .userInitiated) {
                guard let data = CFDataCreateMutable(nil, 0),
                      let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw AttachmentError.captureFailed }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else { throw AttachmentError.captureFailed }
                return try PNGImageAttachment(data: data as Data, displayName: "Screen", context: context, capturedRegion: region)
            }.value
        } catch is CancellationError { throw CancellationError() }
        catch let error as AttachmentError { throw error }
        catch { throw AttachmentError.captureFailed }
    }

    private static func backingScale(for displayID: CGDirectDisplayID) -> CGFloat {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }?.backingScaleFactor ?? 2
    }

    private static func area(_ rect: CGRect) -> CGFloat { rect.isNull ? 0 : rect.width * rect.height }
}
