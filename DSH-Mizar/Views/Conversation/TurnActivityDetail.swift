//
//  TurnActivityDetail.swift
//  DSH-Mizar
//
//  The paid full-detail list under a running turn's row.
//
//  The summary row says how long the turn has been going; this says what it is
//  doing, one compact line at a time. It is deliberately bounded: a process can
//  emit hundreds of details, and a list that grew the page under the operator
//  would move the conversation they are reading. The area is a fixed-height
//  window with its own scroll, fading at both edges so it reads as a glimpse
//  into something continuous rather than as a box that happens to be cut off.
//
//  Rows arrive in a quick waterfall -- each new line descends from under the
//  status row a few points and fades in, staggered by a few tens of milliseconds
//  -- because that is the motion of a feed filling up rather than of content
//  appearing all at once. Collapsing reverses it: the whole area rises back
//  under the row it belongs to. Nothing here is tappable: these are details, not
//  a second conversation.
//

import MizarKit
import SwiftUI

/// The internally scrolling list of process details.
///
/// Sized to its content up to a ceiling, so a turn with two details does not
/// open a 200-point empty window and a busy turn still scrolls.
struct TurnActivityDetail: View {
    /// The details to draw, oldest first. The newest rows are the tail; older
    /// pages are prepended by the screen above as they are read.
    let entries: [ActivityEntry]
    /// Whether older rows may still be read from the host.
    let hasOlder: Bool
    /// Read one older page.
    ///
    /// Called when the operator scrolls the window to its top. Returns whether
    /// the page added rows; the screen above owns the request and the feed.
    let onLoadOlder: () async -> Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// How many rows from the head of the list are visible. Rows past it are
    /// waiting their turn in the waterfall.
    @State private var revealed = 0
    /// The window's height, fixed when the detail opens.
    ///
    /// Frozen on purpose. The height used to be derived from the entry count, so
    /// every row the host appended made the window taller and moved the whole
    /// conversation under its bottom anchor -- a busy turn could make the screen
    /// twitch up repeatedly, once per poll. The window is a viewport onto a feed:
    /// its size belongs to the moment it opened, and new rows scroll inside it.
    @State private var windowHeight: CGFloat
    /// Whether an older page is in flight.
    @State private var loadingOlder = false
    /// The row that was on top when an older page was requested.
    ///
    /// Restored to the top after the page is prepended, so the operator's place
    /// in the feed is kept while the older rows slot in above it.
    @State private var anchorId: String?
    /// Whether the window is scrolled to its bottom. Only then does a new tail
    /// follow; an operator reading further back must not be dragged down.
    @State private var atBottom = true
    /// Whether the opening scroll has happened.
    ///
    /// The first layout pass reports the top of the list (the opening scroll to
    /// the newest row has not run yet), and without this the window would page in
    /// history before the operator had scrolled at all -- and the page would
    /// arrive while the opening scroll was still moving, which is one more way
    /// the area can jump.
    @State private var readyForOlder = false
    /// What the scroll is doing right now.
    ///
    /// A page can land while the drag that asked for it is still settling. A
    /// `scrollTo` issued then moves the offset, and the gesture's own settle puts
    /// it back where it was -- on a fast host (the LAN this feature is sold for)
    /// that is the common case, not a rare one. The restore therefore waits for
    /// the scroll to be idle.
    @State private var scrollPhase: ScrollPhase = .idle
    /// The anchored row a restore is waiting to run, when the page landed while
    /// the scroll was still moving.
    @State private var pendingRestore: String?

    /// Open at a height that suits the feed already held, and with the older
    /// rows drawn outright, so only the newest slice is animated in.
    ///
    /// Both are decided here rather than in `onAppear`: a window that opened at a
    /// placeholder height and resized a frame later was one visible jump, and the
    /// reveal's starting point is a fact about the entries this view was born with.
    init(entries: [ActivityEntry], hasOlder: Bool, onLoadOlder: @escaping () async -> Bool) {
        self.entries = entries
        self.hasOlder = hasOlder
        self.onLoadOlder = onLoadOlder
        let rows = min(max(entries.count, 3), 7)
        _windowHeight = State(initialValue: min(
            Self.maximumHeight,
            max(Self.minimumHeight, CGFloat(rows) * Self.rowHeight + 16),
        ))
        _revealed = State(initialValue: max(0, entries.count - Self.waterfallRows))
    }

