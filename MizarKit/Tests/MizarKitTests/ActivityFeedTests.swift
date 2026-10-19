//
//  ActivityFeedTests.swift
//  MizarKitTests
//
//  The accumulation rules for the running turn's full detail.
//
//  The two reported defects this exists for: the detail area re-waterfalls the
//  whole list on every open (so a long turn takes seconds to fill), and every
//  poll replaces the list instead of adding to it. The merge/prepend rules are
//  pure, so the behaviour is pinned here instead of in a simulator: a newest
//  window appends only what is new, an older page prepends without disturbing the
//  tail, an old host that ignores paging ends the walk instead of looping, and a
//  different turn starts over.
//

import Foundation
import Testing

@testable import MizarKit

struct ActivityFeedTests {
    /// One row with a stable id and seq.
    private static func row(_ seq: Int) -> ActivityEntry {
        ActivityEntry(
            id: "seq-\(seq)",
            seq: seq,
            kind: .command,
            title: "Bash",
            text: "step \(seq)",
        )
    }

    /// A forward (newest-window) answer.
    private static func newestWindow(
        _ seqs: [Int],
        turn: Int? = 4,
        hasMore: Bool = false,
        oldestSeq: Int? = nil,
    ) -> SessionActivityResult {
        SessionActivityResult(
            sessionId: "s1",
            asOfSeq: 100,
            turn: turn,
            entries: seqs.map(row),
            hasMore: hasMore,
            oldestSeq: oldestSeq ?? seqs.first,
        )
    }

    /// A backwards (older-page) answer.
    private static func olderPage(
        _ seqs: [Int],
        turn: Int? = 4,
        hasMore: Bool = false,
        oldestSeq: Int? = nil,
    ) -> SessionActivityResult {
        SessionActivityResult(
            sessionId: "s1",
            asOfSeq: 100,
            turn: turn,
            entries: seqs.map(row),
            hasMore: hasMore,
            oldestSeq: oldestSeq ?? seqs.first,
        )
    }

    @Test("no running turn means no feed")
    func noTurnNoFeed() {
        let result = SessionActivityResult(sessionId: "s1", turn: nil, entries: [])
        #expect(ActivityFeed(latest: result) == nil)
    }

    @Test("the first answer seeds the feed and the paging cursor")
    func seedsFromTheNewestWindow() throws {
        let feed = try #require(ActivityFeed(latest: Self.newestWindow([10, 11, 12], hasMore: true, oldestSeq: 10)))
        #expect(feed.turn == 4)
        #expect(feed.entries.map(\.id) == ["seq-10", "seq-11", "seq-12"])
        #expect(feed.hasOlder)
        #expect(feed.olderCursor == 10)
        #expect(feed.canLoadOlder)
    }

    @Test("a newest window appends only the rows it has not held")
    func mergeAppendsOnlyNewTail() throws {
        var feed = try #require(ActivityFeed(latest: Self.newestWindow([10, 11])))
        let changed = feed.merge(latest: Self.newestWindow([11, 12, 13]))
        #expect(changed)
        // Oldest first, no duplicate of 11: the poll is a window, not a page.
        #expect(feed.entries.map(\.id) == ["seq-10", "seq-11", "seq-12", "seq-13"])
    }

    @Test("a poll that repeats what is held changes nothing")
    func mergeOfTheSameWindowIsQuiet() throws {
        var feed = try #require(ActivityFeed(latest: Self.newestWindow([10, 11, 12])))
        let changed = feed.merge(latest: Self.newestWindow([10, 11, 12]))
        #expect(!changed)
        #expect(feed.entries.count == 3)
    }

    @Test("a newest window for another turn is not merged")
    func mergeRefusesAnotherTurn() throws {
        var feed = try #require(ActivityFeed(latest: Self.newestWindow([10])))
        let merged = feed.merge(latest: Self.newestWindow([20], turn: 5))
        #expect(!merged)
        #expect(feed.entries.map(\.id) == ["seq-10"])
    }

    @Test("an older page goes in front and moves the cursor back")
    func prependMovesTheCursorBack() throws {
        var feed = try #require(ActivityFeed(latest: Self.newestWindow([10, 11], hasMore: true, oldestSeq: 10)))
        let grew = feed.prepend(older: Self.olderPage([7, 8, 9], hasMore: true, oldestSeq: 7))
        #expect(grew)
        #expect(feed.entries.map(\.id) == ["seq-7", "seq-8", "seq-9", "seq-10", "seq-11"])
        #expect(feed.olderCursor == 7)
        #expect(feed.hasOlder)
    }

    @Test("a newest window after an older page keeps the older rows and the paging state")
    func mergeAfterPagingKeepsOlderRows() throws {
        var feed = try #require(ActivityFeed(latest: Self.newestWindow([10, 11], hasMore: true, oldestSeq: 10)))
        feed.prepend(older: Self.olderPage([7, 8, 9], hasMore: true, oldestSeq: 7))
        // The next poll's window still starts at 10 in this fixture; nothing new.
        let merged = feed.merge(latest: Self.newestWindow([10, 11]))
        #expect(!merged)
        #expect(feed.entries.map(\.id) == ["seq-7", "seq-8", "seq-9", "seq-10", "seq-11"])
        #expect(feed.olderCursor == 7, "the newest window's cursor overwrote the older page's")
    }

