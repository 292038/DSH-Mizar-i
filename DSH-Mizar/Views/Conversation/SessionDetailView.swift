//
//  SessionDetailView.swift
//  DSH-Mizar
//
//  One session: the conversation, what is waiting on the operator, and
//  somewhere to type.
//

import SwiftUI
import MizarKit

/// A session: what is waiting, what it has cost, and somewhere to type.
///
/// The order is deliberate. Pending requests sit above usage because an agent
/// blocked on a decision is more urgent than a number, and the composer is
/// pinned to the bottom where the keyboard expects it.
struct SessionDetailView: View {
    let sessionId: String

    @Environment(AppModel.self) private var model
    @Environment(TurnIndex.self) private var turnIndex
    @Environment(ShellState.self) private var shell
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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

    /// The newest log position that was already part of this conversation when
    /// it opened.
    ///
    /// The typewriter's gate. An answer is typed only when it arrives while the
    /// screen is watching, and "arrived while watching" is exactly "its seq is
    /// past the newest one the first page held". Everything at or below this is
    /// history, and history appears as history -- instantly.
    @State private var answerBaseline: Int?
    /// Answers this screen has already started typing (or chosen not to type).
    ///
    /// A lazy row that scrolls out of the stack is destroyed, and the answer it
    /// held would otherwise be a new arrival again when it comes back. One
    /// entry per answer, for the life of the screen.
    @State private var settledAnswerIds: Set<String> = []
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
    /// Messages sent and not yet read back from the host.
    @State private var outgoing: [OutgoingMessage] = []
    /// The text of the last send, on its way from the field to the conversation.
    @State private var flight: Flight?
    /// Whether the operator has scrolled well away from the newest message.
    @State private var farFromBottom = false
    /// Messages that arrived below while the operator was reading further up.
    @State private var unseen = 0
    /// How many pieces of this screen are reading the conversation right now.
    ///
    /// The single-flight lock, and it has to be one lock rather than a flag per
    /// caller: `reload()` and the poll after a send are two loops that both want
    /// the same read, and "is it busy" tested by each of them in turn is a
    /// question two of them can answer "no" to before either starts. Whoever
    /// increments first owns the socket; everyone else waits for zero.
    @State private var conversationLoads = 0
    /// The turn the conversation has been reduced to, for the length of a long
    /// jump. See ``jump(to:proxy:)``.
    @State private var stagedTurn: String?
    /// How far the page is faded out while a long jump plays, and how far it has
    /// been shifted on its way there.
    ///
    /// These two *are* the animation of a jump. A jump across forty turns is
    /// thousands of points of travel, and animating that makes the phone build
    /// and throw away every row along the way -- work spent on frames nobody
    /// asked to see. So the scroll itself is instantaneous and invisible, and
    /// what the eye is given instead is the page leaving in the direction of the
    /// turn and arriving from the other side.
    @State private var jumpFade: Double = 1
    @State private var jumpShift: CGFloat = 0
    /// Whether a jump is playing, so the conversation stops taking taps.
    @State private var jumping = false
    /// Which jump is current, so a second one tapped while the first is still
    /// playing takes over instead of the two of them taking turns.
    @State private var jumpGeneration = 0

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

    /// The coordinate space the send's flight is measured in.
    static let space = "session.detail"
    /// The very end of the page, below the room left for the composer.
    static let endAnchor = "session.end"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    conversation

