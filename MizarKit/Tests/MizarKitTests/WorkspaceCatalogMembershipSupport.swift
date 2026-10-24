//
//  WorkspaceCatalogMembershipSupport.swift
//  MizarKitTests
//
//  Test-only pieces for the `WorkspaceCatalog.groups` membership-index question.
//
//  The production function answers one question per drawn session and per
//  workspace: is this session filed under this workspace? Today it asks with
//  `members.contains(_:)` on the host's `[String]`, so one refresh costs
//  O(S x sum(M_w)) string comparisons. The candidate asks a `Set` built once per
//  workspace instead. Nothing else in the function moves.
//
//  Three things live here:
//
//  - ``FrozenWorkspaceCatalog``: a verbatim copy of `groups` as it is today,
//    array membership included. It is frozen on purpose. The differential tests
//    compare the real production function against it, so a later refactor cannot
//    quietly change what an operator sees and still pass.
//  - ``CandidateWorkspaceCatalog``: the same function with the membership step
//    selectable (array, set, or set only from a size threshold), so each
//    strategy can be checked against the frozen oracle and timed.
//  - ``WorkspaceCatalogSamples``: deterministic hand-written inputs plus a
//    seeded generator. Synthetic data only -- these shapes model the calls the
//    function makes, not a real host's workspace list.
//

import Foundation
@testable import MizarKit

/// One `WorkspaceCatalog.groups` call, with a name for failure messages.
struct WorkspaceCatalogInput: Sendable {
    let name: String
    let sessions: [SessionRow]
    let workspaces: [WorkspaceRow]?
    let selectedSessionId: String?
}

// MARK: - The frozen oracle

/// `WorkspaceCatalog.groups` exactly as it is before the membership change.
///
/// Copied rather than called so the differential has two independent
/// implementations: this one, and whatever production becomes. The body is
/// deliberately the old one, `members.contains` and all. Do not "improve" it --
/// an oracle that tracks the implementation cannot detect a change in it.
enum FrozenWorkspaceCatalog {
    static func groups(
        sessions: [SessionRow],
        workspaces: [WorkspaceRow]?,
        selectedSessionId: String?,
    ) -> [WorkspaceGroup] {
        let drawn = sessions.filter { isDrawn($0, selectedSessionId: selectedSessionId) }

        guard let workspaces else {
            var byPath: [String: [SessionRow]] = [:]
            for session in drawn {
                byPath[session.cwd ?? "", default: []].append(session)
            }
            let paths = byPath.keys.sorted { lhs, rhs in
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

        guard !workspaces.contains(where: { $0.path == WorkspaceGroup.unclaimedId }) else {
            return groups(sessions: sessions, workspaces: nil, selectedSessionId: selectedSessionId)
        }

        var seen = Set<String>()
        var claimed = Set<String>()
        let groups = workspaces.compactMap { workspace -> WorkspaceGroup? in
            guard seen.insert(workspace.path).inserted else { return nil }
            let held = drawn.filter { session in
                guard let members = workspace.sessionIds else { return session.cwd == workspace.path }
                return members.contains(session.sessionId)
            }
            for session in held { claimed.insert(session.sessionId) }
            return WorkspaceGroup(
                path: workspace.path,
                title: workspace.title.isEmpty ? workspace.path : workspace.title,
                sessions: newestFirst(held),
            )
        }

        let unclaimed = drawn.filter { !claimed.contains($0.sessionId) }
        guard !unclaimed.isEmpty else { return groups }
        return groups + [unclaimedGroup(unclaimed)]
    }

    private static func unclaimedGroup(_ sessions: [SessionRow]) -> WorkspaceGroup {
        WorkspaceGroup(
            path: WorkspaceGroup.unclaimedId,
            title: String(localized: "Not in a workspace"),
            sessions: newestFirst(sessions),
        )
    }

    private static func newestFirst(_ sessions: [SessionRow]) -> [SessionRow] {
        sessions.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.sessionId < rhs.sessionId
        }
    }

    private static func isDrawn(_ session: SessionRow, selectedSessionId: String?) -> Bool {
        guard !session.isSubagent else { return false }
        return !session.blank || session.sessionId == selectedSessionId
    }

    private static func title(for path: String, among paths: [String]) -> String {
        if path.isEmpty { return String(localized: "No workspace") }
        let name = (path as NSString).lastPathComponent
        let clashes = paths.filter { ($0 as NSString).lastPathComponent == name }
        guard clashes.count > 1 else { return name }
        return (path as NSString).abbreviatingWithTildeInPath
    }
}

// MARK: - Candidate strategies

/// How a workspace's membership list is asked whether it holds a session.
enum CatalogMembershipStrategy: Sendable, Equatable {
    /// `members.contains(session.sessionId)` -- the current production step.
    case array
    /// `Set(members).contains(session.sessionId)`, with the set built once per
    /// workspace (inside the group loop, so the build is part of the measured
    /// work).
    case set
    /// Array below `threshold` members, set at or above it.
    case hybridFrom(Int)

