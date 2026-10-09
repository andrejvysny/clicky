import AppKit
import OSLog
#if canImport(ClickyCore)
import ClickyCore
#endif

extension VisualGuideController {
    func windowsStillCurrent(_ context: GuideCaptureContext) -> Bool {
        guard task?.isCurrent(context) == true, let target = currentTarget else { return false }
        let currentWindows = [target] + environment.related(target)
        guard currentWindows.count == context.includedWindows.count,
              currentWindows.allSatisfy({ context.includedWindows.contains($0) }) else { return false }
        return currentWindows.allSatisfy { environment.bounds($0) == capturedWindowBounds[$0.windowIdentifier] }
    }
    func evidenceStillCurrent(current: UInt64, evidenceTarget: GuideRect?) async throws -> Bool {
        guard let image = lastImage, let context = lastContext, let target = currentTarget,
              let evidenceTarget,
              let rect = GuidePixelMapping.evidenceComparisonRect(evidenceTarget, pixelWidth: image.pixelWidth, pixelHeight: image.pixelHeight),
              windowsStillCurrent(context), environment.focused(target) else { return false }
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

    /// Local freshness watch for the presented target (local captures only, never provider turns). Pointer hover
    /// and press feedback are expected appearance changes; a pixel change must persist with the pointer away
    /// before it counts as real replacement. Geometry changes re-ground immediately. Pixels never prove success.
    func startTargetGuard(image: PNGImageAttachment, context: GuideCaptureContext, pixelTarget: GuideRect) {
        targetGuard?.cancel()
        targetGuardSuspendedUntil = .distantPast
        guard let pixels = GuidePixelMapping.comparisonRect(pixelTarget, pixelWidth: image.pixelWidth, pixelHeight: image.pixelHeight),
              let target = currentTarget, let screenRect = context.screenRect(pixelTarget),
              let expected = fingerprint(image, rect: pixels) else { invalidateTarget(reason: "comparison_region"); return }
        let bounds = environment.bounds(target)
        targetGuard = Task { [weak self] in
            var mismatches = 0
            while !Task.isCancelled {
                do { try await self?.environment.sleep(Self.guardIntervalNanoseconds) } catch { return }
                guard let self, task?.phase == .waiting, task?.isCurrent(context) == true, !composerOpen else { return }
                guard environment.focused(target) else { interruptForAppSwitch(); return }
                guard environment.bounds(target) != nil else {
                    pause(message: "Target closed or minimized · Choose a window to resume", reason: .targetClosed); return
                }
                guard environment.bounds(target) == bounds, windowsStillCurrent(context) else { relocateTarget(reason: "window_geometry"); return }
                guard observer.expectedFieldGeometryIsCurrent else { relocateTarget(reason: "field_geometry"); return }
                // Editing the requested value changes its pixels by design; verify only on commit.
                if suspendedForInteraction || pointerNear(screenRect) { mismatches = 0; continue }
                do {
                    // Cropping before ScreenCaptureKit resamples produces different edge/text pixels.
                    // Capture with the original transform, then compare the same local pixel rectangle.
                    let fresh = try await matchingCapture(target, context: context)
                    try Task.checkCancellation()
                    guard task?.phase == .waiting, task?.isCurrent(context) == true else { return }
                    guard observer.expectedFieldGeometryIsCurrent else { relocateTarget(reason: "field_geometry"); return }
                    if suspendedForInteraction || pointerNear(screenRect) { mismatches = 0; continue }
                    let same = fresh.pixelWidth == image.pixelWidth && fresh.pixelHeight == image.pixelHeight
                        && fingerprint(fresh, rect: pixels) == expected
                    mismatches = same ? 0 : mismatches + 1
                    if mismatches >= Self.guardMismatchLimit { relocateTarget(reason: "target_pixels"); return }
                } catch is CancellationError { return }
                catch { invalidateTarget(reason: "capture_failed"); return }
            }
        }
    }

    static let guardIntervalNanoseconds: UInt64 = 1_000_000_000
    /// Consecutive pointer-away mismatches before the target counts as changed (about two seconds).
    static let guardMismatchLimit = 2
    /// Margin around the target within which the pointer may cause hover/press feedback.
    static let hoverMargin: CGFloat = 12

    private var suspendedForInteraction: Bool {
        environment.now() < targetGuardSuspendedUntil || observer.isPressingExpectedTarget || observer.isEditingExpectedField
    }
    private func pointerNear(_ rect: CGRect) -> Bool {
        rect.insetBy(dx: -Self.hoverMargin, dy: -Self.hoverMargin).contains(environment.pointer())
    }

    func matchingCapture(_ target: WindowCaptureTarget, context: GuideCaptureContext) async throws -> PNGImageAttachment {
        metrics.count(.captures)
        return try await environment.capture(target, context.region.rect, environment.related(target),
                                      CGSize(width: context.pixelWidth, height: context.pixelHeight))
    }
}
