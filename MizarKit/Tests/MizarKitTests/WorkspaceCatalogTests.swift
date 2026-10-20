//
//  WorkspaceCatalogTests.swift
//  MizarKitTests
//
//  The rule that decides which workspaces the phone shows.
//
//  It was wrong twice, in the same direction: a session outlives its workspace,
//  so the directories in the session list are not the workspaces DSH has. The
//  list drew one row per directory (DSH: 4, phone: 10) and the new-session picker
//  offered all ten as places to start work.
//
//  Both screens now read from one function, and this is what that function
//  promises. The cases are written as the reports came in: a workspace that is
//  gone, a workspace that is real but empty, and a host that cannot answer at
//  all -- which must keep the old behaviour rather than hide somebody's work.
//

import Foundation
import Testing
@testable import MizarKit

@Suite("Workspace catalogue")
struct WorkspaceCatalogTests {
    /// A session row.
    ///
    /// - Parameters:
    ///   - id: the session id.
    ///   - cwd: its working directory, or `nil`.
    ///   - updatedAt: last activity, for ordering.
    ///   - blank: whether nobody has typed into it yet.
    ///   - subagent: whether it is a delegated child.
    ///   - forked: whether it is a "branch in a new conversation" fork.
    /// - Returns: the row.
    private func session(
        _ id: String,
        cwd: String? = "/Users/you/projects/demo",
        updatedAt: Double = 0,
        blank: Bool = false,
        subagent: Bool = false,
        forked: Bool = false,
    ) -> SessionRow {
        SessionRow(
            sessionId: id,
            updatedAt: updatedAt,
            running: false,
            blank: blank,
            agentAvailable: true,
            cwd: cwd,
            // A fork carries the source session as its parent and no subagent
            // origin; a delegated child carries the host's `origin`.
            parentSessionId: (subagent || forked) ? "parent" : nil,
            origin: subagent ? "subagent" : nil,
        )
    }

    /// A workspace row.
    ///
    /// - Parameters:
    ///   - id: the workspace id.
    ///   - path: the directory.
    ///   - title: DSH's name for it.
    ///   - sessionIds: what DSH filed under it, or `nil` for a host that did
    ///     not say — the two are different, and one of these tests is about that.
    /// - Returns: the row.
    private func workspace(
        _ id: String,
        _ path: String,
        title: String? = nil,
        sessionIds: [String]? = nil,
    ) -> WorkspaceRow {
        WorkspaceRow(
            workspaceId: id,
            path: path,
            title: title ?? (path as NSString).lastPathComponent,
            sessionIds: sessionIds,
        )
    }

