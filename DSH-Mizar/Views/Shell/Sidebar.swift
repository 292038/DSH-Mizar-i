//
//  Sidebar.swift
//  DSH-Mizar
//
//  The computer's sessions, grouped the way DSH groups them.
//
//  Top to bottom: the computer's name and a refresh, a search field, "New session",
//  then one row per workspace. Workspaces start folded -- a list of five
//  workspaces each holding a dozen sessions is not a list anybody can read --
//  and open with a tap, their sessions rising into place one after another. The
//  workspace holding the session on screen opens by itself, so the operator can
//  always see where they are.
//
//  The shape mirrors the computer's own sidebar because that is what the operator is
//  looking at when they reach for their phone, and a phone that arranges the
//  same sessions differently is a second thing to learn.
//
//  Subagents are left out. They are real sessions, but they are the agent's
//  bookkeeping rather than the operator's work, and a list where half the rows
//  are delegated children is a list nobody can scan. The arrangement itself is
//  `MizarKit.WorkspaceCatalog`'s, shared with the new-session picker.
//

import SwiftUI
import MizarKit
import UIKit

struct SidebarView: View {
    let actions: SidebarActions

    @Environment(AppModel.self) private var model
    @Environment(ShellState.self) private var shell
    @State private var query = ""
    @FocusState private var searching: Bool
    /// How many sessions each workspace shows before offering more.
    @State private var limits: [String: Int] = [:]
    /// The selection highlight's namespace: one highlight that slides from row
    /// to row rather than one per row that blinks.
    @Namespace private var selection

