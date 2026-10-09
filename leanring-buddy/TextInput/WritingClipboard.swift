import AppKit

/// Controlled paste staging. The user's clipboard is snapshotted in bounded memory, the payload is staged
/// as plain text immediately before Command-V, and the original is restored only while the pasteboard
/// still holds Clicky's staged version. A newer copy by the user or a clipboard manager is never overwritten.
@MainActor
struct WritingClipboard {
    static let maximumSnapshotBytes = 8 * 1_048_576

    struct Snapshot {
        fileprivate let items: [[(NSPasteboard.PasteboardType, Data)]]
    }

    struct Staged {
        let changeCount: Int
        fileprivate let snapshot: Snapshot
    }

    private let pasteboard: NSPasteboard
    init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }

    /// Nil when some item cannot be read back completely (promised/lazy data) or exceeds the bound;
    /// callers then keep a visible Copy alternative instead of silently losing the user's clipboard.
    func snapshot() -> Snapshot? {
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
        return Snapshot(items: items)
    }

    /// Call synchronously right after `snapshot()`; nothing may suspend in between.
    func stage(_ text: String, preserving snapshot: Snapshot) -> Staged? {
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            restore(Staged(changeCount: pasteboard.changeCount, snapshot: snapshot))
            return nil
        }
        return Staged(changeCount: pasteboard.changeCount, snapshot: snapshot)
    }

    /// When consumption is unknown the staged text stays long enough for a slow paste to land, then the user's
    /// clipboard comes back — still only if nothing newer replaced Clicky's version meanwhile.
    func restoreLater(_ staged: Staged, after seconds: TimeInterval = 10) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [pasteboard] in
            MainActor.assumeIsolated { _ = WritingClipboard(pasteboard: pasteboard).restore(staged) }
        }
    }

    /// True while nothing has replaced the staged payload.
    func stillOwns(_ staged: Staged) -> Bool { pasteboard.changeCount == staged.changeCount }

    /// Restores the user's clipboard only if Clicky still owns it; returns whether it restored.
    @discardableResult
    func restore(_ staged: Staged) -> Bool {
        guard stillOwns(staged) else { return false }
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
