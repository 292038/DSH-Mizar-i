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
    /// Internal hosted-test observation seam, nil in production. Delivers the
    /// same state binding the composer's real expand/collapse control changes.
    var onComposerBindingAvailable: ((Binding<Bool>) -> Void)? = nil
    /// Internal read-only hosted-test observation, nil in production; this
    /// callback cannot bypass the placement reveal gate.
    var onPlacementChanged: ((InitialPlacement) -> Void)? = nil
    /// Internal read-only hosted-test geometry, in the conversation coordinate space.
    var onConversationContentBottomChanged: ((CGFloat) -> Void)? = nil
    var onComposerFrameChanged: ((CGRect) -> Void)? = nil

    @Environment(AppModel.self) private var model
    @Environment(TurnIndex.self) private var turnIndex
    @Environment(ShellState.self) private var shell
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Read in the body (the refresh spinner), so the drawer-motion holds
    /// below track it.
    @Environment(\.drawersStill) private var drawersStill
    @State private var stats: SessionStatsFrame?
    /// The session `stats` was read for.
    ///
    /// The shell keys this page per session (`.id(sessionId)`), so the state
    /// belongs to the session it was filled from; this tag is the defence
    /// behind that. The figures are now deliberately never blanked by a read
    /// that fails -- that is what made them vanish on the way into a session --
    /// so without the tag a failed read would leave the *previous* session's
    /// title, model and context on screen instead, which is worse than blank.
    @State private var statsSessionId: String?
    @State private var loading = true
    @State private var showingModelPicker = false
    @State private var showingContextDetail = false
    @State private var showingCommands = false
    @State private var showingPermissionPicker = false
    @State private var items: [ConversationItem] = []
    /// The session `items` and `turns` belong to, for the same reason as
    /// ``statsSessionId``: the shell keys this page per session, and the tag
    /// is the defence behind it -- a read that returns nothing must not be
    /// able to throw away what is on screen, and a page from one session must
    /// never be drawn under another's grouping.
    @State private var conversationSessionId: String?
    /// The same conversation grouped into turns, when the host gave turn numbers.
    @State private var turns: [ConversationTurn] = []

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
    /// Set by the initial placement (see ``InitialPlacement``) once the first
    /// frame is in position, and read by the composer's corrections as "the
    /// operator has been put at the newest message at least once".
    @State private var didReachBottom = false
    /// What has been typed, held here because the command button writes to it.
    @State private var draft = ""
    /// Whether the field has the keyboard. Owned here so a tap on the
    /// conversation can put it away.
    @State private var composerFocused = false
    /// How tall the floating composer is, measured rather than guessed, so the
    /// scroll content reserves exactly the room it covers.
    @State private var composerHeight: CGFloat = 130
    /// The last resting reservation, not the screen-height expanded composer.
    /// Until measured, reuse the existing initial composer height.
    @State private var composerReservedHeight: CGFloat?
    @State private var collapsedComposerHeight: CGFloat?
    /// Dock and stack overhead, measured against the shell in one layout pass.
    @State private var collapsedComposerExtra: CGFloat?
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
    /// Where the conversation is on its way to its first position.
    ///
    /// The page used to reveal the conversation at whatever offset a new
    /// `ScrollView` starts at -- the top -- and move it to the newest message
    /// once the load had finished, which is why a session with a cached
    /// history opened showing its oldest turns and jumped a moment later. The
    /// placement is now a precondition of display: the message area stays
    /// gated until the geometry says the newest turn is in view. See
    /// ``InitialPlacement``.
    @State private var placement: InitialPlacement = .waitingForContent
    /// Which round of placement is running, as part of the placement task's
    /// identity. Bumped when a conversation is committed to a page that has
    /// not been placed yet -- including one whose first read failed, so a
    /// late answer still gets its first frame at the bottom.
    @State private var placementRound = 0
    /// The signed distance from the newest message: positive when it is still
    /// below the viewport, negative when the page sits past the end of the
    /// content. The placement's acceptance test, because a page parked *under*
    /// the content is the one failure a clamped distance reads as "at the
    /// bottom" -- and it is the shape the black conversation used to open in.
    @State private var placementGeometry: ConversationPlacementGeometry?
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
    /// Whether the composer is opened out into its tall, focused-input form.
    /// Owned here because the overlay's layout -- the dock, the jump button,
    /// the room the conversation reserves -- all answer to it.
    @State private var composerExpanded = false
    /// How far the newest message is below what is on screen, and how tall the
    /// viewport is. Tracked continuously so the way-back button can tell a
    /// nudge from a journey -- a long way back takes the same travelling
    /// transition a long turn jump takes, not an animated scroll across rows
    /// nobody asked to see.
    @State private var distanceFromBottom: CGFloat = 0
    @State private var scrollViewportHeight: CGFloat = 0
    /// Whether the composer's expand or collapse animation is still playing.
    /// While it is, the bottom anchor and the composer-height correction are
    /// suspended -- see `defaultScrollAnchor` below.
    @State private var composerAnimating = false
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
    /// The shell keys this page per session (`.id(sessionId)`), so the state
    /// belongs to the session it was filled from; the tag is the belt to that
    /// braces. A read that returns nothing must not be able to draw another
    /// session's model name, and a session that has not answered yet shows
    /// nothing rather than somebody else's.
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

    /// How far from the newest message the placement accepts as "at the
    /// bottom", in points. A hair rather than zero: the composer's reserved
    /// room and rounding at non-integral display scales leave a fraction of a
    /// point between the anchor and the end of the content.
    static let placementTolerance: CGFloat = 4
    /// How many re-aims the placement may spend before offering a retry.
    /// This bounds active correction, not acceptance: a later geometry update
    /// can still reveal the conversation after these attempts are exhausted.
    static let placementAttempts = 32
    /// The spacing between those re-aims, in milliseconds.
    static let placementAttemptSpacing = 32

    /// Whether the message area may be shown and touched: the initial
    /// placement has settled, or there was nothing to settle.
    ///
    /// The gate is the message area alone -- the title, the composer, the
    /// sidebar and the refresh entry answer as usual while a page is being
    /// placed. Freezing the whole app to hide a first-frame flicker would be
    /// a worse trade than the flicker.
    private var placementRevealed: Bool {
        placement.isRevealed
    }

    var body: some View {
        ScrollViewReader { proxy in
            // The gated scroll view and the furniture are two views on
            // purpose. The gate quiets the message area with
            // `allowsHitTesting`, and a modifier applied *before* an overlay
            // covers the overlay with it -- the composer would stop answering
            // while a page is being placed, which is the one thing the gate
            // must not do.
            conversationScroll(proxy: proxy)
                .task(id: PlacementKey(sessionId: sessionId, round: placementRound)) {
                    await placeInitially(proxy: proxy)
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
        .onAppear { onComposerBindingAvailable?($composerExpanded) }
        .onChange(of: placement, initial: true) { _, value in onPlacementChanged?(value) }
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
                        .symbolEffect(.rotate, options: .repeat(.continuous), isActive: refreshing && drawersStill)
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
            // state belongs to the one that was on screen.
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

    /// The conversation's scroll view, gated until its first position is known.
    ///
    /// The gate is opacity, hit-testing and the accessibility tree together,
    /// and nothing is removed: the layout stays in the tree because there has
    /// to be something laid out before there is a position to place, and a
    /// lightweight placeholder stands in for what is being placed. The reveal
    /// is a change of one flag, so the first frame an operator can read is the
    /// one the geometry has already accepted.
    private func conversationScroll(proxy: ScrollViewProxy) -> some View {
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
                //
                // An expanded composer is the size of the screen; reserving
                // that as content would park the conversation a page above
                // its own end, so the reservation stays at the resting
                // height while the composer is open. It also stays there
                // while the composer is *becoming* open or closed: at the
                // start of a collapse the measured height is still a
                // screenful, and reserving it would grow the page by a
                // screen and then shrink it back over the animation --
                // the bounce that made a collapse feel broken.
                Color.clear
                    .frame(height: (composerReservedHeight ?? composerHeight) + 16)
                    .id(Self.endAnchor)
                    .onGeometryChange(for: CGFloat.self) { geometry in
                        geometry.frame(in: .named(Self.space)).minY
                    } action: { bottom in
                        onConversationContentBottomChanged?(bottom)
                    }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
        }
        // A conversation is read from the bottom, and it stays pinned there
        // as the composer and the dock change height.
        //
        // Two roles, answering to two different moments. `.initialOffset` is
        // the first frame's intent: a cached page is often laid out before
        // anything has *changed* size -- which is exactly why the page used
        // to open at the top and jump a moment later, since the `.sizeChanges`
        // role never fired for it. `.sizeChanges` then keeps the page at the
        // bottom as the composer, the dock and the rows settle their heights.
        //
        // Neither role is trusted alone, and that is the lesson of the black
        // conversation this screen once opened with: an anchor applied against
        // content that had not arrived left the scroll view parked in the
        // empty space under the page. The initial placement is what makes the
        // anchor safe to use -- the message area is gated until the geometry
        // says the newest turn is in view, so a first layout that lands wrong
        // is corrected rather than shown, and the overshoot correction below
        // stays live as the backstop.
        //
        // Suspended while a jump plays. A long jump swaps the whole list
        // for one staged turn and back, and each swap is a size change:
        // with the anchor live, every swap yanks the page to the bottom,
        // the jump's own `scrollTo` pulls it back to the turn, and the two
        // take turns for as long as the rows are settling -- the shudder
        // seen at the end of a jump to the newest turn.
        //
        // Also suspended while the composer grows or shrinks. Collapsing
        // the expanded composer hands back a screenful of height: every
        // intermediate size change fired the bottom anchor as an instant
        // jump while the composer's own animation was still easing, and
        // the instant jumps and the easing fought the whole way down --
        // the shudder that followed every collapse.
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(jumping || composerAnimating ? nil : .bottom, for: .sizeChanges)
        // Dragging the conversation puts the keyboard away, which is what
        // every messaging app does and what a thumb already expects.
        .scrollDismissesKeyboard(.interactively)
        // A long jump dips the page rather than travelling it. Applied to
        // the scroll view and not to the screen, so the composer and the
        // rail stay where they are while the conversation moves under
        // them: what is travelling is the page, not the furniture.
        .opacity(placementRevealed ? jumpFade : 0)
        .offset(y: jumpShift)
        .allowsHitTesting(placementRevealed && !jumping)
        .accessibilityHidden(!placementRevealed)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .refreshable { await reload() }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            let distance = geometry.contentSize.height - (geometry.visibleRect.maxY - geometry.contentInsets.bottom)
            return distance > max(320, geometry.containerSize.height * 0.8)
        } action: { _, far in
            withMizarAnimation(.mizarBouncy) {
                farFromBottom = far
                if !far { unseen = 0 }
            }
        }
        // …and the mirror case: past the end of the content rather than
        // short of it. That is where the first layout sometimes parks the
        // page, and what a few swipes by hand fixed.
        //
        // Initial placement owns the hidden page and has a bounded correction
        // budget. Once revealed, correct only on entering an overshoot, not on
        // every changing offset: a failed correction must not scroll forever.
        // Insets belong to the raw visible rect, not to conversation content.
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.visibleRect.minY + geometry.contentInsets.top - geometry.contentSize.height > 2
        } action: { _, overshoot in
            // A jump owns the position until it lands: its staged turn is
            // deliberately a short page, which reads as past the end, and
            // correcting then is a second scroll fighting the first.
            guard overshoot, placement == .ready, !jumping, !composerAnimating, !shownItems.isEmpty else { return }
            reachBottomNow(proxy)
        }
        // How far the operator is from the newest message, kept current so
        // the way-back button can choose between a scroll and a journey.
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentSize.height - (geometry.visibleRect.maxY - geometry.contentInsets.bottom)
        } action: { _, distance in
            distanceFromBottom = max(0, distance)
        }
        // The placement's acceptance test: the same distance, kept signed.
        // Positive when the newest message is still below the viewport,
        // negative when the page sits past the end of the content -- the one
        // shape the clamped distance above reports as "at the bottom", and
        // the shape the black conversation used to open in.
        .onScrollGeometryChange(for: ConversationPlacementGeometry.self) { geometry in
            ConversationPlacementGeometry(
                contentHeight: geometry.contentSize.height,
                viewportHeight: geometry.containerSize.height,
                visibleMinY: geometry.visibleRect.minY,
                visibleMaxY: geometry.visibleRect.maxY,
                topInset: geometry.contentInsets.top,
                bottomInset: geometry.contentInsets.bottom
            )
        } action: { _, geometry in
            placementGeometry = geometry
            // A late success is still valid after the bounded re-aim budget.
            // Accept it without starting another scroll or network read.
            finishInitialPlacement()
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.containerSize.height
        } action: { _, height in
            scrollViewportHeight = height
        }
        .onChange(of: newMessageArrived) { _, _ in
            // A jump owns the position until it lands; a send mid-jump is
            // picked up by the jump's own final aim instead.
            guard !jumping else { return }
            Task { @MainActor in
                await Task.yield()
                guard !Task.isCancelled, placementRevealed else { return }
                withMizarAnimation(.mizarSmooth) {
                    proxy.scrollTo(Self.endAnchor, anchor: .bottom)
                }
            }
        }
        .onChange(of: composerHeight) { _, _ in
            // The dock arriving or the field growing is the bottom moving
            // up; a reader who was at the bottom stays at it.
            guard !jumping, !composerAnimating, !farFromBottom, didReachBottom else { return }
            withMizarAnimation(.mizarSmooth) {
                proxy.scrollTo(Self.endAnchor, anchor: .bottom)
            }
        }
        .onChange(of: composerExpanded) { _, expanded in
            // While the composer trades places with its expanded self the
            // bottom corrections stand down (see `defaultScrollAnchor`);
            // when the move has played out, a reader who was at the bottom
            // is put back at it once, exactly.
            composerAnimating = true
            Task { @MainActor in
                do {
                    try await Task.sleep(for: .milliseconds(600))
                } catch { return }
                guard !Task.isCancelled else { return }
                composerAnimating = false
                guard !expanded, !jumping, !farFromBottom, didReachBottom else { return }
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
            // further up: count it on the way-back button. Not while the
            // initial placement is running -- before it has settled, "below
            // the viewport" is where the page is by construction, not a
            // message that arrived while somebody was reading.
            if farFromBottom, placementRevealed, new > old, old > 0 { unseen += new - old }
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
        .overlay {
            if !placementRevealed {
                placementPlaceholder
            }
        }
    }

    /// What the message area shows while the initial placement runs.
    ///
    /// The conversation stays laid out underneath. Positioning failure offers
    /// a local retry, separately from the network failure state in the log.
    @ViewBuilder
    private var placementPlaceholder: some View {
        if placement == .positioningFailed {
            ContentUnavailableView {
                Label("Could not position the conversation", systemImage: "arrow.up.and.down")
            } description: {
                Text("Your messages are loaded. Try showing the latest message again.")
            } actions: {
                Button("Retry") {
                    placementRound += 1
                    placement = .placing(generation: placementRound)
                }
                .accessibilityIdentifier("session.placement.retry")
            }
            .accessibilityIdentifier("session.placement.failed")
        } else {
            ProgressView()
                .controlSize(.regular)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(true)
        }
    }

    /// The conversation itself.
    ///
    /// A property rather than an expression inline in `body`: the view takes
    /// enough parameters and closures that naming it keeps the body's type
    /// checker inside its budget.
    private var conversation: some View {
        // The older-page row asks by itself while it is on screen. Before the
        // initial placement has settled there is no such thing as "on screen"
        // -- the page sits at the top by construction until it is placed --
        // so the question is not asked until the placement says where the
        // conversation starts. `nil` is the existing way to say "could not be
        // asked right now", and the row is not drawn at all.
        let canReadHistory = placement == .ready || placement == .navigating
        let onLoadOlder: (() async -> Int?)? = canReadHistory ? {
            guard !Task.isCancelled, placement == .ready || placement == .navigating else { return nil }
            let arrived = await model.loadOlder(sessionId: sessionId)
            guard !Task.isCancelled else { return nil }
            // Re-read what is on screen; the page was folded into the
            // cache, and the cache is what the screen draws from after a
            // successful fetch.
            if let arrived, arrived > 0,
               let cached = await model.cachedConversation(for: sessionId) {
                guard !Task.isCancelled else { return nil }
                items = cached.items
                show(turns: cached.turns ?? [])
            }
            return arrived
        } : nil
        return ConversationView(
            sessionId: sessionId,
            items: shownItems,
            turns: shownTurns,
            stagedTurn: stagedTurn,
            loading: loadingConversation,
            failure: shownItems.isEmpty ? model.conversationError : nil,
            onLoadOlder: onLoadOlder,
            typingAnswerId: typingAnswerId,
            onAnswerTypingStarted: noteAnswerTypingStarted,
        )
    }

    /// The dock, the way back to the newest message, and the composer.
    private func bottomStack(proxy: ScrollViewProxy) -> some View {
        GeometryReader { container in
            VStack(spacing: 8) {
                Spacer(minLength: 0)
                // The way back is hidden while a jump plays -- the conversation
                // is already on its way somewhere -- and while the composer is
                // expanded or moving between its two sizes, when there is no
                // conversation in view to return to. Also hidden while the
                // initial placement runs: the page is at the top by
                // construction until it is placed, and "far from bottom" then
                // describes the placement, not the operator.
                if placementRevealed, farFromBottom, !jumping, !composerExpanded, !composerAnimating {
                    JumpToLatest(unseen: unseen) {
                        returnToLatest(proxy: proxy)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 16)
                    .transition(.pop)
                }
                VStack(spacing: 8) {
                    // The dock leaves while the composer is expanded: the open
                    // field is the whole height of the screen, and a queue of
                    // pending requests above it is the opposite of the focus
                    // the expansion is for.
                    if !composerExpanded {
                        InteractionsDock(
                            composerFocused: composerFocused,
                            onExpand: { composerFocused = false },
                            maxHeight: max(160, container.size.height * 0.34),
                        )
                    }
                    ComposerView(
                        sessionId: sessionId,
                        stats: shownStats,
                        text: $draft,
                        focused: $composerFocused,
                        expanded: $composerExpanded,
                        showingModel: $showingModelPicker,
                        showingContext: $showingContextDetail,
                        showingCommands: $showingCommands,
                        onWillSend: { text in launch(text) },
                        onSent: { sent in await refreshAfterSend(sent) },
                        onSendFailed: { text in withdraw(text) },
                        onCollapsedHeightChanged: { height in
                            collapsedComposerHeight = height
                            if let extra = collapsedComposerExtra {
                                composerReservedHeight = height + extra
                            }
                        },
                    )
                    // Expanded, the composer fills the overlay up to just under
                    // the title; at rest it wraps its content.
                    .frame(maxHeight: composerExpanded ? .infinity : nil)
                }
                .overlayPreferenceValue(ComposerShellBoundsKey.self) { shellBounds in
                    GeometryReader { stack in
                        Color.clear
                            .onGeometryChange(for: CGFloat?.self) { _ in
                                guard !composerExpanded, !composerAnimating,
                                      let shell = shellBounds.shell,
                                      let chrome = shellBounds.chrome,
                                      let fieldHeight = shellBounds.fieldHeight,
                                      let insets = shellBounds.insets else { return nil }
                                let shellHeight = stack[shell].height
                                let target = fieldHeight + stack[chrome].height + insets
                                guard target.isFinite, target > 0, shellHeight.isFinite,
                                      abs(shellHeight - target) <= 0.5 else { return nil }
                                let extra = stack.size.height - shellHeight
                                return extra.isFinite && extra >= 0 ? extra : nil
                            } action: { extra in
                                guard !composerExpanded, !composerAnimating, let extra else { return }
                                collapsedComposerExtra = extra
                                if let height = collapsedComposerHeight {
                                    composerReservedHeight = height + extra
                                }
                            }
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    if !composerExpanded && !composerAnimating && collapsedComposerHeight == nil {
                        composerReservedHeight = height
                    }
                    composerHeight = height
                }
                .onGeometryChange(for: CGRect.self) { geometry in
                    geometry.frame(in: .named(Self.space))
                } action: { frame in
                    onComposerFrameChanged?(frame)
                }
            }
        }
    }

    /// Back to the newest message.
    ///
    /// Two ways, the same choice a turn jump makes. Close enough to see, an
    /// animated scroll says where the bottom is. A long way back -- the
    /// threshold mirrors the turn index's `animatedReach`: past a couple of
    /// screens the rows along the way do not exist, and animating across them
    /// is work spent on frames nobody asked to see -- is *travelled*, the same
    /// dip and arrive a long turn jump uses.
    ///
    /// - Parameter proxy: the conversation's scroll view.
    private func returnToLatest(proxy: ScrollViewProxy) {
        guard distanceFromBottom > max(600, scrollViewportHeight * 2) else {
            withMizarAnimation(.mizarSmooth) {
                proxy.scrollTo(Self.endAnchor, anchor: .bottom)
            }
            return
        }
        Task { await travelToBottom(proxy: proxy) }
    }

    /// The long way back to the newest message: the page dips, the scroll
    /// jumps with no animation at all, and the page arrives from above.
    ///
    /// The bottom anchor is always in the hierarchy, so unlike ``travel(to:anchor:proxy:generation:)``
    /// there is no staged turn to build -- only the dip, the jump, and the
    /// return. `jumping` still runs: it suspends the bottom anchor and the
    //  corrections that would fight the jump for the whole of the move.
    private func travelToBottom(proxy: ScrollViewProxy) async {
        jumpGeneration &+= 1
        let generation = jumpGeneration
        if jumping {
            jumpFade = 1
            jumpShift = 0
            jumping = false
        }
        jumping = true
        // The newest message is below: the content leaves upwards, as it would
        // have moved had the operator swiped all the way there.
        withAnimation(Motion.pick(.easeIn(duration: 0.1))) {
            jumpFade = 0.08
            jumpShift = Motion.reduced ? 0 : -30
        }
        try? await Task.sleep(for: .milliseconds(140))
        guard isCurrentJump(generation) else {
            jumping = false
            return
        }
        proxy.scrollTo(Self.endAnchor, anchor: .bottom)
        await settleLayout()
        guard isCurrentJump(generation) else {
            jumping = false
            return
        }
        // A second aim, for the rows that settled their heights in between.
        proxy.scrollTo(Self.endAnchor, anchor: .bottom)

        jumpShift = Motion.reduced ? 0 : 18
        withAnimation(Motion.pick(.mizarSmooth)) {
            jumpFade = 1
            jumpShift = 0
        }
        try? await Task.sleep(for: .milliseconds(220))
        jumping = false
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

    // MARK: - The initial placement

    /// Start the initial placement, if this page has not been placed yet.
    ///
    /// Called the moment a conversation is committed to the page -- the cached
    /// copy first, the host's answer when it lands. The first of the two is
    /// what the operator's first frame is drawn from, and the placement is
    /// what makes that frame the bottom of the conversation rather than the
    /// top of it.
    ///
    /// A page whose first read failed is re-armed rather than left settled: a
    /// late answer deserves the same first frame the first one would have had.
    private func beginInitialPlacementIfNeeded() {
        let nextRound = placementRound + 1
        if placement.beginIfNeeded(generation: nextRound) {
            placementRound = nextRound
        }
    }

    /// Settle a page nothing was ever committed to.
    ///
    /// An empty session and a first read that failed are both answers: the
    /// content *is* the empty state or the failure card, and gating it would
    /// hold a spinner over a screen that has already replied. Called from
    /// `load()` when the read answered with nothing, and from `reload()` once
    /// it has run out of attempts; a retry that lands content re-arms the
    /// placement instead of settling.
    private func settleUnplacedWithoutContent() {
        guard placement == .waitingForContent else { return }
        placement = model.conversationError == nil ? .empty : .failed
    }

    /// Put the conversation at its newest message before it is shown, and
    /// reveal it once the geometry says it is there.
    ///
    /// The task's identity carries the round, so a conversation committed
    /// while an earlier placement was still running takes over cleanly, and a
    /// page going away cancels the correction rather than leaving it to
    /// scroll a view that is gone. Re-aims have a finite budget, but acceptance
    /// stays live in the geometry callback after that budget expires. Slower
    /// layout must not permanently hide a successfully positioned conversation.
    ///
    /// - Parameter proxy: the conversation's scroll view.
    private func placeInitially(proxy: ScrollViewProxy) async {
        // Only a committed conversation has a bottom to place against. The
        // empty and failed terminals reveal at commit; there is nothing here
        // for them to do.
        guard !Task.isCancelled, case .placing(let generation) = placement, !shownItems.isEmpty else { return }
        // One turn of the runloop is not enough: a row exists after the
        // runloop has taken the update, and a scroll asked for before that has
        // nothing to place against.
        await settleLayout()
        guard !Task.isCancelled, placement == .placing(generation: generation) else { return }

        // The anchors have the first frame's intent; this aim is the fine-tune
        // for rows that settle their heights after it, and it must not inherit
        // an animation from whatever transaction is running -- the sidebar
        // closing is the one that used to carry the initial position.
        var transaction = Transaction()
        transaction.animation = nil
        transaction.disablesAnimations = true
        for _ in 0..<Self.placementAttempts {
            withTransaction(transaction) {
                proxy.scrollTo(Self.endAnchor, anchor: .bottom)
            }
            // A sleep that came back nil is a cancellation: the session
            // changed, or the page is going away. Stop, rather than scrolling
            // a view nobody is waiting on.
            guard (try? await Task.sleep(for: .milliseconds(Self.placementAttemptSpacing))) != nil else { return }
            guard !Task.isCancelled, placement == .placing(generation: generation) else { return }
            // Every aim, including the last, gets a layout interval before
            // being judged. Hidden content cannot be dragged away by a reader.
            guard placementGeometry?.isAtBottom(tolerance: Self.placementTolerance) == true else { continue }
            finishInitialPlacement()
            return
        }
        // Do not reveal an unverified position. Keep a stable, actionable
        // placeholder; retrying positioning does not launch another network read.
        guard !Task.isCancelled, placement == .placing(generation: generation) else { return }
        placement = .positioningFailed
    }

    /// Reveal the placed conversation, once.
    private func finishInitialPlacement() {
        guard !Task.isCancelled, !shownItems.isEmpty,
              placement.finishIfPositioned(placementGeometry, tolerance: Self.placementTolerance) else { return }
        // The one-shot claim the composer's corrections read: the placement
        // *is* the appearance's jump to the newest message.
        didReachBottom = true
    }

    /// Scroll to the end now, without the one-shot guard.
    ///
    /// Used by the correction that finds the page parked past the end of the
    /// content: there the question is not "has this happened before" but "get
    /// back onto the conversation".
    private func reachBottomNow(_ proxy: ScrollViewProxy) {
        Task { @MainActor in
            // One turn of the runloop, so the lazy stack has laid the rows out
            // and there is something to scroll to.
            await Task.yield()
            guard !Task.isCancelled, placement == .ready, !jumping, !composerAnimating else { return }
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
        // Explicit navigation owns the scroll position from this point. Cancel
        // the initial bottom placement before its next awaited correction.
        placementRound += 1
        placement = .navigating
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
                if !synced.items.isEmpty {
                    items = synced.items
                    conversationSessionId = sessionId
                }
                if let cached {
                    show(turns: cached.turns ?? [])
                }
            }
            // The page carries the context figure on every refresh, so the
            // bar's occupancy ring and its popover move with the turn instead
            // of waiting for the next full load. Put it up whether or not the
            // sent text has landed yet: the figure is this reply's, and the
            // send poll is the first refresh that runs after a prompt.
            if let frame = synced.stats {
                stats = frame
                statsSessionId = sessionId
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
    /// taking the second half of it. Only the conversation page is fetched, and
    /// that page also carries the current context figure -- so a tick costs one
    /// conversation page, never an extra stats read, and the occupancy ring and
    /// its breakdown still move with the running turn.
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
              // A drawer mid-flight owns the frames; this tick is skipped
              // like any busy one, and the next asks again.
              !shell.isDragging,
              !shell.isSettling,
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
            if !synced.items.isEmpty {
                items = synced.items
                conversationSessionId = sessionId
            }
            if let cached {
                show(turns: cached.turns ?? [])
            }
        }
        // The context figure above the composer, from the same page. This is the
        // tick that keeps it live while a turn runs: the token-meter projection
        // moves with every model request, and the page carries the current
        // occupancy rather than a figure frozen at the last full load.
        if let frame = synced.stats {
            stats = frame
            statsSessionId = sessionId
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

    /// How long after a turn finished its answer may still be typed.
    ///
    /// The reveal stands in for a voice that has just finished talking, so it
    /// plays only while the answer is fresh: a session viewed within a minute
    /// of the turn completing plays it; a session opened later is a record
    /// being read, and records appear as records -- instantly. Typing an answer
    /// that finished hours ago presents a turn long over as one that finished
    /// while you watched, and that is the lie this window closes.
    private static let typewriterFreshness: TimeInterval = 60

    /// The answer currently being typed, if any.
    ///
    /// Only the newest answer can be typed, and only while it is fresh: its own
    /// timestamp -- the host's record of when the turn ended -- has to be within
    /// ``typewriterFreshness`` of now. Freshness is read off the answer, not off
    /// what this phone has fetched: a page pulled in just now can be carrying
    /// an answer that finished last night, and that answer is history.
    ///
    /// The decision freezes the moment the row draws: the answer is recorded as
    /// started (``noteAnswerTypingStarted``), so a later redraw or the minute
    /// running out cannot turn a voice back into history, and a row that first
    /// appears after the minute is simply the message, whole.
    ///
    /// Reduce Motion is the one switch that turns the reveal off entirely: a
    /// reader who asked for less motion gets the answer, not a slower one.
    private var typingAnswerId: String? {
        guard !reduceMotion else { return nil }
        guard let newest = shownItems.last(where: { item in
            if case .message(_, .assistant, _, _) = item { return true }
            return false
        }), !settledAnswerIds.contains(newest.id),
            Self.previewTypesNewestAnswer
                || Date().timeIntervalSince(newest.at) <= Self.typewriterFreshness
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

    /// Whether the Debug launch argument asked for the effect on open.
    ///
    /// The demo replays the newest answer whatever its age -- the point is to
    /// watch (and capture) the reveal without waiting for a live turn to
    /// finish -- so the gate skips the freshness check for it.
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
        // Out of attempts with nothing ever committed: the page has its
        // terminal state. A session that answered with nothing settled as
        // empty inside `load()`; this is the read that never came back, and
        // the failure card is the content -- a message area held transparent
        // for ever is the one answer that is never right.
        settleUnplacedWithoutContent()
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
            show(turns: cached.turns ?? [])
            loadingConversation = false
            // The first frame's source, and the placement's trigger: the
            // message area is gated from here until the geometry says the
            // newest turn is in view.
            beginInitialPlacementIfNeeded()
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
        // The page's context figure landed after the stats read above and comes
        // from the same read that named the page's cut, so it is the fresher of
        // the two -- and it arrives even when the stats read did not.
        if let frame = conversationResult.stats {
            stats = frame
            statsSessionId = sessionId
        }
        // Only replace what is on screen when there is something to replace it
        // with. A read that failed returns the cache rather than nothing, but a
        // cache can be empty on a first visit -- and assigning that over a
        // populated screen is what "pull to refresh loses my history" was.
        let fresh = conversationResult.items
        if !fresh.isEmpty {
            items = fresh
            conversationSessionId = sessionId
            // The host's answer is also a first frame's source: with no cache
            // this is the first content the page has, and the placement runs
            // against it exactly as it does against the cached copy.
            beginInitialPlacementIfNeeded()
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
        // A read that answered with nothing is an empty session, and that is
        // an answer: the empty state is the content, and it is settled here
        // rather than after the retries -- an empty session should not wait
        // for a load that has already replied.
        //
        // A read that *failed* says nothing either way yet: `reload()` asks
        // again, and settles this page only once it has run out of attempts.
        // Showing the failure card on the first failure would flash it over
        // a session that answers a moment later.
        if model.conversationError == nil {
            settleUnplacedWithoutContent()
        }
        // The conversation counts as landed only when this session is the one
        // drawn: an empty page for a session nobody has typed into yet is an
        // answer, but an empty page on a screen showing another session's rows
        // means the read did not arrive.
        return statsLanded && conversationSessionId == sessionId
    }
}

/// Where a page's conversation is on its way to its first position.
///
/// The screen used to reveal the conversation at whatever offset a new
/// `ScrollView` starts at -- the top -- and move it to the newest message once
/// the load had finished, so a session with a cached history opened showing
/// its oldest turns and jumped a moment later, the wait growing with the
/// network. The placement is now a precondition of display: the message area
/// stays gated until the geometry says the newest turn is in view, which makes
/// the first frame an operator can read the one that is already at the bottom.
enum InitialPlacement: Equatable {
    /// The page is up and nothing has been committed to it yet.
    case waitingForContent
    /// A conversation has been committed and the placement is running. The
    /// generation is the round, so a correction belonging to an earlier
    /// commit cannot settle a later one.
    case placing(generation: Int)
    /// The newest turn is in view; the message area is live.
    case ready
    /// Explicit turn navigation has taken ownership from initial placement.
    case navigating
    /// The session has no messages: there is no bottom to place against and
    /// nothing to gate.
    case empty
    /// The first read failed with nothing cached: the failure card is the
    /// content, and holding it back would be a spinner for ever.
    case failed
    /// Loaded content whose local placement did not converge. Offer retry.
    case positioningFailed

    /// A content commit (including refresh) may retry an unplaced page, but
    /// never takes position back from a reader or explicit turn navigation.
    @discardableResult
    mutating func beginIfNeeded(generation: Int) -> Bool {
        switch self {
        case .waitingForContent, .empty, .failed, .positioningFailed:
            self = .placing(generation: generation)
            return true
        case .placing, .ready, .navigating:
            return false
        }
    }

    /// Acceptance outlives the active scroll budget; it never issues a scroll.
    @discardableResult
    mutating func finishIfPositioned(_ geometry: ConversationPlacementGeometry?, tolerance: CGFloat) -> Bool {
        switch self {
        case .placing, .positioningFailed:
            guard geometry?.isAtBottom(tolerance: tolerance) == true else { return false }
            self = .ready
            return true
        default:
            return false
        }
    }

    /// Whether the message area may be shown and touched.
    var isRevealed: Bool {
        switch self {
        case .ready, .navigating, .empty, .failed: return true
        case .waitingForContent, .placing, .positioningFailed: return false
        }
    }
}

/// One round of initial placement, as something a `.task(id:)` can watch.
///
/// The session is in the key as well as the round: the shell already keys the
/// page per session, and a key that names the session makes the placement task
/// one the page's own lifetime owns -- cancelled when the page leaves, rather
/// than a saved handle somebody has to remember to release.
private struct PlacementKey: Equatable {
    var sessionId: String
    var round: Int
}

/// Acceptance uses valid measured geometry, never an unmeasured default zero.
struct ConversationPlacementGeometry: Equatable {
    var contentHeight: CGFloat
    var viewportHeight: CGFloat
    var visibleMinY: CGFloat
    var visibleMaxY: CGFloat
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0

    func isAtBottom(tolerance: CGFloat) -> Bool {
        guard contentHeight.isFinite, viewportHeight.isFinite,
              visibleMinY.isFinite, visibleMaxY.isFinite,
              topInset.isFinite, bottomInset.isFinite,
              contentHeight > 0, viewportHeight > 0, visibleMaxY > visibleMinY else { return false }
        // ScrollGeometry's raw visible rect includes content/safe-area insets.
        // Use the usable interval consistently, including for short pages;
        // containerSize and the raw visible rect are not interchangeable.
        let usableMinY = visibleMinY + topInset
        let usableMaxY = visibleMaxY - bottomInset
        let usableHeight = usableMaxY - usableMinY
        guard usableHeight.isFinite, usableHeight > 0 else { return false }
        if abs(contentHeight - usableMaxY) <= tolerance { return true }
        // A short, top-aligned conversation is already entirely visible.
        // A viewport wholly below the content must not pass this branch.
        return contentHeight <= usableHeight + tolerance
            && usableMinY <= tolerance && usableMaxY >= contentHeight - tolerance
    }
}
