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
//  without a simulator: it starts when something is running -- in the list, in
//  the open conversation, or because a prompt was just accepted -- it does not
//  start twice, and it stops the moment nothing is running or the app leaves the
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

    @Test("a running turn on the open page starts the poll while the list is stale")
    func conversationRunningStartsIt() {
        // The reported case: the list was read before the send and says the
        // session is stopped, while the conversation is showing a running turn.
        var poll = RunningPoll()
        #expect(
            poll.observe(anySessionRunning: false, conversationTurnIsRunning: true, appIsActive: true) == .start,
        )
        #expect(poll.isPolling)
        // Still running is not a reason to restart the ten-second clock.
        #expect(
            poll.observe(anySessionRunning: false, conversationTurnIsRunning: true, appIsActive: true) == .none,
        )
        // And the other direction: a page whose turn has ended is not evidence
        // that the list is wrong, so a running row keeps the poll up.
        #expect(
            poll.observe(anySessionRunning: true, conversationTurnIsRunning: false, appIsActive: true) == .none,
        )
        #expect(poll.isPolling)
    }

    @Test("the page's turn ending and an idle list stop the poll")
    func conversationEndStopsIt() {
        var poll = RunningPoll()
        _ = poll.observe(anySessionRunning: false, conversationTurnIsRunning: true, appIsActive: true)
        #expect(
            poll.observe(anySessionRunning: false, conversationTurnIsRunning: false, appIsActive: true) == .stop,
        )
        #expect(!poll.isPolling)
        // And stays stopped rather than toggling on a repeated "nothing".
        #expect(
            poll.observe(anySessionRunning: false, conversationTurnIsRunning: false, appIsActive: true) == .none,
        )
    }

    @Test("the page cannot start a poll on a phone that is not on screen")
    func conversationCannotStartInBackground() {
        var poll = RunningPoll()
        #expect(
            poll.observe(anySessionRunning: false, conversationTurnIsRunning: true, appIsActive: false) == .none,
        )
        #expect(!poll.isPolling)
        #expect(
            !RunningPoll.shouldPoll(
                anySessionRunning: false,
                conversationTurnIsRunning: true,
                appIsActive: false,
            ),
        )
    }

    @Test("an accepted prompt marks its row running and starts the poll")
    func sendMarksTheRow() {
        let stopped = [row("a", running: false), row("b", running: false)]
        let marked = RunningPoll.markingSessionRunning(in: stopped, sessionId: "b")
        #expect(marked.count == stopped.count, "marking a row invented or dropped one")
        #expect(marked.first { $0.sessionId == "b" }?.running == true)
        #expect(marked.first { $0.sessionId == "a" }?.running == false, "another session was marked")
        // The mark is exactly what the shipped start condition reads.
        #expect(RunningPoll.anySessionRunning(in: marked))
        var poll = RunningPoll()
        #expect(
            poll.observe(anySessionRunning: RunningPoll.anySessionRunning(in: marked), appIsActive: true) == .start,
        )
        // Idempotent: a second accepted prompt, or a row already running, is
        // not a change and must not restart the tick clock.
        #expect(RunningPoll.markingSessionRunning(in: marked, sessionId: "b") == marked)
        // A session the list does not hold is left alone rather than invented.
        #expect(RunningPoll.markingSessionRunning(in: marked, sessionId: "missing") == marked)
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