    private static let pageSize = 10

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
                problemLine
                search
                    .padding(.top, 14)
                newSession
                    .padding(.top, 10)
                workspaces
                    .padding(.top, 22)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.immediately)
        .scrollIndicators(.hidden)
        .refreshable { await model.refreshSessions() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarFooter(actions: actions)
        }
        .scrollEdgeEffectStyle(.soft, for: .vertical)
        .background(Theme.sidebarBackground)
        .onChange(of: model.selectedSessionId, initial: true) { _, selected in
            revealSelection(selected)
        }
        .onChange(of: query) { old, new in
            // Titles are one request each and are normally fetched only for a
            // workspace being opened. A search is a question about every
            // session, so the first keystroke asks for the ones not known yet.
            guard old.isEmpty, !new.isEmpty else { return }
            let unknown = model.workspaceGroups
                .flatMap(\.sessions)
                .map(\.sessionId)
                .filter { model.titles[$0] == nil }
            Task { await model.loadTitles(for: Array(unknown.prefix(40))) }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            // One plain text, alone: the computer's name is how the operator knows
            // which machine this is, and it is the one string on this screen
            // that is theirs rather than the app's.
            Text(model.host?.displayName ?? model.welcome?.hostName ?? String(localized: "Sessions"))
                .font(.title2.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .contentTransition(.opacity)
            Spacer(minLength: 0)
            Button(action: actions.sync) {
                GlassCircleLabel(size: 38) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 15, weight: .semibold))
                        .symbolEffect(.rotate, options: .repeat(.continuous), isActive: model.isSyncing)
                }
            }
            .buttonStyle(.plain)
            .disabled(model.isSyncing)
            .accessibilityLabel(Text("Refresh"))
            .accessibilityIdentifier("sessions.refresh")
        }
    }

    /// A refresh that failed says so and stays out of the way: one quiet line,
    /// not a panel with a Retry button -- the retry already happens on pull, on
    /// the refresh button and by itself.
    @ViewBuilder private var problemLine: some View {
        if let error = model.problem {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    // On the text, not the row: an identifier on a container
                    // does not reach the accessibility tree.
                    .accessibilityIdentifier("sessions.error")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .transition(.rise)
        }
    }

    // MARK: - Search

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            TextField("Search sessions", text: $query)
                .focused($searching)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier("sidebar.search")
            if !query.isEmpty {
                Button {
                    withMizarAnimation(.mizarSnappy) { query = "" }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .transition(.pop)
                .accessibilityLabel(Text("Clear search"))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .liquidCapsule()
        .animation(.mizarSnappy, value: query.isEmpty)
    }

    // MARK: - New session

    private var newSession: some View {
        Button(action: actions.newSession) {
            HStack(spacing: 12) {
                Image(systemName: "square.and.pencil")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 26)
                Text("New session")
                    .font(.body.weight(.medium))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .contentShape(.rect)
            .liquidSurface(in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous), interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sessions.new")
        // Long-press goes straight to a workspace, for the operator who already
        // knows where the work is.
        .contextMenu {
            ForEach(model.workspaceChoices) { workspace in
                Button {
                    Task { await model.createSession(cwd: workspace.path) }
                } label: {
                    Label(workspace.title, systemImage: "folder")
                }
            }
        }
    }

    // MARK: - Workspaces

    private var workspaces: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(query.isEmpty ? String(localized: "Workspaces") : String(localized: "Results"))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
                .contentTransition(.opacity)

            if model.sessions.isEmpty && model.workspaceGroups.allSatisfy(\.sessions.isEmpty) && query.isEmpty {
                emptyState
            }

            let groups = visibleGroups
            if groups.isEmpty, !query.isEmpty {
                Text("Nothing matches “\(query)”")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .transition(.rise)
            }
            ForEach(groups, id: \.group.id) { entry in
                WorkspaceSection(
                    group: entry.group,
                    sessions: entry.sessions,
                    isOpen: entry.forcedOpen || isExpanded(entry.group.path),
                    limit: entry.forcedOpen ? entry.sessions.count : (limits[entry.group.path] ?? Self.pageSize),
                    query: query,
                    selection: selection,
                    onToggle: { toggle(entry.group) },
                    onMore: { more(entry.group) },
                    onCollapseOthers: { collapseOthers(than: entry.group) },
                    onNewHere: { Task { await model.createSession(cwd: entry.group.path) } },
                )
            }
        }
        .animation(.mizarSmooth, value: query)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "tray")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text("No sessions yet")
                .font(.headline)
            Text("Start one on your computer, then refresh.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    /// The groups to draw, with the sessions each shows.
    ///
    /// Searching filters by the workspace's name, the session's title and its
    /// working directory, and opens every group that has a match -- a search
    /// result hidden inside a folded group is not a result.
    private var visibleGroups: [(group: WorkspaceGroup, sessions: [SessionRow], forcedOpen: Bool)] {
        let groups = model.workspaceGroups
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return groups.map { ($0, $0.sessions, false) } }
        return groups.compactMap { group in
            if group.title.localizedCaseInsensitiveContains(needle) {
                return (group, group.sessions, !group.sessions.isEmpty)
            }
            let matches = group.sessions.filter { session in
                SessionTitle.display(for: session, title: model.titles[session.sessionId])
                    .localizedCaseInsensitiveContains(needle)
                    || (session.cwd ?? "").localizedCaseInsensitiveContains(needle)
            }
            return matches.isEmpty ? nil : (group, matches, true)
        }
    }

    // MARK: - Expansion

    private func isExpanded(_ path: String) -> Bool {
        shell.expanded(for: model.host?.hostId).contains(path)
    }

    private func toggle(_ group: WorkspaceGroup) {
        var open = shell.expanded(for: model.host?.hostId)
        withMizarAnimation(.mizarSmooth) {
            if open.contains(group.path) {
                open.remove(group.path)
            } else {
                open.insert(group.path)
            }
            shell.setExpanded(open, for: model.host?.hostId)
        }
        if open.contains(group.path) { loadTitles(for: group) }
    }

    private func more(_ group: WorkspaceGroup) {
        let shown = limits[group.path] ?? Self.pageSize
        withMizarAnimation(.mizarSmooth) {
            limits[group.path] = shown + Self.pageSize
        }
        // The rows just revealed need their titles too. This used to raise the
        // limit and stop, so "Show 10 more" revealed ten rows named by their
        // directory and an id.
        let revealed = group.sessions.dropFirst(shown).prefix(Self.pageSize).map(\.sessionId)
        Task { await model.loadTitles(for: Array(revealed)) }
    }

    private func collapseOthers(than group: WorkspaceGroup) {
        withMizarAnimation(.mizarSmooth) {
            shell.setExpanded([group.path], for: model.host?.hostId)
        }
        loadTitles(for: group)
    }

    private func loadTitles(for group: WorkspaceGroup) {
        let shown = group.sessions.prefix(limits[group.path] ?? Self.pageSize).map(\.sessionId)
        Task { await model.loadTitles(for: Array(shown)) }
    }

    /// Open the workspace holding the session on screen.
    private func revealSelection(_ selected: String?) {
        guard let selected,
              let group = model.workspaceGroups.first(where: { $0.sessions.contains { $0.sessionId == selected } })
        else { return }
        var open = shell.expanded(for: model.host?.hostId)
        guard !open.contains(group.path) else { return }
        open.insert(group.path)
        shell.setExpanded(open, for: model.host?.hostId)
        // Far enough down a long group to be hidden behind "Show more": raise
        // the limit to include it.
        if let index = group.sessions.firstIndex(where: { $0.sessionId == selected }),
           index >= (limits[group.path] ?? Self.pageSize) {
            limits[group.path] = index + 1
        }
        loadTitles(for: group)
    }
}