    /// The largest the window is allowed to be.
    private static let maximumHeight: CGFloat = 208
    /// The smallest the window opens at, even for one row.
    private static let minimumHeight: CGFloat = 120
    /// One row's share of height: a caption line plus its spacing.
    private static let rowHeight: CGFloat = 30
    /// How many of the newest rows descend when the list appears.
    ///
    /// Ten, not the whole list. Every expand used to re-run the waterfall over
    /// every row the phone held, so a long turn took seconds to "fill" and the
    /// operator could not read the newest lines until it finished. Older rows
    /// are already there; only the arrival is animated.
    private static let waterfallRows = 10

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if hasOlder {
                        olderRow
                    }
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        TurnActivityRow(entry: entry)
                            .id(entry.id)
                            // Descend from under the status row: a row that is
                            // arriving starts a few points up and slides into
                            // place as it fades in.
                            .opacity(index < revealed ? 1 : 0)
                            .offset(y: index < revealed ? 0 : -10)
                            .animation(
                                reduceMotion ? .mizarFade : .mizarSnappy,
                                value: revealed,
                            )
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: windowHeight)
            .scrollIndicators(.hidden)
            // The system's soft edge effect blurs the content under the top
            // and bottom edges, so the window reads as continuing past its
            // bounds rather than as a hard crop.
            .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
            // Where the feed is, as two booleans: the bottom decides whether a
            // new tail may follow, the top decides whether older rows are owed.
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height
                    >= geometry.contentSize.height - 12
            } action: { _, bottom in
                atBottom = bottom
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y <= 4
            } action: { _, top in
                guard top, readyForOlder else { return }
                Task { await loadOlder() }
            }
            .onAppear {
                openWindow(proxy)
            }
            .onScrollPhaseChange { _, phase in
                scrollPhase = phase
                // The moment motion stops is the first moment a restore sticks:
                // earlier, the gesture that is settling undoes it.
                guard phase == .idle, let anchor = pendingRestore else { return }
                pendingRestore = nil
                DispatchQueue.main.async { proxy.scrollTo(anchor, anchor: .top) }
            }
            .onChange(of: entries.last?.id) { _, _ in
                // A new tail arrived. Only follow it when the operator is
                // already at the bottom: someone reading further back is not
                // asking to be dragged down, and yanking them was half of the
                // twitching this screen was reported for.
                guard atBottom, let last = entries.last?.id else { return }
                // After layout, without animation: the feed continued, the
                // viewport did not move.
                DispatchQueue.main.async { proxy.scrollTo(last, anchor: .bottom) }
            }
            .onChange(of: entries.first?.id) { _, _ in
                // An older page was prepended. Put the row that was on top back
                // where it was, so the history slots in above it instead of
                // shoving the feed down.
                guard let anchor = anchorId else { return }
                anchorId = nil
                if scrollPhase == .idle {
                    DispatchQueue.main.async { proxy.scrollTo(anchor, anchor: .top) }
                } else {
                    // The drag that asked for this page is still settling; a
                    // restore now would be undone by the gesture's own final
                    // position. The phase handler above runs it on the first
                    // idle frame.
                    pendingRestore = anchor
                }
            }
        }
        .mask {
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [.clear, .black],
                    startPoint: .top,
                    endPoint: .bottom,
                )
                .frame(height: 12)
                Color.black
                LinearGradient(
                    colors: [.black, .clear],
                    startPoint: .top,
                    endPoint: .bottom,
                )
                .frame(height: 14)
            }
        }
        .task(id: entries.count) { await revealArrivals() }
        .accessibilityIdentifier("turn.activity.detail")
    }

    // MARK: - Parts

    /// The row above the oldest held detail: an arrow, or a spinner while the
    /// page it asked for is in flight.
    private var olderRow: some View {
        HStack(spacing: 6) {
            if loadingOlder {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: "arrow.up")
                    .font(.system(size: 9, weight: .semibold))
            }
            Text("Scroll up for earlier details")
                .font(.caption2)
        }
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity)
        .frame(height: 18)
        .accessibilityIdentifier("turn.activity.older")
    }

    // MARK: - Opening the window

    /// Size the window, seed the reveal and start at the newest row.
    ///
    /// - Parameter proxy: the scroll proxy, for the opening scroll.
    private func openWindow(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            if let last = entries.last?.id {
                proxy.scrollTo(last, anchor: .bottom)
            }
            // A turn of grace before the top of the list means "the operator
            // scrolled there", not "this is the first frame".
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                readyForOlder = true
            }
        }
    }

    /// Reveal the rows not yet shown, newest slice only.
    private func revealArrivals() async {
        guard !reduceMotion else {
            revealed = entries.count
            return
        }
        if revealed > entries.count { revealed = entries.count }
        let target = entries.count
        // Too many at once: the extra rows appear with the batch rather than
        // being chased one by one. The animation is about arrival, not about
        // making the operator wait for the list to finish.
        if target - revealed > Self.waterfallRows {
            revealed = target - Self.waterfallRows
        }
        while revealed < target {
            do {
                try await Task.sleep(for: .milliseconds(26))
            } catch {
                return
            }
            revealed += 1
        }
    }

    // MARK: - Older pages

    /// Ask for one older page, anchored on the row that is currently on top.
    ///
    /// The anchor is captured before the request and deliberately left in place
    /// afterwards: the page lands in the parent's feed, this view is handed a new
    /// `entries`, and `onChange(of: entries.first?.id)` restores the anchored row
    /// to the top. Clearing the anchor here from the *old* `entries` value is the
    /// bug this method was born with -- the condition compared the row against
    /// itself, always passed, and the restore never ran, so the window jumped to
    /// the beginning of the newly prepended history.
    ///
    /// A request that adds nothing clears the anchor itself: there is no prepend
    /// for `onChange` to see, and leaving it set would move the viewport the next
    /// time an unrelated page arrived.
    private func loadOlder() async {
        guard hasOlder, !loadingOlder else { return }
        loadingOlder = true
        let anchor = entries.first?.id
        anchorId = anchor
        let grew = await onLoadOlder()
        loadingOlder = false
        guard grew else {
            anchorId = nil
            return
        }
        // Safety net, not the mechanism: if the prepend somehow did not change
        // the first row (all returned rows already held, a page emptied of new
        // ids), the anchor would otherwise wait for an unrelated prepend. A
        // second is far past this update's layout.
        if let anchor {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if anchorId == anchor { anchorId = nil }
                if pendingRestore == anchor { pendingRestore = nil }
            }
        } else {
            anchorId = nil
        }
    }
}