    /// A short name for benchmark output.
    var label: String {
        switch self {
        case .array: "array"
        case .set: "set"
        case .hybridFrom(let threshold): "hybrid>=\(threshold)"
        }
    }
}

/// `WorkspaceCatalog.groups` with the membership step selectable.
///
/// Everything except the membership lookup is the same code as the frozen
/// oracle -- same drawn filter, same path deduplication, same host order, same
/// sorting, same unclaimed tail. Swapping only this one decision is the point of
/// the experiment.
enum CandidateWorkspaceCatalog {
    static func groups(
        sessions: [SessionRow],
        workspaces: [WorkspaceRow]?,
        selectedSessionId: String?,
        strategy: CatalogMembershipStrategy,
    ) -> [WorkspaceGroup] {
        let drawn = sessions.filter { isDrawn($0, selectedSessionId: selectedSessionId) }

        guard let workspaces else {
            var byPath: [String: [SessionRow]] = [:]
            for session in drawn {
                byPath[session.cwd ?? "", default: []].append(session)
            }
            let paths = byPath.keys.sorted { lhs, rhs in
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

        guard !workspaces.contains(where: { $0.path == WorkspaceGroup.unclaimedId }) else {
            return groups(sessions: sessions, workspaces: nil, selectedSessionId: selectedSessionId, strategy: strategy)
        }

        var seen = Set<String>()
        var claimed = Set<String>()
        let groups = workspaces.compactMap { workspace -> WorkspaceGroup? in
            guard seen.insert(workspace.path).inserted else { return nil }
            let held = heldSessions(from: drawn, workspace: workspace, strategy: strategy)
            for session in held { claimed.insert(session.sessionId) }
            return WorkspaceGroup(
                path: workspace.path,
                title: workspace.title.isEmpty ? workspace.path : workspace.title,
                sessions: newestFirst(held),
            )
        }

        let unclaimed = drawn.filter { !claimed.contains($0.sessionId) }
        guard !unclaimed.isEmpty else { return groups }
        return groups + [unclaimedGroup(unclaimed)]
    }

    /// The sessions this workspace holds, with the membership index under test.
    ///
    /// The host's membership list is asked once per workspace, as production
    /// would: a set built here is the whole candidate, not a set built per
    /// session.
    private static func heldSessions(
        from drawn: [SessionRow],
        workspace: WorkspaceRow,
        strategy: CatalogMembershipStrategy,
    ) -> [SessionRow] {
        guard let members = workspace.sessionIds else {
            return drawn.filter { $0.cwd == workspace.path }
        }
        switch strategy {
        case .array:
            return drawn.filter { members.contains($0.sessionId) }
        case .set:
            let index = Set(members)
            return drawn.filter { index.contains($0.sessionId) }
        case .hybridFrom(let threshold):
            guard members.count >= threshold else {
                return drawn.filter { members.contains($0.sessionId) }
            }
            let index = Set(members)
            return drawn.filter { index.contains($0.sessionId) }
        }
    }

    private static func unclaimedGroup(_ sessions: [SessionRow]) -> WorkspaceGroup {
        WorkspaceGroup(
            path: WorkspaceGroup.unclaimedId,
            title: String(localized: "Not in a workspace"),
            sessions: newestFirst(sessions),
        )
    }

    private static func newestFirst(_ sessions: [SessionRow]) -> [SessionRow] {
        sessions.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.sessionId < rhs.sessionId
        }
    }

    private static func isDrawn(_ session: SessionRow, selectedSessionId: String?) -> Bool {
        guard !session.isSubagent else { return false }
        return !session.blank || session.sessionId == selectedSessionId
    }

    private static func title(for path: String, among paths: [String]) -> String {
        if path.isEmpty { return String(localized: "No workspace") }
        let name = (path as NSString).lastPathComponent
        let clashes = paths.filter { ($0 as NSString).lastPathComponent == name }
        guard clashes.count > 1 else { return name }
        return (path as NSString).abbreviatingWithTildeInPath
    }
}

// MARK: - A checksum for outputs

/// A stable fingerprint of a groups array.
///
/// The benchmark reads the result so the optimizer cannot drop the work; the
/// differential compares the full arrays, so this is only a cheap "the output
/// was really produced" witness. FNV-1a, not `Hasher`, so it is reproducible
/// across runs and processes.
enum CatalogFingerprint {
    static func of(_ groups: [WorkspaceGroup]) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ value: UInt64) {
            hash ^= value
            hash &*= 0x0000_0100_0000_01b3
        }
        func mix(_ string: String) {
            for byte in string.utf8 { mix(UInt64(byte)) }
            mix(0xFFFF)
        }
        mix(UInt64(groups.count))
        for group in groups {
            mix(group.path)
            mix(group.title)
            mix(UInt64(group.sessions.count))
            for session in group.sessions {
                mix(session.sessionId)
                mix(UInt64(session.updatedAt.bitPattern))
            }
        }
        return hash
    }
}

