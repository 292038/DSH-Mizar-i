//
//  BackgroundSyncTests.swift
//  MizarKitTests
//
//  What a background refresh is allowed to do, and what the island is made of.
//
//  A refresh that runs while the app is off screen has two things it can get
//  wrong, and neither is visible from a screen: it can start work it has no time
//  to finish (the system revokes the assertion and the app is suspended mid
//  request), and it can spend that time on sessions the island cannot draw.
//  Both are decided here, by hand, at instants a test chooses.
//
//  The derivation tests are the other half. The rows on the island are read from
//  two things that arrive at different moments -- the session list, which says
//  what is running, and the phone's own cache, which says what the operator
//  asked and when the turn began -- and the foreground refresh and the
//  background refresh now share that reading rather than each having one.
//

import Foundation
import Testing
@testable import MizarKit

/// A fixed instant, so no test depends on the machine's clock.
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

/// `t0` plus some seconds.
private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

/// A session-list row.
private func row(
    _ id: String,
    running: Bool = true,
    parent: String? = nil,
    origin: String? = nil,
) -> SessionRow {
    SessionRow(
        sessionId: id,
        updatedAt: t0.timeIntervalSince1970 * 1000,
        running: running,
        blank: false,
        agentAvailable: true,
        cwd: "/Users/you/projects/\(id)",
        parentSessionId: parent,
        origin: origin,
    )
}

/// A cached conversation made of turns.
private func cached(_ id: String, _ turns: [ConversationTurn]) -> CachedConversation {
    CachedConversation(
        sessionId: id,
        items: turns.flatMap(\.items),
        throughSeq: 100,
        turns: turns,
    )
}

/// A turn that has started and not ended.
private func runningTurn(
    _ prompt: String,
    began: Date,
    id: String = "turn-prompt",
) -> ConversationTurn {
    ConversationTurn(
        turn: 1,
        prompts: [.message(id: id, role: .user, text: prompt, at: began)],
        steps: [],
        stepCount: 1,
        startedAt: began,
        endedAt: nil,
        endedReason: nil,
        firstSeq: 1,
    )
}

/// A turn that has ended.
private func finishedTurn(
    _ prompt: String,
    began: Date,
    ended: Date,
    id: String = "turn-prompt",
) -> ConversationTurn {
    ConversationTurn(
        turn: 1,
        prompts: [.message(id: id, role: .user, text: prompt, at: began)],
        steps: [],
        stepCount: 1,
        startedAt: began,
        endedAt: ended,
        endedReason: "completed",
        firstSeq: 1,
    )
}

@Suite("A background refresh")
struct BackgroundSyncTests {
    @Test("runs for a paired host with the activity switched on, and for nothing else")
    func wantsAPairingAndTheSwitch() {
        #expect(BackgroundSync.shouldRun(paired: true, liveActivitiesEnabled: true))
        // No Mac: there is nothing to ask, and the activity would be drawn from
        // a cache the app has already put on the island.
        #expect(!BackgroundSync.shouldRun(paired: false, liveActivitiesEnabled: true))
        // The switch is read here as well as at the activity, because waking a
        // suspended process to refresh something the operator has turned off is
        // work done for nobody.
        #expect(!BackgroundSync.shouldRun(paired: true, liveActivitiesEnabled: false))
        #expect(!BackgroundSync.shouldRun(paired: false, liveActivitiesEnabled: false))
    }

    @Test("starts no request with only the reserve left")
    func stopsBeforeTheDeadline() {
        // The whole point of the reserve: a request begun at the deadline is a
        // request the system cancels, and the assertion has then been spent on a
        // socket that was torn down before it answered.
        #expect(BackgroundSync.mayStartRequest(now: t0, expiresAt: at(30)))
        #expect(BackgroundSync.mayStartRequest(now: t0, expiresAt: at(4)))
        // The reserve itself is not enough.
        #expect(!BackgroundSync.mayStartRequest(now: t0, expiresAt: at(BackgroundSync.requestReserve)))
        #expect(!BackgroundSync.mayStartRequest(now: t0, expiresAt: at(1)))
        // An assertion a moment from expiring, or one that already has.
        #expect(!BackgroundSync.mayStartRequest(now: t0, expiresAt: t0))
        #expect(!BackgroundSync.mayStartRequest(now: t0, expiresAt: at(-5)))
    }

