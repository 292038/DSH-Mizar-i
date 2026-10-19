//
//  ActivityFeed.swift
//  MizarKit
//
//  The running turn's process details, as the phone accumulates them.
//
//  `session.activity` answers one window at a time: the newest few dozen rows,
//  and then older pages when the operator scrolls back. The screen draws what
//  this feed holds, not what the last answer held -- replacing the list on every
//  poll would (and did) re-animate every row once a second, and it throws away
//  the pages the operator asked for the moment the poll lands again.
//
//  So the phone keeps a feed per session and applies three rules:
//
//    - **the newest window merges into the feed**, appending only rows not
//      already held. The tail is always the host's latest word;
//    - **older pages prepend**, and never overwrite the newer rows; the cursor
//      for the next page moves backwards with each page;
//    - **no progress ends the walk.** An older host ignores `beforeSeq` and
//      answers the newest window again; every id is already known, so the feed
//      stops asking instead of looping for ever.
//
//  Pure on purpose: the merge rules are where the bugs live, and they can be
//  tested without a socket, a screen or a clock. ``updated`` tells the caller
//  whether a redraw is warranted.
//

import Foundation

/// One session's running-turn details, oldest first, growing in both directions.
public struct ActivityFeed: Sendable, Equatable {
    /// The turn these details belong to.
    ///
    /// A different turn is a different feed. A turn number is the host's own and
    /// is stable for the life of the turn, which is what makes "the ID changed"
    /// answerable at all.
    public let turn: Int

    /// The rows held, oldest first.
    public private(set) var entries: [ActivityEntry]

    /// Whether older rows may still exist on the host.
    public private(set) var hasOlder: Bool

    /// The log position to ask for next, or `nil` when there is nothing to ask.
    ///
    /// Taken from the host's `oldestSeq` for the page it last read; the oldest
    /// held entry's own seq is the fallback for a host that does not send one.
    public private(set) var olderCursor: Int?

    /// How many rows are kept at most.
    ///
    /// A turn can run for hours. The tail is what the operator watches, and the
    /// pages they scrolled back through are the least valuable; past this cap the
    /// oldest held rows are dropped and the walk back stops, rather than the
    /// phone growing without bound.
    public let capacity: Int

    /// The default cap on held rows.
    public static let maximumEntries = 1_500

    /// Whether the walk back has ended: the turn's beginning was reached, or a
    /// page made no progress.
    private var exhausted: Bool

    /// Start a feed from the first (newest) answer.
    ///
    /// - Parameters:
    ///   - latest: a forward `session.activity` answer.
    ///   - capacity: the most rows to hold. The default is fine for the app; a
    ///     test passes a small one to reach the cap without 1,500 rows.
    /// - Returns: the feed, or `nil` when the answer says nothing is running.
    public init?(latest: SessionActivityResult, capacity: Int = ActivityFeed.maximumEntries) {
        guard let turn = latest.turn else { return nil }
        let capacity = max(1, capacity)
        self.turn = turn
        self.capacity = capacity
        entries = latest.entries.count > capacity
            ? Array(latest.entries.suffix(capacity))
            : latest.entries
        hasOlder = latest.hasMore
        // The oldest *row held*, not the page's oldest record. The host caps a
        // page from the newest end, so a trimmed page has rows between the
        // returned window and the page boundary; paging from the boundary would
        // skip them. The oldest returned row's own seq is always the correct
        // place to continue from.
        olderCursor = entries.first?.seq ?? latest.oldestSeq
        exhausted = false
        if entries.count >= capacity, latest.entries.count > capacity {
            // Already at the cap before a single page was read: nothing older
            // can be held, so do not offer to fetch it.
            hasOlder = false
            olderCursor = nil
            exhausted = true
        }
    }

    /// Fold a newest-window answer into the feed.
    ///
    /// - Parameter latest: a forward answer for the same running turn.
    /// - Returns: whether the held rows or the paging state changed.
    @discardableResult
    public mutating func merge(latest: SessionActivityResult) -> Bool {
        // A newest-window answer for another turn is not this feed's to merge;
        // the caller resets the feed when the turn changes. Guarding here too
        // keeps a mis-routed answer from mixing two turns' processes.
        guard latest.turn == turn else { return false }

        let known = Set(entries.map(\.id))
        let fresh = latest.entries.filter { !known.contains($0.id) }
        if !fresh.isEmpty {
            entries.append(contentsOf: fresh)
        }
        if olderCursor == nil, !exhausted {
            olderCursor = entries.first?.seq ?? latest.oldestSeq
        }
        if !exhausted, latest.hasMore {
            hasOlder = true
        }
        trimToCapacity()
        return !fresh.isEmpty
    }

    /// Fold an older-page answer into the feed, in front of what is held.
    ///
    /// - Parameter older: a backwards answer for the same running turn.
    /// - Returns: whether the page added any row. `false` means the walk back is
    ///   over -- an old host that ignored the page request, the start of the
    ///   turn, or a host that answered with rows already held.
    @discardableResult
    public mutating func prepend(older: SessionActivityResult) -> Bool {
        guard older.turn == turn else {
            // Not this turn's page. Nothing to add, and asking again would get
            // the same answer.
            exhausted = true
            hasOlder = false
            olderCursor = nil
            return false
        }
        let known = Set(entries.map(\.id))
        var fresh = older.entries.filter { !known.contains($0.id) }
        // Keep the rows closest to what is already held: when an old page would
        // put the feed over its cap, the oldest rows are the ones nobody is
        // going to scroll back to.
        let room = max(0, capacity - entries.count)
        if fresh.count > room {
            fresh = Array(fresh.suffix(room))
        }
        let grew = !fresh.isEmpty
        if grew {
            entries.insert(contentsOf: fresh, at: 0)
        }
        if grew {
            // Fresh is in page order, so its first row is the oldest row the
            // host just returned: the next page starts in front of it, which is
            // also in front of anything the host's cap trimmed from the page.
            olderCursor = fresh.first?.seq ?? older.oldestSeq
            hasOlder = older.hasMore
            if !hasOlder || entries.count >= capacity {
                // The walk back is over: the turn's beginning was reached (or
                // the feed is full). Later polls must not re-open it just
                // because the newest window keeps saying older rows exist --
                // the window always says that while the turn runs, and asking
                // again would walk the operator through the whole history for
                // nothing.
                hasOlder = false
                olderCursor = nil
                exhausted = true
            }
        } else {
            // No progress: an old host answered the newest window again, or the
            // walk reached the turn's beginning. Stop.
            exhausted = true
            hasOlder = false
            olderCursor = nil
        }
        return grew
    }

    /// Whether the caller may ask for an older page now.
    public var canLoadOlder: Bool {
        hasOlder && olderCursor != nil && !exhausted
    }

    // MARK: - Internals

    /// Drop the oldest rows once the feed is over its cap.
    private mutating func trimToCapacity() {
        guard entries.count > capacity else { return }
        entries.removeFirst(entries.count - capacity)
        // The rows the cursor pointed at may have just been dropped, and no more
        // are held before them.
        exhausted = true
        hasOlder = false
        olderCursor = nil
    }
}