                    // What was just sent, drawn where it will land before the
                    // host has recorded it. Hidden from the accessibility tree:
                    // the conversation's own copy, read back from the host, is
                    // the proof the message arrived -- this is only the promise.
                    ForEach(outgoing) { message in
                        PendingBubble(text: message.text, visible: message.landed)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frame in
                                land(message.id, at: frame)
                            }
                            .padding(.top, 14)
                            .transition(.opacity)
                    }

                    // Room for the floating composer and the dock, as content
                    // rather than as a margin: a margin is ignored when the
                    // conversation is shorter than the screen, and the newest
                    // turn sat under the dock on an iPad. The anchor is the true
                    // end of the page -- below the stand-ins for anything sent.
                    Color.clear
                        .frame(height: composerHeight + 16)
                        .id(Self.endAnchor)
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
            }
            // A conversation is read from the bottom, and it stays pinned there
            // as the composer and the dock change height.
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            // Dragging the conversation puts the keyboard away, which is what
            // every messaging app does and what a thumb already expects.
            .scrollDismissesKeyboard(.interactively)
            // A long jump dips the page rather than travelling it. Applied to
            // the scroll view and not to the screen, so the composer and the
            // rail stay where they are while the conversation moves under
            // them: what is travelling is the page, not the furniture.
            .opacity(jumpFade)
            .offset(y: jumpShift)
            .allowsHitTesting(!jumping)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .refreshable { await reload() }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let distance = geometry.contentSize.height - geometry.visibleRect.maxY
                return distance > max(320, geometry.containerSize.height * 0.8)
            } action: { _, far in
                withMizarAnimation(.mizarBouncy) {
                    farFromBottom = far
                    if !far { unseen = 0 }
                }
            }
            .onChange(of: loadGeneration) { _, _ in
                // Anchored when the load has *finished*, not when the first
                // content appears: a cached conversation is replaced a moment
                // later by the host's, and anchoring on the first parks the
                // scroll view against rows that are about to be swapped.
                reachBottom(proxy)
            }
            .onChange(of: newMessageArrived) { _, _ in
                Task { @MainActor in
                    await Task.yield()
                    withMizarAnimation(.mizarSmooth) {
                        proxy.scrollTo(Self.endAnchor, anchor: .bottom)
                    }
                }
            }
            .onChange(of: composerHeight) { _, _ in
                // The dock arriving or the field growing is the bottom moving
                // up; a reader who was at the bottom stays at it.
                guard !farFromBottom, didReachBottom else { return }
                withMizarAnimation(.mizarSmooth) {
                    proxy.scrollTo(Self.endAnchor, anchor: .bottom)
                }
            }
            .onChange(of: turnIndex.jumpCount) { _, _ in
                // A turn chosen in the index: go there, then let it glow once
                // so the eye finds it.
                guard turnIndex.sessionId == sessionId, let target = turnIndex.jumpTarget else { return }
                Task { await jump(to: target, proxy: proxy) }
            }
            .onChange(of: shownItems.count) { old, new in
                // Something new arrived below while the operator was reading
                // further up: count it on the way-back button.
                if farFromBottom, new > old, old > 0 { unseen += new - old }
            }
            // Tapping the conversation puts the keyboard away. On a tap catcher
            // behind the content, not a gesture on the scroll view: as a
            // simultaneous gesture on the container it swallowed taps meant for
            // the controls drawn on top of it.
            .background {
                Color.clear
                    .contentShape(.rect)
                    .onTapGesture { composerFocused = false }
            }
            // The composer floats over the conversation instead of sitting under
            // it. A bar in its own row clips the message behind it at a hard
            // edge; floating, the content runs underneath and reads through the
            // glass.
            .overlay(alignment: .bottom) {
                bottomStack(proxy: proxy)
            }
            // On an iPad with the index column put away, the turns stay at the
            // edge as a rail to scrub.
            .overlay(alignment: .trailing) {
                if sizeClass == .regular, !shell.indexPinnedVisible {
                    TurnRail()
                        .padding(.vertical, 90)
                        .padding(.bottom, composerHeight)
                        .padding(.trailing, 6)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.mizarSmooth, value: shell.indexPinnedVisible)
            .overlay(alignment: .topLeading) {
                if let flight {
                    FlightGhost(flight: flight)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
        .coordinateSpace(.named(Self.space))
        .navigationTitle(shownStats?.title ?? String(localized: "Session"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // A subtitle with the workspace, under the session's own title.
            // The session's title, with its workspace and how many turns it
            // has under it -- and a button: the turn index comes out of it, the
            // way a document's outline comes out of its name.
            ToolbarItem(placement: .principal) {
                Button {
                    shell.toggleTrailing(compact: sizeClass != .regular)
                } label: {
                    VStack(spacing: 0) {
                        Text(shownStats?.title ?? String(localized: "Session"))
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .contentTransition(.opacity)
                        HStack(spacing: 4) {
                            if let workspace {
                                Text(workspace)
                            }
                            if !shownTurns.isEmpty {
                                if workspace != nil { Text(verbatim: "·") }
                                Text("\(shownTurns.count) turns")
                                    .contentTransition(.numericText())
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 7, weight: .heavy))
                                    .rotationEffect(.degrees(indexIsOut ? 180 : 0))
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .contentShape(.rect)
                }
                .buttonStyle(.pressable(scale: 0.96))
                .animation(.mizarSmooth, value: shownStats?.title)
                .animation(.mizarBouncy, value: indexIsOut)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(String(format: String(localized: "Turns, %lld"), shownTurns.count)))
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("session.turnIndex")
            }
            ToolbarItem(placement: .topBarTrailing) {
                // A session that has gone quiet is the reason this screen is
                // open at all; pulling the conversation down is invisible, and
                // the composer sits on top of it.
                Button {
                    Task {
                        refreshing = true
                        await reload()
                        refreshing = false
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .symbolEffect(.rotate, options: .repeat(.continuous), isActive: refreshing)
                }
                .disabled(refreshing)
                .accessibilityIdentifier("session.refresh")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingPermissionPicker = true
                } label: {
                    Label(permissionLabel, systemImage: permissionSymbol)
                        .foregroundStyle(permissionTint)
                        .contentTransition(.symbolEffect(.replace))
                }
                .accessibilityIdentifier("session.permissions")
                .mizarPopover(isPresented: $showingPermissionPicker, arrowEdge: .top) {
                    PermissionPickerView(
                        sessionId: sessionId,
                        current: resolvedPermission,
                        onApplied: { await refreshStatsFromCache() },
                    )
                }
            }
        }
        .task(id: sessionId) {
            // A different session is a different conversation, and the typewriter
            // state belongs to the one that was on screen. The first page of the
            // new one sets a fresh baseline.
            answerBaseline = nil
            settledAnswerIds = []
            // A session just started from the home screen arrives with its first
            // prompt already sent: put it where it will land, and watch for the
            // host to record it, exactly as for a send from this screen.
            if let first = model.pendingFirstPrompt.removeValue(forKey: sessionId) {
                outgoing.append(OutgoingMessage(text: first, landed: true))
                Task { await refreshAfterSend(first) }
            }
            // Once per appearance. Coming back to a session should land at its
            // newest message again; a pull-to-refresh should not.
            didReachBottom = false
            await reload()
        }
        .onDisappear {
            // The turns leave with the screen: this drops only the page's
            // evidence, which stops a poll that was up for a conversation nobody
            // is looking at any more.
            model.noteConversationTurns([], for: sessionId)
            turnIndex.withdraw(sessionId: sessionId)
        }
        .onChange(of: shownStats?.title) { _, title in
            turnIndex.publish(sessionId: sessionId, title: title, turns: shownTurns)
        }
        .onChange(of: model.runningPollTicks) { _, _ in
            // The model's poll found a new session list; the turn rows live here,
            // so the cache is re-read for the running row to become the finished
            // one without a tap.
            Task { await refreshConversationForRunningPoll() }
        }
        .onChange(of: scenePhase) { _, phase in
            // Ask again when the operator comes back: suspending cancels whatever
            // was in flight, and this screen had no way to notice.
            guard phase == .active, !reloading else { return }
            Task { await reload() }
        }
        .onChange(of: showingPermissionPicker) { _, showing in
            // The window closes on a switch the host took and on one it refused
            // alike, and after either the bar should be drawn from the newest
            // frame the app has rather than from the one read before the window
            // opened. A refusal keeps the window up, so this is the operator's
            // own dismissal; it changes nothing when nothing changed.
            guard !showing else { return }
            Task { await refreshStatsFromCache() }
        }
    }

    /// The conversation itself.
    ///
    /// A property rather than an expression inline in `body`: the view takes
    /// enough parameters and closures that naming it keeps the body's type
    /// checker inside its budget.
    private var conversation: some View {
        ConversationView(
            sessionId: sessionId,
            items: shownItems,
            turns: shownTurns,
            stagedTurn: stagedTurn,
            loading: loadingConversation,
            failure: shownItems.isEmpty ? model.conversationError : nil,
            onLoadOlder: {
                let arrived = await model.loadOlder(sessionId: sessionId)
                // Re-read what is on screen; the page was folded into the
                // cache, and the cache is what the screen draws from after a
                // successful fetch.
                if let arrived, arrived > 0,
                   let cached = await model.cachedConversation(for: sessionId) {
                    noteAnswerBaseline(in: cached.items)
                    items = cached.items
                    show(turns: cached.turns ?? [])
                }
                return arrived
            },
            typingAnswerId: typingAnswerId,
            onAnswerTypingStarted: noteAnswerTypingStarted,
        )
    }

    /// The dock, the way back to the newest message, and the composer.
    private func bottomStack(proxy: ScrollViewProxy) -> some View {
        GeometryReader { container in
            VStack(spacing: 8) {
                Spacer(minLength: 0)
                if farFromBottom {
                    JumpToLatest(unseen: unseen) {
                        withMizarAnimation(.mizarSmooth) {
                            proxy.scrollTo(Self.endAnchor, anchor: .bottom)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 16)
                    .transition(.pop)
                }
                VStack(spacing: 8) {
                    InteractionsDock(
                        composerFocused: composerFocused,
                        onExpand: { composerFocused = false },
                        maxHeight: max(160, container.size.height * 0.34),
                    )
                    ComposerView(
                        sessionId: sessionId,
                        stats: shownStats,
                        text: $draft,
                        focused: $composerFocused,
                        showingModel: $showingModelPicker,
                        showingContext: $showingContextDetail,
                        showingCommands: $showingCommands,
                        onWillSend: { text in launch(text) },
                        onSent: { sent in await refreshAfterSend(sent) },
                        onSendFailed: { text in withdraw(text) },
                    )
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    composerHeight = height
                }
            }
        }
    }

    /// The workspace this session belongs to, for the subtitle.
    private var workspace: String? {
        model.workspaceGroups.first { $0.sessions.contains { $0.sessionId == sessionId } }?.title
    }

    // MARK: - Sending

    /// Put a message in flight: an optimistic bubble at the bottom of the
    /// conversation, and a ghost of the text lifting out of the field towards
    /// it.
    private func launch(_ text: String) {
        let message = OutgoingMessage(text: text)
        let fly = !farFromBottom && !Motion.reduced && ComposerGeometry.shared.field != .zero
        withMizarAnimation(.mizarSmooth) {
            outgoing.append(OutgoingMessage(id: message.id, text: text, landed: !fly))
        }
        if fly {
            flight = Flight(id: message.id, text: text, from: ComposerGeometry.shared.field)
        }
        newMessageArrived += 1
    }

    /// The stand-in has a place on screen; send the ghost to it.
    ///
    /// Not on the first frame it is given: the conversation is still settling
    /// against its bottom anchor as the stand-in arrives, so the first frame is
    /// where it was for an instant rather than where it stays. A beat later, the
    /// latest frame is the destination.
    private func land(_ id: UUID, at frame: CGRect) {
        let frames = FlightFrames.shared
        frames.frames[id] = frame
        guard let current = flight, current.id == id, current.to == nil,
              !frames.scheduled.contains(id) else { return }
        frames.scheduled.insert(id)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(70))
            frames.scheduled.remove(id)
            guard var current = flight, current.id == id,
                  let destination = frames.frames[id], destination.width > 0 else { return }
            current.to = destination
            flight = current
            withAnimation(Motion.pick(.mizarSmooth)) {
                current.progress = 1
                flight = current
            } completion: {
                if let index = outgoing.firstIndex(where: { $0.id == id }) {
                    outgoing[index].landed = true
                }
                if flight?.id == id { flight = nil }
                frames.frames[id] = nil
            }
        }
    }

    /// The host refused it: the text is back in the field, so take the promise
    /// back too.
    private func withdraw(_ text: String) {
        withMizarAnimation(.mizarSmooth) {
            outgoing.removeAll { $0.text == text }
            if flight?.text == text { flight = nil }
        }
    }

    /// The host's copy has arrived; the stand-in goes.
    private func settle(_ text: String) {
        outgoing.removeAll { $0.text == text }
        if flight?.text == text { flight = nil }
    }

    /// Put the conversation's turns on screen, and tell the model whether one is
    /// running.
    ///
    /// The model cannot see this screen's `@State`, but the running poll's start
    /// condition needs this evidence as much as the session list does: after a
    /// send, and on a launch with a stored list, the page can be the newer
    /// answer. Every assignment of `turns` goes through here, so no read path
    /// can put a running turn on screen without saying so.
    ///
    /// The turns are settled here before they are drawn, and that is the last
    /// line of a policy the model and the views share: the agent ends a turn
    /// before starting the next, so a turn with a later turn after it cannot be
    /// running. A page the phone skipped can leave the cache holding exactly
    /// that shape, and a cache written before the model learned to repair it is
    /// only ever this screen's to fix -- so the rule is applied at draw time as
    /// well as at write time. It is the same pure function, so the two cannot
    /// disagree.
    ///
    /// - Parameter incoming: the turns the screen is about to draw.
    private func show(turns incoming: [ConversationTurn]) {
        let turns = settlingStaleRuns(in: incoming)
        self.turns = turns
        conversationSessionId = sessionId
        model.noteConversationTurns(turns, for: sessionId)
        turnIndex.publish(sessionId: sessionId, title: shownStats?.title, turns: turns)
    }

    /// Whether the turn index is out, for the title's chevron.
    private var indexIsOut: Bool {
        sizeClass == .regular ? shell.indexPinnedVisible : shell.trailingOpen
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
            proxy.scrollTo(Self.endAnchor, anchor: .bottom)
        }
    }

    /// Go to a turn chosen in the index.
    ///
    /// Two ways there, and which one is right is decided by whether the
    /// conversation still has the turn built. A turn within reach is scrolled to
    /// with the same spring every other move on this screen uses. One that is
    /// not -- because a lazy stack throws away what is more than a screen or two
    /// away -- is *travelled* to, and that is the fix for a real report: a turn
    /// could be listed in the index, be tapped, and simply not be shown, because
    /// the row it named had been destroyed and a scroll to a row that does not
    /// exist goes nowhere.
    ///
    /// - Parameters:
    ///   - target: the turn to show.
    ///   - proxy: the conversation's scroll view.
    private func jump(to target: String, proxy: ScrollViewProxy) async {
        jumpGeneration &+= 1
        let generation = jumpGeneration
        // A jump still playing when this one was asked for leaves the page
        // dipped and half-way through a swap. Put it back first: the two must
        // not take turns holding the fade.
        if jumping {
            jumpFade = 1
            jumpShift = 0
            jumping = false
        }
        // A turn this screen does not hold -- an index from a session that has
        // just been replaced, or a turn whose page has not arrived. There is
        // nothing to show and nothing to say.
        guard turnIndex.turns.contains(where: { $0.id == target }) else { return }
        // A beat for the card to start coming back on a phone, so the jump is
        // seen rather than finished behind it.
        try? await Task.sleep(for: .milliseconds(sizeClass == .regular ? 0 : 140))
        guard isCurrentJump(generation) else { return }

        let anchor = UnitPoint(x: 0.5, y: 0.08)
        guard turnIndex.travels(to: target) else {
            withMizarAnimation(.mizarSmooth) {
                proxy.scrollTo(target, anchor: anchor)
            }
            try? await Task.sleep(for: .milliseconds(320))
            guard isCurrentJump(generation) else { return }
            turnIndex.glow(target)
            return
        }
        await travel(to: target, anchor: anchor, proxy: proxy, generation: generation)
    }

    /// The long way: dip the page, put the turn back in the conversation, jump
    /// with no animation at all, and come back up with the turn under the eye.
    ///
    /// The order is the whole trick. A row that is not in the hierarchy cannot be
    /// scrolled to, so the turn asked for is drawn *alone* first -- at the top of
    /// the content, where a lazy stack always builds it, whatever the offset --
    /// and only then is the scroll asked for. The rest of the conversation comes
    /// back in the same update as the final scroll, while the row is still built
    /// and still on screen, so the anchor holds as everything above it is put
    /// back. The neighbours the operator is most likely to flip to next are the
    /// two turns drawn with it; everything beyond them is the lazy stack's own
    /// business, exactly as it is anywhere else in the conversation.
    ///
    /// - Parameters:
    ///   - target: the turn to show.
    ///   - anchor: where the turn should sit once it is there.
    ///   - proxy: the conversation's scroll view.
    ///   - generation: which jump this is, so a later tap takes over cleanly.
    private func travel(
        to target: String,
        anchor: UnitPoint,
        proxy: ScrollViewProxy,
        generation: Int,
    ) async {
        // Which way the page would have gone, so the dip carries it: a turn
        // above the operator brings the content down, as scrolling up does.
        let direction = turnIndex.direction(to: target)
        jumping = true
        // Fast enough that the page is gone before the swap below, slow enough
        // to read as leaving rather than as blinking.
        withAnimation(Motion.pick(.easeIn(duration: 0.1))) {
            jumpFade = 0.08
            jumpShift = Motion.reduced ? 0 : direction * 30
        }
        try? await Task.sleep(for: .milliseconds(140))
        guard isCurrentJump(generation) else {
            jumping = false
            return
        }

        stagedTurn = target
        await settleLayout()
        guard isCurrentJump(generation) else {
            stagedTurn = nil
            jumping = false
            return
        }
        proxy.scrollTo(target, anchor: .top)

        // The conversation back, and the scroll re-aimed in the same update:
        // the row is built and on screen at this instant, so the anchor holds
        // while the turns above it are put back.
        await settleLayout()
        stagedTurn = nil
        proxy.scrollTo(target, anchor: anchor)
        await settleLayout()
        // A second aim, for the update the first one may have raced. Harmless
        // when the first landed: it is the position the view is already at.
        proxy.scrollTo(target, anchor: anchor)

        // Arriving from the far side, so the dip reads as travel rather than as
        // a screen that blinked.
        jumpShift = Motion.reduced ? 0 : -direction * 18
        withAnimation(Motion.pick(.mizarSmooth)) {
            jumpFade = 1
            jumpShift = 0
        }
        turnIndex.glow(target)
        try? await Task.sleep(for: .milliseconds(220))
        jumping = false
    }

    /// Let the lazy stack build and lay out what it was just given.
    ///
    /// A scheduler yield is not enough: a row exists after the runloop has taken
    /// the update, and a `scrollTo` asked for before that turn has nothing to
    /// place.
    private func settleLayout() async {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(16))
    }

    /// Whether a jump is still the one the operator is waiting for.
    private func isCurrentJump(_ generation: Int) -> Bool {
        jumpGeneration == generation
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
            let cached = await model.cachedConversation(for: sessionId)
            withMizarAnimation(.mizarSmooth) {
                if !synced.isEmpty {
                    noteAnswerBaseline(in: synced)
                    items = synced
                    conversationSessionId = sessionId
                }
                if let cached {
                    show(turns: cached.turns ?? [])
                }
            }
            let arrived = shownItems.contains { item in
                if case .message(_, .user, let text, _) = item { return text == sent }
                return false
            }
            if arrived {
                // What was just typed is at the bottom, and a sent message that
                // lands below the fold reads as a send that did not happen.
                settle(sent)
                newMessageArrived += 1
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        // Not read back in time. The host has it -- it said so -- and the next
        // read will draw it; the stand-in does not get to stay as if it were
        // the record.
        withMizarAnimation(.mizarSmooth) { settle(sent) }
    }

    /// Refresh the conversation rows on a running-poll tick.
    ///
    /// The model's tick has already re-read the session list; this is the screen
    /// taking the second half of it. Only the conversation page is fetched -- the
    /// figures above the composer change with a model answering, not with a turn
    /// ending -- so a tick costs at most one conversation page, never a stats
    /// read as well.
    ///
    /// **Skipped, not queued.** A load already in flight owns the socket, and a
    /// tick that joined a queue behind it would be a second load stacked on the
    /// one the queue was for. The next tick asks again in ten seconds; a dropped
    /// tick is a delay, and a stacked one is the interleaved pair ``reload()``
    /// describes.
    private func refreshConversationForRunningPoll() async {
        guard scenePhase == .active,
              !reloading,
              !model.isSyncing,
              model.selectedSessionId == sessionId,
              claimConversationReadIfIdle()
        else { return }
        defer { conversationLoads -= 1 }
        // Through the cache, like every other read of this conversation: the
        // turns are what the screen draws, and they are written beside the page
        // by `syncConversation`.
        let synced = await model.syncConversation(for: sessionId)
        let cached = await model.cachedConversation(for: sessionId)
        // The same rule `reload()` and the poll after a send follow: only a page
        // that came back may replace one already on screen. Animated, because
        // this is the moment a running turn becomes a finished one and its
        // answer rises into place.
        withMizarAnimation(.mizarSmooth) {
            if !synced.isEmpty {
                noteAnswerBaseline(in: synced)
                items = synced
                conversationSessionId = sessionId
            }
            if let cached {
                show(turns: cached.turns ?? [])
            }
        }
    }

    /// Take the conversation read lock only if it is free.
    ///
    /// The poll's half of the gate. ``takeConversationReadLock()`` waits, which
    /// is right for the poll after a send -- its whole job is to see the sent
    /// message arrive -- and wrong for a tick that comes round again in ten
    /// seconds: waiting here would make the tick a queued second load, and
    /// skipping later is indistinguishable from never having tried.
    ///
    /// - Returns: whether the lock was taken. The caller must release it.
    private func claimConversationReadIfIdle() -> Bool {
        guard conversationLoads == 0 else { return false }
        conversationLoads += 1
        return true
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
            // slow computer while it is about to release would be a second reader
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

    // MARK: - The typewriter's gate

    /// The answer currently being typed, if any.
    ///
    /// Only the newest answer can be typed. When several arrived while the
    /// screen was elsewhere -- the phone was on another screen, or the app was
    /// in the background -- they are history the operator missed, and history
    /// appears at once. The voice they are watching is the one still arriving.
    ///
    /// Reduce Motion is the one switch that turns the reveal off entirely: a
    /// reader who asked for less motion gets the answer, not a slower one.
    private var typingAnswerId: String? {
        guard !reduceMotion, let answerBaseline else { return nil }
        guard let newest = shownItems.last(where: { item in
            if case .message(_, .assistant, _, _) = item { return true }
            return false
        }), let seq = newest.seq, seq > answerBaseline,
            !settledAnswerIds.contains(newest.id)
        else { return nil }
        return newest.id
    }

    /// Record that an answer's reveal has begun.
    ///
    /// Called from the row before its first character. From here on the answer
    /// is drawn by the typewriter's own state, so a parent redraw cannot restart
    /// it, and a row rebuilt after scrolling cannot start it again.
    ///
    /// - Parameter answerId: the item id of the answer being typed.
    private func noteAnswerTypingStarted(_ answerId: String) {
        settledAnswerIds.insert(answerId)
    }

    /// Establish the baseline from the first page that reached this screen.
    ///
    /// Called before the page is assigned to `items`, in the same run-loop turn,
    /// so the rows built from it already know whether they are history: the
    /// baseline has to exist before the rows do, or the newest answer would be
    /// drawn once as history and could never be typed.
    ///
    /// - Parameter list: the items about to be drawn.
    private func noteAnswerBaseline(in list: [ConversationItem]) {
        guard answerBaseline == nil, !list.isEmpty else { return }
        let newest = list.compactMap(\.seq).max()
        guard let newest else { return }
        if Self.previewTypesNewestAnswer,
           let answer = list.last(where: { item in
               if case .message(_, .assistant, _, _) = item { return true }
               return false
           })?.seq {
            // Debug-only preview: type the newest answer when the conversation
            // opens, so the effect can be watched (and captured) without waiting
            // for a live turn to finish.
            answerBaseline = max(0, answer - 1)
        } else {
            answerBaseline = newest
        }
    }

    /// Whether the Debug launch argument asked for the effect on open.
    private static var previewTypesNewestAnswer: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-mizarTypewriterDemo")
        #else
        false
        #endif
    }

    /// The permission preset in force, as the app and the host agree on it.
    ///
    /// The stats frame is what the host last *reported*, and after a switch this
    /// phone has made it is older than the app's own record of what the host
    /// accepted. `AppModel` resolves the two, so the shield in the bar and the
    /// picker behind it cannot disagree -- and a refused switch leaves the old
    /// preset in force on both.
    private var resolvedPermission: String? {
        model.permissionPreset(for: sessionId, reported: shownStats?.permissionPreset)
    }

    /// The permission preset, as a word rather than a raw value.
    ///
    /// Through the catalogue's own rows when the host has listed this preset,
    /// so the bar and the picker behind it cannot disagree -- and through the
    /// app's own names when the catalogue has not been read yet, which is the
    /// case on the first frame of a session. A preset nobody has a name for
    /// reads as its value, which is what the host called it.
    private var permissionLabel: String {
        guard let preset = resolvedPermission else { return String(localized: "Permissions") }
        if let option = model.permissionCatalog?.options.first(where: { $0.value == preset }) {
            return option.title
        }
        return PermissionOption.title(for: preset) ?? preset
    }

    /// The shield, shaped by how much the session may do.
    private var permissionSymbol: String {
        switch resolvedPermission {
        case "read-only": "lock.shield"
        case "danger-full-access": "exclamationmark.shield.fill"
        default: "checkmark.shield"
        }
    }

    /// Neutral for read-only, the accent for workspace writes, amber for full
    /// access: the one place a dangerous setting stays visible.
    private var permissionTint: Color {
        switch resolvedPermission {
        case "workspace-write": .accentColor
        case "danger-full-access": Theme.waiting
        default: .primary
        }
    }

    /// Re-read the figures the toolbar is drawn from, after the permission
    /// picker has been used.
    ///
    /// The switch itself is local by the time the call returns -- the app keeps
    /// the accepted preset and the cache holds the newer frame -- but the frame
    /// on screen is the one read before the popover opened. Reading the cache
    /// again is one local read with no request behind it, so the shield is right
    /// without the screen fetching the whole session over again.
    private func refreshStatsFromCache() async {
        guard let known = await model.cachedStats(for: sessionId) else { return }
        stats = known
        statsSessionId = sessionId
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
    /// answer ever settling on screen. Every request the computer received was
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
            noteAnswerBaseline(in: cached.items)
            items = cached.items
            show(turns: cached.turns ?? [])
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
            noteAnswerBaseline(in: fresh)
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
            show(turns: cached.turns ?? [])
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
