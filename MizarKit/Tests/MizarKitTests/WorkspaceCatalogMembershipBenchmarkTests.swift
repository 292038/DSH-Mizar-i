//
//  WorkspaceCatalogMembershipBenchmarkTests.swift
//  MizarKitTests
//
//  How much the membership index is worth, measured rather than guessed.
//
//  Opt-in on purpose (`MIZAR_WORKSPACE_CATALOG_BENCH=1`) and meant for
//  `swift test -c release`: in a default Debug run the benchmark is disabled
//  and costs nothing. The shapes below are synthetic. They vary the three
//  numbers the cost depends on -- sessions, workspaces, members per workspace
//  -- over the small and large ends, including `nil` membership, one shape
//  where every workspace claims the same sessions, and one empty session list
//  with long membership lists. They are not a real host's workspace list and
//  their absolute numbers are not a claim about device behaviour.
//
//  `production` is the shipped `WorkspaceCatalog.groups`; `frozen-array` is the
//  same function before the membership index, copied into the test target.
//  production against frozen-array is the only headline here. The candidates
//  (`array`, `set`, `hybrid>=8`) are timed on the same fixture to show where
//  the crossover is -- they are a reference, not a separate win.
//
//  Every timed sample calls a full `groups` function: the drawn filter, the
//  membership lookup (the set built once per workspace where the strategy uses
//  one), the real sort, the unclaimed tail, and a fingerprint of the complete
//  returned groups. The fingerprint is computed inside the timed region, and
//  the same FNV-1a pass runs for every implementation, so it is part of each
//  side's cost; the checksums are accumulated after the clock stops and
//  returned to the test, which keeps the work from being optimised away.
//
//  Reporting: median and p90 of the per-call time across 11 alternating
//  rounds, after 3 warmup rounds. Alternating the implementation order means a
//  thermal or cache drift hits both sides, not one.
//

import Foundation
import Testing
@testable import MizarKit

/// Only an explicit environment variable turns the benchmark on; a default run
/// skips it and spends no time.
private let workspaceCatalogBenchmarkEnabled = ProcessInfo.processInfo.environment["MIZAR_WORKSPACE_CATALOG_BENCH"] == "1"

@Suite("Workspace catalogue membership benchmark")
struct WorkspaceCatalogMembershipBenchmarkTests {
    private static let warmupRounds = 3
    private static let measuredRounds = 11

    /// The candidate strategies timed against the frozen implementation.
    ///
    /// `frozen-array` is the function before the membership index. `.array` is
    /// the same function with the optional `sessionIds` binding hoisted out of
    /// the per-session closure -- the structure any per-workspace index needs,
    /// and the baseline the set's own contribution is measured against. `.set`
    /// is the plain candidate (a set for every list, empty included).
    /// `.hybridFrom(8)` is the shipped policy's rule: array below eight
    /// members, set at or above it, where the measured crossover is.
    /// Production is timed separately, because it is the function that ships:
    /// the same rule plus the empty-refresh guard.
    private static let strategies: [CatalogMembershipStrategy] = [
        .array,
        .set,
        .hybridFrom(8),
    ]

    // MARK: - Shapes

    private struct Shape: Sendable {
        let name: String
        let sessions: [SessionRow]
        let workspaces: [WorkspaceRow]
        let iterations: Int
    }

    private static func sessionId(_ index: Int) -> String {
        String(format: "session-%08x", index)
    }

    /// A distinct copy of a session id, the way the host's two independently
    /// decoded lists would hold one: string equality has to do the work rather
    /// than a shared-buffer pointer check.
    private static func memberCopy(_ id: String) -> String {
        String(decoding: id.utf8, as: UTF8.self)
    }

