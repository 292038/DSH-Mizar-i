//
//  AttachmentStripSnapshotTests.swift
//  DSH-MizarTests
//
//  The composer's attachment row sets three accessibility identifiers that the
//  UI suite would query, but it cannot be snapshotted through `ImageRenderer`:
//  the strip is a `ScrollView`, which is UIKit-backed, and `ImageRenderer`
//  renders it as an empty rectangle (verified — the reference was blank). This
//  pilot therefore stops at the identifier contract, which is the half of the
//  assertion a unit test can make honestly today.
//
//  Once the strip's chips are extracted into a view the renderer can draw (or a
//  hosted renderer is added to the harness), the snapshot half can be added
//  here without changing the contract below. `docs/snapshots.md` records the
//  finding so nobody re-discovers it by recording a blank PNG.
//

import Testing

@MainActor
struct AttachmentStripSnapshotTests {
    @Test
    func attachmentStripIdentifiersAreAddressable() throws {
        try AppSourceContract.expectIdentifiers(
            ["composer.attachment.strip", "composer.attachment", "composer.attachment.remove"],
            in: "DSH-Mizar/Views/Composer/AttachmentStrip.swift",
        )
    }
}
