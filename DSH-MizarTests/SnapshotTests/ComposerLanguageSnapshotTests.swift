//
//  ComposerLanguageSnapshotTests.swift
//  DSH-MizarTests
//
//  The composer's language in Chinese and in English: the field's placeholder,
//  the command list, and the failure card -- the four copy assertions
//  `AppFlowNavigationTests.testInterfaceFollowsTheLanguageAndContentDoesNot`
//  makes across two full app launches, pushed down to snapshots
//  (docs/phase2-triage.md).
//
//  Three renders:
//  - the field block, rebuilt with the exact modifier chain
//    `ComposerView.body` applies to its `TextField` (the bar itself binds to
//    app state and owns popovers a render must not open);
//  - `CommandList`, the app's own view -- it takes the gate as a `Bool` and
//    owns no environment (`AttachmentGateSnapshotTests` already renders it),
//    and since `ComposerBar.commands`' titles are catalogue keys its rows
//    follow the locale too;
//  - `FailureCard`, the app's own view, internal for exactly this
//    (`ConversationView`). Its message is hard-coded English on purpose: the
//    turn's content never translates with the interface, and the pixels prove
//    it -- the same sentence sits under a Chinese and an English heading.
//
//  The locale follows the environment, not the simulator: the harness pins
//  `en_US` by default and each argument overrides it, so one record run on the
//  canonical English-locale simulator produces both goldens.
//

import SwiftUI
import Testing
@testable import DSH_Mizar

@MainActor
struct ComposerLanguageSnapshotTests {
    enum Language: String, CaseIterable, Sendable {
        /// 简体中文 -- the app's other language.
        case zhHans = "zh-Hans"
        /// English, what the harness pins by default.
        case english = "en"

        var locale: Locale { Locale(identifier: rawValue) }
    }

    // MARK: - The field

    @Test(arguments: Language.allCases)
    func composerFieldPlaceholderFollowsTheLanguage(_ language: Language) throws {
        try AppSourceContract.expectIdentifiers(
            ["composer.field"],
            in: "DSH-Mizar/Views/ComposerView.swift",
        )
        try AppSourceContract.expectFragments(
            [#"TextField("Ask your agent…", text: $text, axis: .vertical)"#],
            in: "DSH-Mizar/Views/ComposerView.swift",
            describing: "the placeholder's catalogue key",
        )

        let snapshot = try SnapshotHarness.assertSnapshot(
            of: field,
            named: "ComposerFieldPlaceholder-\(language.rawValue)",
            size: CGSize(width: 390, height: 48),
            locale: language.locale,
        )
        #expect(snapshot.pixelWidth == 780)
        #expect(snapshot.pixelHeight == 96)
    }

    /// `ComposerView.body`'s field block, modifier chain verbatim: the
    /// `TextField("Ask your agent…")` through the padding and the identifier.
    /// The one modifier left off is the `onGeometryChange` that writes
    /// `ComposerGeometry.shared` -- the render is not on screen, and the
    /// conversation screen owns that frame.
    private var field: some View {
        TextField("Ask your agent…", text: .constant(""), axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...8)
            .padding(.horizontal, 16)
            .padding(.top, 13)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("composer.field")
    }

    // MARK: - The commands

    @Test(arguments: Language.allCases)
    func composerCommandTitlesFollowTheLanguage(_ language: Language) throws {
        try AppSourceContract.expectIdentifiers(
            ["composer.commands"],
            in: "DSH-Mizar/Views/ComposerBar.swift",
        )
        try AppSourceContract.expectFragments(
            [
                #""/goal", "Goal", "target""#,
                #""command.\(command.slash.dropFirst())""#,
            ],
            in: "DSH-Mizar/Views/ComposerBar.swift",
            describing: "the goal command's title key and wire identifier",
        )

        let snapshot = try SnapshotHarness.assertSnapshot(
            of: CommandList(
                canAttach: true,
                onAttachment: { _ in },
                onPick: { _ in },
            ),
            named: "ComposerCommands-\(language.rawValue)",
            size: CGSize(width: 300, height: 380),
            locale: language.locale,
        )
        #expect(snapshot.pixelWidth == 600)
        #expect(snapshot.pixelHeight == 760)
    }

    // MARK: - The failure card

    @Test(arguments: Language.allCases)
    func failureCardFollowsTheLanguageButNotTheContent(_ language: Language) throws {
        try AppSourceContract.expectFragments(
            [#"Label("The turn ended without a response", systemImage: "exclamationmark.triangle.fill")"#],
            in: "DSH-Mizar/Views/ConversationView.swift",
            describing: "the failure card's copy key",
        )

        // The message is the UI test's own fixture sentence, hard-coded in
        // English: the turn's content is host output and never translates with
        // the interface. The pixels are the proof -- the same sentence under
        // 本轮没有产生回复 and under "The turn ended without a response". An
        // hour-old failure never arms the shake (the onAppear guard is twenty
        // seconds), so the render is the resting card.
        let snapshot = try SnapshotHarness.assertSnapshot(
            of: FailureCard(
                message: "Refactor the parser and run the tests.",
                at: Date(timeIntervalSinceNow: -3600),
            )
            .padding(.horizontal, 16),
            named: "FailureCardLanguage-\(language.rawValue)",
            size: CGSize(width: 390, height: 80),
            locale: language.locale,
        )
        #expect(snapshot.pixelWidth == 780)
        #expect(snapshot.pixelHeight == 160)
    }
}
