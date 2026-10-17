//
//  MainView.swift
//  DSH-Mizar
//
//  The session list, and the conversation it opens.
//
//  A `NavigationSplitView` rather than a stack because the same code has to be
//  right on an iPad, where putting a conversation behind a push wastes the
//  screen, and on a phone, where the split view collapses to exactly the stack
//  behaviour anyway. One layout, two idioms.
//

import SwiftUI
import MizarKit

struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var showingNewSession = false
    @State private var showingSync = false

    /// Offered once, right after a pairing completes.
    private var namingPrompt: Binding<Bool> {
        Binding(
            get: { model.pendingNameHostId != nil },
            set: { if !$0 { model.pendingNameHostId = nil } },
        )
    }

    var body: some View {
        NavigationSplitView {
            sessionList(pushing: false)
        } detail: {
            if let sessionId = model.selectedSessionId {
                // Keyed on the session, which is what makes every piece of state
                // below belong to the session it was filled from.
                //
                // The screen is one view for every session and most of what it
                // holds is tagged by hand -- `statsSessionId`,
                // `conversationSessionId` -- but the untagged remainder is drawn
                // for whichever session is open next: the composer kept the text
                // typed for the last one, `ConversationView` kept "this history
                // has been paged to its end" and stopped offering older messages
                // for the new session, and the scroll anchor, the in-flight-load
                // gate and the paging allowance all belonged to a conversation
                // that is no longer on screen. One identity for the session is
                // the tag that covers the ones nobody remembered to add, and it
                // cancels a load the moment its subject goes away.
                SessionDetailView(sessionId: sessionId)
                    .id(sessionId)
                    .sheet(isPresented: namingPrompt) { namingSheet }
            } else {
                ContentUnavailableView(
                    "Pick a session",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Sessions started on your Mac appear here."),
                )
            }
        }
    }

    /// The session list, with everything that hangs off it.
    ///
    /// - Parameter pushing: whether a row pushes a conversation or selects it
    ///   in the split view's detail column. Always `false` today: see the note
    ///   in `WorkspaceListView`.
    /// - Returns: the sidebar content.
    private func sessionList(pushing: Bool) -> some View {
        @Bindable var model = model

        return WorkspaceListView(showingNewSession: $showingNewSession, pushing: pushing)
                .safeAreaInset(edge: .top) {
                    // A refresh that failed says so and stays out of the way. It
                    // used to take over the whole screen, which read as the
                    // connection dying rather than one request not arriving.
                    //
                    // It now also covers a connection that failed outright, for
                    // the same reason: with a stored session list there is a
                    // whole app behind this banner, and taking it away would
                    // take away conversations the operator can still read.
                    //
                    // The row is information, not a control. It used to be a
                    // yellow panel with a "Retry" button, and the operator read
                    // that as a development build rather than as their app
                    // reporting one failed read. The retry the button performed
                    // still happens, on the paths that already offer it: the
                    // read reconnects once by itself, pull to refresh asks
                    // again, and the toolbar's refresh asks again. What is left
                    // here is one quiet line in the app's normal error style,
                    // with no button to mistake for a work in progress.
                    if let error = model.problem {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                // On the text, not the row: an identifier on a
                                // container does not reach the accessibility
                                // tree, so a test looking for the banner would
                                // report the app as silent while it is shouting.
                                .accessibilityIdentifier("sessions.error")
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }
                .navigationTitle(model.host?.displayName ?? model.welcome?.hostName ?? "Sessions")
                .toolbar {
                    ToolbarItemGroup(placement: .topBarLeading) {
                        NavigationLink {
                            HostListView()
                        } label: {
                            Label("Macs", systemImage: "desktopcomputer")
                        }
                        .accessibilityIdentifier("sessions.hosts")
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            showingSync = true
                            Task { await model.syncAllConversations() }
                        } label: {
                            // Turns while it works. A refresh over a phone link
                            // can take a while, and a button that looks idle
                            // while nothing happens reads as a button that did
                            // nothing.
                            if model.isSyncing {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                        }
                        .disabled(model.isSyncing)
                        .accessibilityIdentifier("sessions.refresh")
                    }
                }
                .sheet(isPresented: $showingNewSession) {
                    NewSessionView()
                }
                // Wired, at last. `showingSync` was set by the refresh button and
                // read by nothing: the sheet it was written for was never
                // attached, so a refresh over a slow link was a spinner with no
                // end and no idea how far along it was -- for as long as it took.
                .sheet(isPresented: $showingSync) {
                    SyncProgressSheet()
                }
                .sheet(isPresented: namingPrompt) { namingSheet }
    }

    /// The one-time "what should this Mac be called" prompt.
    private var namingSheet: some View {
        Group {
            if let host = model.pendingNameHostId.flatMap({ id in
                model.hosts.first { $0.hostId == id }
            }) {
                RenameSheet(host: host) { name in
                    Task { await model.rename(hostId: host.hostId, to: name) }
                }
            }
        }
    }
}

