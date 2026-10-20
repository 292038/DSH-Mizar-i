//
//  MizarShell.swift
//  DSH-Mizar
//
//  The app, once a computer is paired: the workspaces on the left, the
//  conversation, and the conversation's plane of pages on the right -- its
//  turns, the subagents it has delegated to, and a preview page still to come.
//
//  On a phone the conversation is the screen and the two drawers are under it.
//  Drag the conversation to the right, or tap the button at the top left, and
//  the workspace sidebar comes out while the conversation steps aside as a card:
//  it follows the finger, shrinks a little, takes on the display's rounded
//  corners and dims, and a tap on it brings it back. Drag it to the left, or tap
//  its title, and the same thing happens in the mirror: the turn index comes out
//  on the right. On an iPad both are columns -- the sidebar beside the
//  conversation, the index beside it on the other side -- each slid away and
//  back with its own button.
//
//  Both drawers and the conversation stay mounted the whole time and only render
//  modifiers move: the card's offset, scale and corner are always applied, at
//  identity values when closed. A modifier added and removed as a drawer opens
//  would give the conversation a new identity -- rebuilding it, re-running its
//  loads, and throwing away the draft and the scroll position.
//

import SwiftUI
import MizarKit

struct MizarShell: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.colorScheme) private var colorScheme
    @State private var shell = ShellState()
    @State private var turnIndex = TurnIndex()
    @State private var placed = false
    #if DEBUG
    /// A debug launch asked for the right drawer; it is opened once a session
    /// has arrived to show in it, since the drawer's own close rides the same
    /// selection change.
    @State private var debugOpenTrailingWanted = false
    #endif

    var body: some View {
        GeometryReader { geometry in
            let compact = sizeClass != .regular
            let insets = geometry.safeAreaInsets
            let size = CGSize(
                width: geometry.size.width + insets.leading + insets.trailing,
                height: geometry.size.height + insets.top + insets.bottom,
            )
            let leading = sidebarWidth(in: size, compact: compact)
            let trailing = indexWidth(in: size, compact: compact)
            // The card is the whole screen, under the status bar and the home
            // indicator. The container's edges only: the keyboard's is the
            // composer's to ride. The reader itself stays inside the safe area
            // so it can say what the insets are, and the drawers are handed them
            // back by hand -- a scroll view inside a view that ignores them does
            // not see them.
            layout(leading: leading, trailing: trailing, size: size, insets: insets, compact: compact)
                .frame(width: size.width, height: size.height)
                .ignoresSafeArea(.container)
                .onChange(of: leading, initial: true) { _, width in shell.leadingWidth = width }
                .onChange(of: trailing, initial: true) { _, width in shell.trailingWidth = width }
                .onChange(of: size.width, initial: true) { _, width in shell.containerWidth = width }
        }
        .environment(shell)
        .environment(turnIndex)
        .onAppear {
            guard !placed else { return }
            placed = true
            // Open on a launch with nothing selected: the list is the only
            // useful thing to look at. Placed without animating; the first frame
            // is a state, not a change.
            shell.place(open: model.selectedSessionId == nil)
            shell.trailingAvailable = model.selectedSessionId != nil
            #if DEBUG
            // A debug way into the right drawer, for screenshots and future
            // drawer tests: the drawer otherwise belongs to a gesture, which
            // `simctl` can launch but cannot make.
            if ProcessInfo.processInfo.arguments.contains("-mizarOpenTurnIndex") {
                debugOpenTrailingWanted = true
                if model.selectedSessionId != nil {
                    shell.trailingAvailable = true
                    shell.openTrailing()
                }
            }
            #endif
        }
        .onChange(of: model.selectedSessionId) { _, selected in
            shell.trailingAvailable = selected != nil
            // A session chosen from anywhere -- a row, a notification, a launch
            // argument, a session just created -- is a session the operator
            // wants to see, so the card comes back. A selection that goes away
            // (a disconnect, a switch of computer) puts the list back in front.
            if selected != nil {
                shell.close()
            } else if !shell.settledOpen {
                shell.open()
            }
            #if DEBUG
            // The debug open arrives after the close that rides the same
            // selection, so the drawer ends the launch open rather than
            // losing the race to it.
            if debugOpenTrailingWanted, selected != nil {
                shell.trailingAvailable = true
                shell.openTrailing()
            }
            #endif
        }
        .onChange(of: turnIndex.jumpCount) { _, _ in
            // A turn chosen in the drawer: the card comes back to show it.
            if shell.trailingOpen { shell.close() }
        }
        .mizarFeedback(.selection, trigger: shell.settled)
    }

    // MARK: - Layout

    @ViewBuilder
    private func layout(leading: CGFloat, trailing: CGFloat, size: CGSize, insets: EdgeInsets, compact: Bool) -> some View {
        let p = compact ? shell.progress : 0
        let lead = compact ? max(0, min(1, p)) : (shell.pinnedVisible ? 1 : 0)
        let trail = compact ? max(0, min(1, -p)) : (indexColumnShown ? 1 : 0)
        // Which drawer, if any, the phone is revealing: decided by the sign
        // of the drag, so it changes once per gesture rather than once per
        // frame. A drawer that is not the one being shown sits behind an
        // opaque card, so its value never shows -- and a constant opacity
        // lets the render server move a cached layer instead of compositing
        // two full-screen blends on every frame of the drag.
        let leadingShown = compact && trail < lead
        let trailingShown = compact && lead < trail
        ZStack(alignment: .topLeading) {
            Theme.sidebarBackground.ignoresSafeArea()

            SidebarView()
                .safeAreaPadding(EdgeInsets(top: insets.top, leading: insets.leading, bottom: insets.bottom, trailing: 0))
                .frame(width: leading)
                // The sidebar comes forward as the card leaves: a little travel
                // and a little light, so the two read as layers rather than as
                // one strip sliding sideways.
                .offset(x: compact ? -(1 - lead) * 44 : -(1 - lead) * leading)
                .opacity(compact ? (leadingShown ? 1 : 0) : 1)
                // The edge of a gesture is a fade rather than a cut: this
                // changes only when the drag crosses from one drawer to the
                // other, never while the finger moves.
                .animation(Motion.pick(.mizarSmooth), value: leadingShown)
                .accessibilityHidden(lead < 0.5)
                .allowsHitTesting(lead > 0.5)
                .gesture(SidebarPan(shell: shell, compact: compact))

            // The mirror image, on the right: one plane of three pages --
            // turns, subagents, preview -- that the conversation card slides
            // over. The card is drawn after this panel, which is what makes
            // the plane's off-focus pages read as passing under it.
            SessionSidePlane(onPick: {})
                .safeAreaPadding(EdgeInsets(top: insets.top, leading: 0, bottom: insets.bottom, trailing: insets.trailing))
                .frame(width: trailing, height: size.height)
                .offset(x: size.width - trailing + (compact ? (1 - trail) * 44 : (1 - trail) * trailing))
                .opacity(compact ? (trailingShown ? 1 : 0) : 1)
                .animation(Motion.pick(.mizarSmooth), value: trailingShown)
                .accessibilityHidden(trail < 0.5)
                .allowsHitTesting(trail > 0.5)
                .gesture(SidebarPan(shell: shell, compact: compact))

            pane(leading: leading, trailing: trailing, size: size, compact: compact, lead: lead, trail: trail)

            // The card, while it is pushed aside, is one big button back.
            if compact && (lead > 0.02 || trail > 0.02) {
                let shift = lead > 0.02 ? leading * p : trailing * p
                Button {
                    shell.close()
                } label: {
                    Color.clear.contentShape(.rect)
                }
                .buttonStyle(.plain)
                .frame(width: max(0, size.width - abs(shift)), height: size.height)
                .offset(x: max(0, shift))
                .gesture(SidebarPan(shell: shell, compact: compact))
                .accessibilityLabel(Text(lead > 0.02 ? "Close sidebar" : "Close turns"))
                .accessibilityIdentifier("shell.dismissSidebar")
                .allowsHitTesting(lead > 0.5 || trail > 0.5)
            }
        }
        .accessibilityAction(.escape) {
            if compact { shell.close() }
        }
    }

    /// Whether the iPad's index column is out: only beside a conversation.
    private var indexColumnShown: Bool {
        shell.indexPinnedVisible && model.selectedSessionId != nil
    }

    private func pane(
        leading: CGFloat,
        trailing: CGFloat,
        size: CGSize,
        compact: Bool,
        lead: CGFloat,
        trail: CGFloat,
    ) -> some View {
        let reveal = max(lead, trail)
        let towardsTrailing = trail > lead
        // The corner is the screen's own or it is nothing. At rest it hides
        // inside the display's mask, and the moment the card moves it wants
        // the full radius -- a corner that grew with the drag only ever
        // showed a square one in the first frames of the movement. Two
        // values, so the mask is laid out at most once per gesture and the
        // render server keeps it for the frames in between.
        let corner = compact && reveal > 0.001 ? Self.cardCorner : 0
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        let offset: CGFloat = compact
            ? (towardsTrailing ? -trailing * trail : leading * shell.progress)
            : leading * lead
        let width = compact ? size.width : max(0, size.width - leading * lead - trailing * trail)
        return NavigationStack {
            Group {
                if let sessionId = model.selectedSessionId {
                    // Keyed on the session, which is what makes every piece of
                    // state inside belong to the session it was filled from: the
                    // draft, the scroll anchor, the paging allowance, the
                    // in-flight-load gate. One identity per session is the tag
                    // that covers the ones nobody remembered to add, and it
                    // cancels a load the moment its subject goes away.
                    SessionDetailView(sessionId: sessionId)
                        .id(sessionId)
                } else {
                    HomeView()
                }
            }
            // Declared here, outside the keyed view, so switching sessions does
            // not rebuild the bar and its glass.
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    SidebarToggle(compact: compact)
                }
                if !compact, model.selectedSessionId != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        TurnIndexToggle()
                    }
                }
            }
        }
        .background(Theme.paneBackground)
        .frame(width: width)
        .clipShape(shape)
        .overlay {
            // A shade, and a faint rim of the accent on the edge that faces the
            // open drawer: the card catching the light of the list behind it.
            // Both ride a single opacity rather than a colour that changes:
            // a shape whose alpha changes is redrawn every frame, while one
            // whose opacity changes is blended from the shape already drawn.
            shape
                .fill(Color.black.opacity(colorScheme == .dark ? 0.32 : 0.05))
                .opacity(compact ? reveal : 0)
                .allowsHitTesting(false)
            shape
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.accentColor.opacity(0.45), .white.opacity(0.06), .clear],
                        startPoint: towardsTrailing ? .trailing : .leading,
                        endPoint: towardsTrailing ? .leading : .trailing,
                    ),
                    lineWidth: 1,
                )
                .opacity(compact ? reveal : 0)
                .allowsHitTesting(false)
        }
        // The shadow is the one effect here that must not follow the
        // finger: a radius that changes every frame re-renders a
        // full-screen blur on every frame of the drag. Fixed at its
        // settled size, only its opacity moves -- a blend, not a blur --
        // so the card still lifts as the drawer opens beside it.
        .shadow(
            color: .black.opacity((colorScheme == .dark ? 0.5 : 0.16) * (compact ? reveal : 0)),
            radius: 30,
            x: towardsTrailing ? 8 : -8,
        )
        // The shrink arrives early -- over the first third of the drawer's
        // travel, the way the corner does -- and then holds. From there the
        // card only translates, which the render server does to a cached
        // layer instead of re-drawing one every frame.
        .scaleEffect(compact ? 1 - Self.cardShrink * min(1, reveal * 3) : 1, anchor: towardsTrailing ? .trailing : .leading)
        .offset(x: offset)
        .gesture(SidebarPan(shell: shell, compact: compact))
        .accessibilityHidden(compact && reveal > 0.5)
    }

    /// The card's corner once pushed aside.
    ///
    /// Not the display's own radius -- that is private API -- but the smallest
    /// radius of any Face ID iPhone, so at rest the corner is hidden inside the
    /// display's mask on every device, and pushed aside it matches closely
    /// enough that the card reads as the screen itself.
    private static let cardCorner: CGFloat = 39

    /// How far the card shrinks once pushed aside, over the first third of
    /// the drawer's travel.
    private static let cardShrink: CGFloat = 0.06

    private func sidebarWidth(in size: CGSize, compact: Bool) -> CGFloat {
        compact ? min(330, size.width * 0.84) : min(340, max(280, size.width * 0.3))
    }

    private func indexWidth(in size: CGSize, compact: Bool) -> CGFloat {
        compact ? min(320, size.width * 0.82) : min(320, max(260, size.width * 0.26))
    }
}

