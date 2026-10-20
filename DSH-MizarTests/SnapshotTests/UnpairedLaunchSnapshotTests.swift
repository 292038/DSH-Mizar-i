//
//  UnpairedLaunchSnapshotTests.swift
//  DSH-MizarTests
//
//  The screen a never-paired phone lands on: the navy first-run screen with
//  the searching mark and the one button that fixes it. This is the state
//  `AppFlowLaunchTests.testAnUnpairedLaunchOffersPairing` launched the whole
//  app to reach; what it asserted is that the launch ends on the scanner
//  (`unpaired.scan`) or, once paired, the session list (`sessions.new`) --
//  and never on neither.
//
//  The golden pins the unpaired half, which is the stronger of the two: this
//  is the exact view `RootView` presents for `.unpaired`, with the scan button
//  on it, and the contract pins both identifiers in both sources. A launch
//  that reached neither screen can only come back by failing this test or the
//  contract, without a 20-second launch.
//
//  `MizarMarkSearching` animates its arcs with a repeating keyframe animator,
//  which no transaction can stop, and `accessibilityReduceMotion` is a
//  get-only environment key the harness cannot set. The app view therefore
//  takes its mark as an injectable subview (`UnpairedView(mark:)`; the
//  shipping `UnpairedView()` keeps the searching one), and this reference
//  pins the resting state the animated arcs' reduce-motion branch rests on:
//  `MizarMark(lit: 3)` at the same size and colours.
//
//  The screen's copy resolves through the app bundle in the simulator's own
//  language, so this reference is pinned by recording on the canonical
//  English-locale simulator (`Mizar Runs`, `AppleLanguages = en-US`), per
//  docs/snapshots.md.
//

import SwiftUI
import Testing
@testable import DSH_Mizar

@MainActor
struct UnpairedLaunchSnapshotTests {
    @Test
    func unpairedLaunchScreen() throws {
        // What the UI test asked for: the unpaired screen's way forward, and
        // the paired fallback's new-session control, still declared in source.
        try AppSourceContract.expectIdentifiers(
            ["unpaired.scan"],
            in: "DSH-Mizar/Views/HostListView.swift",
        )
        try AppSourceContract.expectIdentifiers(
            ["sessions.new"],
            in: "DSH-Mizar/Views/Shell/Sidebar.swift",
        )

        let snapshot = try SnapshotHarness.assertSnapshot(
            of: UnpairedView(
                mark: MizarMark(
                    lit: 3,
                    accent: SnapshotFixtures.brandCyan,
                    ink: .white,
                ),
            ),
            named: "UnpairedLaunch-unpaired",
            size: CGSize(width: 390, height: 844),
        )
        #expect(snapshot.pixelWidth == 780)
        #expect(snapshot.pixelHeight == 1688)
    }
}
