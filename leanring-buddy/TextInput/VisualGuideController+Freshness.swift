import AppKit
import OSLog

extension VisualGuideController {
    func windowsStillCurrent(_ context: GuideCaptureContext) -> Bool {
        guard task?.isCurrent(context) == true, let target = currentTarget else { return false }
        let currentWindows = [target] + ScopedAccessibility.related(target)
        guard currentWindows.count == context.includedWindows.count,
              currentWindows.allSatisfy({ context.includedWindows.contains($0) }) else { return false }
        return currentWindows.allSatisfy { ScopedAccessibility.bounds($0) == capturedWindowBounds[$0.windowIdentifier] }
    }
    func evidenceStillCurrent(current: UInt64, evidenceTarget: GuideRect?) async throws -> Bool {
        guard let image = lastImage, let context = lastContext, let target = currentTarget,
              let evidenceTarget,
              let rect = GuidePixelMapping.evidenceComparisonRect(evidenceTarget, pixelWidth: image.pixelWidth, pixelHeight: image.pixelHeight),
              windowsStillCurrent(context), ScopedAccessibility.focused(target) else { return false }
        let fresh = try await matchingCapture(target, context: context)
        try Task.checkCancellation()
        guard transaction == current, windowsStillCurrent(context) else { return false }
        // The verdict names the whole visible outcome region; unrelated clocks and indicators may change.
        // Compare exact pixels there, still using the original capture transform and current scope.
        guard let before = fingerprint(image, rect: rect), let after = fingerprint(fresh, rect: rect) else { return false }
        let matches = image.pixelWidth == fresh.pixelWidth && image.pixelHeight == fresh.pixelHeight
            && before == after
        #if DEBUG
        if !matches { Logger(subsystem: "clicky", category: "guide").info("evidence freshness mismatch") }
        #endif
        return matches
    }
    func stopObservation() {
        targetGuard?.cancel(); targetGuard = nil; observer.stop()
    }

    func startTargetGuard(image: PNGImageAttachment, context: GuideCaptureContext, pixelTarget: GuideRect) {
        targetGuard?.cancel()
        targetGuardSuspendedUntil = .distantPast
        guard let pixels = GuidePixelMapping.comparisonRect(pixelTarget, pixelWidth: image.pixelWidth, pixelHeight: image.pixelHeight),
              let target = currentTarget,
              let expected = fingerprint(image, rect: pixels) else { invalidateTarget(reason: "comparison_region"); return }
        let bounds = ScopedAccessibility.bounds(target)
        targetGuard = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                guard let self, task?.phase == .waiting, task?.isCurrent(context) == true, !composerOpen else { return }
                guard ScopedAccessibility.focused(target) else { pause(message: "Target no longer active · Resume to refresh"); return }
                guard ScopedAccessibility.bounds(target) != nil else { pause(message: "Target closed or minimized · Choose a window to resume"); return }
                guard ScopedAccessibility.bounds(target) == bounds, windowsStillCurrent(context) else { invalidateTarget(reason: "window_geometry"); return }
                guard observer.expectedFieldGeometryIsCurrent else { invalidateTarget(reason: "field_geometry"); return }
                // Editing the requested value changes its pixels by design; verify only on commit.
                if Date() < targetGuardSuspendedUntil || observer.isPressingExpectedTarget || observer.isEditingExpectedField { continue }
                do {
                    // Cropping before ScreenCaptureKit resamples produces different edge/text pixels.
                    // Capture with the original transform, then compare the same local pixel rectangle.
                    let fresh = try await matchingCapture(target, context: context)
                    try Task.checkCancellation()
                    guard task?.phase == .waiting, task?.isCurrent(context) == true else { return }
                    guard observer.expectedFieldGeometryIsCurrent else { invalidateTarget(reason: "field_geometry"); return }
                    if Date() < targetGuardSuspendedUntil || observer.isPressingExpectedTarget || observer.isEditingExpectedField { continue }
                    guard fresh.pixelWidth == image.pixelWidth, fresh.pixelHeight == image.pixelHeight,
                          fingerprint(fresh, rect: pixels) == expected else {
                        invalidateTarget(reason: "target_pixels"); return
                    }
                } catch is CancellationError { return }
                catch { invalidateTarget(reason: "capture_failed"); return }
            }
        }
    }

    func matchingCapture(_ target: WindowCaptureTarget, context: GuideCaptureContext) async throws -> PNGImageAttachment {
        try await WindowSnapshotCapture.capture(target, region: context.region.rect,
                                                relatedTargets: ScopedAccessibility.related(target),
                                                outputSize: CGSize(width: context.pixelWidth, height: context.pixelHeight))
    }
}
