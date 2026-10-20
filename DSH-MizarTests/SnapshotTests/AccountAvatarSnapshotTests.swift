//
//  AccountAvatarSnapshotTests.swift
//  DSH-MizarTests
//
//  The account avatar's three deterministic drawings, from fixture accounts:
//  the signed-out placeholder, Apple's monogram (what iOS draws for an Apple ID
//  with no photo), and the server-palette initials fallback.
//
//  The Gravatar path is deliberately absent: it loads through `AsyncImage`, and a
//  snapshot that races a network image would be the definition of flaky.
//

import MizarKit
import SwiftUI
import Testing
@testable import DSH_Mizar

@MainActor
struct AccountAvatarSnapshotTests {
    enum Variant: String, CaseIterable, Sendable {
        /// Nobody signed in: neutral fill, person glyph.
        case signedOut
        /// Apple-linked: monogram over the system's gray gradient.
        case appleLinked
        /// Generated: the relay's palette and initials.
        case generated
    }

    @Test(arguments: Variant.allCases)
    func accountAvatar(_ variant: Variant) throws {
        let user: AccountUser? = switch variant {
        case .signedOut: nil
        case .appleLinked: SnapshotFixtures.paidAppleLinkedUser
        case .generated: SnapshotFixtures.signedInFreeUser
        }

        let snapshot = try SnapshotHarness.assertSnapshot(
            of: AccountAvatarView(user: user, size: 44),
            named: "AccountAvatar-\(variant.rawValue)",
            size: CGSize(width: 44, height: 44),
        )

        // The avatar is the account row's 44-pt circle: exactly 44 x 44 points.
        #expect(snapshot.pixelWidth == 88)
        #expect(snapshot.pixelHeight == 88)
    }
}
