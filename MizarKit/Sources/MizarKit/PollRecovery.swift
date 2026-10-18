//
//  PollRecovery.swift
//  MizarKit
//
//  When a poll that cannot read should stop asking and rebuild the socket.
//
//  The polls deliberately do not reconnect on every tick: on a Mac that is
//  asleep, that would turn a ten-second question into a handshake every ten
//  seconds, and the whole reason the running poll is allowed to exist is that a
//  tick costs almost nothing. But the polls are also the only readers on a
//  screen nobody has touched, so a socket that died while the list says a turn
//  is running leaves that row saying "running" for as long as the operator
//  leaves the app open -- the next tick asks the same dead socket, and the one
//  after that asks it again.
//
//  The rules here are the smallest set that recovers without paying for it:
//
//    - a tick that was answered resets the count, because the socket works,
//    - a tick that failed for a reason the socket cannot fix (an answer the host
//      chose to send, a frame that will not decode into *this* type) does not
//      count -- rebuilding the connection would ask the same question again,
//    - a missing socket counts as a failure with no question asked at all: there
//      is nothing to try, and the operator's screen is the thing going stale,
//    - two failures earn one attempt, and attempts are thirty seconds apart. On
//      a Mac that has gone to sleep the poll tries once every half minute
//      instead of six times a minute, and a dropped socket is repaired on the
//      first tick that notices it.
//
//  Nothing here sleeps or opens anything. ``PollRecovery`` is the decision, the
//  caller keeps the clock and the connection, and the tests drive it with
//  instants they choose rather than by waiting.
//

import Foundation

/// Whether a poll that keeps failing should rebuild the socket, and how often.
public struct PollRecovery: Sendable, Equatable {
    /// Consecutive connection-shaped failures that earn one reconnect attempt.
    public static let failuresBeforeReconnect = 2

    /// The shortest gap between two attempts.
    ///
    /// Thirty seconds, not ten: an attempt on every tick is the handshake-every-
    /// ten-seconds cost the poll was written to avoid. Half a minute still
    /// repairs a socket within one tick of a drop being noticed, because a drop
    /// is noticed by the first failing tick, not by the second.
    public static let minimumInterval: Duration = .seconds(30)

    private var consecutiveFailures = 0
    private var lastAttempt: ContinuousClock.Instant?

    public init() {}

    /// How many connection-shaped failures have happened in a row.
    public var failures: Int { consecutiveFailures }

    /// Record a tick the socket answered.
    public mutating func recordSuccess() {
        consecutiveFailures = 0
    }

    /// Record a tick that failed for a reason a new socket could fix.
    public mutating func recordFailure() {
        consecutiveFailures += 1
    }

    /// Whether the next tick should try to rebuild the socket.
    ///
    /// - Parameters:
    ///   - connectionMissing: whether there is no socket at all. That is a
    ///     failure the poll can see without asking, and waiting for two of them
    ///     would mean a tick that cannot possibly do anything.
    ///   - now: the clock, injected so the wait is testable.
    /// - Returns: whether an attempt is due.
    public func reconnectIsDue(
        connectionMissing: Bool,
        now: ContinuousClock.Instant,
    ) -> Bool {
        guard connectionMissing || consecutiveFailures >= Self.failuresBeforeReconnect else {
            return false
        }
        guard let lastAttempt else { return true }
        return now - lastAttempt >= Self.minimumInterval
    }

    /// Remember that an attempt was made, so the next one waits.
    ///
    /// - Parameter now: when the attempt started.
    public mutating func noteAttempt(at now: ContinuousClock.Instant) {
        lastAttempt = now
    }

    /// Forget everything, for a poll that is starting over.
    public mutating func reset() {
        consecutiveFailures = 0
        lastAttempt = nil
    }
}
