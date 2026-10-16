//
//  RunningTurnTests.swift
//  MizarKitTests
//
//  The turn that is running *now*, as the host really writes it.
//
//  The app's grouping was built on a reading of the log that the host does not
//  produce. Every fixture in this suite -- including the mock host the UI tests
//  drive -- wrote the operator's prompt **before** the `turn/start` it causes.
//  The durable log says the other way round, and the difference is the whole
//  bug: a prompt that arrives *after* its `turn/start` cannot be paired by the
//  "hold it for the next turn" rule, so it was left as a group of its own and
//  the running turn was left with no prompt at all -- and then folded.
//
//  Copied from the live wire, not written by hand. `session.messages` answered
//  this for a session whose turn 11 was executing:
//
//      seq=92 turn/start {"turn":11}
//      seq=94 step/start {"turn":11,"step":1}
//      seq=95 user/message {…"source":{"kind":"user"}}     <- no data.turn
//      seq=99 turn/end
//
//  and the same order is in the durable log on disk: `turn/start` at seq 4,
//  `step/start` at 6, the operator's `user/message` at 8, with the injected
//  runtime context after it.
//

import Foundation
import Testing
@testable import MizarKit

/// Decode a page from JSON text.
private func page(_ json: String) throws -> SessionMessagesResult {
    try JSONDecoder().decode(SessionMessagesResult.self, from: Data(json.utf8))
}

@Suite("The running turn")
struct RunningTurnTests {
    /// One finished turn, then a turn that has just started and is still going.
    ///
    /// The record order is the host's: the prompt is written after the
    /// `turn/start` and the `step/start`, and carries no `data.turn`.
    private static let livePage = """
    {"sessionId":"s-live","asOfSeq":99,"hasMore":false,"records":[
      {"type":"event","event":{"type":"turn/start","seq":83,"time":1791984783000,
        "data":{"turn":10}}},
      {"type":"event","event":{"type":"step/start","seq":85,"time":1791984783500,
        "data":{"turn":10,"step":1}}},
      {"type":"event","event":{"type":"user/message","seq":86,"time":1791984783600,
        "data":{"content":[{"type":"text","text":"first question"}],
                  "source":{"kind":"user","rpcId":"r-10"},"role":"user","id":"m-10"}}},
      {"type":"event","event":{"type":"assistant/message","seq":88,"time":1791984783900,
        "data":{"turn":10,"step":1,"message":{"role":"assistant","content":[
          {"type":"text","text":"the first answer"}]}}}},
      {"type":"event","event":{"type":"turn/end","seq":89,"time":1791984784000,
        "data":{"turn":10,"reason":{"kind":"completed"}}}},
      {"type":"event","event":{"type":"turn/start","seq":92,"time":1791984785000,
        "data":{"turn":11}}},
      {"type":"event","event":{"type":"step/start","seq":94,"time":1791984785500,
        "data":{"turn":11,"step":1}}},
      {"type":"event","event":{"type":"user/message","seq":95,"time":1791984785600,
        "data":{"content":[{"type":"text","text":"请汇报当前状态"}],
                  "source":{"kind":"user","rpcId":"r-11"},"role":"user","id":"m-11"}}}
    ]}
    """

    @Test("the prompt written after its turn/start belongs to that turn")
    func promptAfterTurnStartBelongsToTheTurn() throws {
        // The pairing rule the reader already had, in the direction the host
        // actually writes: a prompt with no `data.turn` is claimed by the turn
        // that is *open* when it arrives, not only by one that opens later.
        //
        // Without that, the prompt formed an unnumbered group of its own while
        // the running turn held no prompt -- and the row drawn over a working
        // agent was a turn with nothing in it.
        let result = try page(Self.livePage)

        let running = try #require(result.conversationTurns().first { $0.turn == 11 })
        #expect(running.prompts.count == 1, "the running turn holds no prompt: \(running.prompts)")
        guard case .message(_, let role, let text, _) = running.prompts.first else {
            Issue.record("expected the operator's prompt, got \(running.prompts)")
            return
        }
        #expect(role == .user)
        #expect(text == "请汇报当前状态")
        #expect(running.stepCount == 1)
    }

