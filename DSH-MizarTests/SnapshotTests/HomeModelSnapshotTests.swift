//
//  HomeModelSnapshotTests.swift
//  DSH-MizarTests
//
//  The home screen's model route: the pill that names what the next session
//  will start on, and the picker row it opens -- the view half of
//  `AppFlowNavigationTests.testTheHomeScreenChoosesTheModelItsSessionStartsOn`,
//  which keeps the request half (that the started session really runs on the
//  chosen model) because that belongs to the host round-trip, not to pixels.
//
//  The pill is the app's own `ModelPill` fed by `modelPillLabel`'s exact
//  composition, and the composition is asserted alongside the pixels. The
//  picker sheet itself is not rendered: it reads its catalogue from the
//  environment's `AppModel` -- a connection-scoped value a unit test has none
//  of -- and draws in a `List`, which draws nothing under `ImageRenderer`.
//  What renders instead is the row the sheet draws, `ModelPickerRow`, from a
//  decoded `ModelCatalog` fixture, seeded the way the sheet seeds a chosen
//  row: ticked, with its default effort revealed beneath.
//

import MizarKit
import SwiftUI
import Testing
@testable import DSH_Mizar

@MainActor
struct HomeModelSnapshotTests {
    /// The catalogue as the UI test's host serves it: one provider, one model,
    /// an Off and a High level, High the default the row seeds with.
    private static func catalogFixture() throws -> ModelCatalog {
        let json = """
        {
          "default": null,
          "providers": [
            {
              "id": "deepseek",
              "name": "DeepSeek",
              "models": [
                {
                  "id": "deepseek-v4-pro",
                  "name": "DeepSeek V4 Pro",
                  "description": "The strongest reasoner on the shelf.",
                  "efforts": [
                    { "id": "off", "name": "Off" },
                    { "id": "high", "name": "High" }
                  ],
                  "defaultEffort": "high"
                }
              ]
            }
          ],
          "failures": []
        }
        """
        return try JSONDecoder().decode(ModelCatalog.self, from: Data(json.utf8))
    }

    @Test func homeModelPillNamesTheModelItWillStartOn() throws {
        try AppSourceContract.expectIdentifiers(
            ["home.field", "home.send", "home.model"],
            in: "DSH-Mizar/Views/Shell/HomeView.swift",
        )

        // The UI test asserted the label contains the model's id;
        // `modelPillLabel` is what composes it, and the same composition feeds
        // the pixels below.
        let label = modelPillLabel(model: "deepseek-v4-pro", effort: "off")
        #expect(label == "deepseek-v4-pro · Off")

        let snapshot = try SnapshotHarness.assertSnapshot(
            of: ModelPill(label: label, action: {}),
            named: "HomeModelPill-deepseek-v4-pro",
            size: CGSize(width: 220, height: 44),
        )
        #expect(snapshot.pixelWidth == 440)
        #expect(snapshot.pixelHeight == 88)
    }

    @Test func modelPickerRowRevealsTheReasoningEffort() throws {
        try AppSourceContract.expectFragments(
            [#".accessibilityIdentifier("model.row.\(option.id)")"#],
            in: "DSH-Mizar/Views/Pickers.swift",
            describing: "the model row's wire identifier",
        )

        let snapshot = try SnapshotHarness.assertSnapshot(
            of: PickerRowFixture(catalog: try Self.catalogFixture()),
            named: "HomeModelPickerRow-deepseek-v4-pro",
            size: CGSize(width: 340, height: 140),
        )
        #expect(snapshot.pixelWidth == 680)
        #expect(snapshot.pixelHeight == 280)
    }
}

/// `ModelPickerView`'s chosen row, hosted without the sheet: the sheet's
/// `List` draws nothing under `ImageRenderer`, so the row renders in a plain
/// stack. Chosen and seeded with the catalogue's default effort, which is what
/// the sheet does when a row is tapped -- the state the UI test walks through.
private struct PickerRowFixture: View {
    let catalog: ModelCatalog
    @Namespace private var tick
    @State private var chosenEffort: String? = "high"

    var body: some View {
        let provider = catalog.providers[0]
        let option = provider.models[0]
        return VStack(alignment: .leading, spacing: 0) {
            ModelPickerRow(
                provider: provider,
                option: option,
                isChosen: true,
                chosenEffort: $chosenEffort,
                tick: tick,
                onChoose: {},
                onCommit: { _ in },
            )
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
    }
}