/// Workspaces, each expanding into the conversations inside it.
///
/// The shape mirrors the Mac's own sidebar -- new session at the top, then one
/// row per workspace -- because that is what the operator is already looking at
/// when they reach for their phone, and a phone that arranges the same sessions
/// differently is a second thing to learn.
///
/// Subagents are left out. They are real sessions, but they are the agent's
/// bookkeeping rather than the operator's work, and a list where half the rows
/// are delegated children is a list nobody can scan.
struct WorkspaceListView: View {
    @Environment(AppModel.self) private var model
    @Binding var showingNewSession: Bool
    /// Whether a row pushes a conversation or selects one.
    ///
    /// Always `false` today. The conversation used to be pushed on a phone
    /// (`NavigationStack`) so that hiding the tab bar travelled with the push --
    /// which is the honest fix for the bar appearing after the screen has
    /// loaded, and it is what a system app does. It is not shipped yet: the
    /// restructure broke 21 of the 31 UI tests in one release, and a navigation
    /// change that size belongs in one of its own. Kept as a parameter because
    /// the row is the only part that differed.
    var pushing: Bool = false
    /// Workspaces the operator opened, by path.
    ///
    /// Tracked as what is *open* rather than what is closed, so the default --
    /// an empty set -- is everything folded. It was the other way round, and a
    /// list of five workspaces each holding a dozen identically-titled rows is
    /// not a list anybody can read.
    @State private var expanded: Set<String> = []

    /// How many sessions each workspace shows before offering more.
    @State private var limits: [String: Int] = [:]

    /// How many to add when asked for more.
    private static let pageSize = 10

    /// Sessions the operator started, grouped the way DSH groups them.
    ///
    /// The arrangement lives in `MizarKit.WorkspaceCatalog`, because it is one
    /// rule with two callers — this list and the new-session picker — and it was
    /// wrong in both of them at once. See that file for what it does and why.
    private var workspaces: [WorkspaceGroup] { model.workspaceGroups }

    var body: some View {
        @Bindable var model = model

        return Group {
            if pushing {
                List { rows }
            } else {
                List(selection: $model.selectedSessionId) { rows }
            }
        }
        .overlay {
            if model.sessions.isEmpty {
                ContentUnavailableView(
                    "No sessions yet",
                    systemImage: "tray",
                    description: Text("Start one on your Mac, then refresh."),
                )
            }
        }
        .refreshable { await model.refreshSessions() }
    }