    @Test("the running turn survives being merged with what the phone already had")
    func runningTurnSurvivesTheMerge() throws {
        // `mergeTurns` is not an optional step: `syncConversation` groups the
        // page and folds it into the cache on every read, and the view draws
        // the cache. So the fold is where a running turn has to stay running --
        // and where it did not.
        //
        // Measured before the fix: the prompt-bearing group sorted *after* the
        // turn it belonged to (`orderSeq` is `nil` for a turn whose only
        // records are markers, which sorts last), `reclaimStrandedPrompts` left
        // it alone because there was nothing after it to reattach it to, and
        // `collapseContinuations` then absorbed the prompt-less running turn
        // into that group. The absorbed result inherited the group's `turn`,
        // which is `nil`, so `isRunning` was false, and the row read "已完成"
        // over a turn that had not finished.
        let result = try page(Self.livePage)
        let fresh = result.conversationTurns()
        // The phone had read the conversation while turn 10 was the newest.
        let cached = [try #require(fresh.first { $0.turn == 10 })]

        let merged = mergeTurns(cached: cached, fresh: fresh)
        let running = try #require(merged.first { $0.turn == 11 || $0.prompts.contains {
            if case .message(_, _, let text, _) = $0 { return text == "请汇报当前状态" }
            return false
        } })

        #expect(running.isRunning, "the newest turn is not running: \(running)")
        #expect(running.prompts.count == 1, "the running turn lost its prompt: \(running.prompts)")
        // And the turn that finished is not dragged back into running by the
        // fold, which is what "the newest turn lost its own identity" looked
        // like from the screen: a finished turn with a clock counting on it.
        #expect(merged.first { $0.turn == 10 }?.isRunning == false)
    }

    @Test("a page cut through the newest turn still reports the work as running")
    func pageCutThroughTheTurnStillRuns() throws {
        // A page is a window, and the window can start inside the newest turn --
        // its `turn/start` and the prompt that began it in the page before. What
        // is left is a `step/start` or two.
        //
        // Such a turn has no prompt, so the fold treats it as the agent carrying
        // on rather than as a new instruction, and that is the intent: one
        // instruction is one row. What must not happen is what did -- the row
        // above it stayed "已完成" while the host was executing, because a turn
        // made only of markers had no start, and `absorbing` reads "has a start
        // or an end" as "this is a real turn".
        //
        // The marker is also the only clock available: `step/start` is written
        // one record after the turn opens (measured on a live host: seq 803 for
        // the `turn/start`, 805 for the marker), which is the same tolerance
        // `beganAt` already used for a page cut across a turn.
        let result = try page("""
        {"sessionId":"s-live","asOfSeq":810,"hasMore":true,"records":[
          {"type":"event","event":{"type":"step/start","seq":805,"time":1791984786000,
            "data":{"turn":101,"step":1}}},
          {"type":"event","event":{"type":"step/start","seq":807,"time":1791984787000,
            "data":{"turn":101,"step":2}}}
        ]}
        """)
        // The instruction the work is a continuation of, as the phone had it.
        let known = ConversationTurn(
            turn: 100,
            prompts: [.message(id: "seq-806", role: .user, text: "first question", at: Date(timeIntervalSince1970: 1_791_984_785))],
            steps: [.message(id: "seq-806b", role: .assistant, text: "the first answer", at: Date(timeIntervalSince1970: 1_791_984_786))],
            stepCount: 1,
            startedAt: Date(timeIntervalSince1970: 1_791_984_783),
            endedAt: Date(timeIntervalSince1970: 1_791_984_789),
            endedReason: "completed",
            firstSeq: 803,
        )

        let merged = mergeTurns(cached: [known], fresh: result.conversationTurns())

        #expect(merged.count == 1, "the continuation was drawn as a second turn: \(merged)")
        let newest = try #require(merged.last)
        #expect(newest.isRunning, "the work in progress is reported as finished: \(newest)")
        // Nothing the phone already had is lost in the fold, and the work done
        // since is counted with it.
        #expect(newest.prompts.map(\.id) == ["seq-806"])
        #expect(newest.steps.map(\.id) == ["seq-806b"])
        #expect(newest.stepCount == 3)
    }

    @Test("a prompt that arrived in a later read goes back to the running turn")
    func promptFromALaterReadJoinsTheRunningTurn() {
        // The same bug across two reads: the markers came from the page the
        // phone read while the turn was starting, the prompt a moment later.
        // The turn is above the prompt and still open, and the host writes a
        // prompt inside its turn -- so that is where it belongs.
        let running = ConversationTurn(
            turn: 12,
            prompts: [],
            steps: [],
            stepCount: 1,
            startedAt: Date(timeIntervalSince1970: 1_791_984_800),
            endedAt: nil,
            endedReason: nil,
            firstSeq: 900,
        )
        let prompt = ConversationTurn(
            turn: nil,
            prompts: [.message(id: "seq-902", role: .user, text: "carry on then", at: Date(timeIntervalSince1970: 1_791_984_801))],
            steps: [],
            startedAt: nil,
            endedAt: nil,
            endedReason: nil,
        )

        let merged = mergeTurns(cached: [running], fresh: [prompt])

        #expect(merged.count == 1, "the prompt was left as a turn of its own: \(merged)")
        #expect(merged.first?.turn == 12)
        #expect(merged.first?.isRunning == true)
        #expect(merged.first?.prompts.map(\.id) == ["seq-902"])
    }

    @Test("a group left behind by the old grouping does not draw the prompt twice")
    func staleGroupDoesNotDuplicateThePrompt() throws {
        // Every phone that ran the previous build has a cache holding one of
        // these: the running turn's prompt kept as a group of its own because it
        // was written after the `turn/start`. Reading again now claims it for the
        // turn -- and the group it used to live in is the same record, so it must
        // go rather than be drawn a second time.
        let result = try page(Self.livePage)
        let prompt = try #require(result.conversationItems().first { item in
            if case .message(_, .user, let text, _) = item { return text == "请汇报当前状态" }
            return false
        })
        let stale = ConversationTurn(
            turn: nil,
            prompts: [prompt],
            steps: [],
            stepCount: 1,
            startedAt: nil,
            endedAt: nil,
            endedReason: nil,
            firstSeq: prompt.seq,
        )

        let merged = mergeTurns(cached: [stale], fresh: result.conversationTurns())
        let shown = merged.flatMap(\.prompts).filter { $0.id == prompt.id }

        #expect(shown.count == 1, "the same prompt is on screen \(shown.count) times")
        #expect(merged.first { $0.turn == 11 }?.prompts.map(\.id) == [prompt.id])
    }

    @Test("a finished turn in the host's own order keeps its prompt and answer")
    func finishedTurnInTheHostOrder() throws {
        // The same order the running case is about, for a turn that ended: the
        // prompt sits after `turn/start` and `step/start`. This used to read
        // correctly by accident -- the `assistant/message` flushed the held
        // prompt into its turn -- and the accident is exactly why the running
        // turn was broken. Kept as a test so the pairing rule cannot be "fixed"
        // in a way that only works for finished turns.
        let result = try page(Self.livePage)

        let finished = try #require(result.conversationTurns().first { $0.turn == 10 })
        #expect(finished.prompts.map(\.id) == ["seq-86"])
        #expect(finished.steps.count == 1)
        #expect(finished.isRunning == false)
        #expect(finished.duration != nil)
    }
}
