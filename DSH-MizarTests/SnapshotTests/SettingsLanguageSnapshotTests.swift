//
//  SettingsLanguageSnapshotTests.swift
//  DSH-MizarTests
//
//  The settings screen's language: the notifications, Live Activity and
//  credits sections in Chinese and in English -- the two full app launches
//  `AppFlowLaunchTests.testTheSettingsScreenFollowsTheLanguage` spends on the
//  same copy, pushed down to snapshots (docs/phase2-triage.md).
//
//  Not the whole screen, deliberately: `SettingsView` draws in a `List`, which
//  renders nothing under `ImageRenderer` (the
//  `SettingsAccountRowSnapshotTests` precedent); its header carries
//  `MizarMarkConnecting`, a repeating keyframe animation the render cannot
//  stop; and its row titles and footers resolve through `String(localized:)`,
//  which follows the process language and cannot be driven by a render-local
//  locale. So the sections the UI test asserts on are rebuilt here from the
//  same catalogue keys the app renders -- `Text` and `Label` literals, which
//  DO follow the environment locale -- with the identifiers pinned by contract
//  against the app source and the copy pinned in pixels in both languages.
//
//  The locale follows the environment, not the simulator: the harness pins
//  `en_US` by default and each argument overrides it
//  (`.environment(\.locale, ...)`), so one record run on the canonical
//  English-locale simulator (`Mizar Runs`, per docs/snapshots.md) produces
//  both goldens.
//

import MizarKit
import SwiftUI
import Testing
@testable import DSH_Mizar

@MainActor
struct SettingsLanguageSnapshotTests {
    enum Language: String, CaseIterable, Sendable {
        /// 简体中文 -- the app's other language.
        case zhHans = "zh-Hans"
        /// English, what the harness pins by default.
        case english = "en"

        var locale: Locale { Locale(identifier: rawValue) }
    }

    @Test(arguments: Language.allCases)
    func settingsSectionsFollowTheLanguage(_ language: Language) throws {
        // What the UI test asserted, pinned where it lives: the identifier it
        // queried on the credits row, the section headers, the rows' copy keys,
        // and the wire-named notification identifier built from the kind's raw
        // value.
        try AppSourceContract.expectIdentifiers(
            ["settings.credits.shirazu"],
            in: "DSH-Mizar/Views/SettingsView.swift",
        )
        try AppSourceContract.expectFragments(
            [
                #"Text("Notifications")"#,
                #"Text("Live Activity")"#,
                #"Text("Credits")"#,
                #"String(localized: "Task complete")"#,
                #"Label("Live Activity", systemImage: "bolt.horizontal.circle")"#,
                #"Label("Source code", systemImage: "chevron.left.forwardslash.chevron.right")"#,
                #"Label("ShirazuNagisa", systemImage: "person.crop.circle")"#,
                #""settings.notify.\(kind.rawValue)""#,
            ],
            in: "DSH-Mizar/Views/SettingsView.swift",
            describing: "the copy and identifiers the language UI test asserted",
        )

        let snapshot = try SnapshotHarness.assertSnapshot(
            of: sections,
            named: "SettingsLanguage-\(language.rawValue)",
            size: CGSize(width: 390, height: 440),
            locale: language.locale,
        )
        #expect(snapshot.pixelWidth == 780)
        #expect(snapshot.pixelHeight == 880)
    }

    /// `SettingsView`'s notifications, Live Activity and credits sections,
    /// rebuilt row for row at the list's insets. The copy is the same catalogue
    /// keys the app renders (`notificationsSection`'s four toggles through
    /// `title(for:)`/`symbol(for:)`, `liveActivitySection`'s toggle,
    /// `aboutSection`'s source link and credits rows). The footers are left
    /// out -- the app resolves them with `String(localized:)`, which a
    /// render-local locale cannot drive, and the UI test asserts none of them.
    private var sections: some View {
        VStack(alignment: .leading, spacing: 0) {
            section("Notifications") {
                ForEach(NotificationKind.allCases, id: \.self) { kind in
                    row {
                        Toggle(isOn: .constant(true)) {
                            Label(Self.title(for: kind), systemImage: Self.symbol(for: kind))
                        }
                        .accessibilityIdentifier("settings.notify.\(kind.rawValue)")
                    }
                }
            }
            section("Live Activity") {
                row {
                    Toggle(isOn: .constant(true)) {
                        Label("Live Activity", systemImage: "bolt.horizontal.circle")
                    }
                    .accessibilityIdentifier("settings.liveActivity")
                }
            }
            section("Credits") {
                row {
                    HStack {
                        Label("Source code", systemImage: "chevron.left.forwardslash.chevron.right")
                        Spacer(minLength: 12)
                        Image(systemName: "arrow.up.right")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                row {
                    Label("ShirazuNagisa", systemImage: "person.crop.circle")
                        .accessibilityIdentifier("settings.credits.shirazu")
                }
                row {
                    Label("Arowey", systemImage: "person.crop.circle")
                }
            }
        }
    }

    /// A section header, at the list's caption weight and inset.
    private func section(_ title: LocalizedStringKey, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 6)
            rows()
        }
    }

    /// One row, full width, at the list's horizontal inset.
    private func row(@ViewBuilder content: () -> some View) -> some View {
        content()
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// `SettingsView.title(for:)`'s copy, as the keys `Text` localises.
    private static func title(for kind: NotificationKind) -> LocalizedStringKey {
        switch kind {
        case .turnFinished: "Task complete"
        case .turnInterrupted: "Task interrupted"
        case .question: "Model question"
        case .approval: "Permission needed"
        }
    }

    /// `SettingsView.symbol(for:)`'s symbols.
    private static func symbol(for kind: NotificationKind) -> String {
        switch kind {
        case .turnFinished: "checkmark.circle"
        case .turnInterrupted: "exclamationmark.triangle"
        case .question: "questionmark.bubble"
        case .approval: "hand.raised"
        }
    }
}
