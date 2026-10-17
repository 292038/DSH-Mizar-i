//
//  RunningPoll.swift
//  MizarKit
//
//  When the foreground should keep asking, decided without a clock or a screen.
//
//  The report this answers: a turn is sent from the phone (or from the Mac, with
//  the phone watching), the session list says it is running, and the operator
//  leaves the conversation open. The turn finishes ten seconds later and the
//  screen keeps saying it is running until somebody pulls to refresh. Nothing
//  was wrong with any single read -- the app had simply stopped reading. The
//  poll that follows a send gives up once the sent prompt has arrived, and the
//  only other timer is for pending interactions, which has nothing to say about
//  a turn ending.
//
//  So there is one more poll, and it exists **only while something is running**.
//  That is the whole design, and it is a decision rather than an implementation
//  detail: a poll that runs all the time is a phone that asks its Mac a question
//  every ten seconds for a day of not being used. The rules are:
//
//    - start when a session-list read says at least one session is running,
//    - stop as soon as a read says none is,
//    - stop while the app is not active, because a backgrounded phone costs
//      nothing and iOS suspends the process anyway,
//    - and never start a second one while the first is up.
//
//  Nothing here sleeps, owns a task, or knows about a screen. ``RunningPoll`` is
//  the state machine the app's one task is started and stopped by, so the rules
//  are tested at transitions a test chooses rather than by waiting ten seconds
//  against a simulator.
//

import Foundation

/// Whether the foreground poll should be up, and what to do about the one task.
///
/// A value rather than a set of free functions because "is one already running"
/// is part of the decision: two readers on the session list must not each start
/// a poll, and a poll that is already up must not be restarted by the next read
/// -- restarting it would reset the ten-second clock on every refresh the
/// operator makes by hand, so the tick could be postponed for ever.
public struct RunningPoll: Sendable, Equatable {
    /// What the caller should do to its one poll task.
    public enum Action: Sendable, Equatable {
        /// Nothing is polling and something is running: start the task.
        case start
        /// The task is up and no longer wanted: cancel it.
        case stop
        /// Already in the right state. Nothing to do.
        case none
    }

    /// How long between ticks.
    ///
    /// Ten seconds, and not a number chosen for a spinner: it is short enough
    /// that a turn ending is noticed while the operator is still looking at the
    /// screen, and long enough that an hour of a running session costs 360
    /// `session.list` reads rather than a request per second. The post-send poll
    /// covers the first few seconds after a prompt, when the host records it;
    /// this covers the rest of the turn.
    public static let interval: Duration = .seconds(10)

    /// Whether a poll task is up. Kept in step with the caller's task through
    /// ``observe(anySessionRunning:appIsActive:)``.
    public private(set) var isPolling = false

    public init() {}

    /// Whether a poll is wanted at all, ignoring what is already running.
    ///
    /// - Parameters:
    ///   - anySessionRunning: whether the session list's latest read says a turn
    ///     is executing.
    ///   - appIsActive: whether the app is on screen. A poll while the process
    ///     is suspended never fires, and one that starts the instant the app
    ///     comes back would ask before the foreground refresh has a chance to.
    /// - Returns: whether one should be up.
    public static func shouldPoll(anySessionRunning: Bool, appIsActive: Bool) -> Bool {
        anySessionRunning && appIsActive
    }

    /// Take one observation and say what the caller should do to its task.
    ///
    /// This is the single instance rule: with the poll already up, an observation
    /// that still wants one answers `.none`, never `.start`. The caller still
    /// holds one task property, so the answer and the task cannot disagree even
    /// when a cancelled task has not noticed yet.
    ///
    /// - Parameters:
    ///   - anySessionRunning: whether any row in the latest session list says a
    ///     turn is executing.
    ///   - appIsActive: whether the app is on screen.
    /// - Returns: the transition, if there is one.
    public mutating func observe(anySessionRunning: Bool, appIsActive: Bool) -> Action {
        let wanted = Self.shouldPoll(anySessionRunning: anySessionRunning, appIsActive: appIsActive)
        switch (wanted, isPolling) {
        case (true, false):
            isPolling = true
            return .start
        case (false, true):
            isPolling = false
            return .stop
        default:
            return .none
        }
    }

    /// Whether any row in a session list says it is running.
    ///
    /// The session list is the source, and the whole of it: a subagent's row says
    /// `running` too, and its work is still work the operator may be waiting on.
    /// Being conservative here costs one tick; being wrong the other way is the
    /// screen that keeps saying a session is running when the Mac says it is not.
    ///
    /// - Parameter sessions: the list as the host last gave it.
    /// - Returns: whether anything in it is running.
    public static func anySessionRunning(in sessions: [SessionRow]) -> Bool {
        sessions.contains(where: \.running)
    }
}