/// The button at the top left: two lines that fold into a chevron as the
/// sidebar opens, following the drag frame by frame.
struct SidebarToggle: View {
    let compact: Bool
    @Environment(ShellState.self) private var shell
    @Environment(AppModel.self) private var model

    /// Whether the one-time naming prompt should be out of this button.
    ///
    /// Read in the body, not only inside the binding: SwiftUI observes what a
    /// body reads, and a prompt held back while a drawer is moving has to be
    /// asked about again when the drawer stops. A value read only from inside a
    /// presentation binding is read once, at the wrong moment, and never again
    /// -- which is how a delayed prompt became a prompt that never appeared.
    private var wantsNaming: Bool {
        compact && model.pendingNameHostId != nil
            && !shell.settledOpen && !shell.isSettling && !shell.isDragging
    }

    var body: some View {
        let namingWanted = wantsNaming
        Button {
            shell.toggle(compact: compact)
        } label: {
            SidebarGlyph(progress: compact ? max(0, min(1, shell.progress)) : (shell.pinnedVisible ? 1 : 0))
                .stroke(.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .frame(width: 20, height: 16)
                .padding(4)
                .contentShape(.rect)
        }
        .accessibilityLabel(Text(isOpen ? "Hide sidebar" : "Show sidebar"))
        .accessibilityIdentifier("shell.sidebarToggle")
        .mizarPopover(
            isPresented: Binding(
                get: { namingWanted },
                set: { if !$0 { model.pendingNameHostId = nil } },
            ),
        ) {
            NamingWindow()
        }
    }

    private var isOpen: Bool { compact ? shell.settledOpen : shell.pinnedVisible }
}

/// The iPad's button for the index column: the sidebar's glyph, mirrored.
struct TurnIndexToggle: View {
    @Environment(ShellState.self) private var shell

