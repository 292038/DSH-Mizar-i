//
//  MizarMarkSnapshotTests.swift
//  DSH-MizarTests
//
//  The icon mark, lit and mid-fill.
//
//  This is the cheapest possible snapshot: pure geometry with no environment
//  dependency, so it is also the harness's own smoke test — if this reference
//  stops matching, the renderer or the runtime moved, not the mark.
//

import SwiftUI
import Testing
@testable import DSH_Mizar

@MainActor
struct MizarMarkSnapshotTests {
    /// The two states the app actually draws: resting at full signal, and the
    /// partial fill the first download shows.
    enum Lit: String, CaseIterable, Sendable {
        case full
        case partial

        var amount: Double {
            switch self {
            case .full: 3
            case .partial: 1.4
            }
        }
    }

    @Test(arguments: Lit.allCases)
    func mizarMark(_ lit: Lit) throws {
        let snapshot = try SnapshotHarness.assertSnapshot(
            of: MizarMark(
                lit: lit.amount,
                accent: SnapshotFixtures.brandCyan,
                ink: SnapshotFixtures.navy,
            ),
            named: "MizarMark-\(lit.rawValue)",
            size: CGSize(width: 68, height: 46),
        )

        // The icon's own box, exactly: a changed aspect ratio must not be
        // absorbed by the tolerance.
        #expect(snapshot.pixelWidth == 136)
        #expect(snapshot.pixelHeight == 92)
        #expect(snapshot.recorded == SnapshotHarness.isRecording)
    }
}
