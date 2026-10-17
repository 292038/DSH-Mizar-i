//
//  RunningPollTests.swift
//  MizarKitTests
//
//  When the foreground poll is up, at transitions a test chooses.
//
//  The bug this covers was not a wrong read but a missing one: a conversation
//  left open while a turn finished showed "DeepSeeking" until somebody pulled
//  to refresh, because the only poll gave up when the send settled. The fix is
//  allowed to be cheap only if it is narrow, so the rules are asserted here
//  without a simulator: it starts when something is running, it does not start
//  twice, and it stops the moment nothing is running or the app leaves the
//  screen.
//

import Foundation
import Testing
@testable import MizarKit

@Suite("The running poll")
struct RunningPollTests {
    /// A session-list row.
    private func row(_ id: String, running: Bool) -> SessionRow {
        SessionRow(
            sessionId: id,
            updatedAt: 1_800_000_000_000,
            running: running,
            blank: false,
            agentAvailable: true,
            cwd: "/Users/you/projects/\(id)",
            parentSessionId: nil,
            origin: nil,
        )
    }

    @Test("a tick is ten seconds")
    func tickIsTenSeconds() {
        #expect(RunningPoll.interval == .seconds(10))
    }

    @Test("nothing running means no poll, however active the app is")
    func nothingRunningDoesNotStart() {
        var poll = RunningPoll()
        #expect(poll.observe(anySessionRunning: false, appIsActive: true) == .none)
        #expect(!poll.isPolling)
    }

    @Test("a running session starts one poll, and only one")
    func startsOnce() {
        var poll = RunningPoll()
        #expect(poll.observe(anySessionRunning: true, appIsActive: true) == .start)
        #expect(poll.isPolling)
        // Every later read of a list that still says "running" must not restart
        // the task: a restart resets the ten-second clock, so an operator who
        // refreshes the list by hand every few seconds would never get a tick.
        #expect(poll.observe(anySessionRunning: true, appIsActive: true) == .none)
        #expect(poll.observe(anySessionRunning: true, appIsActive: true) == .none)
        #expect(poll.isPolling, "the poll was stopped by an observation that still wanted it")
    }

    @Test("it stops as soon as nothing is running")
    func stopsWhenNothingRuns() {
        var poll = RunningPoll()
        _ = poll.observe(anySessionRunning: true, appIsActive: true)
        #expect(poll.observe(anySessionRunning: false, appIsActive: true) == .stop)
        #expect(!poll.isPolling)
        // And stays stopped, rather than toggling on a repeated "nothing".
        #expect(poll.observe(anySessionRunning: false, appIsActive: true) == .none)
        #expect(!poll.isPolling)
    }

    @Test("a backgrounded phone starts nothing and stops what is running")
    func inactivePhoneDoesNotPoll() {
        var idle = RunningPoll()
        #expect(idle.observe(anySessionRunning: true, appIsActive: false) == .none)
        #expect(!idle.isPolling)

        var polling = RunningPoll()
        _ = polling.observe(anySessionRunning: true, appIsActive: true)
        #expect(polling.observe(anySessionRunning: true, appIsActive: false) == .stop)
        #expect(!polling.isPolling)
    }

    @Test("a running row in the list is what starts it")
    func runningRowStartsIt() {
        #expect(!RunningPoll.anySessionRunning(in: []))
        #expect(!RunningPoll.anySessionRunning(in: [row("a", running: false)]))
        #expect(RunningPoll.anySessionRunning(in: [row("a", running: false), row("b", running: true)]))
        #expect(!RunningPoll.anySessionRunning(in: [row("a", running: false), row("b", running: false)]))
    }

    @Test("the two conditions are both required, not either")
    func bothConditionsRequired() {
        var poll = RunningPoll()
        #expect(RunningPoll.shouldPoll(anySessionRunning: true, appIsActive: true))
        #expect(!RunningPoll.shouldPoll(anySessionRunning: true, appIsActive: false))
        #expect(!RunningPoll.shouldPoll(anySessionRunning: false, appIsActive: true))
        #expect(!RunningPoll.shouldPoll(anySessionRunning: false, appIsActive: false))
        #expect(poll.observe(anySessionRunning: true, appIsActive: true) == .start)
    }
}