    /// The list's contents: the new-session row, then one section per workspace.
    @ViewBuilder
    private var rows: some View {
        @Bindable var model = model

        Section {
                Button {
                    showingNewSession = true
                } label: {
                    Label("New session", systemImage: "square.and.pencil")
                }
                .accessibilityIdentifier("sessions.new")
            }

            ForEach(workspaces) { workspace in
                Section {
                    if expanded.contains(workspace.path) {
                        let shown = workspace.sessions.prefix(limits[workspace.path] ?? Self.pageSize)
                        ForEach(shown) { session in
                            if pushing {
                                NavigationLink(value: session.sessionId) {
                                    SessionRowView(
                                        session: session,
                                        title: model.titles[session.sessionId],
                                    )
                                }
                            } else {
                                SessionRowView(session: session, title: model.titles[session.sessionId])
                                    .tag(session.sessionId)
                            }
                        }
                        if workspace.sessions.count > shown.count {
                            Button {
                                limits[workspace.path] = shown.count + Self.pageSize
                            } label: {
                                Text("Show \(min(Self.pageSize, workspace.sessions.count - shown.count)) more")
                                    .font(.caption)
                            }
                            .accessibilityIdentifier("workspace.more.\(workspace.path)")
                        }
                    }
                } header: {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            if expanded.contains(workspace.path) {
                                expanded.remove(workspace.path)
                            } else {
                                expanded.insert(workspace.path)
                                // Titles are one request each, so they are
                                // fetched when a workspace is opened and only
                                // for the rows it is about to show.
                                let shown = workspace.sessions
                                    .prefix(limits[workspace.path] ?? Self.pageSize)
                                    .map(\.sessionId)
                                Task { await model.loadTitles(for: Array(shown)) }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: expanded.contains(workspace.path) ? "chevron.down" : "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            // The leftover group is drawn as what it is. It is not
                            // a workspace DSH has -- the heading says so in words,
                            // and this says so without them, so nobody counts it
                            // as one when comparing against their Mac.
                            if workspace.isUnclaimed {
                                Image(systemName: "tray")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Text(workspace.title)
                                .lineLimit(1)
                                .foregroundStyle(workspace.isUnclaimed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                            Spacer()
                            Text("\(workspace.sessions.count)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .textCase(nil)
                    .accessibilityIdentifier("workspace.\(workspace.path)")
                }
            }
    }
}

/// One row.
///
/// The host reports no title for most sessions — a title is only assigned once
/// the model produces one — so the row falls back to the working directory,
/// which is what an operator actually uses to tell two sessions apart.
struct SessionRowView: View {
    let session: SessionRow
    /// DSH's title for the session, when the host has assigned one.
    var title: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if session.running {
                    ProgressView().controlSize(.small)
                }
                Text(displayTitle)
                    .lineLimit(1)
                    .font(.body)
                if session.isSubagent {
                    Text("subagent")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }
            Text(session.updatedDate, format: .relative(presentation: .named))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    /// What to call this session.
    ///
    /// The host's title first, because it describes the conversation. Falling
    /// back to the working directory is what the row used to do always, and a
    /// workspace grouped by directory makes every row in it read the same -- five
    /// sessions all called "DSH-Mizar", with nothing to tell them apart.
    ///
    /// A shortened session id is the last resort: it is not a name, but it is
    /// still a way to distinguish one row from the next, which the directory was
    /// not.
    private var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let cwd = session.cwd {
            let name = (cwd as NSString).lastPathComponent
            return "\(name) · \(session.sessionId.prefix(8))"
        }
        return session.sessionId
    }
}

/// A session: what is waiting, what it has cost, and somewhere to type.
///
/// The order is deliberate. Pending requests sit above usage because an agent
/// blocked on a decision is more urgent than a number, and the composer is
/// pinned to the bottom where the keyboard expects it.
struct SessionDetailView: View {
    let sessionId: String

    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    /// Whether this screen is a whole screen rather than a pane of a split view.
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var stats: SessionStatsFrame?
    /// The session `stats` was read for.
    ///
    /// One view draws every session, so `@State` outlives the conversation it
    /// was filled from. The figures are now deliberately never blanked by a read
    /// that fails -- that is what made them vanish on the way into a session --
    /// so without this tag a failed read would leave the *previous* session's
    /// title, model and context on screen instead, which is worse than blank.
    @State private var statsSessionId: String?
    @State private var loading = true
    @State private var showingModelPicker = false
    @State private var showingContextDetail = false
    @State private var showingCommands = false
    @State private var showingPermissionPicker = false
    @State private var items: [ConversationItem] = []
    /// The session `items` and `turns` belong to, for the same reason as
    /// ``statsSessionId``: one view, many sessions, and a read that returns
    /// nothing must not be able to throw away what is on screen.
    @State private var conversationSessionId: String?
    /// The same conversation grouped into turns, when the host gave turn numbers.
    @State private var turns: [ConversationTurn] = []
    @State private var loadingConversation = true
    /// Whether this appearance has already jumped to the newest message.
    ///
    /// Once per appearance, not once per load: scrolling to the bottom after a
    /// page of *older* messages arrives would undo the scroll that asked for it.
    @State private var didReachBottom = false
    /// What has been typed, held here because the command button writes to it.
    @State private var draft = ""
    /// Whether the field has the keyboard. Owned here so a tap on the
    /// conversation can put it away.
    @FocusState private var composerFocused: Bool
    /// How tall the floating composer is, measured rather than guessed, so the
    /// scroll content reserves exactly the room it covers.
    @State private var composerHeight: CGFloat = 130
    /// Whether a load of this screen is already running.
    @State private var reloading = false
    /// Whether something asked for a load while one was running.
    @State private var reloadWanted = false
    /// Whether a reload the operator asked for by hand is in flight.
    ///
    /// `reloading` cannot answer this: it is true for the load the screen makes
    /// on appearance too, so a toolbar button driven by it would show a spinner
    /// at the moment the screen opens -- reporting a refresh nobody asked for.
    /// This is the narrower claim: someone tapped the control and it has not
    /// answered yet.
    @State private var refreshing = false
    /// Bumped when one full load of this screen has finished.
    ///
    /// The scroll is anchored on this rather than on the appearance of content,
    /// so it lands against what is finally on screen rather than against the
    /// cached copy the host's answer is about to replace.
    @State private var loadGeneration = 0
    /// Bumped when something was just sent, to move the view to it.
    @State private var newMessageArrived = 0
    /// How many pieces of this screen are reading the conversation right now.
    ///
    /// The single-flight lock, and it has to be one lock rather than a flag per
    /// caller: `reload()` and the poll after a send are two loops that both want
    /// the same read, and "is it busy" tested by each of them in turn is a
    /// question two of them can answer "no" to before either starts. Whoever
    /// increments first owns the socket; everyone else waits for zero.
    @State private var conversationLoads = 0

    /// The figures for the session on screen, or nothing.
    ///
    /// The screen is one view for every session: what it has read for one is
    /// still in `@State` when another is opened. Tagging rather than clearing is
    /// what makes both directions right -- a read that fails for the session
    /// already on screen keeps what it has, and a session that has not answered
    /// yet shows nothing rather than somebody else's model name.
    private var shownStats: SessionStatsFrame? {
        statsSessionId == sessionId ? stats : nil
    }

    /// The conversation for the session on screen, or nothing. See ``shownStats``.
    private var shownItems: [ConversationItem] {
        conversationSessionId == sessionId ? items : []
    }

    /// The same, grouped into turns.
    private var shownTurns: [ConversationTurn] {
        conversationSessionId == sessionId ? turns : []
    }

    var body: some View {
        VStack(spacing: 0) {
            // No segmented control here any more. The conversation and the usage
            // figures are the same subject seen two ways, and a control that
            // swaps one for the other hides half of it; the numbers now sit in
            // the row above the composer, where they are visible the whole time
            // and cost no tap.
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        InteractionsView()

                        ConversationView(
                            items: shownItems,
                            turns: shownTurns,
                            loading: loadingConversation,
                            failure: shownItems.isEmpty ? model.conversationError : nil,
                            onLoadOlder: {
                                let arrived = await model.loadOlder(sessionId: sessionId)
                                // Re-read what is on screen; the page was folded
                                // into the cache, and the cache is what the
                                // screen draws from after a successful fetch.
                                if let arrived, arrived > 0,
                                       let cached = await model.cachedConversation(for: sessionId) {
                                        items = cached.items
                                        turns = cached.turns ?? []
                                        conversationSessionId = sessionId
                                    }
                                    return arrived
                                },
                            )
                    }
                    .padding()
                }
                // A conversation is read from the bottom. Opening one that starts
                // at the top means re-reading the whole session to find the
                // answer, and coming back to a session you were part-way through
                // means scrolling past everything you already read.
                .defaultScrollAnchor(.bottom)
                // Dragging the conversation puts the keyboard away, which is what
                // every messaging app does and what a thumb already expects.
                .scrollDismissesKeyboard(.interactively)
                .refreshable { await reload() }
                .onChange(of: loadGeneration) { _, _ in
                    // Anchored when the load has *finished*, not when the first
                    // content appears.
                    //
                    // A cached conversation is put on screen immediately and the
                    // host's copy replaces it a moment later. Anchoring on the
                    // first of those parks the scroll view against one page's
                    // worth of rows and then swaps the rows underneath it, which
                    // leaves the list at an offset that matches neither -- the
                    // "strange position" this was reported as, arriving only
                    // sometimes because it depends on whether the cache was warm
                    // and how much the two pages differ.
                    reachBottom(proxy)
                }
                .onChange(of: newMessageArrived) { _, _ in
                    // Unconditional: this one is a send, not an initial load.
                    Task { @MainActor in
                        await Task.yield()
                        proxy.scrollTo(ConversationView.bottomAnchor, anchor: .bottom)
                    }
                }
                // Tapping the conversation puts the keyboard away. Without this
                // the only way out was the Return key or a drag -- and with a
                // multi-line field Return inserts a newline rather than
                // dismissing, so there was no way out at all but the swipe.
                //
                // On the conversation itself, not on the scroll view. As a
                // `simultaneousGesture` on the container it swallowed the taps
                // meant for the bar above the composer: the buttons ran, and the
                // panels they open never appeared. A tap catcher behind the
                // content has no opinion about anything drawn on top of it.
                .background {
                    Color.clear
                        .contentShape(.rect)
                        .onTapGesture { composerFocused = false }
                }
                // The composer floats over the conversation instead of sitting
                // under it. Messages does the same, and the difference is not
                // decoration: a bar that occupies its own row clips the message
                // behind it at a hard edge, so a bubble halfway up the screen is
                // sliced flat. Floating, the content runs underneath and reads
                // through the glass.
                .overlay(alignment: .bottom) {
                    VStack(spacing: 0) {
                        ComposerBar(
                            sessionId: sessionId,
                            stats: shownStats,
                            draft: $draft,
                            focused: $composerFocused,
                            showingModel: $showingModelPicker,
                            showingContext: $showingContextDetail,
                            showingCommands: $showingCommands,
                        )

                        ComposerView(
                            sessionId: sessionId,
                            text: $draft,
                            onSent: { sent in
                                await refreshAfterSend(sent)
                            },
                            focused: $composerFocused,
                        )
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        composerHeight = height
                    }
                }
                // Room to scroll the last message clear of the floating
                // composer, so nothing is permanently underneath it.
                .contentMargins(.bottom, composerHeight, for: .scrollContent)
            }
        }
        .navigationTitle(shownStats?.title ?? String(localized: "Session"))
        .navigationBarTitleDisplayMode(.inline)
        // The selection bar is put away while a conversation is open.
        //
        // It chooses between the two *screens* -- the conversations and the
        // settings -- and a conversation is not a third one, it is somewhere
        // inside the first. Leaving it up put a second row of controls under a
        // composer that already has two of its own, over the bottom of a
        // transcript that is read from the bottom, and the operator almost never
        // wants the settings from here: they want back, which is what the
        // navigation bar is for.
        //
        // Only in a compact width, though. On an iPad the split view shows the
        // list and the conversation at the same time, so the listing is still on
        // screen next to the conversation and putting the bar away would take it
        // from a screen that is still there.
        .toolbar(sizeClass == .compact ? .hidden : .automatic, for: .tabBar)
        .toolbar {
            // Only the permission selector and a refresh stay up here. The model
            // is in the bar above the composer now, next to the context figure it
            // is read with -- a bar that shows which model is answering and a
            // button somewhere else that changes it is one decision in two
            // places.
            //
            // The title is the session's, truncated by the navigation bar, which
            // is what Messages does with a long contact name.
            ToolbarItem(placement: .topBarTrailing) {
                // A session that has gone quiet is the reason this screen is
                // open at all, and until now the only way to ask it again was to
                // pull the conversation down -- which is invisible, and which the
                // floating composer sits on top of. The same control the session
                // list has, in the same place, doing the same thing.
                //
                // Both size classes, deliberately: this is a trailing toolbar
                // item, so it is drawn in the navigation bar on an iPad as well,
                // where the pull gesture has no room to start.
                Button {
                    Task {
                        refreshing = true
                        await reload()
                        refreshing = false
                    }
                } label: {
                    // Turns while it works. A reload over a phone link can take
                    // a while, and a button that looks idle while nothing happens
                    // reads as a button that did nothing.
                    if refreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(refreshing)
                .accessibilityIdentifier("session.refresh")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingPermissionPicker = true
                } label: {
                    Label(permissionLabel, systemImage: "lock.shield")
                }
                .accessibilityIdentifier("session.permissions")
            }
        }
        .sheet(isPresented: $showingPermissionPicker) {
            PermissionPickerView(sessionId: sessionId)
        }
        .task(id: sessionId) {
            // Once per appearance. Coming back to a session should land at its
            // newest message again; a pull-to-refresh should not, which is why
            // this is reset here and not at the top of `reload()`.
            didReachBottom = false
            await reload()
        }
        .onChange(of: scenePhase) { _, phase in
            // Ask again when the operator comes back.
            //
            // Suspending the process cancels whatever was in flight, and this
            // screen had no way to notice: it would sit there showing whatever
            // the cancellation left behind -- usually nothing -- while the Mac
            // was perfectly reachable. Every phone app is backgrounded
            // constantly, so this is the ordinary path, not an edge one.
            guard phase == .active, !reloading else { return }
            Task { await reload() }
        }
    }

