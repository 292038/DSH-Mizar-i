//
//  MizarShell.swift
//  DSH-Mizar
//
//  The app, once a computer is paired: a sidebar of workspaces, and the conversation.
//
//  On a phone the conversation is the screen and the sidebar is underneath it.
//  Opening the sidebar -- the button at the top left, or a sideways drag anywhere
//  on the conversation -- pushes the conversation aside as a card: it follows
//  the finger, shrinks a little, takes on the display's rounded corners and dims,
//  and a tap on it brings it back. On an iPad the sidebar simply sits beside the
//  conversation, and the same button slides it away.
//
//  This replaced a two-tab bar. A conversation is not a third place beside "the
//  conversations" and "the settings"; it is where the operator is, and the list
//  is how they move between them -- which is the shape every assistant app on
//  the phone has settled on.
//
//  Both halves stay mounted the whole time and only render modifiers move: the
//  card's offset, scale and corner are always applied, at identity values when
//  closed. A modifier added and removed as the sidebar opens would give the
//  conversation a new identity -- rebuilding it, re-running its loads, and
//  throwing away the draft and the scroll position.
//

import SwiftUI
import MizarKit

struct MizarShell: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.colorScheme) private var colorScheme
    @State private var shell = ShellState()
    @State private var placed = false

    @State private var showingSettings = false
    @State private var showingHosts = false
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
        GeometryReader { geometry in
            let compact = sizeClass != .regular
            let insets = geometry.safeAreaInsets
            let size = CGSize(
                width: geometry.size.width + insets.leading + insets.trailing,
                height: geometry.size.height + insets.top + insets.bottom,
            )
            let width = sidebarWidth(in: size, compact: compact)
            // The card is the whole screen, under the status bar and the home
            // indicator. The container's edges only: the keyboard's is the
            // composer's to ride. The reader itself stays inside the safe area
            // so it can say what the insets are, and the sidebar is handed them
            // back by hand -- a scroll view inside a view that ignores them does
            // not see them.
            layout(width: width, size: size, insets: insets, compact: compact)
                .frame(width: size.width, height: size.height)
                .ignoresSafeArea(.container)
        }
        .environment(shell)
        .onAppear {
            guard !placed else { return }
            placed = true
            // Open on a launch with nothing selected: the list is the only
            // useful thing to look at. Placed without animating; the first frame
            // is a state, not a change.
            shell.place(open: model.selectedSessionId == nil)
        }
        .onChange(of: model.selectedSessionId) { _, selected in
            // A session chosen from anywhere -- a row, a notification, a launch
            // argument, a session just created -- is a session the operator
            // wants to see, so the card comes back. A selection that goes away
            // (a disconnect, a switch of computer) puts the list back in front.
            if selected != nil {
                shell.close()
            } else if !shell.settledOpen {
                shell.open()
            }
        }
        .mizarFeedback(.selection, trigger: shell.settledOpen)
        .sheet(isPresented: $showingSettings) {
            SettingsView(onDone: { showingSettings = false })
        }
        .sheet(isPresented: $showingHosts) {
            HostsSheet()
        }
        .sheet(isPresented: $showingNewSession) {
            NewSessionView()
        }
        // Read by the sheet itself rather than handed a value: a sheet's content
        // closure is outside this body, so it would not see the progress move.
        .sheet(isPresented: $showingSync) {
            SyncProgressSheet()
        }
        .sheet(isPresented: namingPrompt) { namingSheet }
    }

    // MARK: - Layout

    @ViewBuilder
    private func layout(width: CGFloat, size: CGSize, insets: EdgeInsets, compact: Bool) -> some View {
        let p = compact ? shell.progress : (shell.pinnedVisible ? 1 : 0)
        let reveal = max(0, min(1, p))
        ZStack(alignment: .topLeading) {
            Theme.sidebarBackground.ignoresSafeArea()

            SidebarView(actions: sidebarActions)
                .safeAreaPadding(EdgeInsets(top: insets.top, leading: insets.leading, bottom: insets.bottom, trailing: 0))
                .frame(width: width)
                // The sidebar comes forward as the card leaves: a little travel
                // and a little light, so the two read as layers rather than as
                // one strip sliding sideways.
                .offset(x: compact ? -(1 - reveal) * 44 : -(1 - reveal) * width)
                .opacity(compact ? 0.35 + 0.65 * reveal : 1)
                .accessibilityHidden(reveal < 0.5)
                .allowsHitTesting(reveal > 0.5)
                .gesture(SidebarPan(shell: shell, width: width, direction: .closing, enabled: compact))

            pane(width: width, size: size, compact: compact, progress: p)

            // The card, while it is pushed aside, is one big button back.
            if compact && reveal > 0.02 {
                Button {
                    shell.close()
                } label: {
                    Color.clear.contentShape(.rect)
                }
                .buttonStyle(.plain)
                .frame(width: max(0, size.width - width * p), height: size.height)
                .offset(x: width * p)
                .gesture(SidebarPan(shell: shell, width: width, direction: .closing))
                .accessibilityLabel(Text("Close sidebar"))
                .accessibilityIdentifier("shell.dismissSidebar")
                .allowsHitTesting(reveal > 0.5)
            }
        }
        .accessibilityAction(.escape) {
            if compact { shell.close() }
        }
    }

    private func pane(width: CGFloat, size: CGSize, compact: Bool, progress p: CGFloat) -> some View {
        let reveal = max(0, min(1, p))
        let corner = compact ? Self.cardCorner * min(1, reveal * 3) : 0
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
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
                    HomeView(onChooseWorkspace: { showingNewSession = true })
                }
            }
            // Declared here, outside the keyed view, so switching sessions does
            // not rebuild the bar and its glass.
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    SidebarToggle(compact: compact)
                }
            }
        }
        .background(Theme.paneBackground)
        .frame(width: compact ? size.width : max(0, size.width - width * reveal))

        .clipShape(shape)
        .overlay {
            // A shade, and a faint rim of the accent on the edge that faces the
            // sidebar: the card catching the light of the list behind it.
            shape
                .fill(Color.black.opacity((colorScheme == .dark ? 0.32 : 0.05) * reveal))
                .allowsHitTesting(false)
            shape
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.accentColor.opacity(0.45 * reveal), .white.opacity(0.06 * reveal), .clear],
                        startPoint: .leading,
                        endPoint: .trailing,
                    ),
                    lineWidth: 1,
                )
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity((colorScheme == .dark ? 0.5 : 0.16) * reveal), radius: 30 * reveal, x: -8 * reveal)
        .scaleEffect(compact ? 1 - 0.06 * reveal : 1, anchor: .leading)
        .offset(x: width * (compact ? p : reveal))
        .gesture(SidebarPan(shell: shell, width: width, direction: .opening, enabled: compact && (!shell.settledOpen || shell.isDragging)))
        .accessibilityHidden(compact && reveal > 0.5)
    }

    /// The card's corner once pushed aside.
    ///
    /// Not the display's own radius -- that is private API -- but the smallest
    /// radius of any Face ID iPhone, so at rest the corner is hidden inside the
    /// display's mask on every device, and pushed aside it matches closely
    /// enough that the card reads as the screen itself.
    private static let cardCorner: CGFloat = 39

    private func sidebarWidth(in size: CGSize, compact: Bool) -> CGFloat {
        compact ? min(330, size.width * 0.84) : min(340, max(280, size.width * 0.3))
    }

    private var sidebarActions: SidebarActions {
        SidebarActions(
            newSession: { showingNewSession = true },
            settings: { showingSettings = true },
            hosts: { showingHosts = true },
            sync: {
                showingSync = true
                Task { await model.syncAllConversations() }
            },
        )
    }

    /// The one-time "what should this computer be called" prompt.
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

/// What the sidebar's controls ask the shell to do.
struct SidebarActions {
    var newSession: () -> Void
    var settings: () -> Void
    var hosts: () -> Void
    var sync: () -> Void
}

/// The button at the top left: two lines that fold into a chevron as the
/// sidebar opens, following the drag frame by frame.
struct SidebarToggle: View {
    let compact: Bool
    @Environment(ShellState.self) private var shell

    var body: some View {
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
    }

    private var isOpen: Bool { compact ? shell.settledOpen : shell.pinnedVisible }
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

/// The list of computers, as a sheet of its own.
///
/// It used to be pushed inside the session list's navigation, and the way back
/// was the back button. As a sheet it has a Done button -- and it closes by
/// itself once a switch has landed, because the operator chose a computer to look at
/// its sessions, not to keep looking at the list of computers.
private struct HostsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            HostListView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier("hosts.done")
                    }
                }
        }
        .onChange(of: model.host?.hostId) { old, new in
            guard old != nil, new != nil, old != new else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(450))
                dismiss()
            }
        }
    }
}
