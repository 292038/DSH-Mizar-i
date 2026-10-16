//
//  LiveActivity.swift
//  MizarKit
//
//  What the Live Activity shows, decided without a screen, a clock, or
//  ActivityKit.
//
//  The activity is drawn in another process. The widget extension is handed the
//  activity's `ContentState` and nothing else -- no model, no connection, no
//  cache -- so everything the two processes have to agree on is a value: the
//  rows, the elapsed times, and whether the activity should still be up at all.
//  That is this file, and it is why every type here is `Codable` and `Sendable`.
//
//  The clock belongs to the operator's arrangement rather than to the host: the
//  island counts the elapsed time of the session that has been running longest,
//  seeded from the last figure the app read off the host -- the
//  "深度求索中，用时 xx 分 xx 秒" of the running turn's own row -- and then
//  ticked by whoever is drawing it. **Nothing re-syncs it.** A clock that asked
//  the Mac for the time every second would stop telling the time whenever the
//  link hiccuped, which on a phone is constant; the running row in the app
//  already makes that argument for itself.
//
//  Nothing here reads the clock either. `now` is a parameter to every function
//  that needs one, which is what lets the whole thing be tested at instants the
//  test chooses.
//
//  The title row the expanded card draws -- the app icon and the literal
//  "DSH-Mizar" -- is not here on purpose. It is the same on every activity this
//  app will ever post, so it is a fact about the widget rather than about any
//  session, and state that never varies is state that can only go stale.
//

import Foundation

/// One session that is running, as the app last saw it.
///
/// The app builds one of these per running turn in its conversation cache: the
/// instruction is that turn's most recent prompt, and the two clock fields are
/// the figure the host last gave for the turn and the moment it arrived.
public struct RunningSession: Codable, Sendable, Equatable, Identifiable {
    /// The session.
    ///
    /// Opaque here, and it becomes a row's identity: the widget keys its rows on
    /// it, so it has to be the same string every time the same session is
    /// passed.
    public let id: String
    /// The operator's most recent instruction to that session, whole.
    ///
    /// Cut to size when a row is built; see
    /// ``LiveActivityDecision/promptSnippetLength``.
    public let prompt: String
    /// How long the session had been running when the app last read the host.
    ///
    /// The figure behind "深度求索中，用时 xx 分 xx 秒", and the only measurement
    /// this clock ever gets. Not optional: a row on a card has to say something,
    /// so a session whose figure never arrived is seeded with zero and counts
    /// from the moment the app saw it.
    public let elapsedWhenSeeded: TimeInterval
    /// When that figure was read.
    public let seededAt: Date

    /// - Parameters:
    ///   - id: the session.
    ///   - prompt: the operator's most recent instruction to it.
    ///   - elapsedWhenSeeded: how long it had been running at `seededAt`.
    ///   - seededAt: when that figure was read.
    public init(id: String, prompt: String, elapsedWhenSeeded: TimeInterval, seededAt: Date) {
        self.id = id
        self.prompt = prompt
        self.elapsedWhenSeeded = elapsedWhenSeeded
        self.seededAt = seededAt
    }

    /// The instant this session's clock counts from.
    ///
    /// The host's figure and the moment it arrived say the same thing as an
    /// instant -- a session the host said had been running two minutes when the
    /// app read it at 10:00 began at 09:58 -- and the instant is what the
    /// ticking and the ordering both use.
    public var countingSince: Date { seededAt.addingTimeInterval(-elapsedWhenSeeded) }

    /// How long the session has been running at `now`.
    ///
    /// Clamped at zero: the figure is the host's and the clock is the phone's,
    /// and the two can disagree about an instant in the near future. A row
    /// reading "-2 s" would be worse than one reading "0 s".
    ///
    /// - Parameter now: the instant to measure to.
    /// - Returns: the elapsed time.
    public func elapsed(asOf now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(countingSince))
    }
}

/// One running session as a row of the expanded activity.
///
/// Both the elapsed time and the instant it counts from are carried, rather
/// than only one of them: the number is what the row reads at the moment the
/// app made it, and the instant is what the widget's own ticking text counts
/// from, so a second can pass on the lock screen without the app being asked
/// for anything.
public struct LiveActivityRow: Codable, Sendable, Equatable, Identifiable {
    /// The session this row is about.
    public let id: String
    /// The operator's instruction, already cut short.
    public let prompt: String
    /// How long the session had been running when the row was built.
    public let elapsed: TimeInterval
    /// The instant ``elapsed`` was measured from.
    public let countingSince: Date

    /// - Parameters:
    ///   - id: the session.
    ///   - prompt: the instruction, cut short for the row.
    ///   - elapsed: how long it has been running.
    ///   - countingSince: the instant that count started at.
    public init(id: String, prompt: String, elapsed: TimeInterval, countingSince: Date) {
        self.id = id
        self.prompt = prompt
        self.elapsed = elapsed
        self.countingSince = countingSince
    }
}

/// What the activity is showing.
///
/// This is the value an activity's `ContentState` holds. The widget draws it and
/// decides nothing: which of the two it is *is* the difference between a clock
/// and a green check.
public enum LiveActivityPhase: Codable, Sendable, Equatable {
    /// At least one session is running: the longest-running one first, one row
    /// or two.
    case running(rows: [LiveActivityRow])
    /// Nothing is running, so nothing is counting.
    case finished

