//
//  SettlingRunsTests.swift
//  MizarKitTests
//
//  A running turn is impossible once a later turn exists.
//
//  Reported from the phone as: "后面的对话都成功执行完毕结束了，前面还有会话显示
//  正在执行" -- the newest turns all finished, and a row above them still counting
//  "深度求索中". The agent's model makes it impossible, because it ends one turn
//  before starting the next. What happened is that the phone's incremental read
//  stepped over a page of records it never received -- the host trims a page to
//  its newest few hundred messages -- and a `turn/end` was in the skipped range.
//  The skipped position became permanent the moment the phone claimed it held
//  everything through the page it did receive.
//
//  These tests are about the two halves of the answer: recognizing the shape
//  from turns alone (no clock, no socket), and settling it when the record cannot
//  be recovered -- without ever touching a turn that may genuinely be running.
//

import Foundation
import Testing
@testable import MizarKit

@Suite("Settling stale runs")
struct SettlingRunsTests {
    /// A turn with one prompt and one answer, at times derived from its number.
    private func turn(
        _ number: Int?,
        startedAt: Double?,
        endedAt: Double? = nil,
        endedReason: String? = nil,
        endInferred: Bool? = nil,
        prompt: String? = nil,
    ) -> ConversationTurn {
        let start = startedAt.map { Date(timeIntervalSince1970: $0) }
        let end = endedAt.map { Date(timeIntervalSince1970: $0) }
        return ConversationTurn(
            turn: number,
            prompts: prompt.map {
                [
                    .message(
                        id: "prompt-\(number ?? -1)",
                        role: .user,
                        text: $0,
                        at: start ?? Date(timeIntervalSince1970: 0),
                    ),
                ]
            } ?? [],
            steps: end.map {
                [
                    .message(
                        id: "answer-\(number ?? -1)",
                        role: .assistant,
                        text: "answer \(number ?? -1)",
                        at: $0,
                    ),
                ]
            } ?? [],
            stepCount: end == nil ? 1 : 2,
            startedAt: start,
            endedAt: end,
            endedReason: endedReason,
            firstSeq: (number ?? 1) * 100,
            endInferred: endInferred,
        )
    }

    /// The cache and the page that produced the reported shape.
    ///
    /// The phone had read as far as the middle of turn 11, which was running.
    /// The next read came after the phone had been away: turn 11 had ended and
    /// the operator had sent another prompt, turn 12, which finished. The page
    /// held turns 12 and 13; turn 11's `turn/end` was among the records the
    /// page window cut away, so nothing on the phone would ever say it ended.
    private func reportedShape() -> (cached: [ConversationTurn], fresh: [ConversationTurn]) {
        let cached = [
            turn(10, startedAt: 1000, endedAt: 1010, endedReason: "completed", prompt: "first"),
            turn(11, startedAt: 1020, prompt: "second"),
        ]
        let fresh = [
            turn(12, startedAt: 1200, endedAt: 1210, endedReason: "completed", prompt: "third"),
            turn(13, startedAt: 1220, endedAt: 1230, endedReason: "completed"),
        ]
        return (cached, fresh)
    }

    @Test("the merged turns of a skipped page hold a run a later turn disproves")
    func mergeLeavesAnImpossibleRun() {
        let (cached, fresh) = reportedShape()

        // The merge is what the phone does with the page, so this is the state
        // the screen draws. Turn 11 has no end and turns 12 and 13 do.
        let merged = mergeTurns(cached: cached, fresh: fresh)
        let stale = staleRunningTurn(in: merged)

        #expect(stale?.turn.turn == 11)
        // The page to ask for is the one before the earliest later turn, which
        // is where the missing end must be.
        #expect(stale?.beforeSeq == 1200)
    }

    @Test("settling ends the stale turn at the later turn's start")
    func settlingEndsTheStaleTurn() throws {
        let (cached, fresh) = reportedShape()
        let merged = mergeTurns(cached: cached, fresh: fresh)

        let settled = settlingStaleRuns(in: merged)

        let repaired = try #require(settled.first { $0.turn == 11 })
        #expect(repaired.isRunning == false)
        // The end is an upper bound, not a reading. It is marked as such so no
        // screen reports a duration or an outcome the log never wrote.
        #expect(repaired.isEndInferred)
        #expect(repaired.endedAt == Date(timeIntervalSince1970: 1200))
        #expect(repaired.failed == false)
        // The newest turn is untouched: it could still be running for real. The
        // continuation (turn 13) folded into it, so the one inferred end in the
        // conversation is the stale turn's.
        #expect(settled.filter(\.isEndInferred).map(\.turn) == [11])
        #expect(settled.filter(\.isRunning).isEmpty)
        #expect(staleRunningTurn(in: settled) == nil)
    }