    @Test("refreshes the running top-level sessions, in the order the host listed them")
    func picksTheRunningSessions() {
        let sessions = [
            row("s-running", running: true),
            row("s-idle", running: false),
            row("s-child", running: true, parent: "s-running"),
            // A row the host did not give a parent for but called a subagent in
            // its own `origin`. The two marks mean the same thing, and the app
            // has never synced a subagent's page -- a row for one would count
            // from zero for work that may have been going for ten minutes.
            row("s-delegated", running: true, origin: "subagent"),
            row("s-also-running", running: true),
        ]

        #expect(
            BackgroundSync.conversationRefreshTargets(in: sessions)
                == ["s-running", "s-also-running"],
        )
        // Nothing left to do, and nothing invented for it.
        #expect(BackgroundSync.conversationRefreshTargets(in: []).isEmpty)
    }

    @Test("derives the island's rows from the session list and the phone's cache")
    func derivesRowsFromTheListAndTheCache() async {
        let cache = InMemoryConversationCache()
        await cache.save(cached("s-first", [
            finishedTurn("an older prompt", began: at(-900), ended: at(-800)),
            runningTurn("fix the parser", began: at(-134)),
        ]))
        await cache.save(cached("s-second", [
            runningTurn("run the tests", began: at(-60), id: "turn-prompt-2"),
        ]))

        let rows = await RunningSession.running(
            in: [
                row("s-first"),
                row("s-second"),
                row("s-idle", running: false),
                row("s-child", parent: "s-first"),
                // Marked a subagent only in the host's own `origin`. The two
                // marks mean the same thing, and the reading that decides what
                // to refresh already honours both -- a row drawn here and not
                // refreshed there would be a clock on the card that the
                // background sync deliberately never updates.
                row("s-delegated", origin: "subagent"),
            ],
            conversations: cache,
            titles: [:],
            now: t0,
        )

        // The running top-level sessions, in the list's order, seeded from the
        // running turn's own clock: the island shows the two longest first, and
        // the sort is the decision layer's, not this reading's.
        #expect(rows.map(\.id) == ["s-first", "s-second"])
        #expect(rows.map(\.prompt) == ["fix the parser", "run the tests"])
        #expect(rows.map(\.elapsedWhenSeeded) == [134, 60])
        #expect(rows.allSatisfy { $0.seededAt == t0 })
        #expect(rows.map(\.countingSince) == [at(-134), at(-60)])
    }

    @Test("seeds a session the phone has no page for at zero, and claims no prompt")
    func unseenSessionStartsAtZero() async {
        // The row says it is running and the phone has not fetched its page, so
        // there is no figure to seed from and no instruction to show. Counting
        // from the moment the app saw it is the only honest answer; the
        // operator's session id in the prompt's place would be the app talking.
        let rows = await RunningSession.running(
            in: [row("s-unseen")],
            conversations: InMemoryConversationCache(),
            titles: [:],
            now: t0,
        )

        #expect(rows.count == 1)
        #expect(rows.first?.prompt == "")
        #expect(rows.first?.elapsedWhenSeeded == 0)
        #expect(rows.first?.countingSince == t0)
    }

    @Test("shows the last thing the operator said when no turn is running")
    func promptFallsBackToTheLastUserMessage() async {
        // A session that started since the last sync: its `turn/start` is in a
        // page the phone has not fetched, so the cache holds the conversation
        // before it. Its most recent instruction is still the operator's own
        // words, and is better on the card than an empty row.
        let cache = InMemoryConversationCache()
        await cache.save(cached("s-started", [
            finishedTurn("the last thing I asked", began: at(-600), ended: at(-500)),
        ]))

        let rows = await RunningSession.running(
            in: [row("s-started")],
            conversations: cache,
            titles: [:],
            now: t0,
        )

        #expect(rows.first?.prompt == "the last thing I asked")
        // No running turn means no clock to seed from, so the row counts from
        // now rather than from a finished turn's duration.
        #expect(rows.first?.elapsedWhenSeeded == 0)
    }

    @Test("leaves out a cached turn that has ended")
    func finishedTurnDoesNotSeedTheClock() async {
        // The session list and the cache are read at different moments, and the
        // list can say "running" for a turn the cached page already shows as
        // finished. The figure is the older one: `turn/end` is the evidence,
        // and a clock seeded from a turn that ended reports a session that is
        // over as still counting.
        let cache = InMemoryConversationCache()
        await cache.save(cached("s-finished", [
            finishedTurn("tidy up", began: at(-300), ended: at(-120)),
        ]))

        let rows = await RunningSession.running(
            in: [row("s-finished")],
            conversations: cache,
            titles: [:],
            now: t0,
        )

        #expect(rows.first?.elapsedWhenSeeded == 0)
        #expect(rows.first?.prompt == "tidy up")
    }
}
