//
//  ConnectionDotSnapshotTests.swift
//  DSH-MizarTests
//
//  The reachability dot in its offline state: grey and still, drawn at the size
//  the connection panel uses.
//
//  Only the offline state is snapshotted. The live state draws a
//  `phaseAnimator`, and Reduce Motion — the state in which it stops — cannot be
//  forced from a unit test because `accessibilityReduceMotion` is a get-only
//  environment key. Rendering an animated view would compare whatever frame the
//  renderer happened to catch, which is exactly the flaky test a snapshot suite
//  must not ship. The offline state is static by construction: both the fill and
//  the absent halo are decided by the `live` flag alone.
//

import SwiftUI
import Testing
@testable import DSH_Mizar

@MainActor
struct ConnectionDotSnapshotTests {
    @Test
    func connectionDotOffline() throws {
        let snapshot = try SnapshotHarness.assertSnapshot(
            of: ConnectionDot(live: false, size: 14),
            named: "ConnectionDot-offline",
            size: CGSize(width: 34, height: 34),
        )

        // `ConnectionDot` reserves size * 1.4 around the dot.
        #expect(snapshot.pixelWidth == 68)
        #expect(snapshot.pixelHeight == 68)
    }
}
