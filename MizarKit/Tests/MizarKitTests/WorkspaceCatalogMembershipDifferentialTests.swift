//
//  WorkspaceCatalogMembershipDifferentialTests.swift
//  MizarKitTests
//
//  The membership index changes only how one question is asked -- "is this
//  session in this workspace's list?" -- so the answer must be identical for
//  every input. These tests are the proof: a frozen copy of the old function,
//  every candidate strategy, and the real `WorkspaceCatalog.groups`, all three
//  compared on deterministic hand-written inputs and on seeded random inputs.
//
//  The random inputs are synthetic. They exercise the rules the function
//  documents (nil versus [] membership, duplicate paths, duplicate members,
//  duplicate session ids, overlap, the sentinel, blank/subagent/selected,
//  claimed/unclaimed, ties), not any real host's data.
//

import Foundation
import Testing
@testable import MizarKit

@Suite("Workspace catalogue membership index")
struct WorkspaceCatalogMembershipDifferentialTests {
    /// Every strategy under test, including thresholds on both sides of any
    /// plausible crossover. The chosen threshold has to appear here so both of
    /// its branches are compared with the oracle.
    private static let strategies: [CatalogMembershipStrategy] = [
        .array,
        .set,
        .hybridFrom(1),
        .hybridFrom(2),
        .hybridFrom(3),
        .hybridFrom(4),
        .hybridFrom(5),
        .hybridFrom(8),
        .hybridFrom(16),
        .hybridFrom(26),
        .hybridFrom(101),
    ]

    private func checkProduction(_ input: WorkspaceCatalogInput) {
        let oracle = FrozenWorkspaceCatalog.groups(
            sessions: input.sessions,
            workspaces: input.workspaces,
            selectedSessionId: input.selectedSessionId,
        )
        let production = WorkspaceCatalog.groups(
            sessions: input.sessions,
            workspaces: input.workspaces,
            selectedSessionId: input.selectedSessionId,
        )
        #expect(
            production == oracle,
            "\(input.name): production diverged from the frozen oracle at fingerprint \(CatalogFingerprint.of(production))",
        )
    }

    private func checkStrategies(_ input: WorkspaceCatalogInput) {
        let oracle = FrozenWorkspaceCatalog.groups(
            sessions: input.sessions,
            workspaces: input.workspaces,
            selectedSessionId: input.selectedSessionId,
        )
        for strategy in Self.strategies {
            let candidate = CandidateWorkspaceCatalog.groups(
                sessions: input.sessions,
                workspaces: input.workspaces,
                selectedSessionId: input.selectedSessionId,
                strategy: strategy,
            )
            #expect(
                candidate == oracle,
                "\(input.name): \(strategy.label) diverged from the frozen oracle at fingerprint \(CatalogFingerprint.of(candidate))",
            )
        }
    }

    @Test("production matches the frozen oracle on the hand-written inputs")
    func productionMatchesOracleOnHandWrittenInputs() {
        for input in WorkspaceCatalogSamples.handWritten {
            checkProduction(input)
        }
    }

    @Test("every membership strategy matches the frozen oracle on the hand-written inputs")
    func strategiesMatchOracleOnHandWrittenInputs() {
        for input in WorkspaceCatalogSamples.handWritten {
            checkStrategies(input)
        }
    }

    @Test("production matches the frozen oracle on seeded random inputs")
    func productionMatchesOracleOnRandomInputs() {
        for input in Self.randomInputs {
            checkProduction(input)
        }
    }

    @Test("every membership strategy matches the frozen oracle on seeded random inputs")
    func strategiesMatchOracleOnRandomInputs() {
        for input in Self.randomInputs {
            checkStrategies(input)
        }
    }

    @Test("the chosen crossover is compared on both sides of eight members")
    func crossoverIsCoveredOnBothSides() {
        // The benchmark picks a threshold where the set starts winning. Both
        // branches of that threshold have to be compared with the oracle, not
        // just the winning one: seven members is the array side, eight is the
        // set side. Duplicate members and cross-group overlap stay in, because
        // they are the inputs a membership index is most likely to get wrong.
        let seven = WorkspaceCatalogInput(
            name: "members-7-array-side",
            sessions: [
                WorkspaceCatalogSamples.session("s1", updatedAt: 3),
                WorkspaceCatalogSamples.session("s2", updatedAt: 2),
                WorkspaceCatalogSamples.session("s3", updatedAt: 1),
            ],
            workspaces: [
                WorkspaceCatalogSamples.workspace(
                    "w1",
                    "/Users/you/projects/demo",
                    sessionIds: ["s1", "s1", "s2", "s3", "s4", "s5", "not-a-session"],
                ),
                WorkspaceCatalogSamples.workspace(
                    "w2",
                    "/Users/you/projects/other",
                    sessionIds: ["s1", "s2", "s3", "s4", "s5", "s5", "s6", "s7"],
                ),
            ],
            selectedSessionId: nil,
        )
        let eight = WorkspaceCatalogInput(
            name: "members-8-set-side",
            sessions: [
                WorkspaceCatalogSamples.session("s1", updatedAt: 3),
                WorkspaceCatalogSamples.session("s2", updatedAt: 2),
                WorkspaceCatalogSamples.session("s3", updatedAt: 1),
                WorkspaceCatalogSamples.session("s4", cwd: nil, updatedAt: 1),
            ],
            workspaces: [
                WorkspaceCatalogSamples.workspace(
                    "w1",
                    "/Users/you/projects/demo",
                    sessionIds: ["s1", "s2", "s2", "s3", "s4", "s5", "s6", "not-a-session"],
                ),
                WorkspaceCatalogSamples.workspace(
                    "w2",
                    "/Users/you/projects/other",
                    sessionIds: ["s1", "s3", "s4", "s4", "s5", "s6", "s7", "not-a-session"],
                ),
            ],
            selectedSessionId: "s4",
        )
        for input in [seven, eight] {
            checkProduction(input)
            checkStrategies(input)
        }
    }

    /// Small random inputs across three fixed seeds, plus a handful at the
    /// sizes where set construction and lookup actually differ.
    private static let randomInputs: [WorkspaceCatalogInput] = {
        var inputs: [WorkspaceCatalogInput] = []
        for seed: UInt64 in [0x14_2026, 0x5EED, 0xBEEF] {
            inputs += WorkspaceCatalogSamples.seeded(seed: seed, count: 60)
        }
        inputs += WorkspaceCatalogSamples.seeded(
            seed: 0x1A_26_10_23,
            count: 8,
            maxSessions: 300,
            maxWorkspaces: 10,
            maxMembers: 40,
        )
        return inputs
    }()
}