    @Test("a genuinely running newest turn is left alone")
    func newestRunSurvives() {
        let turns = [
            turn(1, startedAt: 100, endedAt: 110, endedReason: "completed", prompt: "go"),
            turn(2, startedAt: 120, prompt: "again"),
        ]

        #expect(staleRunningTurn(in: turns) == nil)
        #expect(settlingStaleRuns(in: turns) == turns)
        #expect(turns[1].isRunning)
    }

    @Test("a finished turn is not changed by settling")
    func finishedTurnsAreLeftAlone() {
        let turns = [
            turn(1, startedAt: 100, endedAt: 110, endedReason: "completed", prompt: "go"),
            turn(2, startedAt: 120, endedAt: 130, endedReason: "error"),
            turn(3, startedAt: 140, prompt: "latest"),
        ]

        let settled = settlingStaleRuns(in: turns)

        #expect(settled == turns)
        #expect(settled[1].endedReason == "error")
        #expect(settled[1].isEndInferred == false)
    }

    @Test("later is decided by turn number, not by array position")
    func laterIsDecidedByNumber() {
        // A cache written before turn positions were stored can order a turn by
        // its items, and an item-less turn sorts last regardless of when it
        // happened -- so a genuinely running newest turn can sit *before* an
        // older one in the array. Settling it would stop a clock that is really
        // running.
        let newest = turn(9, startedAt: 200, prompt: "latest")
        let older = ConversationTurn(
            turn: 8,
            prompts: [],
            steps: [],
            startedAt: nil,
            endedAt: Date(timeIntervalSince1970: 150),
            endedReason: "completed",
            firstSeq: nil,
        )

        #expect(staleRunningTurn(in: [newest, older]) == nil)
        #expect(settlingStaleRuns(in: [newest, older])[0].isRunning)
    }

    @Test("an unnumbered group is not evidence that a run ended")
    func unnumberedGroupsAreNotEvidence() {
        // A prompt group without a turn number is a page-edge artifact, not a
        // turn that started. It must not be enough to settle a running turn --
        // being wrong here would stop the clock on work still in progress.
        let running = turn(5, startedAt: 100, prompt: "go")
        let stranded = ConversationTurn(
            turn: nil,
            prompts: [.message(id: "seq-999", role: .user, text: "edge", at: Date(timeIntervalSince1970: 99))],
            steps: [],
            startedAt: nil,
            endedAt: nil,
            endedReason: nil,
            firstSeq: 999,
        )

        #expect(staleRunningTurn(in: [running, stranded]) == nil)
    }

    @Test("two stale runs are both settled")
    func everyStaleRunIsSettled() {
        // One skipped window can swallow more than one ending. The rule is the
        // same for each: a later turn exists, so it is over.
        let turns = [
            turn(1, startedAt: 100, prompt: "one"),
            turn(2, startedAt: 200, prompt: "two"),
            turn(3, startedAt: 300, endedAt: 310, endedReason: "completed", prompt: "three"),
        ]

        let settled = settlingStaleRuns(in: turns)

        #expect(settled[0].isRunning == false)
        #expect(settled[1].isRunning == false)
        #expect(settled[0].isEndInferred)
        #expect(settled[1].isEndInferred)
        #expect(settled[2].isEndInferred == false)
        #expect(staleRunningTurn(in: settled) == nil)
    }

    @Test("settling twice settles nothing new")
    func settlingIsIdempotent() {
        let (cached, fresh) = reportedShape()
        let once = settlingStaleRuns(in: mergeTurns(cached: cached, fresh: fresh))
        let twice = settlingStaleRuns(in: once)

        #expect(twice == once)
    }

