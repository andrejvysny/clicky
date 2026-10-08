import AppKit

extension VisualGuideController {
    func windowsStillCurrent(_ context: GuideCaptureContext) -> Bool {
        guard task?.isCurrent(context) == true, let target = currentTarget else { return false }
        let currentWindows = [target] + ScopedAccessibility.related(target)
        guard currentWindows.count == context.includedWindows.count,
              currentWindows.allSatisfy({ context.includedWindows.contains($0) }) else { return false }
        return currentWindows.allSatisfy { ScopedAccessibility.bounds($0) == capturedWindowBounds[$0.windowIdentifier] }
    }
    func evidenceStillCurrent(current: UInt64) async throws -> Bool {
        guard let image = lastImage, let context = lastContext, let target = currentTarget,
              windowsStillCurrent(context), ScopedAccessibility.focused(target) else { return false }
        let fresh = try await WindowSnapshotCapture.capture(target, region: context.region.rect,
                                                            relatedTargets: ScopedAccessibility.related(target))
        try Task.checkCancellation()
        guard transaction == current, windowsStillCurrent(context) else { return false }
        let rect = CGRect(x: 0, y: 0, width: image.pixelWidth, height: image.pixelHeight)
        guard let before = fingerprint(image, rect: rect), let after = fingerprint(fresh, rect: rect) else { return false }
        return image.pixelWidth == fresh.pixelWidth && image.pixelHeight == fresh.pixelHeight
            && before == after
    }
    func stopObservation() {
        targetGuard?.cancel(); targetGuard = nil; observer.stop()
    }

    func startTargetGuard(image: PNGImageAttachment, context: GuideCaptureContext, pixelTarget: GuideRect) {
        targetGuard?.cancel()
        let pixels = pixelTarget.rect.integral
        guard let target = currentTarget, let region = context.screenRect(GuideRect(pixels)),
              let expected = fingerprint(image, rect: pixels) else { invalidateTarget(); return }
        let bounds = ScopedAccessibility.bounds(target)
        targetGuard = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                guard let self, task?.phase == .waiting, task?.isCurrent(context) == true, !composerOpen else { return }
                guard ScopedAccessibility.focused(target) else { pause(message: "Target no longer active · Resume to refresh"); return }
                guard ScopedAccessibility.bounds(target) != nil else { pause(message: "Target closed or minimized · Choose a window to resume"); return }
                guard ScopedAccessibility.bounds(target) == bounds, windowsStillCurrent(context) else { invalidateTarget(); return }
                do {
                    // This bounded comparison stays local; it never triggers a provider turn.
                    let fresh = try await WindowSnapshotCapture.capture(target, region: region,
                                                                        relatedTargets: ScopedAccessibility.related(target), outputSize: pixels.size)
                    try Task.checkCancellation()
                    guard task?.isCurrent(context) == true else { return }
                    guard fresh.pixelWidth == Int(pixels.width), fresh.pixelHeight == Int(pixels.height),
                          fingerprint(fresh, rect: CGRect(origin: .zero, size: pixels.size)) == expected else { invalidateTarget(); return }
                } catch is CancellationError { return }
                catch { invalidateTarget(); return }
            }
        }
    }
}
