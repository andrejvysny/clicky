import AppKit

/// Controlled paste staging, shared by every paste adapter so overlapping operations see one lifecycle.
/// The user's clipboard is snapshotted in bounded memory, the payload is staged as plain text immediately
/// before Command-V, and the original is restored only while the pasteboard still holds Clicky's staged
/// version. A newer copy by the user or a clipboard manager is never overwritten.
///
/// Ownership is tracked with `changeCount`: a snapshot is refused when the pasteboard changed while it was
/// read, and staging is refused when it changed since the snapshot. Residual limitation: another process can
/// still write between that last check and `clearContents()`; macOS offers no atomic compare-and-swap.
@MainActor
final class WritingClipboard {
    static let shared = WritingClipboard()
    static let maximumSnapshotBytes = 8 * 1_048_576

    struct Snapshot {
        /// The pasteboard version the items were read from.
        let changeCount: Int
        fileprivate let items: [[(NSPasteboard.PasteboardType, Data)]]
    }

    struct Staged {
        let changeCount: Int
        fileprivate let snapshot: Snapshot
    }

    private let pasteboard: NSPasteboard
    /// A staged payload whose paste was never confirmed. It is not restored on a timer (a late paste would then
    /// insert the user's old clipboard); the next staging carries its original snapshot forward instead.
    private(set) var unsettled: Staged?

    init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }

    /// Nil when some item cannot be read back completely (promised/lazy data), exceeds the bound, or the
    /// pasteboard changed while it was read; callers then keep a visible Copy alternative instead.
    func snapshot() -> Snapshot? {
        let version = pasteboard.changeCount
        if let unsettled, unsettled.changeCount == version {
            // Clicky's own unconfirmed text is still there; the user's real clipboard is the one saved before it.
            return Snapshot(changeCount: version, items: unsettled.snapshot.items)
        }
        unsettled = nil
        var total = 0
        var items: [[(NSPasteboard.PasteboardType, Data)]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var pairs: [(NSPasteboard.PasteboardType, Data)] = []
            for type in item.types {
                guard let data = item.data(forType: type) else { return nil }
                total += data.count
                guard total <= Self.maximumSnapshotBytes else { return nil }
                pairs.append((type, data))
            }
            items.append(pairs)
        }
        guard pasteboard.changeCount == version else { return nil }
        return Snapshot(changeCount: version, items: items)
    }

    /// Call synchronously right after `snapshot()`; nothing may suspend in between. Refuses (nil, nothing
    /// cleared) when another application changed the pasteboard after the snapshot.
    func stage(_ text: String, preserving snapshot: Snapshot) -> Staged? {
        guard pasteboard.changeCount == snapshot.changeCount else { return nil }
        unsettled = nil
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            restore(Staged(changeCount: pasteboard.changeCount, snapshot: snapshot))
            return nil
        }
        return Staged(changeCount: pasteboard.changeCount, snapshot: snapshot)
    }

    /// Delivery is unknown: the staged text stays so a late paste still inserts the intended text, and the
    /// user's clipboard is restored by the next confirmed paste, never on a timer.
    func leaveUnsettled(_ staged: Staged) {
        guard stillOwns(staged) else { return }
        unsettled = staged
    }

    /// Copies the target application's selection the way the user's ⌘C would, returns it as plain text and
    /// puts the user's clipboard back. Nil when nothing was copied within the timeout (no selection) or the
    /// clipboard cannot be preserved. The user's clipboard is restored only while it still holds that copy.
    func copySelection(_ postCopy: () -> Void, timeout: TimeInterval = 0.6) async -> String? {
        guard let saved = snapshot() else { return nil }
        let before = pasteboard.changeCount
        postCopy()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while pasteboard.changeCount == before, ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        guard pasteboard.changeCount != before else { return nil }
        let copied = pasteboard.string(forType: .string)
        restore(Staged(changeCount: pasteboard.changeCount, snapshot: saved))
        return copied
    }

    /// True while nothing has replaced the staged payload.
    func stillOwns(_ staged: Staged) -> Bool { pasteboard.changeCount == staged.changeCount }

    /// Restores the user's clipboard only if Clicky still owns it; returns whether it restored.
    @discardableResult
    func restore(_ staged: Staged) -> Bool {
        guard stillOwns(staged) else { return false }
        unsettled = nil
        pasteboard.clearContents()
        let items = staged.snapshot.items.map { pairs -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in pairs { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
        return true
    }
}