    /// The rows to draw, empty when nothing is running.
    public var rows: [LiveActivityRow] {
        if case .running(let rows) = self { return rows }
        return []
    }

    /// The time on the island's right side: the clock of the session that has
    /// been running longest, which is the first row's.
    ///
    /// Derived rather than stored, and `nil` once nothing is running. A second
    /// copy of a number is a second number that can disagree with the first.
    public var headline: TimeInterval? { rows.first?.elapsed }
}

/// What the activity should be showing, and whether it should still be up.
///
/// The contract the app is expected to keep, in full:
///
/// - ``phase`` `.running` means start an activity if there is none, and update
///   the one there is otherwise.
/// - ``phase`` `.finished` means the island shows a check, and no activity may
///   be *started* from it: the finished state is over the moment it is taken
///   down, and a check for a session that ended an hour ago is not worth a
///   second look.
/// - ``shouldDismiss`` means end the activity now.
public struct LiveActivityDecision: Codable, Sendable, Equatable {
    /// What to draw.
    public let phase: LiveActivityPhase
    /// Whether the activity should be ended.
    public let shouldDismiss: Bool

    /// - Parameters:
    ///   - phase: what to draw.
    ///   - shouldDismiss: whether to end the activity.
    public init(phase: LiveActivityPhase, shouldDismiss: Bool) {
        self.phase = phase
        self.shouldDismiss = shouldDismiss
    }

    /// How many rows the expanded activity shows.
    ///
    /// Two, and no more, however many sessions are running. They are the two
    /// that have been running longest, because that is where the attention is:
    /// the operator wants to know about the work that is taking a while.
    public static let maximumRows = 2

    /// How much of an instruction a row shows before it is cut short.
    ///
    /// Deliberately tiny. The rows are the identity of two sessions on a
    /// lock-screen card, and the width they have is a card's: an instruction
    /// long enough to read as a sentence wraps, and two wrapped rows push the
    /// clock off the card. A few characters are enough to tell "fix the parser"
    /// from "run the tests", which is all a row has to do.
    public static let promptSnippetLength = 8

    /// Read the running sessions and say what the activity should show.
    ///
    /// The whole state machine, and the only thing the app has to call: once
    /// when a session starts or ends, once when the app comes to the foreground,
    /// and once whenever it is about to touch the activity.
    ///
    /// The preference on the settings screen is not an input. Whether an
    /// activity may run at all is the app's question, asked before this one;
    /// this function answers what an activity would show if there were one.
    ///
    /// - Parameters:
    ///   - sessions: the paired sessions that are running right now, in any
    ///     order. A session that is not running is not passed: an activity has
    ///     nothing to say about one.
    ///   - appOpenedSinceLastFinish: whether the operator has opened the app
    ///     since the last running session ended, **and the activity has not been
    ///     taken down for it yet**. The app owns this flag -- set when it comes
    ///     to the foreground, cleared when it acts on a dismissal -- and the
    ///     clearing is what makes the dismissal happen once. Left set, it would
    ///     take the next session to finish down the instant it did, with nobody
    ///     there to have seen the check.
    ///   - now: the instant to measure the clocks to.
    /// - Returns: what to show, and whether to end the activity.
    public static func make(
        sessions: [RunningSession],
        appOpenedSinceLastFinish: Bool,
        now: Date,
    ) -> LiveActivityDecision {
        let rows = sessions
            .sorted(by: longestRunningFirst)
            .prefix(maximumRows)
            .map { session in
                LiveActivityRow(
                    id: session.id,
                    prompt: snippet(session.prompt),
                    elapsed: session.elapsed(asOf: now),
                    countingSince: session.countingSince,
                )
            }
        guard !rows.isEmpty else {
            // Nothing is running: the island stops counting and shows the check,
            // and the check stays until the app is opened -- which is what the
            // flag says, and the only thing that takes a finished activity down.
            return LiveActivityDecision(phase: .finished, shouldDismiss: appOpenedSinceLastFinish)
        }
        return LiveActivityDecision(phase: .running(rows: rows), shouldDismiss: false)
    }

    /// The session that has been running longest, first.
    ///
    /// Ordered by the instant each clock counts from rather than by the elapsed
    /// time at `now`. Every clock here advances at the same rate, so the two
    /// give the same order -- but the instant cannot move while the sessions do
    /// not, and that is the property the card needs: rows that swap places on
    /// their own are rows the operator cannot follow.
    ///
    /// Sessions that count from the very same instant fall back to their ids, so
    /// the order is a total one and two runs over the same sessions cannot
    /// disagree about it.
    private static func longestRunningFirst(_ left: RunningSession, _ right: RunningSession) -> Bool {
        if left.countingSince != right.countingSince {
            return left.countingSince < right.countingSince
        }
        return left.id < right.id
    }

    /// The first few characters of an instruction, with an ellipsis when it was
    /// cut.
    ///
    /// `prefix` counts what a reader counts -- one CJK character is one, one
    /// emoji is one -- so the cut falls on a boundary rather than inside a
    /// composed glyph.
    ///
    /// An instruction the app does not have comes back as nothing at all: a page
    /// can be cut across a turn, and a row that then says only how long is true,
    /// where the session id in the operator's place would be the app talking.
    private static func snippet(_ prompt: String) -> String {
        guard prompt.count > promptSnippetLength else { return prompt }
        return prompt.prefix(promptSnippetLength) + "…"
    }
}
