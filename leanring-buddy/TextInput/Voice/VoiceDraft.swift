import Foundation
#if canImport(ClickyCore)
import ClickyCore
#endif

/// Where voice text landed inside the Quick Ask draft (UTF-16 offsets), what it holds and the original transcript.
struct VoiceDraftSpan: Equatable {
    var start: Int
    var text: String
    var raw: String
}

/// Pure rules for placing voice text in a draft: never overwrite, never reorder, never submit.
enum VoiceDraftPlacement {
    /// An empty draft receives the text; anything already written stays in place and the text goes on a new line after it.
    static func place(text: String, raw: String, in draft: inout String) -> VoiceDraftSpan {
        guard !draft.isEmpty else {
            draft = text
            return VoiceDraftSpan(start: 0, text: text, raw: raw)
        }
        let separator = draft.hasSuffix("\n") ? "" : "\n"
        let start = (draft + separator).utf16.count
        draft += separator + text
        return VoiceDraftSpan(start: start, text: text, raw: raw)
    }

    /// The span's current range, only while the draft still holds exactly what was placed there.
    static func range(of span: VoiceDraftSpan, in draft: String) -> Range<String.Index>? {
        let utf16 = draft.utf16
        guard let lower = utf16.index(utf16.startIndex, offsetBy: span.start, limitedBy: utf16.endIndex),
              let upper = utf16.index(lower, offsetBy: span.text.utf16.count, limitedBy: utf16.endIndex),
              let start = lower.samePosition(in: draft), let end = upper.samePosition(in: draft),
              draft[start..<end] == span.text else { return nil }
        return start..<end
    }

    static func canUseOriginal(_ span: VoiceDraftSpan?, in draft: String) -> Bool {
        guard let span, span.text != span.raw else { return false }
        return range(of: span, in: draft) != nil
    }

    /// Swaps exactly the placed span for the original transcript; refuses (nil) when the user edited it.
    static func useOriginal(_ span: VoiceDraftSpan, in draft: inout String) -> VoiceDraftSpan? {
        guard span.text != span.raw, let range = range(of: span, in: draft) else { return nil }
        draft.replaceSubrange(range, with: span.raw)
        return VoiceDraftSpan(start: span.start, text: span.raw, raw: span.raw)
    }

    /// Short explanation shown beside the draft, and whether it offers "Use original".
    static func note(text: String, raw: String, concerns: [CleanupConcern], cleanupFailed: Bool) -> (note: String?, offersOriginal: Bool) {
        if cleanupFailed { return ("Cleanup failed — original kept", false) }
        if text == raw { return (concerns.isEmpty ? nil : "Cleanup changed meaning — kept original", false) }
        return (concerns.isEmpty ? "Cleaned up" : "Cleaned up — check the changes", true)
    }
}
