//
//  SubagentPageContract.swift
//  DSH-MizarTests
//
//  A delegated child's page is readable only if the parent travels with the
//  request, and only a child gets one.
//
//  The host does not address a subagent as a session. `session/follow` and
//  `session/page` refuse `{kind: "session"}` for a log whose header says
//  `origin: "subagent"`, before reading anything:
//
//      session/agent-busy: subagent Sessions require their durable parent address
//
//  -- so the subagent board, which reads each child's page to learn when a turn
//  began and how it ended, could never draw a finished child: its status stayed
//  blank and its elapsed time stayed zero, and every poll tick logged the same
//  failure.
//
//  The fix is one key on the request, and the two ways to lose it again are the
//  two fragments below: dropping the key, and sending it for a fork. A fork
//  carries a parent and is the operator's own conversation -- addressed as a
//  session, it reads fine; addressed as a child, it describes a log that is not
//  a subagent's.
//

import Testing
@testable import DSH_Mizar

struct SubagentPageContract {
    @Test
    func aChildsPageIsReadThroughItsParent() throws {
        try AppSourceContract.expectFragments(
            [
                // The key the plugin turns back into a subagent address.
                #"fields["parentSessionId"] = .string(parentSessionId)"#,
                // Resolved from the row, and only for a delegated child: the
                // host's own `origin` mark, not the mere presence of a parent.
                #"$0.sessionId == sessionId && $0.isSubagent"#,
            ],
            in: "DSH-Mizar/App/AppModel.swift",
            describing: "subagent page addressing",
        )
    }
}
