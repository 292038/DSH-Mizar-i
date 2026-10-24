//
//  WorkspaceCatalog.swift
//  MizarKit
//
//  Which workspaces the phone shows, and which sessions are in them.
//
//  This is the rule that was wrong twice. The phone has no workspace API of its
//  own to draw from, so it used the working directory in a session's header as a
//  stand-in — and a session outlives its workspace. Deleting a workspace removes
//  the host's registry entry and leaves the session log on disk, so `session.list`
//  keeps answering with sessions from directories DSH no longer recognises. The
//  session list drew one row per directory any session had ever used (DSH: 4
//  workspaces, phone: 10) and the new-session picker offered all ten as places to
//  start work — "手机app中有许多电脑端dsh已经删除的工作区".
//
//  The fix is not a better guess. It is asking the host, which knows: it sends
//  its workspaces and each one's session membership, and this file arranges
//  exactly what it sent. Where the host cannot say, the old grouping stays — not
//  because it is right, but because hiding a workspace somebody is working in is
//  worse than drawing one they deleted.
//
//  The whole rule lives here, away from both screens, so that the difference
//  between the two cases is one function that can be read and tested instead of
//  two `body`s that have to agree.
//

import Foundation

/// One workspace as the list draws it: a heading, and the sessions under it.
public struct WorkspaceGroup: Sendable, Equatable, Identifiable {
    /// The directory, which is what the row is identified by.
    public let path: String
    /// What to call it.
    public let title: String
    /// The sessions in it, newest activity first.
    public let sessions: [SessionRow]

    /// The path, because two workspaces cannot share one.
    public var id: String { path }

    /// The sentinel a group of sessions no workspace claims is identified by.
    ///
    /// Not a path, and deliberately not shaped like one: DSH canonicalises a
    /// workspace path through `fs.realpath`, so every real one is absolute, and
    /// the row's accessibility identifier stays stable enough to test against.
    /// The invariant is enforced rather than assumed — a list containing this
    /// string as a path falls back to grouping by directory instead of drawing
    /// two rows with one id.
    public static let unclaimedId = "not-in-a-workspace"

    /// Whether this group is the host's workspace list's leftover.
    ///
    /// Read by the section header: this group is drawn differently from a
    /// workspace on purpose, so that "not a workspace" is something the operator
    /// can see rather than something they have to read.
    public var isUnclaimed: Bool { path == Self.unclaimedId }

    public init(path: String, title: String, sessions: [SessionRow]) {
        self.path = path
        self.title = title
        self.sessions = sessions
    }
}

/// One place a session can be started.
public struct WorkspaceChoice: Sendable, Equatable, Identifiable {
    public let path: String
    public let title: String

    public var id: String { path }

    public init(path: String, title: String) {
        self.path = path
        self.title = title
    }
}