// MARK: - Deterministic samples

/// Hand-written and seeded inputs for the differential.
///
/// Synthetic on purpose. These are the shapes production's rules mention --
/// `nil` versus `[]` membership, duplicate paths, duplicate members, duplicate
/// session ids, cross-group overlap, the sentinel, blank/subagent/selected,
/// claimed/unclaimed, ties in `newestFirst` -- not a measurement of any real
/// machine's workspace list.
enum WorkspaceCatalogSamples {
    private static let demo = "/Users/you/projects/demo"
    private static let other = "/Users/you/projects/other"
    private static let deleted = "/Users/you/projects/deleted"

    /// A membership list long enough to be indexed, naming no session these
    /// empty-session inputs contain. Only its length matters here.
    private static let longMembership = (0..<12).map { "member-\($0)" }

    static func session(
        _ id: String,
        cwd: String? = demo,
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
            parentSessionId: (subagent || forked) ? "parent" : nil,
            origin: subagent ? "subagent" : nil,
        )
    }

    static func workspace(
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

    static var handWritten: [WorkspaceCatalogInput] {
        [
            // The host has not said anything at all: directory grouping, and a
            // session with no directory at all.
            WorkspaceCatalogInput(
                name: "unknown-host",
                sessions: [session("s1"), session("s2", cwd: other), session("s3", cwd: nil)],
                workspaces: nil,
                selectedSessionId: nil,
            ),
            // An empty answer: no workspace rows, everything unclaimed.
            WorkspaceCatalogInput(
                name: "empty-host-list",
                sessions: [session("s1"), session("s2", cwd: other)],
                workspaces: [],
                selectedSessionId: nil,
            ),
            // A host list whose rows say nothing, `[]` and a real membership.
            WorkspaceCatalogInput(
                name: "mixed-membership-forms",
                sessions: [
                    session("s1", cwd: demo),
                    session("s2", cwd: other),
                    session("s3", cwd: deleted),
                ],
                workspaces: [
                    workspace("w1", demo, sessionIds: nil),
                    workspace("w2", other, sessionIds: []),
                    workspace("w3", "/Users/you/projects/third", sessionIds: ["s3"]),
                ],
                selectedSessionId: nil,
            ),
            // Two host rows for one directory: the second is dropped, and its
            // membership list must not claim anything.
            WorkspaceCatalogInput(
                name: "duplicate-path",
                sessions: [session("s1"), session("s2", cwd: other)],
                workspaces: [
                    workspace("w1", demo, title: "demo", sessionIds: ["s1"]),
                    workspace("w2", demo, title: "again", sessionIds: ["s1", "s2"]),
                    workspace("w3", other, sessionIds: []),
                ],
                selectedSessionId: nil,
            ),
            // Duplicate member ids in one list.
            WorkspaceCatalogInput(
                name: "duplicate-members",
                sessions: [session("s1"), session("s2")],
                workspaces: [
                    workspace("w1", demo, sessionIds: ["s1", "s1", "s2", "s1"]),
                ],
                selectedSessionId: nil,
            ),
            // Nothing drawn, and membership lists long enough to be indexed: a
            // set built here would be built and never asked. The answer has to
            // stay "no rows", and the duplicate path in the host's list must
            // still be dropped rather than drawn twice.
            WorkspaceCatalogInput(
                name: "empty-sessions-long-membership",
                sessions: [],
                workspaces: [
                    workspace("w1", demo, title: "demo", sessionIds: longMembership),
                    workspace("w2", demo, title: "again", sessionIds: longMembership),
                    workspace("w3", other, sessionIds: []),
                ],
                selectedSessionId: nil,
            ),
            // The same empty refresh with a sentinel row: the list is
            // unreadable, the fallback groups by directory, and there is no
            // drawn session to put a directory under.
            WorkspaceCatalogInput(
                name: "empty-sessions-long-membership-sentinel",
                sessions: [],
                workspaces: [
                    workspace("w1", WorkspaceGroup.unclaimedId, title: "odd", sessionIds: longMembership),
                    workspace("w2", demo, sessionIds: longMembership),
                ],
                selectedSessionId: nil,
            ),
            // Duplicate session ids in the session list: both copies are drawn,
            // both are claimed, and neither is sorted away.
            WorkspaceCatalogInput(
                name: "duplicate-session-ids",
                sessions: [
                    session("s1", updatedAt: 1),
                    session("s1", updatedAt: 1),
                    session("s2", updatedAt: 2),
                ],
                workspaces: [workspace("w1", demo, sessionIds: ["s1", "s2"])],
                selectedSessionId: nil,
            ),
            // One session filed under two workspaces: it is in both groups and
            // there is no unclaimed tail.
            WorkspaceCatalogInput(
                name: "cross-group-overlap",
                sessions: [session("s1"), session("s2"), session("s3")],
                workspaces: [
                    workspace("w1", demo, sessionIds: ["s1", "s2"]),
                    workspace("w2", other, sessionIds: ["s1", "s3"]),
                ],
                selectedSessionId: nil,
            ),
            // A host row at the sentinel: the whole list is unreadable and the
            // fallback groups by directory.
            WorkspaceCatalogInput(
                name: "sentinel-path",
                sessions: [session("s1"), session("s2", cwd: nil)],
                workspaces: [
                    workspace("w1", WorkspaceGroup.unclaimedId, title: "odd", sessionIds: []),
                    workspace("w2", demo, sessionIds: ["s1"]),
                ],
                selectedSessionId: nil,
            ),
            // A blank session that is not selected is not drawn; the selected
            // one is; a subagent never is -- even when a membership list names
            // it, in which case it is not claimed either.
            WorkspaceCatalogInput(
                name: "blank-subagent-selected",
                sessions: [
                    session("s1", updatedAt: 5),
                    session("s2", updatedAt: 4, subagent: true),
                    session("s3", updatedAt: 3, blank: true),
                    session("s4", updatedAt: 2, blank: true),
                ],
                workspaces: [workspace("w1", demo, sessionIds: ["s1", "s2", "s3", "s4"])],
                selectedSessionId: "s3",
            ),
            // Ties in updatedAt are broken by session id, ascending.
            WorkspaceCatalogInput(
                name: "newest-first-ties",
                sessions: [
                    session("s-b", updatedAt: 7),
                    session("s-a", updatedAt: 7),
                    session("s-c", updatedAt: 9),
                ],
                workspaces: [workspace("w1", demo, sessionIds: ["s-a", "s-b", "s-c"])],
                selectedSessionId: nil,
            ),
            // The host's order is the row order, not sorted paths.
            WorkspaceCatalogInput(
                name: "host-order",
                sessions: [session("s1"), session("s2", cwd: other)],
                workspaces: [
                    workspace("w2", other, sessionIds: ["s2"]),
                    workspace("w1", demo, sessionIds: ["s1"]),
                ],
                selectedSessionId: nil,
            ),
            // Everything the host drew is claimed: no unclaimed tail.
            WorkspaceCatalogInput(
                name: "no-unclaimed",
                sessions: [session("s1"), session("s2", cwd: other)],
                workspaces: [
                    workspace("w1", demo, sessionIds: ["s1"]),
                    workspace("w2", other, sessionIds: ["s2"]),
                ],
                selectedSessionId: nil,
            ),
            // Membership ids the session list does not contain: empty group,
            // and the drawn sessions below it are unclaimed.
            WorkspaceCatalogInput(
                name: "unknown-member-ids",
                sessions: [session("s1")],
                workspaces: [workspace("w1", demo, sessionIds: ["nope", "nope2"])],
                selectedSessionId: nil,
            ),
            // Canonically equivalent spellings of the same id. Swift compares
            // and hashes `String` under Unicode canonical equivalence, so a set
            // must answer exactly what the array scan answers here: both
            // workspaces hold the one session even though one list is written
            // precomposed and the other decomposed.
            WorkspaceCatalogInput(
                name: "unicode-canonical-membership",
                sessions: [session("cafe\u{301}", updatedAt: 1)],
                workspaces: [
                    workspace("w1", demo, sessionIds: ["caf\u{E9}"]),
                    workspace("w2", other, sessionIds: ["cafe\u{301}"]),
                ],
                selectedSessionId: nil,
            ),
            // A session with no directory is claimed by membership, not by path.
            WorkspaceCatalogInput(
                name: "nil-cwd-claimed",
                sessions: [session("s1", cwd: nil)],
                workspaces: [workspace("w1", demo, sessionIds: ["s1"])],
                selectedSessionId: nil,
            ),
        ]
    }

    /// A deterministic generator shared by the random differential.
    ///
    /// SplitMix64: fixed seed in, identical inputs out, on every machine.
    struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) { self.state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Random inputs around the shapes production's rules mention.
    ///
    /// - Parameters:
    ///   - seed: the generator seed; the same seed always yields the same list.
    ///   - count: how many inputs to build.
    ///   - maxSessions: upper bound on the session list.
    ///   - maxWorkspaces: upper bound on the workspace list.
    ///   - maxMembers: upper bound on a membership list.
    /// - Returns: the inputs, named `random-<seed>-<index>`.
    static func seeded(
        seed: UInt64,
        count: Int,
        maxSessions: Int = 30,
        maxWorkspaces: Int = 6,
        maxMembers: Int = 8,
    ) -> [WorkspaceCatalogInput] {
        var rng = SeededGenerator(seed: seed)
        var inputs: [WorkspaceCatalogInput] = []
        inputs.reserveCapacity(count)

        for index in 0..<count {
            let sessionCount = Int.random(in: 0...maxSessions, using: &rng)
            var sessions: [SessionRow] = []
            sessions.reserveCapacity(sessionCount)
            for sessionIndex in 0..<sessionCount {
                // A duplicate id is deliberately allowed: the host can list the
                // same session twice, and the drawn filter keeps both.
                let id = sessionIndex > 0 && Int.random(in: 0..<8, using: &rng) == 0
                    ? "s\(Int.random(in: 0..<sessionIndex, using: &rng))"
                    : "s\(sessionIndex)"
                let cwd: String?
                switch Int.random(in: 0..<10, using: &rng) {
                case 0: cwd = nil
                case 1: cwd = deleted
                default: cwd = "/Users/you/projects/p\(Int.random(in: 0..<4, using: &rng))"
                }
                sessions.append(
                    SessionRow(
                        sessionId: id,
                        updatedAt: Double(Int.random(in: 0..<5, using: &rng)),
                        running: false,
                        blank: Int.random(in: 0..<7, using: &rng) == 0,
                        agentAvailable: true,
                        cwd: cwd,
                        parentSessionId: Int.random(in: 0..<6, using: &rng) == 0 ? "parent" : nil,
                        origin: Int.random(in: 0..<7, using: &rng) == 0 ? "subagent" : nil,
                    ),
                )
            }

            let mode = Int.random(in: 0..<20, using: &rng)
            let workspaces: [WorkspaceRow]?
            if mode == 0 {
                workspaces = nil
            } else {
                let workspaceCount = Int.random(in: 0...maxWorkspaces, using: &rng)
                var rows: [WorkspaceRow] = []
                rows.reserveCapacity(workspaceCount)
                let shareOnePool = workspaceCount > 1 && Int.random(in: 0..<2, using: &rng) == 0
                for workspaceIndex in 0..<workspaceCount {
                    // Duplicate paths are allowed: the second row must be
                    // dropped, and its membership must not claim anything.
                    let path = workspaceIndex > 0 && Int.random(in: 0..<10, using: &rng) == 0
                        ? "/Users/you/projects/p\(Int.random(in: 0..<2, using: &rng))"
                        : "/Users/you/projects/p\(Int.random(in: 0..<5, using: &rng))"
                    let membership: [String]?
                    switch Int.random(in: 0..<8, using: &rng) {
                    case 0:
                        membership = nil
                    default:
                        let memberCount = Int.random(in: 0...maxMembers, using: &rng)
                        var members: [String] = []
                        members.reserveCapacity(memberCount + 1)
                        for _ in 0..<memberCount {
                            if shareOnePool || Int.random(in: 0..<2, using: &rng) == 0 {
                                let pick = Int.random(in: 0..<max(maxSessions, 1), using: &rng)
                                members.append("s\(pick)")
                            } else {
                                members.append("x\(Int.random(in: 0..<maxMembers, using: &rng))")
                            }
                        }
                        // Duplicate member ids are allowed, including at the
                        // empty end: `[]` is an answer and must stay one.
                        if Int.random(in: 0..<6, using: &rng) == 0, let first = members.first {
                            members.append(first)
                        }
                        membership = members
                    }
                    rows.append(
                        WorkspaceRow(
                            workspaceId: "w\(workspaceIndex)",
                            path: path,
                            title: Int.random(in: 0..<5, using: &rng) == 0 ? "" : "Workspace \(workspaceIndex)",
                            sessionIds: membership,
                        ),
                    )
                }
                // Occasionally a row at the sentinel: the whole list must fall
                // back to directory grouping.
                if Int.random(in: 0..<25, using: &rng) == 0, workspaceCount > 0 {
                    rows[Int.random(in: 0..<workspaceCount, using: &rng)] = WorkspaceRow(
                        workspaceId: "sentinel",
                        path: WorkspaceGroup.unclaimedId,
                        title: "odd",
                        sessionIds: [],
                    )
                }
                workspaces = rows
            }

            let selectedSessionId: String?
            switch Int.random(in: 0..<10, using: &rng) {
            case 0...2:
                selectedSessionId = sessions.isEmpty ? nil : sessions[Int.random(in: 0..<sessions.count, using: &rng)].sessionId
            case 3:
                selectedSessionId = "s-not-listed"
            default:
                selectedSessionId = nil
            }

            inputs.append(
                WorkspaceCatalogInput(
                    name: "random-\(seed)-\(index)",
                    sessions: sessions,
                    workspaces: workspaces,
                    selectedSessionId: selectedSessionId,
                ),
            )
        }
        return inputs
    }
}
