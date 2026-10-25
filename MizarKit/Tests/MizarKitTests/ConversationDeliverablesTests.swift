//
//  ConversationDeliverablesTests.swift
//  MizarKitTests
//
//  A turn's delivered files, followed from the wire to the card.
//
//  Three places can lose them, and each one is a different bug:
//
//    - the reader (`conversationTurns`) not looking at the record they arrive on,
//    - the merge dropping them when a refresh returns a page that was cut before
//      the turn ended — the cards would then vanish on the next pull,
//    - the cache decode failing on a turn written before the field existed, which
//      makes the whole conversation look lost.
//

import Foundation
import Testing
@testable import MizarKit

@Suite("Delivered files on a turn")
struct ConversationDeliverablesTests {
    /// A page with one finished turn that declared a file.
    private static let page = """
    {"sessionId":"s1","asOfSeq":12,"hasMore":false,"records":[
      {"type":"event","event":{"type":"turn/start","seq":4,"time":1791984791224,"data":{"turn":1}}},
      {"type":"event","event":{"type":"user/message","seq":5,"time":1791984791300,
        "data":{"role":"user","content":[{"type":"text","text":"写一份报告"}],
                "source":{"kind":"user"}}}},
      {"type":"event","event":{"type":"assistant/message","seq":6,"time":1791984791400,
        "data":{"turn":1,"step":1,
                "message":{"role":"assistant","content":[{"type":"text","text":"已完成。"}]}}}},
      {"type":"event","event":{"type":"turn/end","seq":7,"time":1791984791500,
        "data":{"turn":1,"reason":{"kind":"completed"},
                "mizarDeliverables":[
                  {"path":"docs/report.md","description":"根因报告"},
                  {"path":"Build/shot.pdf"}]}}}
    ]}
    """

    private static func turns(_ json: String) throws -> [ConversationTurn] {
        let result = try JSONDecoder().decode(SessionMessagesResult.self, from: Data(json.utf8))
        return result.conversationTurns()
    }

    @Test
    func aTurnCarriesTheFilesItDeclared() throws {
        let turn = try #require(Self.turns(Self.page).first)
        #expect(turn.files.count == 2)
        #expect(turn.files[0].path == "docs/report.md")
        #expect(turn.files[0].detail == "根因报告")
        #expect(turn.files[1].kind == .pdf)
    }

    @Test
    func aTurnWithNoFilesSaysNothing() throws {
        let plain = """
        {"sessionId":"s1","asOfSeq":7,"hasMore":false,"records":[
          {"type":"event","event":{"type":"turn/start","seq":4,"time":1,"data":{"turn":1}}},
          {"type":"event","event":{"type":"assistant/message","seq":5,"time":2,
            "data":{"turn":1,"step":1,
                    "message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}}}},
          {"type":"event","event":{"type":"turn/end","seq":6,"time":3,
            "data":{"turn":1,"reason":{"kind":"completed"}}}}
        ]}
        """
        let turn = try #require(Self.turns(plain).first)
        #expect(turn.files.isEmpty)
        #expect(turn.deliverables == nil)
    }

    @Test
    func aRefreshThatCutTheTurnKeepsTheCards() throws {
        // The phone holds the finished turn; a refresh returns a page whose end
        // for it has no deliverables (an older host, or a page cut before the
        // end). The cards must survive: they were a fact when they arrived.
        let finished = try #require(Self.turns(Self.page).first)
        let partial = ConversationTurn(
            turn: 1,
            prompts: [],
            steps: [],
            stepCount: 1,
            startedAt: Date(timeIntervalSince1970: 1),
            endedAt: Date(timeIntervalSince1970: 2),
            endedReason: "completed",
            endSeq: 7,
        )

        let merged = partial.merging(finished)
        #expect(merged.files.count == 2)
    }

    @Test
    func aTurnWrittenBeforeThisExistedStillDecodes() throws {
        let json = """
        {"turn":3,"prompts":[],"steps":[],"startedAt":0,"endedAt":10,"endedReason":"completed"}
        """
        let turn = try JSONDecoder().decode(ConversationTurn.self, from: Data(json.utf8))
        #expect(turn.deliverables == nil)
        #expect(turn.files.isEmpty)
    }

    @Test
    func theCacheRoundTripsTheFiles() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mizar-turn-files-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let turn = ConversationTurn(
            turn: 1,
            prompts: [],
            steps: [],
            startedAt: Date(timeIntervalSince1970: 1),
            endedAt: Date(timeIntervalSince1970: 2),
            endedReason: "completed",
            deliverables: [DeliveredFile(path: "docs/report.md", detail: "报告")],
        )
        let cache = FileConversationCache(directory: directory)
        await cache.save(CachedConversation(sessionId: "s1", items: [], throughSeq: 7, turns: [turn]))

        let read = try #require(await FileConversationCache(directory: directory).load(sessionId: "s1"))
        #expect(read.turns?.first?.files == [DeliveredFile(path: "docs/report.md", detail: "报告")])
    }
}