    /// - Parameters:
    ///   - sessionCount: rows in the session list.
    ///   - workspaceCount: rows in the host's workspace list.
    ///   - memberCount: members per workspace (membership lists may be `nil`
    ///     for `mixedNil`).
    ///   - mixedNil: every third workspace sends `nil` instead of a list.
    ///   - overlap: every workspace claims the same first sessions.
    /// - Returns: the shape, with a seeded iteration count for a ~1 ms sample.
    private static func makeShape(
        name: String,
        sessionCount: Int,
        workspaceCount: Int,
        memberCount: Int,
        mixedNil: Bool = false,
        overlap: Bool = false,
    ) -> Shape {
        var sessions: [SessionRow] = []
        sessions.reserveCapacity(sessionCount)
        for index in 0..<sessionCount {
            sessions.append(
                SessionRow(
                    sessionId: sessionId(index),
                    updatedAt: Double((index * 37) % 1000),
                    running: false,
                    blank: false,
                    agentAvailable: true,
                    cwd: "/Users/you/projects/p\(workspaceCount == 0 ? 0 : index % workspaceCount)",
                    parentSessionId: nil,
                    origin: nil,
                ),
            )
        }

        var workspaces: [WorkspaceRow] = []
        workspaces.reserveCapacity(workspaceCount)
        for workspaceIndex in 0..<workspaceCount {
            let members: [String]?
            if mixedNil && workspaceIndex % 3 == 0 {
                members = nil
            } else {
                var list: [String] = []
                list.reserveCapacity(memberCount)
                for memberIndex in 0..<memberCount {
                    if sessionCount > 0 {
                        let pick: Int
                        if overlap {
                            pick = memberIndex % sessionCount
                        } else {
                            pick = (workspaceIndex * 7 + memberIndex * 13 + 3) % sessionCount
                        }
                        list.append(memberCopy(sessionId(pick)))
                    } else {
                        list.append("session-empty-\(memberIndex)")
                    }
                }
                members = list
            }
            workspaces.append(
                WorkspaceRow(
                    workspaceId: "w\(workspaceIndex)",
                    path: "/Users/you/projects/p\(workspaceIndex)",
                    title: "Workspace \(workspaceIndex)",
                    sessionIds: members,
                ),
            )
        }

        // Operations the array path performs, used only to pick an iteration
        // count that makes one sample about a millisecond. The sample size is
        // the same for every implementation of a shape, so the comparison does
        // not depend on this estimate.
        let operations = max(1, sessionCount) * max(1, workspaceCount) * max(1, memberCount)
        let iterations = max(1, min(1000, 1_000_000 / operations))
        return Shape(name: name, sessions: sessions, workspaces: workspaces, iterations: iterations)
    }

    /// Sixteen shapes: sessions 0/20/200/1000, workspaces 1/8/30, members
    /// 0/1/3/25/100, both sides of the measured crossover (6 and 8 members),
    /// `nil`/mixed membership, and cross-group overlap.
    private static let shapes: [Shape] = [
        makeShape(name: "S0-W1-M0", sessionCount: 0, workspaceCount: 1, memberCount: 0),
        makeShape(name: "S20-W8-M0", sessionCount: 20, workspaceCount: 8, memberCount: 0),
        makeShape(name: "S20-W8-M1", sessionCount: 20, workspaceCount: 8, memberCount: 1),
        makeShape(name: "S20-W8-M3", sessionCount: 20, workspaceCount: 8, memberCount: 3),
        makeShape(name: "S20-W8-M6", sessionCount: 20, workspaceCount: 8, memberCount: 6),
        makeShape(name: "S200-W1-M25", sessionCount: 200, workspaceCount: 1, memberCount: 25),
        makeShape(name: "S200-W8-M1", sessionCount: 200, workspaceCount: 8, memberCount: 1),
        makeShape(name: "S200-W8-M3", sessionCount: 200, workspaceCount: 8, memberCount: 3),
        makeShape(name: "S200-W8-M6", sessionCount: 200, workspaceCount: 8, memberCount: 6),
        makeShape(name: "S200-W8-M8", sessionCount: 200, workspaceCount: 8, memberCount: 8),
        makeShape(name: "S200-W8-M25", sessionCount: 200, workspaceCount: 8, memberCount: 25),
        makeShape(name: "S200-W30-M100", sessionCount: 200, workspaceCount: 30, memberCount: 100),
        makeShape(name: "S1000-W8-M8", sessionCount: 1000, workspaceCount: 8, memberCount: 8),
        makeShape(name: "S1000-W8-M25", sessionCount: 1000, workspaceCount: 8, memberCount: 25),
        makeShape(name: "S1000-W8-M100-mixedNil", sessionCount: 1000, workspaceCount: 8, memberCount: 100, mixedNil: true),
        makeShape(name: "S200-W8-M25-overlap", sessionCount: 200, workspaceCount: 8, memberCount: 25, overlap: true),
    ]

    // MARK: - Timing

    private struct Timing: Sendable {
        let medianMicros: Double
        let p90Micros: Double
    }

    private static func micros(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000_000
            + Double(components.attoseconds) / 1_000_000_000_000
    }

    /// Nearest-rank p90 for eleven samples: the tenth of eleven.
    private static func p90(_ sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((Double(sorted.count) * 0.9).rounded(.up))
        return sorted[min(sorted.count - 1, max(0, rank - 1))]
    }

