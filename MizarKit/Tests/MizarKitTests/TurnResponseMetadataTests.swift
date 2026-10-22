import Foundation
import Testing
@testable import MizarKit

@Suite("Turn response metadata")
struct TurnResponseMetadataTests {
    private func date(_ text: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: text))
    }

    @Test("Today is always a 24-hour clock")
    func todayClock() throws {
        let zone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        #expect(TurnResponseClock.text(at: try date("2026-10-22T13:05:00Z"), now: try date("2026-10-22T14:00:00Z"), timeZone: zone) == "21:05")
    }

    @Test("Local midnight, not UTC, decides today")
    func midnight() throws {
        let zone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        #expect(TurnResponseClock.text(at: try date("2026-10-22T06:59:00Z"), now: try date("2026-10-22T07:01:00Z"), timeZone: zone) == "10月21日 23:59")
    }

    @Test("Local year boundaries include the year only when needed")
    func yearBoundary() throws {
        let zone = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let now = try date("2026-12-31T15:01:00Z")
        #expect(TurnResponseClock.text(at: try date("2026-12-31T14:59:00Z"), now: now, timeZone: zone) == "2026年12月31日 23:59")
        #expect(TurnResponseClock.text(at: try date("2026-12-31T15:00:00Z"), now: now, timeZone: zone) == "00:00")
    }

    @Test("The selected turn keeps its own inclusive end boundary and exact usage")
    func selectedBoundary() throws {
        let json = #"{"sessionId":"s","asOfSeq":30,"hasMore":false,"records":[{"type":"turn/start","seq":1,"time":1000,"data":{"turn":1}},{"type":"assistant/message","seq":8,"time":2000,"data":{"turn":1,"step":1,"message":{"role":"assistant","content":[{"type":"text","text":"First answer"}]}}},{"type":"turn/end","seq":10,"time":3000,"data":{"turn":1,"reason":{"kind":"completed"},"mizarTokenUsage":{"totalTokens":123},"mizarBranchUnavailable":false}},{"type":"turn/start","seq":20,"time":4000,"data":{"turn":2}},{"type":"user/message","seq":21,"time":4001,"data":{"turn":2,"source":{"kind":"user"},"content":[{"type":"text","text":"Next question"}]}}]}"#
        let page = try JSONDecoder().decode(SessionMessagesResult.self, from: Data(json.utf8))
        let turns = page.conversationTurns()
        #expect(turns[0].endSeq == 10)
        #expect(turns[0].endSeq != turns[0].steps.last?.seq)
        #expect(turns[0].tokenUsage?.totalTokens == 123)
        #expect(turns[0].branchUnavailable == false)
        #expect(turns[1].endSeq == nil)
        #expect(turns[1].tokenUsage == nil)
        #expect(turns[1].isRunning)
    }

    @Test("Old caches decode without footer metadata")
    func oldCache() throws {
        let json = #"{"turn":1,"prompts":[],"steps":[],"startedAt":0,"endedAt":10,"endedReason":"completed"}"#
        let turn = try JSONDecoder().decode(ConversationTurn.self, from: Data(json.utf8))
        #expect(turn.endSeq == nil)
        #expect(turn.tokenUsage == nil)
        #expect(turn.branchUnavailable == nil)
    }

    @Test("A running continuation cannot inherit its predecessor's footer boundary")
    func runningContinuation() {
        let first = ConversationTurn(turn: 1, prompts: [], steps: [], startedAt: .distantPast, endedAt: .now, endedReason: "completed", lastTurn: 1, endSeq: 10, tokenUsage: TurnTokenUsage(totalTokens: 100), branchUnavailable: false)
        let running = ConversationTurn(turn: 2, prompts: [], steps: [], startedAt: .now, endedAt: nil, endedReason: nil, lastTurn: 2)
        let combined = first.absorbing(running)
        #expect(combined.endSeq == nil)
        #expect(combined.tokenUsage == nil)
        #expect(combined.isRunning)
    }

    @Test("Paging an older prefix cannot replace the final continuation metadata")
    func olderPrefixMerge() {
        let first = ConversationTurn(turn: 1, prompts: [], steps: [], startedAt: .distantPast, endedAt: Date(timeIntervalSince1970: 10), endedReason: "completed", lastTurn: 1, endSeq: 10, tokenUsage: TurnTokenUsage(totalTokens: 100), branchUnavailable: false)
        let chain = ConversationTurn(turn: 1, prompts: [], steps: [], startedAt: .distantPast, endedAt: Date(timeIntervalSince1970: 20), endedReason: "completed", lastTurn: 2, endSeq: 20, tokenUsage: TurnTokenUsage(totalTokens: 200), branchUnavailable: false)
        let merged = first.merging(chain).merging(first)
        #expect(merged.lastTurn == 2)
        #expect(merged.endSeq == 20)
        #expect(merged.tokenUsage?.totalTokens == 200)
        let running = ConversationTurn(turn: 1, prompts: [], steps: [], startedAt: .distantPast, endedAt: nil, endedReason: nil, lastTurn: 2)
        let refreshed = first.merging(running).merging(first)
        #expect(refreshed.isRunning)
        #expect(refreshed.endedReason == nil)
        #expect(refreshed.endSeq == nil)
        #expect(refreshed.tokenUsage == nil)
    }

    @Test("A partial repeat of the same boundary cannot erase proven usage or branch safety")
    func partialRepeat() {
        let known = ConversationTurn(turn: 1, prompts: [], steps: [], startedAt: .distantPast, endedAt: .now, endedReason: "completed", lastTurn: 1, endSeq: 10, tokenUsage: TurnTokenUsage(totalTokens: 123), branchUnavailable: false)
        let partial = ConversationTurn(turn: 1, prompts: [], steps: [], startedAt: nil, endedAt: .now, endedReason: "completed", lastTurn: 1, endSeq: 10)
        let merged = partial.merging(known).merging(partial)
        #expect(merged.endSeq == 10)
        #expect(merged.tokenUsage?.totalTokens == 123)
        #expect(merged.branchUnavailable == false)
    }

    @Test("Missing usage is not a fabricated zero; explicit exact zero is valid")
    func exactUsage() throws {
        #expect(TurnTokenUsage(totalTokens: -1) == nil)
        #expect(TurnTokenUsage(totalTokens: 0)?.totalTokens == 0)
        #expect(TurnTokenUsage(totalTokens: 1234567)?.totalTokens == 1234567)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(TurnTokenUsage.self, from: Data("{}".utf8))
        }
    }
}
