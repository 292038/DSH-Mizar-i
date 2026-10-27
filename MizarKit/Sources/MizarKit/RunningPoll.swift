//
//  RunningPoll.swift
//  MizarKit
//
//  When the foreground should keep asking, decided without a clock or a screen.
//
//  The report this answers: a turn is sent from the phone (or from the computer, with
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
//  detail: a poll that runs all the time is a phone that asks its computer a question
//  every ten seconds for a day of not being used. The rules are:
//
//    - start when a session-list read says at least one session is running,
//    - **or when a prompt was just accepted for a session** (the caller marks
//      that row running, because the host accepting a prompt is direct evidence
//      that a turn is executing) -- the list may be a read from before the send,
//    - **or when the open conversation holds a turn that has not ended**
//      (``ConversationTurn/isRunning``) -- a stale list must not be able to hide
//      a turn the operator can see on screen,
//    - stop when none of those says a turn is executing. For the conversation
//      that means after a read of its page says the running turn has ended,
//    - stop while the app is not active, because a backgrounded phone costs
//      nothing and iOS suspends the process anyway,
//    - and never start a second one while the first is up.
//
//  The second and third rules are the fix for a real report against the first
//  version: its only input was `sessions`, and after a send the app refreshes
//  the *conversation* and never re-reads the list. So the list went on saying
//  the session was not running, the poll never started, and the only thing that
//  could correct it was a manual pull-to-refresh. A send, and a running turn on
//  the page, are both evidence the list is too stale to decide alone.
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

    /// How long between ticks on a local-network link.
    ///
    /// Three seconds, because the reason the interval is ten is the relay's
    /// bandwidth and the phone's battery, and neither carries this case: a
    /// direct link is the operator's own network, and the phone is on it. The
    /// turn ending is then noticed while the operator is still watching it,
    /// which is the whole point of a phone client sitting open next to the
    /// computer.
    public static let localInterval: Duration = .seconds(3)

    /// How long between ticks while a prompt is held for the end of a turn.
    ///
    /// A held prompt is a message the operator has already committed to. The
    /// only thing that sends it is a read that says the turn has ended, so the
    /// tick is what the operator experiences as the delay between the answer
    /// finishing and their message going. Ten seconds of that reads as a send
    /// that did not happen; three is the same tick the app already runs on its
    /// own network, and a turn is at most a handful of them long.
    ///
    /// Only while something is *also* running -- the poll's start condition is
    /// unchanged, and a held prompt on its own does not keep a poll alive. The
    /// app sends it from whatever read next says the turn has ended.
    public static let heldPromptInterval: Duration = .seconds(3)

    /// Whether a poll task is up. Kept in step with the caller's task through
    /// ``observe(anySessionRunning:appIsActive:)``.
    public private(set) var isPolling = false

    public init() {}

    /// Whether a poll is wanted at all, ignoring what is already running.
    ///
    /// - Parameters:
    ///   - anySessionRunning: whether the session list's latest read says a turn
    ///     is executing.
    ///   - conversationTurnIsRunning: whether the open conversation's turns hold
    ///     a turn that has begun and not ended. The list and the page can be
    ///     read at different moments, and either can be the newer one; a page
    ///     showing a running turn is the operator looking at work in progress,
    ///     so it is evidence in its own right.
    ///   - appIsActive: whether the app is on screen. A poll while the process
    ///     is suspended never fires, and one that starts the instant the app
    ///     comes back would ask before the foreground refresh has a chance to.
    /// - Returns: whether one should be up.
    public static func shouldPoll(
        anySessionRunning: Bool,
        conversationTurnIsRunning: Bool = false,
        appIsActive: Bool,
    ) -> Bool {
        (anySessionRunning || conversationTurnIsRunning) && appIsActive
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
    ///   - conversationTurnIsRunning: whether the open conversation holds a turn
    ///     that has not ended. See ``shouldPoll(anySessionRunning:conversationTurnIsRunning:appIsActive:)``.
    ///   - appIsActive: whether the app is on screen.
    /// - Returns: the transition, if there is one.
    public mutating func observe(
        anySessionRunning: Bool,
        conversationTurnIsRunning: Bool = false,
        appIsActive: Bool,
    ) -> Action {
        let wanted = Self.shouldPoll(
            anySessionRunning: anySessionRunning,
            conversationTurnIsRunning: conversationTurnIsRunning,
            appIsActive: appIsActive,
        )
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

    /// The session list, with one session marked as running.
    ///
    /// A send is the second way the poll can start, and the caller does not need
    /// a round trip to use it: the host accepted the prompt, which is direct
    /// evidence that a turn is executing. Marking the row is cheaper and more
    /// immediate than re-reading the list after every send -- and it is
    /// self-correcting, because the poll's own tick replaces the list with the
    /// host's answer ten seconds later. A list read immediately after a send
    /// would race the host recording the turn, which is the same stale answer
    /// this fixes.
    ///
    /// Nothing is invented: a session the list does not hold is left alone, and
    /// a row already saying running is returned unchanged.
    ///
    /// - Parameters:
    ///   - sessions: the list as the host last gave it.
    ///   - sessionId: the session a prompt was just accepted for.
    /// - Returns: the list, with that one row's running flag set.
    public static func markingSessionRunning(in sessions: [SessionRow], sessionId: String) -> [SessionRow] {
        guard let index = sessions.firstIndex(where: { $0.sessionId == sessionId }),
              !sessions[index].running
        else { return sessions }
        let row = sessions[index]
        var marked = sessions
        marked[index] = SessionRow(
            sessionId: row.sessionId,
            updatedAt: row.updatedAt,
            running: true,
            blank: row.blank,
            agentAvailable: row.agentAvailable,
            cwd: row.cwd,
            parentSessionId: row.parentSessionId,
            origin: row.origin,
        )
        return marked
    }

    /// Whether any row in a session list says it is running.
    ///
    /// The session list is the source, and the whole of it: a subagent's row says
    /// `running` too, and its work is still work the operator may be waiting on.
    /// Being conservative here costs one tick; being wrong the other way is the
    /// screen that keeps saying a session is running when the computer says it is not.
    ///
    /// - Parameter sessions: the list as the host last gave it.
    /// - Returns: whether anything in it is running.
    public static func anySessionRunning(in sessions: [SessionRow]) -> Bool {
        sessions.contains(where: \.running)
    }
}