    @Test("a workspace the host deleted is not a workspace row")
    func deletedWorkspaceIsNotADrawnWorkspace() {
        // The report, in its original shape: two sessions in workspaces DSH has,
        // plus one in a directory whose workspace was deleted -- which the host
        // still lists as a session, because deleting a workspace does not delete
        // the conversation in it. The deleted directory is not a section of its
        // own; the conversation it holds is collected with the rest.
        let groups = WorkspaceCatalog.groups(
            sessions: [
                session("s1", cwd: "/Users/you/projects/demo"),
                session("s2", cwd: "/Users/you/projects/other"),
                session("s3", cwd: "/Users/you/projects/deleted"),
            ],
            workspaces: [
                workspace("w1", "/Users/you/projects/demo", sessionIds: ["s1"]),
                workspace("w2", "/Users/you/projects/other", sessionIds: ["s2"]),
            ],
            selectedSessionId: nil,
        )
        #expect(groups.map(\.path) == [
            "/Users/you/projects/demo",
            "/Users/you/projects/other",
            WorkspaceGroup.unclaimedId,
        ])
        #expect(groups.filter { !$0.isUnclaimed }.map(\.sessions).map { $0.map(\.sessionId) }
            == [["s1"], ["s2"]])
        // Not gone, and not a workspace: one heading for everything the host has
        // no workspace for. Measured on the machine this was reported from, four
        // deleted workspaces held conversations of 269, 142, 89, 64 and 32
        // prompts, and the list is the only screen that can open one.
        #expect(groups.last?.title == "Not in a workspace")
        #expect(groups.last?.sessions.map(\.sessionId) == ["s3"])
    }

    @Test("the picker offers the host's workspaces and nothing else")
    func pickerOffersOnlyHostedWorkspaces() {
        // 手机app中有许多电脑端dsh已经删除的工作区 -- the picker was built from the
        // working directory of every session, so a deleted workspace stayed on
        // offer forever.
        let choices = WorkspaceCatalog.choices(
            sessions: [
                session("s1", cwd: "/Users/you/projects/demo"),
                session("s3", cwd: "/Users/you/projects/deleted"),
            ],
            workspaces: [workspace("w1", "/Users/you/projects/demo", sessionIds: ["s1"])],
        )
        #expect(choices.map(\.path) == ["/Users/you/projects/demo"])
        #expect(choices.first?.title == "demo")
    }

    @Test("an empty answer draws no workspace rows")
    func emptyAnswerDrawsNoWorkspaceRows() {
        // Somebody deleted their last workspace. `[]` is an answer -- it is what
        // the host sends when there is nothing left -- and the list has to
        // respect it, or the deleted workspaces stay on screen for good.
        let groups = WorkspaceCatalog.groups(
            sessions: [session("s1")],
            workspaces: [],
            selectedSessionId: nil,
        )
        #expect(groups.count == 1)
        #expect(groups.filter(\.isUnclaimed).count == 1)
        // The picker has nothing to offer at all, which is the difference that
        // matters: there is nowhere DSH recognises to start work.
        #expect(WorkspaceCatalog.choices(sessions: [session("s1")], workspaces: []).isEmpty)
    }

    @Test("a host that cannot answer keeps the old grouping")
    func unknownKeepsGroupingByDirectory() {
        // `nil` is not `[]`. Hiding a workspace somebody is working in is worse
        // than drawing one they deleted, so an unanswered question falls back to
        // the behaviour that shows everything.
        let groups = WorkspaceCatalog.groups(
            sessions: [
                session("s1", cwd: "/Users/you/projects/demo"),
                session("s3", cwd: "/Users/you/projects/deleted"),
            ],
            workspaces: nil,
            selectedSessionId: nil,
        )
        #expect(groups.map(\.path) == ["/Users/you/projects/deleted", "/Users/you/projects/demo"])
        #expect(
            WorkspaceCatalog.choices(
                sessions: [session("s1", cwd: "/a"), session("s2", cwd: "/a"), session("s3", cwd: "/b")],
                workspaces: nil,
            ).map(\.path) == ["/a", "/b"],
        )
    }

    @Test("a workspace with no sessions is still drawn")
    func emptyWorkspaceIsDrawn() {
        // It is in DSH's registry and on the computer's sidebar, so it is one of the
        // workspaces the phone is supposed to be counting.
        let groups = WorkspaceCatalog.groups(
            sessions: [session("s1", cwd: "/Users/you/projects/demo")],
            workspaces: [
                workspace("w1", "/Users/you/projects/demo", sessionIds: ["s1"]),
                workspace("w2", "/Users/you/projects/fresh"),
            ],
            selectedSessionId: nil,
        )
        #expect(groups.map(\.path) == ["/Users/you/projects/demo", "/Users/you/projects/fresh"])
        #expect(groups.last?.sessions.isEmpty == true)
        #expect(
            WorkspaceCatalog.choices(sessions: [], workspaces: [workspace("w2", "/Users/you/projects/fresh")])
                .map(\.path) == ["/Users/you/projects/fresh"],
        )
        // And an empty workspace is not a home for somebody else's sessions:
        // `sessionIds: []` is DSH saying nothing is filed there.
        #expect(groups.first?.sessions.map(\.sessionId) == ["s1"])
    }

    @Test("membership comes from the host, not from the path")
    func membershipComesFromTheHost() {
        // DSH's membership check is a canonical-cwd comparison against a header
        // it wrote itself, and the phone has no way to reproduce that: `/tmp/x`
        // and `/private/tmp/x` are one directory and two strings. So the id the
        // host filed is what decides, and this session is in the workspace its
        // path does not match.
        let groups = WorkspaceCatalog.groups(
            sessions: [session("s1", cwd: "/tmp/project")],
            workspaces: [workspace("w1", "/private/tmp/project", sessionIds: ["s1"])],
            selectedSessionId: nil,
        )
        #expect(groups.count == 1)
        #expect(groups.first?.sessions.map(\.sessionId) == ["s1"])
    }

    @Test("a host that sends no membership is matched on the path")
    func missingMembershipFallsBackToThePath() {
        // `nil` is a host from before membership was sent: it names the
        // directory and nothing else. Matching on it is what the phone did
        // anyway, and it is better than an empty workspace.
        let groups = WorkspaceCatalog.groups(
            sessions: [session("s1", cwd: "/Users/you/projects/demo")],
            workspaces: [workspace("w1", "/Users/you/projects/demo", sessionIds: nil)],
            selectedSessionId: nil,
        )
        #expect(groups.count == 1)
        #expect(groups.first?.sessions.map(\.sessionId) == ["s1"])
    }

    @Test("a host that says a workspace is empty is believed")
    func emptyMembershipIsBelieved() {
        // The one case the two spellings of "nothing" differ on. A workspace
        // deleted and recreated at the same directory has no sessions filed
        // under it, and matching on the path would hand it the dead workspace's
        // conversations -- which the computer does not have there either.
        let groups = WorkspaceCatalog.groups(
            sessions: [session("s1", cwd: "/Users/you/projects/demo")],
            workspaces: [workspace("w1", "/Users/you/projects/demo", sessionIds: [])],
            selectedSessionId: nil,
        )
        #expect(groups.map(\.path) == ["/Users/you/projects/demo", WorkspaceGroup.unclaimedId])
        #expect(groups.first?.sessions.isEmpty == true)
        #expect(groups.last?.sessions.map(\.sessionId) == ["s1"])
    }

    @Test("two workspaces claiming one directory are drawn once")
    func duplicatePathsAreDrawnOnce() {
        // The registry cannot hold two workspaces for one directory. The stream
        // fallback is not the registry, and a duplicate id in a `ForEach` is a
        // crash rather than a drawing mistake.
        let groups = WorkspaceCatalog.groups(
            sessions: [],
            workspaces: [
                workspace("w1", "/Users/you/projects/demo", title: "demo"),
                workspace("w2", "/Users/you/projects/demo", title: "again"),
            ],
            selectedSessionId: nil,
        )
        #expect(groups.map(\.path) == ["/Users/you/projects/demo"])
        #expect(
            WorkspaceCatalog.choices(sessions: [], workspaces: [
                workspace("w1", "/a"), workspace("w2", "/a"),
            ]).count == 1,
        )
    }

    @Test("a host row at the unclaimed sentinel falls back instead of colliding")
    func sentinelPathFallsBack() {
        // Not a path DSH can produce: a canonical workspace path is absolute.
        // If one arrives anyway, two rows sharing an id is a crash, so the whole
        // list is treated as unreadable and the list goes back to grouping by
        // directory -- which hides nothing.
        let groups = WorkspaceCatalog.groups(
            sessions: [session("s1", cwd: "/Users/you/projects/demo")],
            workspaces: [workspace("w1", WorkspaceGroup.unclaimedId, title: "odd", sessionIds: [])],
            selectedSessionId: nil,
        )
        #expect(groups.map(\.path) == ["/Users/you/projects/demo"])
        #expect(groups.filter(\.isUnclaimed).count == 0)
    }

    @Test("a workspace with no name is shown by its directory")
    func emptyTitleFallsBackToThePath() throws {
        // Built from JSON rather than through the initialiser, because the wire
        // is where an empty title would arrive and the decoder is what has to
        // deal with it.
        let json = #"{"workspaceId":"w1","path":"/Users/you/projects/demo","title":"","sessionIds":[]}"#
        let row = try JSONDecoder().decode(WorkspaceRow.self, from: Data(json.utf8))
        let groups = WorkspaceCatalog.groups(
            sessions: [],
            workspaces: [row],
            selectedSessionId: nil,
        )
        #expect(groups.first?.title == "/Users/you/projects/demo")
    }

    @Test("a session with no directory and no workspace is still reachable")
    func sessionWithoutADirectoryIsUnclaimed() {
        // Nothing on the computer's sidebar knows about it, and nothing on the phone
        // would either if the leftover group did not exist.
        let groups = WorkspaceCatalog.groups(
            sessions: [session("s1", cwd: nil)],
            workspaces: [workspace("w1", "/Users/you/projects/demo", sessionIds: [])],
            selectedSessionId: nil,
        )
        #expect(groups.map(\.path) == ["/Users/you/projects/demo", WorkspaceGroup.unclaimedId])
        #expect(groups.last?.sessions.map(\.sessionId) == ["s1"])
    }

    @Test("a malformed membership list does not cost the whole index")
    func malformedMembershipIsSurvived() throws {
        // `FileSessionIndexStore.load` is a `try?`: one row the decoder refuses
        // is a session list with no rows in it, which is the failure the store
        // exists to prevent. A membership list of the wrong shape reads as "the
        // host did not say", which hides nothing.
        let json = #"{"workspaceId":"w1","path":"/a","title":"A","sessionIds":[1,2]}"#
        let row = try JSONDecoder().decode(WorkspaceRow.self, from: Data(json.utf8))
        #expect(row.sessionIds == nil)
    }

    @Test("the unclaimed heading is not a place to start a session")
    func unclaimedIsNotOffered() {
        // Choosing one would recreate the workspace the operator deleted, so the
        // picker would quietly rebuild exactly what the report was about.
        #expect(
            WorkspaceCatalog.choices(
                sessions: [session("s3", cwd: "/Users/you/projects/deleted")],
                workspaces: [workspace("w1", "/Users/you/projects/demo", sessionIds: [])],
            ).map(\.path) == ["/Users/you/projects/demo"],
        )
    }

    @Test("DSH's own name for a workspace is the one shown")
    func hostTitleIsUsed() {
        // The operator is looking at this computer's sidebar. A workspace called two
        // different things on two screens is one they have to check twice.
        let groups = WorkspaceCatalog.groups(
            sessions: [],
            workspaces: [workspace("w1", "/Users/you/work/api-service", title: "API")],
            selectedSessionId: nil,
        )
        #expect(groups.first?.title == "API")
    }

    @Test("two directories with the same name are told apart when there is no host title")
    func clashingTitlesAreDisambiguated() {
        // Under the real home directory, because that is what the disambiguation
        // abbreviates against: two rows both reading "api" are two rows nobody
        // can choose between.
        let home = NSHomeDirectory()
        let groups = WorkspaceCatalog.groups(
            sessions: [session("s1", cwd: "\(home)/work/api"), session("s2", cwd: "\(home)/oss/api")],
            workspaces: nil,
            selectedSessionId: nil,
        )
        #expect(groups.map(\.title) == ["~/oss/api", "~/work/api"])
    }

    @Test("a conversation forked by \"branch in a new conversation\" is drawn")
    func forkedConversationsAreDrawn() {
        // The reported bug: DSH's fork button creates a session whose header has
        // a `parentSession` and no subagent origin. The app treated every parent
        // as a delegated child and hid the fork for ever -- the session existed
        // on the computer and never appeared on the phone, refresh included.
        let sessions = [
            session("s1", updatedAt: 3),
            session("s-fork", updatedAt: 2, forked: true),
            session("s-subagent", updatedAt: 1, subagent: true),
        ]
        let workspaces = [workspace("w1", "/Users/you/projects/demo", sessionIds: ["s1", "s-fork", "s-subagent"])]

        #expect(
            WorkspaceCatalog.groups(sessions: sessions, workspaces: workspaces, selectedSessionId: nil)
                .first?.sessions.map(\.sessionId) == ["s1", "s-fork"],
        )
        #expect(!sessions[1].isSubagent, "a forked conversation was treated as a delegated child")
        #expect(sessions[1].isFork)
        #expect(sessions[2].isSubagent)
    }

    @Test("subagents and blank sessions are left out, except the one being looked at")
    func subagentsAndBlankSessionsAreLeftOut() {
        let sessions = [
            session("s1", updatedAt: 3),
            session("s2", updatedAt: 2, subagent: true),
            session("s3", updatedAt: 1, blank: true),
        ]
        let workspaces = [workspace("w1", "/Users/you/projects/demo", sessionIds: ["s1", "s2", "s3"])]

        #expect(
            WorkspaceCatalog.groups(sessions: sessions, workspaces: workspaces, selectedSessionId: nil)
                .first?.sessions.map(\.sessionId) == ["s1"],
        )
        // A session created from the phone starts blank, and hiding the row the
        // operator just tapped would make it vanish under their finger.
        #expect(
            WorkspaceCatalog.groups(sessions: sessions, workspaces: workspaces, selectedSessionId: "s3")
                .first?.sessions.map(\.sessionId) == ["s1", "s3"],
        )
    }

    @Test("sessions are newest first inside a workspace")
    func sessionsAreNewestFirst() {
        let groups = WorkspaceCatalog.groups(
            sessions: [session("old", updatedAt: 1), session("new", updatedAt: 9)],
            workspaces: [workspace("w1", "/Users/you/projects/demo", sessionIds: ["old", "new"])],
            selectedSessionId: nil,
        )
        #expect(groups.first?.sessions.map(\.sessionId) == ["new", "old"])
    }
}

