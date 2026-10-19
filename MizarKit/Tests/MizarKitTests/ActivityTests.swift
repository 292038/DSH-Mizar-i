//
//  ActivityTests.swift
//  MizarKitTests
//
//  `session.activity`: the paid full-detail feed.
//
//  Two things are pinned here, and both fail silently if they drift:
//
//  - the **wire shape** — `at` is epoch milliseconds (off by 1000 is invisible
//    on a row that shows no time, and very visible if it is ever shown), `seq`,
//    `turn` and `asOfSeq` are nullable, and an unknown `kind` must decode rather
//    than sink the answer;
//  - the **request shape** — one method name and `sessionId`, with `maxEntries`
//    only when asked for, because a typo in either is a `NOT_IMPLEMENTED` the
//    app would swallow as "no detail feed".
//

import Foundation
import Testing
@testable import MizarKit

@Suite("SessionActivity")
struct ActivityTests {
    /// One full answer, as the host writes it.
    static let answer = #"""
    {
      "sessionId": "s-1",
      "asOfSeq": 42,
      "turn": 4,
      "entries": [
        {"id": "seq-40", "seq": 40, "at": 1760000000000, "kind": "thinking",
         "title": "", "text": "Reading the parser and planning a change"},
        {"id": "seq-41-command", "seq": 41, "at": 1760000001000, "kind": "command",
         "title": "Bash", "text": "rg -n trailing comma src/"},
        {"id": "seq-42-output", "seq": 42, "at": 1760000002000, "kind": "output",
         "title": "Bash", "text": "src/lexer.ts:42: trailing commas are allowed here"},
        {"id": "seq-43-tool", "seq": 43, "at": 1760000003000, "kind": "tool",
         "title": "Read", "text": "src/parser.ts (1-120)"}
      ],
      "hasMore": false
    }
    """#

    private func decode(_ json: String) throws -> SessionActivityResult {
        try JSONDecoder().decode(SessionActivityResult.self, from: Data(json.utf8))
    }

    @Test("decodes the documented answer, with epoch-millisecond times")
    func decodesAnswer() throws {
        let result = try decode(Self.answer)
        #expect(result.sessionId == "s-1")
        #expect(result.asOfSeq == 42)
        #expect(result.turn == 4)
        #expect(result.hasRunningTurn)
        #expect(result.hasMore == false)
        #expect(result.entries.count == 4)
        #expect(result.entries.map(\.kind) == [.thinking, .command, .output, .tool])
        #expect(result.entries[1].title == "Bash")
        #expect(result.entries[2].text.contains("trailing commas"))
        #expect(result.entries[0].id == "seq-40")
        // 1760000000000 ms is 2025-10-09T12:53:20Z. Seconds would be 1970.
        #expect(result.entries[0].at == Date(timeIntervalSince1970: 1_760_000_000))
        #expect(result.entries[3].at == Date(timeIntervalSince1970: 1_760_000_003))
    }

    @Test("an unknown kind decodes as other instead of failing")
    func unknownKind() throws {
        let json = #"""
        {
          "sessionId": "s-1", "asOfSeq": null, "turn": 7, "hasMore": true,
          "entries": [
            {"id": "e1", "seq": null, "at": 1760000000000, "kind": "telemetry",
             "title": "Future", "text": "a detail from a newer host"}
          ]
        }
        """#
        let result = try decode(json)
        #expect(result.entries.count == 1)
        #expect(result.entries[0].kind == .other)
        #expect(result.entries[0].title == "Future")
        #expect(result.entries[0].seq == nil)
        #expect(result.hasMore)
    }

    @Test("an answer with no running turn is empty, not an error")
    func noRunningTurn() throws {
        let result = try decode(#"{"sessionId":"s-1","asOfSeq":null,"turn":null,"entries":[],"hasMore":false}"#)
        #expect(!result.hasRunningTurn)
        #expect(result.entries.isEmpty)
        #expect(result.asOfSeq == nil)
    }

    @Test("missing optional keys decode with safe defaults")
    func tolerantDecoding() throws {
        let result = try decode(#"{"sessionId":"s-1"}"#)
        #expect(result.sessionId == "s-1")
        #expect(result.turn == nil)
        #expect(result.entries.isEmpty)
        #expect(!result.hasMore)

        // An entry with no kind, title or text still draws as something.
        let entry = try JSONDecoder().decode(
            ActivityEntry.self,
            from: Data(#"{"id":"e1","at":0}"#.utf8),
        )
        #expect(entry.kind == .other)
        #expect(entry.title.isEmpty)
        #expect(entry.text.isEmpty)
        #expect(entry.at == Date(timeIntervalSince1970: 0))
    }

    @Test("the empty answer helper says nothing is running")
    func emptyHelper() {
        let result = SessionActivityResult.empty(sessionId: "s-1")
        #expect(!result.hasRunningTurn)
        #expect(result.entries.isEmpty)
        #expect(!result.hasMore)
    }

    // MARK: - The request

    /// Build a connection whose host welcomes and answers one method.
    private func makeConnection(sessionId: String = "s-1") -> (MizarConnection, StubTransport) {
        let answer = Self.answer
        let transport = StubTransport(responder: { text in
            guard let type = frameType(of: text) else { return [] }
            if type == "hello" { return [welcomeFrame()] }
            let id = correlationId(of: text) ?? ""
            if type == "session.activity" {
                // The host echoes the session it was asked about.
                let result = answer.replacingOccurrences(of: #""s-1""#, with: "\"\(sessionId)\"")
                return [serverFrame([
                    "v": .number(Double(mizarProtocolVersion)),
                    "type": .string("ok"),
                    "id": .string(id),
                    "result": (try? JSONDecoder().decode(JSONValue.self, from: Data(result.utf8))) ?? .null,
                ])]
            }
            return []
        })
        let connection = MizarConnection(
            configuration: .init(authority: "127.0.0.1:19390", token: "mz_test"),
            makeTransport: { transport },
        )
        return (connection, transport)
    }

    @Test("requests session.activity with the session id and nothing else by default")
    func requestShape() async throws {
        let (connection, transport) = makeConnection()
        _ = try await connection.connect()

        let result = try await connection.sessionActivity(sessionId: "s-1")
        #expect(result.turn == 4)
        #expect(result.entries.count == 4)

        let sent = await transport.sent
        let request = try #require(sent.last)
        #expect(frameType(of: request) == "session.activity")
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(request.utf8))
        #expect(decoded["payload"]?["sessionId"]?.stringValue == "s-1")
        // Omitted, not zero: the host's own default (200) is the cap the app
        // wants, and sending 0 would ask for an empty answer.
        #expect(decoded["payload"]?["maxEntries"] == nil)
    }

    @Test("passes maxEntries when the caller asks for a cap")
    func requestWithCap() async throws {
        let (connection, transport) = makeConnection()
        _ = try await connection.connect()
        _ = try await connection.sessionActivity(sessionId: "s-1", maxEntries: 50)

        let sent = await transport.sent
        let request = try #require(sent.last)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(request.utf8))
        #expect(decoded["payload"]?["maxEntries"]?.intValue == 50)
    }
}
