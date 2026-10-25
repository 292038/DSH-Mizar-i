//
//  SettingsView.swift
//  DSH-Mizar
//
//  The settings sheet: what the app does, what happened, and what it is.
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
import UIKit

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
    /// Bumped after the cache is cleared, so the tap has a haptic to play on.
    @State private var mizarSuccess = false
    /// Closes the sheet this screen is presented in.
    var onDone: (() -> Void)?
    /// The one switch every haptic in the app answers to.
    @AppStorage(Haptics.storageKey) private var hapticsEnabled = true
    /// The paid-plan explanation, from either this screen or the account screen.
    @State private var showingPlanDetail = false
    /// The preview cache, for the 文件 section. Optional because the snapshot
    /// suite renders this screen without the shell's environment around it.
    @Environment(PreviewCenter.self) private var preview: PreviewCenter?

    var body: some View {
        NavigationStack {
            List {
                header
                accountSection
                planSection
                notificationsSection
                liveActivitySection
                transferSection
                filesSection
                feelSection
                logsSection
                aboutSection
            }
            .navigationTitle(Text("Settings"))
            // A small window keeps its title small.
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let onDone {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: onDone)
                            .accessibilityIdentifier("settings.done")
                    }
                }
            }
            .refreshable {
                await model.credits.refresh()
            }
            .task {
                // Asked here rather than at launch: this is the screen where the
                // answer is meaningful, and reading it is a call into the
                // notification centre that nothing else needs.
                permission = await NotificationPermission.current()
                await model.credits.start()
            }
            .sheet(item: $sharing) { archive in
                ShareSheet(items: [archive.url])
            }
            .sheet(isPresented: $showingPlanDetail) {
                MizarPaidDetailView()
            }
        }
    }

    // MARK: - Header

    /// What this is, before what it does: the icon, the name, the version.
    private var header: some View {
        Section {
            HStack(spacing: 16) {
                MizarMarkConnecting(accent: Color(red: 0.235, green: 0.796, blue: 0.957), ink: .white)
                    .frame(width: 36)
                    .frame(width: 64, height: 64)
                    .background(
                        LinearGradient(colors: [Theme.navy, Theme.navyDeep], startPoint: .top, endPoint: .bottom),
                        in: RoundedRectangle(cornerRadius: 15, style: .continuous),
                    )
                    .shadow(color: Theme.navy.opacity(0.35), radius: 10, y: 4)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: "DSH-Mizar")
                        .font(.title2.weight(.bold))
                    Text(model.host.map { String(format: String(localized: "Paired with %@"), $0.displayName) } ?? String(localized: "No computer paired yet"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 6)
            .listRowBackground(Color.clear)
        }
    }

    // MARK: - 账户

    /// The account row: who is signed in, or that nobody is.
    ///
    /// Placed between the header and notifications because it is the second
    /// thing a person looks for in settings, and because it has to be reachable
    /// without signing in — the row is how anybody discovers an account exists.
    /// A blank avatar and 未登录 is not an error state; it is the truth about an
    /// app that works without one.
    private var accountSection: some View {
        Section {
            NavigationLink {
                AccountScreen(onDone: onDone)
            } label: {
                HStack(spacing: 14) {
                    AccountAvatarView(user: model.account.user, image: model.account.customAvatar, size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.account.isLoggedIn ? model.account.displayName : String(localized: "Not signed in"))
                            .font(.body.weight(.medium))
                            .foregroundStyle(model.account.isLoggedIn ? Color.primary : Color.secondary)
                            .accessibilityIdentifier("settings.account.name")
                        Text(model.account.isPaid ? String(localized: "Paid account") : String(localized: "Free account"))
                            .font(.caption)
                            .foregroundStyle(model.account.isPaid ? Color.accentColor : Color.secondary)
                            .accessibilityIdentifier("settings.account.plan")
                    }
                }
                .padding(.vertical, 2)
            }
            .accessibilityIdentifier("settings.account")
        } header: {
            Text("Account")
        } footer: {
            if !model.account.isLoggedIn {
                Text("A Mizar account is required to use the app. It keeps every relay session attributable to one person.")
            } else if let notice = model.account.noticeMessage {
                Text(notice)
            }
        }
    }

    // MARK: - 付费版

    /// The plan row, and the one honest paragraph about what it pays for.
    ///
    /// It sits directly under the account because "what am I on" and "what would
    /// paying change" are the same question asked twice.
    private var planSection: some View {
        Section {
            LabeledContent {
                Button("Details") { showingPlanDetail = true }
                    .font(.footnote.weight(.medium))
                    .accessibilityIdentifier("settings.plan.detail")
            } label: {
                Label("Mizar Paid", systemImage: "star.circle")
            }
            .accessibilityIdentifier("settings.plan")
        } header: {
            Text("Plan")
        } footer: {
            Text("A high-bandwidth relay, paid for by the people who need it. The free server stays free.")
        }
    }

    // MARK: - 触感

    private var feelSection: some View {
        Section {
            Toggle(isOn: $hapticsEnabled) {
                Label("Haptics", systemImage: "hand.tap")
            }
            .accessibilityIdentifier("settings.haptics")
        } header: {
            Text("Feel")
        } footer: {
            Text(String(localized: "A light tap when a turn you are watching finishes, when a request is answered, and when a message is sent."))
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
    ///
    /// Built from the kind's *wire* name rather than from its Swift case name, so
    /// the identifier is one derivation in one place: `settings.notify.turn-finished`,
    /// not `settings.notify.turnFinished`. A UI test asks for the hyphenated form,
    /// and asking for the other one finds nothing at all -- which is how this was
    /// learned.
    ///
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
                    localized: "Shows a running turn on the Lock Screen. Switching it off takes an activity that is up down with it and stops a new one from starting; it does not touch the conversation.",
                ),
            )
        }
    }

    // MARK: - 传输

    /// How a reconnect chooses its route.
    ///
    /// Off is the fast path: no probe, straight to the stored route. On asks
    /// the local network first and falls back to the relay, which is slower per
    /// reconnect and is what makes a phone that is back on the same Wi-Fi take
    /// the direct route (and its free LAN features) again.
    private var transferSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { model.settings.values.localNetworkFirst },
                set: { model.settings.values.localNetworkFirst = $0 },
            )) {
                Label("Local network first", systemImage: "wifi")
            }
            .accessibilityIdentifier("settings.transfer.lanPriority")

            // Off by default, and the footer says what it costs rather than
            // what it promises: a punch that fails adds seconds to a reconnect
            // that would otherwise have been the relay straight away.
            Toggle(isOn: Binding(
                get: { model.settings.values.directConnection },
                set: { model.settings.values.directConnection = $0 },
            )) {
                Label("P2P direct connection", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
            }
            .accessibilityIdentifier("settings.transfer.directConnection")
        } header: {
            Text("Transfer")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text(
                    String(
                        localized: "Turn this on if you use the app on the same local network; turning it off makes every reconnect faster.",
                    ),
                )
                Text(
                    String(
                        localized: "P2P direct connection asks this computer and your phone to reach each other without the relay. It falls back to the relay when the two networks will not allow it.",
                    ),
                )
            }
        }
    }

    // MARK: - 文件

    /// The files this phone has read, and the way to get the space back.
    ///
    /// A cache the operator cannot see is a cache they cannot trust: the number
    /// is here so "why is the app 300 MB" has an answer on the screen, and the
    /// button is here because the answer to that question should be one tap
    /// away. Nothing in the app depends on these files — every one of them can be
    /// read from the computer again — so clearing them needs no confirmation.
    private var filesSection: some View {
        Section {
            LabeledContent {
                Text(cacheSummary)
                    .monospacedDigit()
                    .accessibilityIdentifier("settings.files.size")
            } label: {
                Label("Previewed files", systemImage: "doc.text.magnifyingglass")
            }

            Button(role: .destructive) {
                Task {
                    await preview?.clearCache()
                    mizarSuccess = true
                }
            } label: {
                Label("Clear file cache", systemImage: "trash")
            }
            .disabled((preview?.cacheFiles ?? 0) == 0)
            .accessibilityIdentifier("settings.files.clear")
            .mizarFeedback(.success, trigger: mizarSuccess)
        } header: {
            Text("Files")
        } footer: {
            Text(
                String(
                    localized: "Files the model delivered are kept on this phone so a second look does not send them again. Clearing them frees the space; the next preview reads the file from the computer.",
                ),
            )
        }
        .task { await preview?.refreshCacheUsage() }
    }

    /// What the cache holds, as one line.
    private var cacheSummary: String {
        let files = preview?.cacheFiles ?? 0
        guard files > 0 else { return String(localized: "Empty") }
        let bytes = preview?.cacheBytes ?? 0
        return String(format: String(localized: "%lld files · %@"), files, Self.size(bytes))
    }

    /// A byte count, the way the log export says it.
    ///
    /// - Parameter bytes: how many bytes.
    /// - Returns: a short human figure.
    static func size(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
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
                    localized: "A zip with this build and phone, the settings above, every request to the computer and how it ended, the connection attempts, the sync progress and the recent host events. Device tokens and pairing codes are removed before the file is written, and conversations are not in it.",
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

            // 兑换邀请码 lives on the account screen, next to the plan it pays
            // for: an invite is an account thing, and About is about the build.
            LabeledContent {
                Text(AppModel.versionLine)
                    .monospacedDigit()
            } label: {
                Label("Version", systemImage: "number")
            }
            .accessibilityIdentifier("settings.about.version")
        } header: {
            Text("About")
        }

        // 开发者鸣谢 — one person per row, as native list rows, fetched from
        // GitHub and cached for a day. Not a text block: a paragraph is not a
        // credit, it is a paragraph, and it reads as one to VoiceOver.
        creditsSection
        }
    }

    // MARK: - 鸣谢

    /// The contributors, one row each, tappable to their GitHub profile.
    private var creditsSection: some View {
        Section {
            if model.credits.contributors.isEmpty {
                HStack(spacing: 10) {
                    if case .loading = model.credits.state {
                        ProgressView().controlSize(.small)
                    }
                    Text(creditsEmptyText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings.credits.empty")
                }
                .padding(.vertical, 4)
            } else {
                ForEach(model.credits.contributors) { contributor in
                    Link(destination: contributor.profileURL) {
                        ContributorRow(
                            contributor: contributor,
                            avatar: model.credits.avatar(for: contributor.login),
                        )
                    }
                    .accessibilityIdentifier("settings.credits.row.\(contributor.login)")
                }
            }
        } header: {
            Text("Credits")
        }
    }

    /// What an empty list says, by state.
    private var creditsEmptyText: String {
        switch model.credits.state {
        case .failed(let message): message
        case .loading: String(localized: "Loading contributors…")
        default: String(localized: "No contributors to show yet.")
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

/// One contributor: avatar, name, what they did, and the way to their profile.
struct ContributorRow: View {
    let contributor: Contributor
    let avatar: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            avatarView
                .frame(width: 32, height: 32)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(contributor.name ?? contributor.login)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(contributor.name == nil
                    ? contributor.detail
                    : "@\(contributor.login) · \(contributor.detail)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "arrow.up.right")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var avatarView: some View {
        if let avatar {
            Image(uiImage: avatar).resizable().scaledToFill()
        } else {
            ZStack {
                Circle().fill(.fill.tertiary)
                Image(systemName: "person.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