/// The workspaces the host has, arranged for the two screens that show them.
public enum WorkspaceCatalog {
    /// The sections of the session list.
    ///
    /// - Parameters:
    ///   - sessions: every row the host listed.
    ///   - workspaces: the host's workspaces, or `nil` when it has not said.
    ///     An empty array is an answer — the operator has no workspaces left —
    ///     and draws no workspace rows.
    ///   - selectedSessionId: the session the operator is looking at, which is
    ///     exempt from the blank-session rule below.
    /// - Returns: one group per workspace, in the host's order, or one group per
    ///   working directory when the host has not said. Sessions no workspace
    ///   claims are collected into one final group — see {@link unclaimed}.
    public static func groups(
        sessions: [SessionRow],
        workspaces: [WorkspaceRow]?,
        selectedSessionId: String?,
    ) -> [WorkspaceGroup] {
        let drawn = sessions.filter { isDrawn($0, selectedSessionId: selectedSessionId) }

        guard let workspaces else {
            // The host has not said. Group on the working directory, which is
            // what the phone did before it could ask.
            var byPath: [String: [SessionRow]] = [:]
            for session in drawn {
                byPath[session.cwd ?? "", default: []].append(session)
            }
            let paths = byPath.keys.sorted { lhs, rhs in
                // Sessions with no working directory last: they are the ones an
                // operator can least identify, so they should not lead.
                if lhs.isEmpty != rhs.isEmpty { return !lhs.isEmpty }
                return lhs < rhs
            }
            return paths.map { path in
                WorkspaceGroup(
                    path: path,
                    title: title(for: path, among: paths),
                    sessions: newestFirst(byPath[path] ?? []),
                )
            }
        }

        // A host row at the sentinel path would collide with the unclaimed
        // group's id, and two rows sharing one id in a `ForEach` is a crash
        // rather than a drawing mistake. DSH cannot produce it -- a canonical
        // workspace path is absolute -- so the answer is the same as for any
        // other list this cannot read: fall back, and hide nothing.
        guard !workspaces.contains(where: { $0.path == WorkspaceGroup.unclaimedId }) else {
            return groups(sessions: sessions, workspaces: nil, selectedSessionId: selectedSessionId)
        }

        // One row per path. The registry cannot hold two workspaces for one
        // directory, but the stream fallback can hand over a list that does --
        // and duplicate ids in a `ForEach` are not a drawing mistake, they are a
        // crash.
        var seen = Set<String>()
        var claimed = Set<String>()
        let groups = workspaces.compactMap { workspace -> WorkspaceGroup? in
            guard seen.insert(workspace.path).inserted else { return nil }
            // Membership when the host sent it. Paths only when it did not:
            // a host from before this existed names the directory and
            // nothing else, and the phone is no worse off matching on it.
            //
            // The membership list is scanned once per drawn session. Above
            // ``membershipIndexThreshold`` members the list is indexed once
            // per workspace instead: a set costs an allocation and a hash per
            // session, and saves a scan of the whole list each time. Below it
            // the scan stays -- the set would cost more than the comparisons
            // it saves. A refresh with nothing drawn takes the scan either
            // way: there is no session to look up, so a set would be built
            // and never asked.
            let held: [SessionRow]
            if let members = workspace.sessionIds,
               !drawn.isEmpty,
               members.count >= Self.membershipIndexThreshold {
                let index = Set(members)
                held = drawn.filter { index.contains($0.sessionId) }
            } else if let members = workspace.sessionIds {
                held = drawn.filter { members.contains($0.sessionId) }
            } else {
                held = drawn.filter { $0.cwd == workspace.path }
            }
            for session in held { claimed.insert(session.sessionId) }
            return WorkspaceGroup(
                path: workspace.path,
                // DSH's own name, repeated rather than improved on: the operator
                // is looking at this computer's sidebar, and a workspace called two
                // different things on two screens is a workspace they have to
                // check twice. An empty one is not a name, so the directory is
                // shown instead of a heading with nothing under it.
                title: workspace.title.isEmpty ? workspace.path : workspace.title,
                sessions: newestFirst(held),
            )
        }

        let unclaimed = drawn.filter { !claimed.contains($0.sessionId) }
        guard !unclaimed.isEmpty else { return groups }
        return groups + [unclaimedGroup(unclaimed)]
    }

    /// The membership-list length from which a per-workspace set replaces the
    /// array scan.
    ///
    /// Measured on 2026-10-23 in release on this Apple-silicon host, against a
    /// frozen copy of the old scan, on synthetic shapes -- not a real host's
    /// workspace list, and not a device measurement. Per-shape medians for the
    /// shipped function, the frozen scan and each membership strategy are in
    /// `docs/evidence/ios-workspace-catalog-benchmark-2026-10-23.json`.
    ///
    /// Not a universal crossover: the win depends on sessions and workspaces
    /// as well as on the list length, and only the shapes in that file were
    /// measured. Eight is the first member count at which the set won at both
    /// measured session scales, and it is a member-count rule -- not one that
    /// knows how many sessions will be looked up.
    private static let membershipIndexThreshold = 8

    /// The sessions no workspace claims, under one heading.
    ///
    /// This is the half of the report that is not about workspaces. A workspace
    /// the operator deleted leaves its sessions behind — on the machine this was
    /// fixed on, four deleted workspaces held conversations of 269, 142, 89, 64
    /// and 32 prompts — and DSH's own sidebar does not show them, because it is
    /// built from workspaces and they belong to none.
    ///
    /// The phone could match that exactly by drawing nothing, and the rows would
    /// then be gone from the only screen that can open a conversation: the list
    /// is the only route in, so "not a workspace" would quietly become "not
    /// reachable". One clearly-labelled heading is the honest middle: it is not a
    /// workspace, it is not offered as somewhere to start work (see
    /// {@link choices}), and nothing the operator can still read is lost.
    ///
    /// - Parameter sessions: the rows to collect.
    /// - Returns: the group.
    private static func unclaimedGroup(_ sessions: [SessionRow]) -> WorkspaceGroup {
        WorkspaceGroup(
            path: WorkspaceGroup.unclaimedId,
            title: String(localized: "Not in a workspace"),
            sessions: newestFirst(sessions),
        )
    }

