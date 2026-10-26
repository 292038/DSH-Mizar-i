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
//  ## The first decision a wake makes
//
//  A wake that arrives on a phone nobody has opened cannot ask the model whether
//  this phone is paired: `AppModel.start()`, which reads the store, runs from the
//  root view, and a background launch has no view. `host` therefore reads `nil`
//  there whether or not a computer is paired. The outcome is "do not run" either
//  way -- a launch with no screen has no session list, no socket and nothing to
//  refresh -- but the two facts are different sentences in the log, and the log
//  is the only evidence a phone leaves. So the question is asked of the store,
//  and it has three answers rather than two: paired, unpaired, and *not
//  readable*. ``wake(pairing:modelIsLoaded:liveActivitiesEnabled:hasRunningSession:)`` is that
//  decision.
//
//  A wake that cannot run also submits no next request. Every submission is
//  another launch the app may be woken for, and a cold launch never loads the
//  model, so the wake after it would have nothing to do either; the next
//  foreground trip to the background is what asks again.
//
//  The larger saving is the ordinary one: **nothing is running**. A phone in a
//  pocket with no session going neither shows a card nor has a card to keep
//  current, and the next wake could only re-read a session list for a screen
//  nobody is looking at. Those wakes are the ones that cost the most and buy the
//  least -- each one is a process launch the system may kill for taking too long
//  -- so a known "nothing running" stops the chain. A background launch is the
//  one place where asking for less is strictly better, which is why the rule
//  lives here and not in the controller.
//

import Foundation

/// What one background refresh does, and whether there is time for it.
public enum BackgroundSync {
    /// How much of the assertion is kept back from new work.
    ///
    /// Not a guess at how long a request takes: it is the point at which a
    /// request begun now would land after the assertion is gone. Three seconds
    /// is longer than a `session.list` against a computer on the same Wi-Fi and much
    /// shorter than the system's window, which leaves the reserve doing its job
    /// without eating the sync.
    public static let requestReserve: TimeInterval = 3

    /// What is known about this phone's pairing when a wake arrives.
    ///
    /// Three answers, not two. `.unpaired` and `.unknown` look the same to code
    /// that only has a `Bool`, and the difference is a sentence in the log: one
    /// says a phone with no computer was woken, the other says the question has
    /// not been answered yet.
    public enum Pairing: Equatable, Sendable {
        /// A computer is paired.
        case paired
        /// This phone holds no pairing.
        case unpaired
        /// The store could not be read: a keychain that refuses before the first
        /// unlock after a restart, or a read that failed for another reason. Not
        /// the same as "no computer".
        case unknown
    }

    /// What one wake should do.
    public enum Wake: Equatable, Sendable {
        /// Run the refresh. The next wake is asked for first.
        case refresh
        /// Do nothing, submit nothing, and say why.
        ///
        /// No request goes in for any of these: see the note at the top of the
        /// file. The reasons are kept apart because they are what the log says
        /// about a phone nobody watched.
        case skip(SkipReason)

        /// Why a wake cannot run.
        public enum SkipReason: Equatable, Sendable {
            /// No computer is paired.
            case unpaired
            /// The operator switched the Live Activity off.
            case liveActivitiesOff
            /// The pairing could not be read this time.
            case pairingUnknown
            /// The pairing is stored, but this launch has not loaded the model:
            /// no screen has appeared, so `start()` has not run.
            case modelNotLoaded
            /// The list is known and nothing on it is running: there is no card
            /// to keep current and no next wake that could do more.
            case nothingRunning
        }
    }

    /// Whether a background refresh is worth waking for at all.
    ///
    /// The foreground half of ``wake(pairing:modelIsLoaded:liveActivitiesEnabled:hasRunningSession:)``:
    /// there the pairing is known and the model is loaded, because a screen is
    /// running. Both conditions, and the pairing is not redundant. With no
    /// computer there is nothing to ask, and the activity would be drawn from a
    /// cache the app has already put on the island -- a background wake spent on
    /// a refresh of something that cannot have changed.
    ///
    /// - Parameters:
    ///   - paired: whether this phone is paired with a computer.
    ///   - liveActivitiesEnabled: the operator's switch, read at the moment of
    ///     acting rather than remembered from the last foreground refresh.
    ///   - hasRunningSession: whether anything is running that the island could
    ///     draw. See ``Wake/SkipReason/nothingRunning``.
    /// - Returns: whether to run one.
    public static func shouldRun(
        paired: Bool,
        liveActivitiesEnabled: Bool,
        hasRunningSession: Bool,
    ) -> Bool {
        wake(
            pairing: paired ? .paired : .unpaired,
            modelIsLoaded: true,
            liveActivitiesEnabled: liveActivitiesEnabled,
            hasRunningSession: hasRunningSession,
        ) == .refresh
    }

    /// What a wake the system granted should do with it.
    ///
    /// The decision is deliberately not "may I sync" alone: it is also "is this
    /// phone's state known well enough to say why not". Those are different
    /// questions, and the second one is what a log export answers when nobody can
    /// reproduce the wake.
    ///
    /// - Parameters:
    ///   - pairing: what the credentials store says, which on a background
    ///     launch is not what the model says.
    ///   - modelIsLoaded: whether `AppModel.start()` has read the pairing and
    ///     opened the socket. `false` on a launch no screen has appeared in.
    ///   - liveActivitiesEnabled: the operator's switch right now.
    ///   - hasRunningSession: whether a session is running, or `nil` when the
    ///     list has not been read and the count is therefore not an answer. A
    ///     wake that *does* run reads the list, so unknown is a reason to run,
    ///     not to skip: only a known zero means there is nothing to draw.
    /// - Returns: what this wake may do.
    public static func wake(
        pairing: Pairing,
        modelIsLoaded: Bool,
        liveActivitiesEnabled: Bool,
        hasRunningSession: Bool?,
    ) -> Wake {
        guard liveActivitiesEnabled else { return .skip(.liveActivitiesOff) }
        switch pairing {
        case .unpaired:
            return .skip(.unpaired)
        case .unknown:
            return .skip(.pairingUnknown)
        case .paired:
            // Stored but not loaded: a background launch has no screen, so
            // `start()` has not run, and there is no session list, no socket and
            // no model content to refresh. Nothing is wrong; there is just
            // nothing here to do yet.
            guard modelIsLoaded else { return .skip(.modelNotLoaded) }
            // Nothing running, nothing on the island, and nothing the next wake
            // could do that this one cannot: the list would be read for a screen
            // nobody is looking at, and the card (if one is up) is ended by the
            // sync that saw the finish or by the relay's end push. Not asking is
            // the one place this app can spend fewer background launches -- and
            // every launch is a process the system may kill for starting slowly.
            guard hasRunningSession != false else { return .skip(.nothingRunning) }
            return .refresh
        }
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