/// One detail, as a compact DSH-like line: icon, category, one-line text.
///
/// Not a button and not a disclosure: tapping a detail is not a thing an
/// operator should be able to do, because there is nothing behind it -- the
/// full process payloads never reach the phone.
private struct TurnActivityRow: View {
    let entry: ActivityEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .center)
            Text(category)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            Text(detailText)
                .font(.caption2)
                .foregroundStyle(.primary.opacity(0.78))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("turn.activity.row")
    }

    /// What the row calls this kind of detail.
    ///
    /// The four categories in the host's contract, plus a generic one for a kind
    /// a newer host may add: an unknown detail is worth drawing as "Working"
    /// rather than dropping, because the row is decoration and a missing line
    /// reads as a stall.
    private var category: String {
        switch entry.kind {
        case .thinking: String(localized: "Thinking")
        case .command: String(localized: "Run command")
        case .output: String(localized: "Read output")
        case .tool: entry.title.isEmpty ? String(localized: "Tool") : entry.title
        case .other: entry.title.isEmpty ? String(localized: "Working") : entry.title
        }
    }

    /// The one-line body. The host has already truncated it to 240 characters;
    /// the row truncates again to what fits.
    private var detailText: String {
        entry.text.isEmpty ? entry.title : entry.text
    }

    /// The glyph for the kind, following the app's restrained icon language.
    private var symbol: String {
        switch entry.kind {
        case .thinking: "brain.head.profile"
        case .command: "terminal"
        case .output: "text.alignleft"
        case .tool: "wrench.and.screwdriver"
        case .other: "ellipsis.circle"
        }
    }
}
