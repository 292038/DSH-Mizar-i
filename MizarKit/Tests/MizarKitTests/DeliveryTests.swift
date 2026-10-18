//
//  DeliveryTests.swift
//  MizarKitTests
//
//  Incremental delivery: what the phone claims to hold.
//
//  A refresh used to download the whole tail of a session every time -- the
//  phone already had every record and paid for them again on every pull,
//  reconnect and poll. The claim that fixes it is only as honest as the position
//  it is built from, so these tests pin the three pieces:
//
//    - the cursor's three wire forms (absent, null, number), because the host
//      treats each one differently;
//    - where a record sits in the log, in both shapes the gateway and the log
//      use;
//    - the position a page may claim -- the highest record it carried, never the
//      page's cutoff, because the budget can trim records out of that window.
//

import Foundation
import Testing

@testable import MizarKit

struct SessionMessagesCursorTests {
    @Test("makes no claim by leaving the key off the wire")
    func unstatedOmitsTheField() {
        #expect(SessionMessagesCursor.unstated.fieldValue == nil)
    }

    @Test("says null when the phone lost its cache")
    func emptySendsNull() {
        // An explicit null is not the same as an absent key: the host must send
        // a full page instead of answering from what it remembers delivering.
        #expect(SessionMessagesCursor.empty.fieldValue == .null)
    }

    @Test("sends the position as a number")
    func afterSendsThePosition() {
        #expect(SessionMessagesCursor.after(42).fieldValue == .number(42))
    }
}

struct SessionRecordPositionTests {
    /// Decode one page from JSON, the way the wire delivers it.
    ///
    /// - Parameter json - the result frame's body.
    /// - Returns: the decoded page.
    private func page(_ json: String) throws -> SessionMessagesResult {
        try JSONDecoder().decode(SessionMessagesResult.self, from: Data(json.utf8))
    }

    @Test("reads a position out of a wrapped record")
    func wrappedRecord() throws {
        let result = try page(
            #"{"sessionId":"s","asOfSeq":9,"hasMore":false,"records":[{"type":"event","event":{"type":"user/message","seq":8,"data":{}}}]}"#,
        )
        #expect(result.records.first?.seq == 8)
    }

    @Test("reads a position out of an unwrapped record")
    func unwrappedRecord() throws {
        // The log writes records with `seq` at the top level; the gateway wraps
        // them. A reader that only knew one shape would claim nothing for the
        // other and re-download it forever.
        let result = try page(
            #"{"sessionId":"s","asOfSeq":9,"hasMore":false,"records":[{"type":"user/message","seq":7,"data":{}}]}"#,
        )
        #expect(result.records.first?.seq == 7)
    }

    @Test("reports no position when the record names none")
    func unnumberedRecord() throws {
        let result = try page(
            #"{"sessionId":"s","asOfSeq":9,"hasMore":false,"records":[{"type":"event","event":{"type":"step/start","data":{}}}]}"#,
        )
        #expect(result.records.first?.seq == nil)
    }
}

struct DeliveredPositionTests {
    /// Decode one page from JSON, the way the wire delivers it.
    ///
    /// - Parameter json - the result frame's body.
    /// - Returns: the decoded page.
    private func page(_ json: String) throws -> SessionMessagesResult {
        try JSONDecoder().decode(SessionMessagesResult.self, from: Data(json.utf8))
    }

    @Test("claims the highest position the page carried")
    func newestRecordWins() throws {
        let result = try page(
            #"{"sessionId":"s","asOfSeq":40,"hasMore":false,"records":[{"type":"event","event":{"type":"step/start","seq":3,"data":{}}},{"type":"event","event":{"type":"user/message","seq":5,"data":{}}}]}"#,
        )
        #expect(result.newestDeliveredSeq == 5)
    }

    @Test("claims nothing when no record names a position")
    func noPositions() throws {
        let result = try page(
            #"{"sessionId":"s","asOfSeq":40,"hasMore":false,"records":[{"type":"event","event":{"type":"step/start","data":{}}}]}"#,
        )
        #expect(result.newestDeliveredSeq == nil)
    }

    @Test("does not claim the page's cutoff")
    func notTheCut() throws {
        // `asOfSeq` is the log cut the page was taken at. The host's byte budget
        // trims from the old end of that window, so claiming the cut would claim
        // records that never travelled -- and the phone would never ask for them
        // again.
        let result = try page(
            #"{"sessionId":"s","asOfSeq":40,"hasMore":false,"records":[{"type":"event","event":{"type":"user/message","seq":2,"data":{}}}]}"#,
        )
        #expect(result.newestDeliveredSeq == 2)
    }
}

struct CachedDeliveredPositionTests {
    @Test("a delivered position survives the cache")
    func roundTrip() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mizar-delivery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = FileConversationCache(directory: directory)
        await cache.save(
            CachedConversation(
                sessionId: "s1",
                items: [],
                throughSeq: 42,
                deliveredSeq: 37,
            ),
        )

        let loaded = try #require(await cache.load(sessionId: "s1"))
        #expect(loaded.deliveredSeq == 37)
        // The cutoff and the claim are different numbers on purpose: a page can
        // have ended at 42 while the highest record inside it was 37.
        #expect(loaded.throughSeq == 42)
    }

    @Test("a cache written before positions existed still decodes")
    func oldCacheDecodes() throws {
        // The cache is a file format and it outlives a build. A file from the
        // previous version has no `deliveredSeq` key, and the phone must read it
        // as "no claim" rather than fail to read a conversation at all.
        let json = #"{"sessionId":"s1","items":[],"throughSeq":3,"syncedAt":0,"hasMore":false}"#
        let decoded = try JSONDecoder().decode(
            CachedConversation.self,
            from: Data(json.utf8),
        )
        #expect(decoded.deliveredSeq == nil)
        #expect(decoded.throughSeq == 3)
    }
}
