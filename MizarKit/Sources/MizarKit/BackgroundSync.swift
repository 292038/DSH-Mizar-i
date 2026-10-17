//
//  BackgroundSync.swift
//  MizarKit
//
//  What a refresh may do while the app is off screen, decided without a clock,
//  a screen, or a background task.
//
//  iOS gives an app that has just been backgrounded a short assertion -- about
//  thirty seconds, decided by the system rather than by the app; measured at
//  26.4 s between the assertion being taken and the expiry handler being called
//  on this simulator -- and it takes it back by calling the expiration handler. Two mistakes are possible inside
//  that window, and neither is visible from the app's own screen:
//
//    - **Starting work that cannot finish.** A request begun at the deadline is
//      a request the system cancels, so the assertion is spent on a socket that
//      is torn down before it answers and the island is no fresher than it was.
//      ``mayStartRequest(now:expiresAt:)`` keeps a reserve for exactly that.
//
//    - **Spending it on sessions the island cannot draw.** A subagent has no
//      page on this phone -- the sync fetches top-level sessions only -- so a
//      row for one would count from zero for work that may have been running for
//      minutes. ``conversationRefreshTargets(in:)`` is the same predicate the
//      island's own rows are read with (``SessionRow/isLiveActivityCandidate``),
//      so the two cannot drift apart.
//
//  Nothing here starts a task, asks iOS for time, or talks to ActivityKit. That
//  is the app's side of the wall (`BackgroundRefresh` in the app target), and it
//  is deliberately not in this file: what runs is a decision that can be tested
//  at instants a test chooses, and what it is wrapped in is something only a
//  device can answer.
//

import Foundation

/// What one background refresh does, and whether there is time for it.
public enum BackgroundSync {
    /// How much of the assertion is kept back from new work.
    ///
    /// Not a guess at how long a request takes: it is the point at which a
    /// request begun now would land after the assertion is gone. Three seconds
    /// is longer than a `session.list` against a Mac on the same Wi-Fi and much
    /// shorter than the system's window, which leaves the reserve doing its job
    /// without eating the sync.
    public static let requestReserve: TimeInterval = 3

    /// Whether a background refresh is worth waking for at all.
    ///
    /// - Parameters:
    ///   - paired: whether this phone is paired with a Mac.
    ///   - liveActivitiesEnabled: the operator's switch, read at the moment of
    ///     acting rather than remembered from the last foreground refresh.
    /// - Returns: whether to run one.
    public static func shouldRun(paired: Bool, liveActivitiesEnabled: Bool) -> Bool {
        // Both, and the pairing is not redundant. With no Mac there is nothing
        // to ask, and the activity would be drawn from a cache the app has
        // already put on the island -- a background wake spent on a refresh of
        // something that cannot have changed.
        paired && liveActivitiesEnabled
    }

    /// Whether there is time to begin one more request.
    ///
    /// - Parameters:
    ///   - now: the instant the question is asked.
    ///   - expiresAt: when the app's assertion runs out.
    /// - Returns: whether a request begun now has the reserve left in front of
    ///   it.
    public static func mayStartRequest(now: Date, expiresAt: Date) -> Bool {
        expiresAt.timeIntervalSince(now) > requestReserve
    }

    /// The sessions whose page is worth re-reading, in the order to read them.
    ///
    /// One conversation read per session, so this is also the number of requests
    /// the refresh can make after the list: a phone with eight sessions running
    /// will not spend the whole assertion on them, because the caller asks
    /// ``mayStartRequest(now:expiresAt:)`` before each one and stops when the
    /// answer turns false.
    ///
    /// - Parameter sessions: the session list, as the host last gave it.
    /// - Returns: the ids, in the order the host listed them.
    public static func conversationRefreshTargets(in sessions: [SessionRow]) -> [String] {
        sessions.filter(\.isLiveActivityCandidate).map(\.sessionId)
    }
}
