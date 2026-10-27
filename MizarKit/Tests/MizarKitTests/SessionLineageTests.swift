//
//  SessionLineageTests.swift
//  MizarKitTests
//
//  What makes a session a delegated child, and what does not.
//
//  The reported bug: a conversation created with DSH's "branch in a new
//  conversation" (fork) appeared on the computer and never on the phone, not
//  even after a refresh. The app decided "subagent" from either the host's
//  `origin` or the presence of `parentSessionId`; a fork carries the parent
//  (it was copied from that session) and no origin, so every forked
//  conversation was filtered out of the list, the history sync and the island.
//
//  A real DSH session header from this machine, for the record:
//
//      { parentSession: "session-31e3001a-…", isSeeded: true, … }   // fork
//      { parentSession: "session-58a0f140-…", origin: "subagent",
//        delegationDepth: 1, … }                                    // child
//
//  So `parentSessionId` is lineage, `origin` is classification, and only the
//  second one decides. These tests pin that from the wire shape the phone
//  decodes, so a future "the two marks mean the same thing" cannot creep back.
//

import Foundation
import Testing

@testable import MizarKit

struct SessionLineageTests {
    /// Decode one row from its JSON, the way `session.list` delivers it.
    private func row(_ json: String) throws -> SessionRow {
        try JSONDecoder().decode(SessionRow.self, from: Data(json.utf8))
    }

    @Test("a session with no lineage is neither a fork nor a child")
    func topLevel() throws {
        let row = try row(#"""
        {"sessionId":"s1","updatedAt":1000,"running":false,"blank":false,
         "agentAvailable":true,"cwd":"/Users/you/projects/demo"}
        """#)
        #expect(!row.isSubagent)
        #expect(!row.isFork)
    }

    @Test("a forked conversation is a top-level session, not a subagent")
    func forkedIsTopLevel() throws {
        // The reported shape: parentSession set, no origin, isSeeded on the
        // header. `isSeeded` is not even carried by `session.list` -- the parent
        // is the only lineage field the phone sees -- which is exactly why the
        // parent alone must not mean "subagent".
        let row = try row(#"""
        {"sessionId":"fork-1","updatedAt":2000,"running":false,"blank":false,
         "agentAvailable":true,"cwd":"/Users/you/projects/demo",
         "parentSessionId":"session-source-1"}
        """#)
        #expect(!row.isSubagent, "a forked conversation was treated as a delegated child")
        #expect(row.isFork)
    }

    @Test("a delegated child is a subagent")
    func delegatedChild() throws {
        let row = try row(#"""
        {"sessionId":"child-1","updatedAt":3000,"running":true,"blank":false,
         "agentAvailable":true,"cwd":"/Users/you/projects/demo",
         "parentSessionId":"session-source-1","origin":"subagent"}
        """#)
        #expect(row.isSubagent)
        #expect(!row.isFork)
    }

    @Test("the host's origin alone is enough to classify a child")
    func childMarkedOnlyByOrigin() throws {
        // A host that does not send parentSessionId for a child still marks the
        // origin; the classification is the host's, not a guess from lineage.
        let row = try row(#"""
        {"sessionId":"child-2","updatedAt":3000,"running":false,"blank":false,
         "agentAvailable":false,"origin":"subagent"}
        """#)
        #expect(row.isSubagent)
    }

    @Test("a child is counted only under its own parent")
    func countedOnlyUnderItsParent() throws {
        // The drawer's Subagents tab counts with this predicate and the page
        // lists with it too, so "which parent" has to be part of the answer.
        // The plane stays mounted while no conversation is open, which is why a
        // nil parent is a miss rather than "no parent on either side".
        let child = try row(#"""
        {"sessionId":"child-1","updatedAt":3000,"running":false,"blank":false,
         "agentAvailable":true,"parentSessionId":"session-source-1","origin":"subagent"}
        """#)
        #expect(child.isSubagent(of: "session-source-1"))
        #expect(!child.isSubagent(of: "session-source-2"))
        #expect(!child.isSubagent(of: nil))

        let fork = try row(#"""
        {"sessionId":"fork-1","updatedAt":2000,"running":false,"blank":false,
         "agentAvailable":true,"parentSessionId":"session-source-1"}
        """#)
        #expect(!fork.isSubagent(of: "session-source-1"))

        let top = try row(#"""
        {"sessionId":"s1","updatedAt":1000,"running":false,"blank":false,
         "agentAvailable":true}
        """#)
        #expect(!top.isSubagent(of: nil))
        #expect(!top.isSubagent(of: "session-source-1"))
    }

    @Test("unknown future origins are not subagents")
    func unknownOriginIsNotAChild() throws {
        // `origin` is a product classification the host may grow. An unknown
        // value must not silently become "delegated child" -- hiding a session
        // is the failure that cannot be seen from the phone at all.
        let row = try row(#"""
        {"sessionId":"s9","updatedAt":3000,"running":false,"blank":false,
         "agentAvailable":true,"origin":"something-new"}
        """#)
        #expect(!row.isSubagent)
    }
}