    @Test("a settled turn asks for no page when no later position is known")
    func noPositionNoRepairPage() {
        // Without a position on any later turn there is no exclusive upper
        // bound to page from -- the phone cannot ask for "the records after the
        // ones I missed". The shape is still detected and still settled.
        let stale = ConversationTurn(
            turn: 4,
            prompts: [.message(id: "p", role: .user, text: "go", at: Date(timeIntervalSince1970: 1))],
            steps: [],
            startedAt: Date(timeIntervalSince1970: 1),
            endedAt: nil,
            endedReason: nil,
            firstSeq: nil,
        )
        let later = ConversationTurn(
            turn: 5,
            prompts: [],
            steps: [.message(id: "s", role: .assistant, text: "done", at: Date(timeIntervalSince1970: 2))],
            startedAt: nil,
            endedAt: Date(timeIntervalSince1970: 2),
            endedReason: "completed",
            firstSeq: nil,
        )

        let found = staleRunningTurn(in: [stale, later])
        #expect(found?.turn.turn == 4)
        #expect(found?.beforeSeq == nil)
        #expect(settlingStaleRuns(in: [stale, later])[0].isRunning == false)
    }

    @Test("a recorded end replaces an inferred one when the record arrives")
    func recordedEndClearsInference() throws {
        // How the repair can still correct the screen: the page fetched from the
        // host holds the real `turn/end`, and merging it must drop both the
        // made-up instant and the mark that said it was made up.
        let inferred = turn(11, startedAt: 1020, endedAt: 1200, endInferred: true, prompt: "second")
        let recorded = turn(11, startedAt: 1020, endedAt: 1080, endedReason: "aborted", prompt: "second")

        for merged in [recorded.merging(inferred), inferred.merging(recorded)] {
            let settled = settlingStaleRuns(in: [merged, turn(12, startedAt: 1200, endedAt: 1210, endedReason: "completed", prompt: "third")])

            let fixed = try #require(settled.first { $0.turn == 11 })
            #expect(fixed.isRunning == false)
            #expect(fixed.isEndInferred == false)
            #expect(fixed.endedAt == Date(timeIntervalSince1970: 1080))
            #expect(fixed.endedReason == "aborted")
            #expect(fixed.failed)
        }
    }

    @Test("a fresh copy with no end does not erase a settled end")
    func mergingPartialPageKeepsTheSettledEnd() {
        // A page can carry the turn's records again without carrying its end --
        // the window cuts through the turn. That copy must not make a settled
        // turn count again.
        let inferred = turn(11, startedAt: 1020, endedAt: 1200, endInferred: true, prompt: "second")
        let partial = turn(11, startedAt: 1020, prompt: "second")

        let merged = partial.merging(inferred)

        #expect(merged.isRunning == false)
        #expect(merged.isEndInferred)
        #expect(merged.endedAt == Date(timeIntervalSince1970: 1200))
    }

    @Test("a settled continuation's end belongs to the whole folded turn")
    func absorbedContinuationKeepsInference() {
        // The chain's end comes from its last continuation; if that end was
        // inferred, the folded turn's end is inferred too.
        let asked = turn(5, startedAt: 100, endedAt: 110, endedReason: "completed", prompt: "go")
        let carriedOn = turn(6, startedAt: 111, endedAt: 130, endInferred: true)

        let folded = asked.absorbing(carriedOn)

        #expect(folded.turn == 5)
        #expect(folded.isEndInferred)
        #expect(folded.endedAt == Date(timeIntervalSince1970: 130))
    }

    @Test("a cache written before inferred ends existed still decodes")
    func oldCacheDecodes() throws {
        // The cache is the operator's data: a file from the previous build must
        // not fail to read because the shape gained a key.
        let json = """
        {"turn":3,"prompts":[],"steps":[],"stepCount":2,
         "startedAt":770000000,"endedAt":770000010,"endedReason":"completed","firstSeq":300}
        """
        let decoded = try JSONDecoder().decode(ConversationTurn.self, from: Data(json.utf8))

        #expect(decoded.turn == 3)
        #expect(decoded.endInferred == nil)
        #expect(decoded.isEndInferred == false)
        #expect(decoded.lastTurn == nil)

        // And the mark survives a write/read of a settled turn.
        let settled = decoded.settling(at: Date(timeIntervalSince1970: 770000020))
        let roundTrip = try JSONDecoder().decode(
            ConversationTurn.self,
            from: JSONEncoder().encode(settled),
        )
        #expect(roundTrip.isEndInferred)
        #expect(roundTrip.endedAt == settled.endedAt)
    }