    @Test("a page that adds nothing ends the walk instead of looping")
    func noProgressStops() throws {
        // The old-host case: `beforeSeq` ignored, the newest window answered.
        var feed = try #require(ActivityFeed(latest: Self.newestWindow([10, 11], hasMore: true, oldestSeq: 10)))
        let grew = feed.prepend(older: Self.olderPage([10, 11], hasMore: true, oldestSeq: 10))
        #expect(!grew)
        #expect(!feed.hasOlder)
        #expect(!feed.canLoadOlder)
        #expect(feed.olderCursor == nil)
        // And a later poll must not re-enable paging just because the host keeps
        // saying more rows exist.
        _ = feed.merge(latest: Self.newestWindow([10, 11, 12], hasMore: true, oldestSeq: 10))
        #expect(!feed.canLoadOlder)
    }

    @Test("a page past the turn's beginning ends the walk")
    func emptyPageStops() throws {
        var feed = try #require(ActivityFeed(latest: Self.newestWindow([10], hasMore: true, oldestSeq: 10)))
        let grew = feed.prepend(older: Self.olderPage([], hasMore: false, oldestSeq: 3))
        #expect(!grew)
        #expect(!feed.canLoadOlder)
    }

    @Test("reaching the turn's beginning ends the walk for good")
    func reachingTheStartEndsPaging() throws {
        var feed = try #require(ActivityFeed(latest: Self.newestWindow([10, 11], hasMore: true, oldestSeq: 10)))
        let grew = feed.prepend(older: Self.olderPage([7, 8, 9], hasMore: false, oldestSeq: 7))
        #expect(grew)
        #expect(!feed.canLoadOlder)
        // The still-running turn's newest window keeps saying older rows exist
        // (the host page is trimmed); that must not re-open a walk that has
        // already reached the turn's start.
        _ = feed.merge(latest: Self.newestWindow([10, 11, 12], hasMore: true, oldestSeq: 10))
        #expect(!feed.canLoadOlder)
    }

    @Test("the feed is capped, and the cap ends the walk")
    func capacityKeepsTheTail() throws {
        var feed = try #require(ActivityFeed(latest: Self.newestWindow([10, 11, 12]), capacity: 5))
        feed.merge(latest: Self.newestWindow([10, 11, 12, 13, 14, 15]))
        // The oldest rows are dropped; the newest are what the operator watches.
        #expect(feed.entries.map(\.id) == ["seq-11", "seq-12", "seq-13", "seq-14", "seq-15"])
        #expect(!feed.canLoadOlder)
        // A prepend past the cap has no room and does not grow the feed.
        let grew = feed.prepend(older: Self.olderPage([1, 2, 3], hasMore: true))
        #expect(!grew)
        #expect(feed.entries.map(\.id) == ["seq-11", "seq-12", "seq-13", "seq-14", "seq-15"])
    }

    @Test("a page with fewer rows than the cap is prepended whole")
    func prependKeepsEverythingWhenThereIsRoom() throws {
        var feed = try #require(ActivityFeed(latest: Self.newestWindow([10, 11]), capacity: 30))
        let grew = feed.prepend(older: Self.olderPage([7, 8, 9], hasMore: true))
        #expect(grew)
        #expect(feed.entries.map(\.id) == ["seq-7", "seq-8", "seq-9", "seq-10", "seq-11"])
    }

    @Test("the cursor is the oldest held row, not the page boundary")
    func cursorUsesOldestHeldRow() throws {
        // The host caps a page from its newest end: the page began at seq 3 but
        // the returned window starts at 10. Paging from 3 would skip 4...9, so
        // the oldest returned row's own seq is the cursor.
        let result = SessionActivityResult(
            sessionId: "s1",
            turn: 4,
            entries: [Self.row(10), Self.row(11)],
            hasMore: true,
            oldestSeq: 3,
        )
        let feed = try #require(ActivityFeed(latest: result))
        #expect(feed.olderCursor == 10)
    }

    @Test("a page's cursor is its oldest returned row, not the page boundary")
    func pageCursorUsesOldestReturnedRow() throws {
        var feed = try #require(ActivityFeed(latest: Self.newestWindow([20, 21], hasMore: true, oldestSeq: 20)))
        let grew = feed.prepend(older: Self.olderPage([10, 11, 12], hasMore: true, oldestSeq: 3))
        #expect(grew)
        #expect(feed.olderCursor == 10)
    }

    @Test("a fallback cursor comes from the oldest row when the host names none")
    func fallbackCursorFromOldestRow() throws {
        // An older host sends no `oldestSeq`; the oldest held row's own seq is
        // the only position the phone can page from.
        let result = SessionActivityResult(
            sessionId: "s1",
            turn: 4,
            entries: [Self.row(30), Self.row(31)],
            hasMore: true,
        )
        let feed = try #require(ActivityFeed(latest: result))
        #expect(feed.olderCursor == 30)
    }
}