    private static func median(_ sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return 0 }
        return sorted[sorted.count / 2]
    }

    /// Shapes outside the sixteen-shape table that the lead review asked for:
    /// the small-session end of the threshold (S=20 at 8 and 25 members), a
    /// single workspace with many members at small S, a session list with
    /// nothing drawn but large membership lists -- where a set is built and
    /// never looked up -- and the empty refresh across thirty workspaces with
    /// a hundred members each. Bounded at five: a supplement, not a grid.
    private static let supplementaryShapes: [Shape] = [
        makeShape(name: "S20-W8-M8", sessionCount: 20, workspaceCount: 8, memberCount: 8),
        makeShape(name: "S20-W8-M25", sessionCount: 20, workspaceCount: 8, memberCount: 25),
        makeShape(name: "S20-W1-M25", sessionCount: 20, workspaceCount: 1, memberCount: 25),
        makeShape(name: "S0-W8-M8", sessionCount: 0, workspaceCount: 8, memberCount: 8),
        // No sessions drawn at all, with long membership lists in thirty
        // workspaces: every set here would be built and never asked, so this
        // is the shape the shipped empty-refresh guard has to keep cheap.
        makeShape(name: "S0-W30-M100", sessionCount: 0, workspaceCount: 30, memberCount: 100),
    ]

    @Test(
        "membership strategies versus the array scan, in release",
        .enabled(if: workspaceCatalogBenchmarkEnabled),
    )
    func benchmarkMembershipStrategies() throws {
        let consumed = try benchmark(Self.shapes)
        #expect(consumed != 0, "benchmark checksums were never consumed")
    }

    @Test(
        "small-session and empty-input shapes outside the sixteen-shape table",
        .enabled(if: workspaceCatalogBenchmarkEnabled),
    )
    func benchmarkSupplementaryShapes() throws {
        let consumed = try benchmark(Self.supplementaryShapes)
        #expect(consumed != 0, "supplementary benchmark checksums were never consumed")
    }

    /// Times every strategy on every shape and prints one `BENCH` line per
    /// implementation. Returns the consumed fingerprints.
    private func benchmark(_ shapes: [Shape]) throws -> UInt64 {
        let clock = ContinuousClock()
        var consumed: UInt64 = 0

        for shape in shapes {
            let input = WorkspaceCatalogInput(
                name: shape.name,
                sessions: shape.sessions,
                workspaces: shape.workspaces,
                selectedSessionId: nil,
            )

            // The timed strategies must first produce exactly what the frozen
            // implementation produces. Numbers for a different answer are not
            // worth reporting.
            let oracle = FrozenWorkspaceCatalog.groups(
                sessions: shape.sessions,
                workspaces: shape.workspaces,
                selectedSessionId: nil,
            )
            let production = WorkspaceCatalog.groups(
                sessions: shape.sessions,
                workspaces: shape.workspaces,
                selectedSessionId: nil,
            )
            try #require(
                production == oracle,
                "\(input.name): production diverged from the frozen oracle before timing",
            )
            for strategy in Self.strategies {
                let candidate = CandidateWorkspaceCatalog.groups(
                    sessions: shape.sessions,
                    workspaces: shape.workspaces,
                    selectedSessionId: nil,
                    strategy: strategy,
                )
                try #require(
                    candidate == oracle,
                    "\(input.name): \(strategy.label) diverged from the frozen oracle before timing",
                )
            }

            var implementations: [(label: String, run: () -> UInt64)] = [
                ("frozen-array", {
                    let groups = FrozenWorkspaceCatalog.groups(
                        sessions: shape.sessions,
                        workspaces: shape.workspaces,
                        selectedSessionId: nil,
                    )
                    return CatalogFingerprint.of(groups)
                }),
                // The function that ships: a direct call across the MizarKit
                // module boundary; app build/runtime costs are not measured here.
                // Nothing in this closure is a test double.
                ("production", {
                    let groups = WorkspaceCatalog.groups(
                        sessions: shape.sessions,
                        workspaces: shape.workspaces,
                        selectedSessionId: nil,
                    )
                    return CatalogFingerprint.of(groups)
                }),
            ]
            for strategy in Self.strategies {
                implementations.append(
                    (strategy.label, {
                        let groups = CandidateWorkspaceCatalog.groups(
                            sessions: shape.sessions,
                            workspaces: shape.workspaces,
                            selectedSessionId: nil,
                            strategy: strategy,
                        )
                        return CatalogFingerprint.of(groups)
                    }),
                )
            }

            var samples: [String: [Double]] = [:]
            for implementation in implementations { samples[implementation.label] = [] }

            for round in 0..<(Self.warmupRounds + Self.measuredRounds) {
                // Alternate the order: whichever implementation runs second in
                // one round runs first in the next.
                let ordered: [(label: String, run: () -> UInt64)] = round % 2 == 0
                    ? implementations
                    : Array(implementations.reversed())
                for implementation in ordered {
                    var checksum: UInt64 = 0
                    let duration = clock.measure {
                        for _ in 0..<shape.iterations {
                            checksum &+= implementation.run()
                        }
                    }
                    consumed &+= checksum
                    if round >= Self.warmupRounds {
                        samples[implementation.label, default: []].append(
                            Self.micros(duration) / Double(shape.iterations),
                        )
                    }
                }
            }

            let sessionCount = shape.sessions.count
            let workspaceCount = shape.workspaces.count
            for label in ["frozen-array", "production"] + Self.strategies.map(\.label) {
                let sorted = samples[label, default: []].sorted()
                print(
                    "BENCH shape=\(shape.name) sessions=\(sessionCount) workspaces=\(workspaceCount)"
                        + " impl=\(label) iterations=\(shape.iterations) rounds=\(Self.measuredRounds)"
                        + " median_us=\(String(format: "%.3f", Self.median(sorted)))"
                        + " p90_us=\(String(format: "%.3f", Self.p90(sorted)))",
                )
            }
        }
        return consumed
    }
}
