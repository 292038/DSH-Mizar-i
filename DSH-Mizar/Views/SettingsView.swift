//
//  SettingsView.swift
//  DSH-Mizar
//
//  The second tab: what the app does, what happened, and what it is.
//
//  Four sections, in the order somebody needs them: what this phone will tell
//  you (notifications), what it shows while it is working (the Live Activity),
//  what to send when something is wrong (the log export), and what it is
//  (about).
//
//  Every switch here is wired to something that reads it, and that is the whole
//  reason this file is not a list of preferences. 通知 asks
//  ``NotificationKind`` what arrived and ``PushAppDelegate`` refuses what the
//  operator switched off; 实时活动 is ``AppModel/liveActivitiesEnabled``, which
//  the activity reads; 日志 exports what ``ActivityLog`` recorded. A switch
//  nothing consults is worse than no switch, because it teaches the operator that
//  this screen does not work.
//
//  Native throughout -- `List`, `Section`, `Toggle`, `LabeledContent`, the system
//  share sheet -- because every one of these has an accessibility shape the
//  operator already knows and a look that follows the OS forward. Nothing is
//  imitated, and no row is drawn by hand.
//

import MizarKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    /// The system's browser opener, for the source link.
    @Environment(\.openURL) private var openURL

    /// The archive currently being offered to the share sheet.
    @State private var sharing: LogArchive?
    /// Whether an export is in flight, so the button can say so.
    @State private var exporting = false
    /// What iOS thinks of this app's notifications, read when the screen opens.
    @State private var permission: NotificationPermission?

    var body: some View {
        NavigationStack {
            List {
                notificationsSection
                liveActivitySection
                logsSection
                aboutSection
            }
            .navigationTitle(Text("Settings"))
            .task {
                // Asked here rather than at launch: this is the screen where the
                // answer is meaningful, and reading it is a call into the
                // notification centre that nothing else needs.
                permission = await NotificationPermission.current()
            }
            .sheet(item: $sharing) { archive in
                ShareSheet(items: [archive.url])
            }
        }
    }

    // MARK: - 通知

    private var notificationsSection: some View {
        Section {
            ForEach(NotificationKind.allCases, id: \.self) { kind in
                Toggle(isOn: binding(for: kind)) {
                    Label(title(for: kind), systemImage: symbol(for: kind))
                }
                .accessibilityIdentifier(identifier(for: kind))
            }
            LabeledContent {
                Text(permission?.description ?? String(localized: "Checking…"))
            } label: {
                Label("iOS notifications", systemImage: "bell.badge")
            }
            .accessibilityIdentifier("settings.notify.authorization")
        } header: {
            Text("Notifications")
        } footer: {
            // `String(localized:)` rather than a literal, and the whole sentence
            // in one piece: `Text` given a concatenation of literals resolves to
            // the `StringProtocol` overload, which is not localized -- and a
            // Chinese screen with an English paragraph in the middle of it is
            // exactly what that looks like.
            Text(
                String(
                    localized: "A notification whose kind is switched off is dropped when it arrives, whatever iOS is set to. The line above is the system permission: if it says notifications are off, no switch here can bring them back.",
                ),
            )
        }
    }

    /// The switch for one kind, written straight through to the stored value.
    ///
    /// Built by hand rather than projected with `@Bindable`, because a kind is an
    /// argument and not a property: there is no key path to a `Bool`. The write
    /// goes through `values`, whose `didSet` persists it and logs it, so a switch
    /// flipped here is on disk before the finger is off the screen.
    ///
    /// - Parameter kind: the notification kind.
    /// - Returns: a binding for its switch.
    private func binding(for kind: NotificationKind) -> Binding<Bool> {
        Binding(
            get: { model.settings.values.notifications.isEnabled(kind) },
            set: { model.settings.values.notifications.set($0, for: kind) },
        )
    }

    /// What one kind is called on screen.
    /// - Parameter kind: the notification kind.
    /// - Returns: its label.
    private func title(for kind: NotificationKind) -> String {
        switch kind {
        case .turnFinished: String(localized: "Task complete")
        case .turnInterrupted: String(localized: "Task interrupted")
        case .question: String(localized: "Model question")
        case .approval: String(localized: "Permission needed")
        }
    }

    /// The symbol for one kind.
    /// - Parameter kind: the notification kind.
    /// - Returns: an SF Symbol name.
    private func symbol(for kind: NotificationKind) -> String {
        switch kind {
        case .turnFinished: "checkmark.circle"
        case .turnInterrupted: "exclamationmark.triangle"
        case .question: "questionmark.bubble"
        case .approval: "hand.raised"
        }
    }

    /// The accessibility identifier for one kind's switch.
    /// - Parameter kind: the notification kind.
    /// - Returns: the identifier a UI test looks for.
    private func identifier(for kind: NotificationKind) -> String {
        "settings.notify.\(kind.rawValue)"
    }

    // MARK: - 实时活动

    private var liveActivitySection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { model.settings.values.liveActivitiesEnabled },
                set: { model.settings.values.liveActivitiesEnabled = $0 },
            )) {
                Label("Live Activity", systemImage: "bolt.horizontal.circle")
            }
            .accessibilityIdentifier("settings.liveActivity")
        } header: {
            Text("Live Activity")
        } footer: {
            Text(
                String(
                    localized: "Shows a running turn on the Lock Screen. Switching it off stops a new activity from starting; it does not touch the conversation.",
                ),
            )
        }
    }

    // MARK: - 日志

    private var logsSection: some View {
        Section {
            Button {
                Task { await export() }
            } label: {
                Label("Export logs", systemImage: "square.and.arrow.up")
            }
            .disabled(exporting)
            .accessibilityIdentifier("settings.logs.export")

            if exporting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Packing the log…")
                }
                .accessibilityIdentifier("settings.logs.exporting")
            }

            if let archive = model.lastLogExport {
                // The file's name and size, kept on screen after the share sheet
                // goes away: "did that work" is a question with an answer, and
                // the answer is not "tap it again".
                LabeledContent {
                    Text(archive.readableSize)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(archive.fileName)
                            .font(.footnote.monospaced())
                        Text("Last export, \(archive.fileCount) files, \(archive.recordCount) entries")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("settings.logs.lastArchive")
            } else if model.log.count > 0 {
                // Before the first export, what there is to export. After one,
                // the file itself is the more useful row.
                LabeledContent {
                    Text("\(model.log.count)")
                        .monospacedDigit()
                } label: {
                    Label("Entries recorded", systemImage: "text.alignleft")
                }
                .accessibilityIdentifier("settings.logs.count")
            }
        } header: {
            Text("Logs")
        } footer: {
            Text(
                String(
                    localized: "A zip with this build and phone, the settings above, every request to the Mac and how it ended, the connection attempts, the sync progress and the recent host events. Device tokens and pairing codes are removed before the file is written, and conversations are not in it.",
                ),
            )
        }
    }

    /// Build the archive and offer it to the share sheet.
    private func export() async {
        exporting = true
        // The flag is cleared on every path: an export that failed and left the
        // button disabled would be a screen with no way to try again.
        defer { exporting = false }
        sharing = await model.exportLogs()
    }

    // MARK: - 关于

    private var aboutSection: some View {
        // Two sections under one name, because 关于 is one idea: what this app is
        // (the version and where it comes from) and who made it. A `Group` and
        // not a third `Section`: credits are not part of "about this build".
        Group {
            Section {
            Button {
                openSource()
            } label: {
                LabeledContent {
                    Image(systemName: "arrow.up.right")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } label: {
                    Label("Source code", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            }
            .accessibilityIdentifier("settings.about.source")

            LabeledContent {
                Text(AppModel.versionLine)
                    .monospacedDigit()
            } label: {
                Label("Version", systemImage: "number")
            }
            .accessibilityIdentifier("settings.about.version")
        } header: {
            Text("About")
        } footer: {
            Text(
                String(
                    localized: "Monitor and guide a DSH agent from a phone. The Mac decides; this app shows and answers.",
                ),
            )
        }

        // 开发者鸣谢 — one name per row, as native list rows. Not one text block
        // with a line break in it: a paragraph is not a credit, it is a
        // paragraph, and it reads as one to VoiceOver.
        Section {
            Label("ShirazuNagisa", systemImage: "person.crop.circle")
                .accessibilityIdentifier("settings.credits.shirazu")
            Label("Arowey", systemImage: "person.crop.circle")
                .accessibilityIdentifier("settings.credits.arowey")
        } header: {
            Text("Credits")
        }
        }
    }

    /// Open the project in the default browser.
    private func openSource() {
        // The system's own opener, so the operator's browser choice is honoured
        // and nothing here pretends to be a browser view.
        guard let url = URL(string: "https://github.com/ShirazuNagisa/DSH-Mizar") else { return }
        openURL(url)
    }
}

#Preview {
    SettingsView().environment(AppModel())
}
