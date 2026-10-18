//
//  PollRecoveryTests.swift
//  MizarKitTests
//
//  When a poll that cannot read should stop asking and rebuild the socket.
//
//  The bug this exists for: a turn finished on the Mac while the phone sat on
//  the session list, and the row went on saying "running" until somebody pulled
//  to refresh. The poll was asking a socket that had already died, and nothing
//  told it to open a new one. The rules are pinned here with instants the tests
//  choose, so the thirty-second wait is proved without waiting thirty seconds.
//

import Foundation
import Testing

@testable import MizarKit

struct PollRecoveryTests {
    /// A clock reading the test controls.
    private let start = ContinuousClock.now

    @Test("one failure is not enough to rebuild the socket")
    func oneFailureWaits() {
        var recovery = PollRecovery()
        recovery.recordFailure()
        #expect(!recovery.reconnectIsDue(connectionMissing: false, now: start))
    }

    @Test("two failures earn one attempt")
    func twoFailuresAskForReconnect() {
        var recovery = PollRecovery()
        recovery.recordFailure()
        recovery.recordFailure()
        #expect(recovery.reconnectIsDue(connectionMissing: false, now: start))
    }

    @Test("a missing socket is due at once, without waiting for failures")
    func missingSocketIsImmediate() {
        // There is nothing to ask, so a tick that waits for two failures is a
        // tick that cannot possibly do anything.
        var recovery = PollRecovery()
        #expect(recovery.reconnectIsDue(connectionMissing: true, now: start))
    }

    @Test("attempts wait thirty seconds apart")
    func attemptsAreRateLimited() {
        var recovery = PollRecovery()
        recovery.recordFailure()
        recovery.recordFailure()
        recovery.noteAttempt(at: start)
        #expect(!recovery.reconnectIsDue(connectionMissing: false, now: start.advanced(by: .seconds(29))))
        #expect(recovery.reconnectIsDue(connectionMissing: false, now: start.advanced(by: .seconds(30))))
    }

    @Test("a missing socket respects the same wait")
    func missingSocketIsRateLimitedToo() {
        // A Mac that has gone to sleep is the case the wait exists for: the poll
        // must not handshake every ten seconds at a machine that is not there.
        var recovery = PollRecovery()
        recovery.noteAttempt(at: start)
        #expect(!recovery.reconnectIsDue(connectionMissing: true, now: start.advanced(by: .seconds(10))))
        #expect(recovery.reconnectIsDue(connectionMissing: true, now: start.advanced(by: .seconds(30))))
    }

    @Test("an answered tick clears the count")
    func successResets() {
        var recovery = PollRecovery()
        recovery.recordFailure()
        recovery.recordFailure()
        recovery.recordSuccess()
        #expect(recovery.failures == 0)
        #expect(!recovery.reconnectIsDue(connectionMissing: false, now: start))
    }

    @Test("a poll that starts over keeps no history")
    func resetClearsEverything() {
        var recovery = PollRecovery()
        recovery.recordFailure()
        recovery.recordFailure()
        recovery.noteAttempt(at: start)
        recovery.reset()
        #expect(recovery.failures == 0)
        // No wait is inherited from the poll that has ended.
        #expect(recovery.reconnectIsDue(connectionMissing: true, now: start))
    }
}