    var body: some View {
        Button {
            shell.toggleTrailing(compact: false)
        } label: {
            Image(systemName: shell.indexPinnedVisible ? "list.bullet.indent" : "list.bullet")
                .font(.system(size: 16, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 28, height: 24)
                .contentShape(.rect)
        }
        .accessibilityLabel(Text(shell.indexPinnedVisible ? "Hide turns" : "Show turns"))
        .accessibilityIdentifier("shell.turnIndexToggle")
    }
}

/// Two lines, the lower one shorter, that become a chevron pointing left.
struct SidebarGlyph: Shape {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        func point(_ closed: CGPoint, _ open: CGPoint) -> CGPoint {
            CGPoint(
                x: rect.minX + (closed.x + (open.x - closed.x) * progress) * rect.width,
                y: rect.minY + (closed.y + (open.y - closed.y) * progress) * rect.height,
            )
        }
        var path = Path()
        // Upper line -> upper stroke of the chevron.
        path.move(to: point(CGPoint(x: 0.05, y: 0.28), CGPoint(x: 0.62, y: 0.1)))
        path.addLine(to: point(CGPoint(x: 0.95, y: 0.28), CGPoint(x: 0.24, y: 0.5)))
        // Lower line -> lower stroke.
        path.move(to: point(CGPoint(x: 0.05, y: 0.72), CGPoint(x: 0.62, y: 0.9)))
        path.addLine(to: point(CGPoint(x: 0.6, y: 0.72), CGPoint(x: 0.24, y: 0.5)))
        return path
    }
}
