import Foundation

/// Identifies the counting rules a source's stored daily history was produced under.
///
/// Daily history is a floor: a collection never replaces a day with a smaller total, and never deletes a stored
/// day the collector no longer reports (ADR-0008). Bump a source's revision here in a release that intentionally
/// lowers or moves already-counted usage (a deduplication fix, a date-attribution fix). The next collection for
/// that source then rebaselines the days after the earliest day it reports, instead of holding the old floor
/// forever. tokscale-collected sources also carry the pinned engine version, so an engine upgrade rebaselines
/// their recent days.
public enum HistoryEpochs {
    /// Every source starts at revision 1; only an intentional correction changes this table. Devin moves to 2
    /// because its turns are now dated by the request stamp rather than the row write time, which shifts usage
    /// between local days (ADR-0009). Antigravity moves to 2 because it no longer counts the fixed per-model
    /// preamble as input, which lowers already-counted tokens (ADR-0009). Cursor is listed at its first revision
    /// so the account-scoped collector's epoch is visible here rather than implied. Devin and Antigravity move to 3
    /// because a store upgraded to schema 3 recorded revision 2 without rebaselining, so those corrections never
    /// replaced the older, larger days; revision 3 applies them once. Devin moves to 4 because build 28 re-stored its
    /// unchanged cached rows under revision 3 without rebaselining; collection stamps now carry the epoch.
    private static let revisions: [String: Int] = ["devin": 4, "antigravity": 3, "cursor": 1]

    public static func epoch(for sourceID: String) -> String {
        let revision = revisions[sourceID] ?? 1
        // A source that leaves `TokscaleCollector.defaultSourceIDs` for a native collector also loses the
        // engine suffix, so its stored epoch changes and the next collection rebaselines without a bump.
        guard TokscaleCollector.defaultSourceIDs.contains(sourceID) else { return String(revision) }
        return "\(revision)+tokscale-\(TokscaleCollector.engineVersion)"
    }
}