@Suite("Stored workspaces")
struct StoredWorkspaceTests {
    private func directory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mizar-workspaces-\(UUID().uuidString)")
    }

    @Test("a file written before the host sent membership still decodes")
    func decodesAnOlderFile() async throws {
        // The stored index outlives the build that wrote it. A file that will not
        // decode is a session list with no rows in it, and that is the failure the
        // whole store exists to prevent.
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = """
        {
          "hostId": "host-1",
          "sessions": [],
          "titles": {},
          "workspaces": [
            {"workspaceId": "w1", "path": "/Users/you/projects/demo", "title": "demo"}
          ],
          "updatedAt": 776000000
        }
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent("host-1.json"))

        let read = try #require(await FileSessionIndexStore(directory: dir).load(hostId: "host-1"))
        // A file written before membership existed reads as "the host did not
        // say", which is what it means -- not as "nothing is filed here".
        #expect(read.workspaces?.first?.sessionIds == nil)
        #expect(read.workspaces?.first?.title == "demo")
    }

    @Test("both spellings of membership survive the file")
    func membershipSurvivesTheFile() async throws {
        // The difference decides whether a session is matched by the id DSH
        // filed or by the directory it happens to sit in, and the phone reads it
        // back off disk on a launch that may never reach the computer. A round trip
        // that collapsed the two would put a dead workspace's conversations back
        // under a live one -- or lose a workspace's sessions entirely.
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileSessionIndexStore(directory: dir)
        await store.save(
            SessionIndex(
                hostId: "host-1",
                workspaces: [
                    WorkspaceRow(workspaceId: "w1", path: "/a", title: "A", sessionIds: []),
                    WorkspaceRow(workspaceId: "w2", path: "/b", title: "B", sessionIds: ["s1"]),
                    WorkspaceRow(workspaceId: "w3", path: "/c", title: "C", sessionIds: nil),
                ],
            ),
        )

        let read = try #require(await store.load(hostId: "host-1"))
        #expect(read.workspaces?.map(\.sessionIds) == [[], ["s1"], nil])

        // And on disk, not only in memory: absent for "the host did not say",
        // `[]` for "nothing is filed here". A later refactor that normalised one
        // into the other would change what the phone matches sessions on, and
        // this is the assertion that would fail.
        let raw = try Data(contentsOf: dir.appendingPathComponent("host-1.json"))
        let stored = try #require(
            JSONSerialization.jsonObject(with: raw) as? [String: Any],
        )
        let rows = try #require(stored["workspaces"] as? [[String: Any]])
        #expect(rows.count == 3)
        #expect(Set(rows[0].keys) == ["workspaceId", "path", "title", "sessionIds"])
        #expect(rows[0]["sessionIds"] as? [String] == [])
        #expect(Set(rows[2].keys) == ["workspaceId", "path", "title"])
    }

    @Test("an index with no workspaces at all reads as not knowing")
    func missingWorkspacesIsUnknown() async throws {
        // `nil`, not `[]`: a phone that has never been told must group by
        // directory, not decide the operator has no workspaces.
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"hostId": "host-1", "sessions": [], "titles": {}, "updatedAt": 776000000}"#.utf8)
            .write(to: dir.appendingPathComponent("host-1.json"))

        let read = try #require(await FileSessionIndexStore(directory: dir).load(hostId: "host-1"))
        #expect(read.workspaces == nil)
    }
}