    /// Move the conversation to its newest message, once per appearance.
    ///
    /// One shot rather than on every growth of the list: a page of *older*
    /// messages grows it too, and jumping to the bottom then would undo the very
    /// scroll that asked for them.
    ///
    /// - Parameter proxy: the scroll view to move.
    private func reachBottom(_ proxy: ScrollViewProxy) {
        guard !didReachBottom, !shownItems.isEmpty else { return }
        didReachBottom = true
        Task { @MainActor in
            // One turn of the runloop, so the lazy stack has laid the rows out
            // and there is something to scroll to.
            await Task.yield()
            proxy.scrollTo(ConversationView.bottomAnchor, anchor: .bottom)
        }
    }

    /// Reload the conversation after a send, allowing for the host's lag.
    ///
    /// The host accepts a prompt and records it a moment later, so reading the
    /// log once straight after a send returns a page without the message in it.
    /// Before this, a sent message simply did not appear until the operator
    /// pulled to refresh -- the send worked, the screen did not say so. Found by
    /// a smoke assertion that counts the message in the log rather than trusting
    /// the `accepted` flag.
    ///
    /// Through the same gate as ``reload()``, and that is not tidiness. This was
    /// a second load of the same session on the same socket, started from outside
    /// the gate: send a message while the screen is reloading -- one tap on a
    /// screen that reloads on appearance, on a return to the foreground and on a
    /// pull -- and the pair interleaves exactly as ``reload()`` documents, each
    /// one's failed request reconnecting out from under the other.
    ///
    /// - Parameter sent: the text that was accepted.
    private func refreshAfterSend(_ sent: String) async {
        for _ in 0..<8 {
            // Claimed rather than merely waited for. Waiting and then reading
            // leaves a window in which the reload this waited for can start, and
            // that window is the whole bug.
            guard await takeConversationReadLock() else { return }
            // Synced rather than merely read. `conversation(for:)` returns the
            // flat list, and the screen draws *turns* whenever the host gave
            // turn numbers -- so a message that arrived only in the flat list
            // was a message that did not appear. It went unnoticed because the
            // stored conversation, from a previous visit, happened to contain an
            // equivalent prompt: pull-to-refresh fixed it, and a fresh install
            // did not need fixing.
            // Only a page with something in it replaces what is on screen: a
            // sync that failed returns an empty list, and assigning that over a
            // conversation the operator is reading is the same erasure this
            // screen just stopped doing to its figures.
            let synced = await model.syncConversation(for: sessionId)
            conversationLoads -= 1
            if !synced.isEmpty {
                items = synced
                conversationSessionId = sessionId
            }
            if let cached = await model.cachedConversation(for: sessionId) {
                turns = cached.turns ?? []
            }
            let arrived = shownItems.contains { item in
                if case .message(_, .user, let text, _) = item { return text == sent }
                return false
            }
            if arrived {
                // What was just typed is at the bottom, and a sent message that
                // lands below the fold reads as a send that did not happen. Every
                // messaging app moves to it; this one used to leave the operator
                // looking at whatever they had scrolled to.
                newMessageArrived += 1
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    /// Take the conversation read lock, waiting for whoever holds it.
    ///
    /// Two callers, one lock. `reload()` runs on appearance, on a return to the
    /// foreground and on a pull; this poll runs after every send. Both are loops,
    /// and a loop that checks "is anyone reading" and then starts reading is not
    /// exclusion -- two of them can check before either has started. The claim is
    /// this one method: a single `MainActor` step that decides and increments
    /// together, which is the only place either caller may start from.
    ///
    /// Bounded, because a read that never comes back must not leave a send's
    /// refresh waiting for ever. After the deadline it takes the lock anyway:
    /// its own reads then fail on their own terms, which is a worse answer than
    /// waiting but a better one than a poll that never runs again.
    ///
    /// - Returns: whether the lock was taken. `false` only when the task was
    ///   cancelled while waiting -- the screen is going away and there is nothing
    ///   left to refresh. A caller that gets `false` must not release the lock:
    ///   it never took it, and decrementing here is how a counter-style lock ends
    ///   up negative and stops excluding anybody.
    private func takeConversationReadLock() async -> Bool {
        while conversationLoads > 0 {
            // The yields come first and only once: SwiftUI starts a reload in a
            // Task, and a claim made before that Task has run would see an idle
            // screen and start the second read this exists to prevent.
            await Task.yield()
            await Task.yield()
            guard conversationLoads > 0 else { break }
            let waitedLongEnough = ContinuousClock.now.advanced(by: .seconds(20))
            // One sleep at a time, with the deadline re-measured: the lock is
            // held for the length of a network round trip, and giving up on a
            // slow Mac while it is about to release would be a second reader
            // rather than a patient one.
            while conversationLoads > 0, ContinuousClock.now < waitedLongEnough {
                // Cancellation is the session going away, and there is nothing
                // left to refresh when it has.
                guard (try? await Task.sleep(for: .milliseconds(50))) != nil else { return false }
            }
        }
        conversationLoads += 1
        return true
    }

    /// The permission preset, as a word rather than a raw value.
    private var permissionLabel: String {
        guard let preset = shownStats?.permissionPreset else { return String(localized: "Permissions") }
        switch preset {
        case "read-only": return String(localized: "Read only")
        case "workspace-write": return String(localized: "Workspace write")
        case "danger-full-access": return String(localized: "Full access")
        default: return preset
        }
    }

    /// Refresh everything the screen shows.
    ///
    /// Not re-entrant, and that is load-bearing rather than tidy. Three things
    /// call this -- the screen appearing, the app returning to the foreground,
    /// and a pull-to-refresh -- and they overlap freely. Two overlapping loads
    /// interleave on one socket: the first one's failed request reconnects,
    /// which replaces the connection the second one is using, whose request then
    /// fails too and reconnects again.
    ///
    /// Measured from the host's side, that pair sustained itself: a fresh
    /// WebSocket every few seconds, each one re-downloading the same 244 KB
    /// page, `session.stats` printing twice for every `session.messages`, and no
    /// answer ever settling on screen. Every request the Mac received was
    /// answered correctly, which is why this looked like "cannot connect" while
    /// the connection was in fact fine.
    private func reload() async {
        if reloading {
            // Remembered rather than dropped. The guard has to exist -- two
            // loads interleaving on one socket is what produced a fresh
            // WebSocket every few seconds -- but a request that arrived while
            // one was running used to be discarded, which is a screen that
            // ignores the operator asking it to refresh.
            reloadWanted = true
            return
        }
        reloading = true
        defer { reloading = false }

        var landed = await load()
        // A read that did not land, on a connection that is up, is worth asking
        // about again -- twice more, and the second attempt is the one that
        // matters most.
        //
        // The first request after a launch lands while the socket is still
        // settling; a reconnect holds `connection` at nil for anything from a
        // second to ten, and a read asked for during that window fails without
        // the host ever hearing about it. This screen used to have one retry
        // conditioned on the figures being *blank*, and the figures are no longer
        // blanked by a failure (see `load`), so the condition follows what the
        // reads actually did rather than what is drawn. A failure with the
        // connection down is a different thing and is left alone -- `reconnect`
        // is already working on it.
        for _ in 0..<2 where model.phase == .ready && !landed {
            try? await Task.sleep(for: .milliseconds(700))
            landed = await load()
        }
        while reloadWanted {
            reloadWanted = false
            await load()
        }
    }

    /// One pass over everything this screen draws.
    ///
    /// Writes only what a read actually produced, and that rule is the whole
    /// point of this function. Every value here was assigned unconditionally
    /// once, so a read that failed -- or a socket that answered nothing while it
    /// was reconnecting -- took the title, the model and the context figure off
    /// the screen together, having drawn them from the cache a moment earlier.
    /// Reported exactly that way: "刚点进去一个会话，然后该会话的标题、正在使用的
    /// 模型、上下文用量显示全部消失", repaired by leaving the session and coming
    /// back. A screen that has an answer and loses it is worse than one that
    /// never had it.
    ///
    /// One pass holds ``conversationLoads`` for the whole of its conversation
    /// read, so the poll after a send cannot read the same session alongside it.
    /// Claimed through ``takeConversationReadLock()`` rather than by incrementing
    /// here, and released by the `defer` below so that an early return cannot
    /// leave it held -- a leaked lock is a screen that never loads again.
    ///
    /// - Returns: whether every read landed. The caller asks again when one did
    ///   not -- a failure is not fatal here, it just is not an answer.
    @discardableResult
    private func load() async -> Bool {
        // Claimed, not re-checked: the one place either caller may start from,
        // and it is a single step so that two callers cannot both see an idle
        // screen before either of them starts. `false` is the screen being torn
        // down, and a `defer` below is only installed once the lock is held.
        guard await takeConversationReadLock() else { return false }
        defer { conversationLoads -= 1 }
        loading = true
        loadingConversation = true
        // The phone's own copy first. It is instant, it is there when the
        // network is not, and the fetch below replaces it when it lands.
        if let cached = await model.cachedConversation(for: sessionId), !cached.items.isEmpty {
            items = cached.items
            turns = cached.turns ?? []
            conversationSessionId = sessionId
            loadingConversation = false
        }
        // The last known figures, drawn before the network is asked. Without
        // this the bar was blank until a read came back, and stayed blank
        // whenever one did not -- the model name and the context percentage
        // appeared and disappeared from one visit to the next.
        if let known = await model.cachedStats(for: sessionId) {
            stats = known
            statsSessionId = sessionId
        }
        // One after the other, deliberately. The two reads are independent, and
        // they were run together once -- which is how one dropped request became
        // two overlapping loads over a single socket, each reconnecting out from
        // under the other. They share one connection, so they take it in turn.
        let freshStats = await model.stats(for: sessionId)
        // `statsError` is how a *read* is told apart from a session that has no
        // usage yet: both come back as no frame, and only the first is worth
        // asking about again.
        let statsLanded = model.statsError == nil
        if let freshStats {
            stats = freshStats
            statsSessionId = sessionId
        }
        // Synced rather than merely read: the result is folded into the cache,
        // so what is on screen and what is on disk are the same thing.
        let conversationResult = await model.syncConversation(for: sessionId)
        // Only replace what is on screen when there is something to replace it
        // with. A read that failed returns the cache rather than nothing, but a
        // cache can be empty on a first visit -- and assigning that over a
        // populated screen is what "pull to refresh loses my history" was.
        let fresh = conversationResult
        if !fresh.isEmpty {
            items = fresh
            conversationSessionId = sessionId
        }
        // The cache again, for the turns: the page was just folded into it.
        //
        // Read and written together with the tag, and that is not tidiness. A
        // page and its grouping are one answer: assigning session B's page while
        // `turns` still holds session A's -- which a failed cache read here used
        // to do -- draws A's rows under B, a conversation that never existed.
        // When the cache does not answer, keep the grouping only if it is
        // already this session's, and drop it if it belongs to another.
        if let cached = await model.cachedConversation(for: sessionId) {
            turns = cached.turns ?? []
            conversationSessionId = sessionId
        } else if conversationSessionId != sessionId {
            turns = []
        }
        loading = false
        loadingConversation = false
        await model.refreshInteractions()
        // Last, so the scroll anchor runs against the content that is actually
        // staying on screen.
        loadGeneration += 1
        // The conversation counts as landed only when this session is the one
        // drawn: an empty page for a session nobody has typed into yet is an
        // answer, but an empty page on a screen showing another session's rows
        // means the read did not arrive.
        return statsLanded && conversationSessionId == sessionId
    }
}