    @Test("an ending whose turn is on the previous page is kept, as a sign-off")
    func loneEndingIsASignOff() throws {
        // The other half of the reported shape, and the likelier one: the page
        // window begins between turn 11's last record and its `turn/end`, so the
        // ending arrives alone. It used to be dropped -- the reader only grouped
        // records that named a turn and drew something -- and the phone never
        // learned that the turn it held as running had finished.
        let page = try JSONDecoder().decode(
            SessionMessagesResult.self,
            from: Data("""
            {"sessionId":"s-stale","asOfSeq":1300,"hasMore":true,"records":[
              {"type":"event","event":{"type":"turn/end","seq":1100,"time":1180000,
                "data":{"turn":11,"reason":{"kind":"completed"}}}}
            ]}
            """.utf8),
        )

        let turns = page.conversationTurns()
        #expect(turns.count == 1)
        #expect(turns.first?.turn == 11)
        #expect(turns.first?.isRunning == false)
        #expect(turns.first?.isEndOnly == true)
        // On its own it is not a turn: with no copy to end it is not drawn as an
        // empty row nobody typed into.
        #expect(mergeTurns(cached: [], fresh: turns).isEmpty)
    }

    @Test("a page that begins after a turn's last record still ends that turn")
    func pageBoundaryEndingSettlesTheRun() throws {
        // The reported shape produced without any skipped page at all: the phone
        // held turn 11 as running, the next incremental read landed after turn
        // 11's last message and before its `turn/end`, and the turn ended -- so
        // the page begins with the ending and carries the operator's next prompt
        // (turn 12) after it. Before the sign-off rule the ending sat in no
        // group and was thrown away, and the screen counted turn 11 for ever
        // while turn 12 arrived finished.
        let cached = [turn(11, startedAt: 1020, prompt: "second")]
        let page = try JSONDecoder().decode(
            SessionMessagesResult.self,
            from: Data("""
            {"sessionId":"s-stale","asOfSeq":1300,"hasMore":true,"records":[
              {"type":"event","event":{"type":"turn/end","seq":1200,"time":1190000,
                "data":{"turn":11,"reason":{"kind":"completed"}}}},
              {"type":"event","event":{"type":"turn/start","seq":1205,"time":1200000,
                "data":{"turn":12}}},
              {"type":"event","event":{"type":"step/start","seq":1207,"time":1200100,
                "data":{"turn":12,"step":1}}},
              {"type":"event","event":{"type":"user/message","seq":1208,"time":1200200,
                "data":{"content":[{"type":"text","text":"third"}],
                          "source":{"kind":"user"},"role":"user","id":"m-12"}}},
              {"type":"event","event":{"type":"assistant/message","seq":1210,"time":1210000,
                "data":{"turn":12,"step":1,"message":{"role":"assistant",
                  "content":[{"type":"text","text":"answer 12"}]}}}},
              {"type":"event","event":{"type":"turn/end","seq":1211,"time":1210100,
                "data":{"turn":12,"reason":{"kind":"completed"}}}}
            ]}
            """.utf8),
        )

        let merged = mergeTurns(cached: cached, fresh: page.conversationTurns())

        let finished = try #require(merged.first { $0.turn == 11 })
        #expect(finished.isRunning == false)
        #expect(finished.isEndInferred == false)
        #expect(finished.endedReason == "completed")
        #expect(finished.endedAt == Date(timeIntervalSince1970: 1190))
        #expect(finished.prompts.map(\.id) == ["prompt-11"])
        // The later turn came in finished, and the stale run is gone without the
        // repair ever having to fetch anything.
        #expect(merged.first { $0.turn == 12 }?.isRunning == false)
        #expect(staleRunningTurn(in: merged) == nil)
    }