/// What to call a session.
///
/// The host's title first, because it describes the conversation. Falling back
/// to the working directory alone makes every row in a workspace read the same
/// -- five sessions all called "DSH-Mizar" -- so a shortened id goes with it:
/// not a name, but still a way to tell one row from the next.
enum SessionTitle {
    static func display(for session: SessionRow, title: String?) -> String {
        if let title, !title.isEmpty { return title }
        if let cwd = session.cwd {
            let name = (cwd as NSString).lastPathComponent
            return "\(name) · \(session.sessionId.prefix(8))"
        }
        return session.sessionId
    }
}

// MARK: - Footer

/// The computer this is, how it is reached, and the way to the settings.
private struct SidebarFooter: View {
    let actions: SidebarActions
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Button(action: actions.hosts) {
                HStack(spacing: 12) {
                    ConnectionDot(live: model.isConnected)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(status)
                            .font(.subheadline.weight(.semibold))
                            .contentTransition(.opacity)
                        Text(route)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .frame(height: 54)
                .contentShape(.capsule)
                .liquidCapsule(interactive: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Computers, \(status)"))
            .accessibilityIdentifier("sessions.hosts")

            Button(action: actions.settings) {
                GlassCircleLabel(size: 54) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 19, weight: .medium))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Settings"))
            .accessibilityIdentifier("sidebar.settings")
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .animation(.mizarSmooth, value: model.isConnected)
    }

    private var status: String {
        if model.isConnected { return String(localized: "Connected") }
        if model.reconnecting { return String(localized: "Connecting…") }
        return String(localized: "Offline")
    }

    private var route: String {
        guard model.isConnected else {
            return model.hasStoredIndex ? String(localized: "Showing saved history") : String(localized: "Not reachable")
        }
        switch model.activeEndpoint {
        case .relay: return String(localized: "Through the relay")
        case .direct(let authority): return authority
        case nil: return model.host?.authority ?? ""
        }
    }
}

/// Green and breathing while the computer is reachable; grey and still when it is
/// not.
private struct ConnectionDot: View {
    let live: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if live && !reduceMotion {
                Circle()
                    .fill(Theme.running.opacity(0.35))
                    .frame(width: 10, height: 10)
                    .phaseAnimator([false, true]) { content, out in
                        content
                            .scaleEffect(out ? 2.4 : 1)
                            .opacity(out ? 0 : 1)
                    } animation: { out in
                        out ? .easeOut(duration: 1.6) : .linear(duration: 0.01).delay(0.6)
                    }
            }
            Circle()
                .fill(live ? Theme.running : Color.secondary.opacity(0.5))
                .frame(width: 10, height: 10)
        }
        .frame(width: 14, height: 14)
        .accessibilityHidden(true)
    }
}