    /// Where a new session can be started.
    ///
    /// The same rule as {@link groups}, without the sessions and **without** the
    /// unclaimed group: the host's workspaces when it has said, and the
    /// directories its sessions have used when it has not. Every workspace is
    /// offered, including the ones holding no sessions — that is what the computer
    /// offers, and a folder the operator opened five minutes ago is exactly
    /// where they want to start something.
    ///
    /// A directory whose workspace was deleted is deliberately *not* offered,
    /// even though sessions still live in it. That was the report this answers,
    /// verbatim: "手机app中有许多电脑端dsh已经删除的工作区". Choosing one would
    /// also recreate it on the host, so the picker would be quietly rebuilding
    /// the workspaces the operator had just deleted.
    ///
    /// - Parameters:
    ///   - sessions: every row the host listed.
    ///   - workspaces: the host's workspaces, or `nil` when it has not said.
    /// - Returns: the directories to offer — DSH's own order when it has said,
    ///   and the order its sessions were listed in (newest activity first) when
    ///   it has not.
    public static func choices(
        sessions: [SessionRow],
        workspaces: [WorkspaceRow]?,
    ) -> [WorkspaceChoice] {
        guard let workspaces else {
            var seen = Set<String>()
            return sessions
                .compactMap(\.cwd)
                .filter { seen.insert($0).inserted }
                .map { WorkspaceChoice(path: $0, title: ($0 as NSString).lastPathComponent) }
        }
        var paths = Set<String>()
        return workspaces.compactMap { workspace in
            guard paths.insert(workspace.path).inserted else { return nil }
            let title = workspace.title.isEmpty ? workspace.path : workspace.title
            return WorkspaceChoice(path: workspace.path, title: title)
        }
    }

    /// The rows in the order an operator reads them: newest activity first.
    ///
    /// The id breaks ties, and that is not decoration: Swift's sort is not
    /// stable, so two sessions sharing a timestamp could swap places between one
    /// refresh and the next -- rows moving under the operator's finger while
    /// nothing about them changed.
    ///
    /// - Parameter sessions: the rows to order.
    /// - Returns: the rows, newest first.
    private static func newestFirst(_ sessions: [SessionRow]) -> [SessionRow] {
        sessions.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.sessionId < rhs.sessionId
        }
    }

    /// Whether the list draws a row for this session at all.
    ///
    /// Two exclusions, both of which the list used to get wrong in the same
    /// direction — by showing rows DSH's own list does not.
    ///
    /// Subagents are left out. They are real sessions, but they are the agent's
    /// bookkeeping rather than the operator's work, and a list where half the
    /// rows are delegated children is a list nobody can scan. A **forked**
    /// conversation is not a subagent: DSH's "branch in a new conversation"
    /// carries the source session as its parent without the host's subagent
    /// `origin`, and it is the operator's conversation, so it is drawn.
    ///
    /// `blank` is a session nobody has typed into yet. It has no title, no turns
    /// and no messages, so as a row it reads as ``<dir> · session-`` with a
    /// timestamp — indistinguishable from a real conversation and impossible to
    /// act on. Measured against a live host, one workspace held eight rows of
    /// which five were subagents and two were blank; DSH's own list showed the
    /// remaining one, and this one showed three.
    ///
    /// The selected session is exempt: a session created from the phone starts
    /// blank, and hiding it the moment it is created would make the row the
    /// operator just tapped vanish under their finger.
    ///
    /// - Parameters:
    ///   - session: the row.
    ///   - selectedSessionId: the session the operator is looking at.
    /// - Returns: whether to draw it.
    private static func isDrawn(_ session: SessionRow, selectedSessionId: String?) -> Bool {
        guard !session.isSubagent else { return false }
        return !session.blank || session.sessionId == selectedSessionId
    }

    /// What to call a working directory the host did not name.
    ///
    /// The last path component, with the parent shown when two would collide —
    /// `~/work/api` and `~/personal/api` are both "api", and two identical
    /// headings is a list nobody can navigate.
    ///
    /// - Parameters:
    ///   - path: the directory.
    ///   - paths: every directory in the list, for the collision test.
    /// - Returns: the heading.
    private static func title(for path: String, among paths: [String]) -> String {
        if path.isEmpty { return String(localized: "No workspace") }
        let name = (path as NSString).lastPathComponent
        let clashes = paths.filter { ($0 as NSString).lastPathComponent == name }
        guard clashes.count > 1 else { return name }
        return (path as NSString).abbreviatingWithTildeInPath
    }
}
