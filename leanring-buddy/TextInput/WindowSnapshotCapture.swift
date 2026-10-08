import AppKit
import ApplicationServices
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

@MainActor
enum WindowSnapshotCapture {
    private struct CapturePlan {
        let window: SCWindow
        let related: [SCWindow]
        let display: SCDisplay
        let region: CGRect
        let fullFrame: CGRect
    }
    /// Resolve the originating app's frontmost normal window before showing Quick Ask.
    /// Window enumeration does not capture pixels or request permissions.
    static func target(for application: NSRunningApplication?) -> WindowCaptureTarget? {
        guard let application, !application.isTerminated,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let candidates = windows.filter {
                  ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == application.processIdentifier &&
                  ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
        }
        var selected = candidates.first
        if AXIsProcessTrusted() {
            let app = AXUIElementCreateApplication(application.processIdentifier)
            AXUIElementSetMessagingTimeout(app, 0.2)
            if let focused = ScopedAccessibility.value(app, kAXFocusedWindowAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID(),
               let frame = ScopedAccessibility.frame(focused as! AXUIElement) {
                // AX and Window Server frames can differ by sub-point rounding; keep the front-most window as fallback.
                selected = candidates.first { entry in
                    guard let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                          let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
                    return abs(rect.minX - frame.minX) < 2 && abs(rect.minY - frame.minY) < 2
                        && abs(rect.width - frame.width) < 2 && abs(rect.height - frame.height) < 2
                } ?? candidates.first
            }
        }
        guard let window = selected, let identifier = window[kCGWindowNumber as String] as? NSNumber else { return nil }
        return WindowCaptureTarget(processIdentifier: application.processIdentifier, windowIdentifier: identifier.uint32Value,
                                   applicationIdentifier: application.bundleIdentifier ?? "pid:\(application.processIdentifier)",
                                   applicationName: application.localizedName ?? "Original application")
    }

    static func capture(_ target: WindowCaptureTarget, region requestedRegion: CGRect? = nil,
                        relatedTargets: [WindowCaptureTarget] = [], outputSize: CGSize? = nil) async throws -> PNGImageAttachment {
        guard target.processIdentifier != ProcessInfo.processInfo.processIdentifier else { throw AttachmentError.noTarget }
        // Only an explicit attachment or an active task grant reaches this capture path.
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
            guard CGPreflightScreenCaptureAccess() else { throw AttachmentError.permissionRequired }
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            try Task.checkCancellation()
            let plan = try capturePlan(content, target: target, requestedRegion: requestedRegion, relatedTargets: relatedTargets)
            let (filter, configuration) = try captureConfiguration(plan, detail: requestedRegion != nil, outputSize: outputSize)
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            try Task.checkCancellation()
            // Recheck the PID/window binding after the await; never fall back to a display capture.
            guard ([plan.window] + plan.related).allSatisfy({ capturedWindow in
                guard let pid = capturedWindow.owningApplication?.processID else { return false }
                let identity = WindowCaptureTarget(processIdentifier: pid, windowIdentifier: capturedWindow.windowID,
                                                   applicationIdentifier: capturedWindow.owningApplication?.bundleIdentifier ?? "pid:\(pid)",
                                                   applicationName: target.applicationName)
                return ScopedAccessibility.bounds(identity) == capturedWindow.frame
            }) else { throw AttachmentError.targetChanged }
            let context = ScreenContextIdentity(applicationIdentifier: target.applicationIdentifier,
                                                windowIdentifier: target.windowIdentifier,
                                                displayIdentifier: plan.display.displayID, capturedAt: Date())
            // Compress away from the UI thread. No screenshot file is created.
            return try await Task.detached(priority: .userInitiated) {
                guard let data = CFDataCreateMutable(nil, 0),
                      let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw AttachmentError.captureFailed }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else { throw AttachmentError.captureFailed }
                return try PNGImageAttachment(data: data as Data, displayName: target.applicationName + " window", context: context, capturedRegion: plan.region)
            }.value
        } catch is CancellationError { throw CancellationError() }
        catch let error as AttachmentError { throw error }
        catch { throw AttachmentError.captureFailed }
    }

    private static func capturePlan(_ content: SCShareableContent, target: WindowCaptureTarget,
                                    requestedRegion: CGRect?, relatedTargets: [WindowCaptureTarget]) throws -> CapturePlan {
        guard let window = content.windows.first(where: {
            $0.windowID == target.windowIdentifier && $0.owningApplication?.processID == target.processIdentifier && $0.isOnScreen
        }), let owner = window.owningApplication,
              target.applicationIdentifier == owner.bundleIdentifier || target.applicationIdentifier == "pid:\(owner.processID)" else {
            throw AttachmentError.targetChanged
        }
        let related = content.windows.filter { candidate in
            relatedTargets.contains { $0.windowIdentifier == candidate.windowID && $0.processIdentifier == candidate.owningApplication?.processID
                && $0.applicationIdentifier == candidate.owningApplication?.bundleIdentifier && candidate.isOnScreen }
        }
        guard related.count == relatedTargets.count else { throw AttachmentError.targetChanged }
        let fullFrame = related.reduce(window.frame) { $0.union($1.frame) }
        let frame = requestedRegion ?? fullFrame
        guard fullFrame.contains(frame), frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0 else {
            throw AttachmentError.targetChanged
        }
        let display = content.displays.max { area($0.frame.intersection(frame)) < area($1.frame.intersection(frame)) }
        guard let display, area(display.frame.intersection(frame)) > 0 else { throw AttachmentError.targetChanged }
        return CapturePlan(window: window, related: related, display: display, region: frame, fullFrame: fullFrame)
    }

    private static func captureConfiguration(_ plan: CapturePlan, detail: Bool,
                                             outputSize: CGSize?) throws -> (SCContentFilter, SCStreamConfiguration) {
        let pixelSize = outputSize ?? CaptureSizing.pixelSize(forPointSize: plan.region.size, backingScale: backingScale(for: plan.display.displayID))
        guard pixelSize.width.isFinite, pixelSize.height.isFinite, pixelSize.width > 0, pixelSize.height > 0,
              pixelSize.width <= 4096, pixelSize.height <= 4096 else { throw AttachmentError.captureFailed }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(pixelSize.width); configuration.height = Int(pixelSize.height)
        configuration.showsCursor = false; configuration.ignoreShadowsSingleWindow = true
        configuration.ignoreShadowsDisplay = true; configuration.includeChildWindows = false
        let filter: SCContentFilter
        if plan.related.isEmpty {
            filter = SCContentFilter(desktopIndependentWindow: plan.window)
            if detail { configuration.sourceRect = relativeRegion(plan.region, in: plan.window.frame) }
        } else {
            guard plan.display.frame.contains(plan.fullFrame) else { throw AttachmentError.targetChanged }
            filter = SCContentFilter(display: plan.display, including: [plan.window] + plan.related)
            filter.includeMenuBar = false
            configuration.sourceRect = relativeRegion(plan.region, in: plan.display.frame)
        }
        return (filter, configuration)
    }

    private static func relativeRegion(_ region: CGRect, in frame: CGRect) -> CGRect {
        CGRect(x: region.minX - frame.minX, y: region.minY - frame.minY, width: region.width, height: region.height)
    }

    /// `pointer` is in global top-left points. Captures the whole display under it, minus Clicky's own windows.
    static func captureDisplay(containing pointer: CGPoint) async throws -> PNGImageAttachment {
        // The task guide invokes this only after a one-transmission display approval.
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
            guard CGPreflightScreenCaptureAccess() else { throw AttachmentError.permissionRequired }
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            try Task.checkCancellation()
            guard let display = content.displays.first(where: { $0.frame.contains(pointer) }) else {
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