    @Test("an ending that names a chain's last continuation ends the chain")
    func signOffJoinsTheFoldedChain() throws {
        // A chain keeps its first number as identity: turn 10 answered, then the
        // agent carried on into turn 11 with no prompt of its own, and the cache
        // holds them folded as turn 10. The page's ending names turn 11 -- the
        // last link of the chain -- so it arrives under a number no entry has.
        // Before ``ConversationTurn/lastTurn`` it was dropped, and the folded
        // turn the operator was watching kept counting.
        let asked = turn(10, startedAt: 100, endedAt: 110, endedReason: "completed", prompt: "go")
        let carriedOn = turn(11, startedAt: 111)
        let chain = mergeTurns(cached: [], fresh: [asked, carriedOn])

        #expect(chain.count == 1)
        #expect(chain.first?.turn == 10)
        #expect(chain.first?.lastTurn == 11)
        #expect(chain.first?.isRunning == true)

        let ending = try JSONDecoder().decode(
            SessionMessagesResult.self,
            from: Data("""
            {"sessionId":"s-chain","asOfSeq":1300,"hasMore":true,"records":[
              {"type":"event","event":{"type":"turn/end","seq":1200,"time":1190000,
                "data":{"turn":11,"reason":{"kind":"completed"}}}}
            ]}
            """.utf8),
        ).conversationTurns()

        let merged = mergeTurns(cached: chain, fresh: ending)

        #expect(merged.count == 1)
        let repaired = try #require(merged.first)
        #expect(repaired.turn == 10)
        #expect(repaired.lastTurn == 11)
        #expect(repaired.isRunning == false)
        #expect(repaired.isEndInferred == false)
        #expect(repaired.endedReason == "completed")
        #expect(repaired.prompts.map(\.id) == ["prompt-10"])
        // The other end of the chain's identity is a cache fact: a file that
        // loses it can no longer join the chain's next ending.
        let stored = try JSONDecoder().decode(
            ConversationTurn.self,
            from: JSONEncoder().encode(repaired),
        )
        #expect(stored.lastTurn == 11)
    }

    @Test("a sign-off that carries a reason keeps it, and is not a completion")
    func signOffWithReasonKeepsIt() throws {
        // The ending is allowed a failure item (it is a detail of the ending),
        // and when it joins the held turn the row must show what the log said --
        // "未完成", not "已完成", and certainly not "深度求索中".
        let cached = [turn(11, startedAt: 1020, prompt: "second")]
        let page = try JSONDecoder().decode(
            SessionMessagesResult.self,
            from: Data("""
            {"sessionId":"s-stale","asOfSeq":1300,"hasMore":true,"records":[
              {"type":"event","event":{"type":"turn/end","seq":1200,"time":1190000,
                "data":{"turn":11,"reason":{"kind":"aborted",
                  "error":{"message":"the operator cancelled it"}}}}}
            ]}
            """.utf8),
        )

        let merged = mergeTurns(cached: cached, fresh: page.conversationTurns())

        let repaired = try #require(merged.first { $0.turn == 11 })
        #expect(repaired.isRunning == false)
        #expect(repaired.isEndInferred == false)
        #expect(repaired.endedReason == "aborted")
        #expect(repaired.failed)
        #expect(repaired.prompts.map(\.id) == ["prompt-11"])
    }

    @Test("a repaired page really settles the turn, without a made-up end")
    func repairedPageSettlesTheRun() throws {
        // What the repair does with the page it fetched: the host's `turn/end`
        // arrives through the ordinary reader and the ordinary merge, so the
        // turn keeps its recorded end and no inferred mark -- the screen says
        // "已完成" because the log now says so.
        let (cached, fresh) = reportedShape()
        let broken = mergeTurns(cached: cached, fresh: fresh)

        let repairedPage = try JSONDecoder().decode(
            SessionMessagesResult.self,
            from: Data("""
            {"sessionId":"s-stale","asOfSeq":1199,"hasMore":true,"records":[
              {"type":"event","event":{"type":"turn/end","seq":1100,"time":1180000,
                "data":{"turn":11,"reason":{"kind":"completed"}}}}
            ]}
            """.utf8),
        )

        let merged = mergeTurns(cached: broken, fresh: repairedPage.conversationTurns())

        let repaired = try #require(merged.first { $0.turn == 11 })
        #expect(repaired.isRunning == false)
        #expect(repaired.isEndInferred == false)
        #expect(repaired.endedReason == "completed")
        #expect(repaired.endedAt == Date(timeIntervalSince1970: 1180))
        // The prompt the cached copy held is still there: a page cut through a
        // turn arrives without the start, and merging is by item id.
        #expect(repaired.prompts.count == 1)
        #expect(staleRunningTurn(in: merged) == nil)
    }
}
