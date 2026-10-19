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
    /// The details to draw, oldest first.
    let entries: [ActivityEntry]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// How many rows have finished descending. Drives the staggered arrival.
    @State private var revealed = 0

    /// The largest the window is allowed to be.
    private static let maximumHeight: CGFloat = 208
    /// One row's share of height: a caption line plus its spacing.
    private static let rowHeight: CGFloat = 30

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        TurnActivityRow(entry: entry)
                            .id(entry.id)
                            // Descend from under the status row: a new row
                            // starts a few points up and slides into place as
                            // it fades in. The delay is per row, which is what
                            // turns the arrival into a waterfall.
                            .opacity(index < revealed ? 1 : 0)
                            .offset(y: index < revealed ? 0 : -10)
                            .animation(
                                reduceMotion
                                    ? .mizarFade
                                    : .mizarSnappy.delay(Double(index) * 0.015),
                                value: revealed,
                            )
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: height)
            .scrollIndicators(.hidden)
            // The system's soft edge effect blurs the content under the top
            // and bottom edges, so the window reads as continuing past its
            // bounds rather than as a hard crop.
            .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
            .onAppear { scrollToNewest(proxy, animated: false) }
            .onChange(of: revealed) { _, count in
                // Keep the newest line in view as it descends. A feed whose new
                // lines appear below the fold is a feed the operator has to
                // chase with their thumb.
                guard count > 0, count <= entries.count else { return }
                withAnimation(.mizarSnappy) {
                    proxy.scrollTo(entries[count - 1].id, anchor: .bottom)
                }
            }
            .onChange(of: entries.last?.id) { _, _ in
                scrollToNewest(proxy, animated: true)
            }
        }
        // Soft edges, top and bottom: the window into the feed fades out rather
        // than stopping on a hard line. Drawn as a mask so it works on any
        // background and does not tint the text.
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
        .task(id: entries.count) { await revealRows() }
        .onAppear { revealed = 0 }
        .accessibilityIdentifier("turn.activity.detail")
    }

    /// The window's height: content-sized, bounded.
    private var height: CGFloat {
        let wanted = CGFloat(min(entries.count, 7)) * Self.rowHeight + 16
        return min(Self.maximumHeight, max(76, wanted))
    }

    /// Descend the rows a few at a time.
    ///
    /// One state bump per row with a short sleep between: the sleep is what makes
    /// the stagger visible, and a `revealed` count is what lets a row that
    /// arrives while the list is already up join the waterfall from the end.
    private func revealRows() async {
        guard !reduceMotion else {
            revealed = entries.count
            return
        }
        while revealed < entries.count {
            do {
                try await Task.sleep(for: .milliseconds(28))
            } catch {
                return
            }
            withAnimation(.mizarSnappy) { revealed += 1 }
        }
    }

    /// Put the newest detail at the bottom of the window.
    ///
    /// - Parameters:
    ///   - proxy: the scroll proxy.
    ///   - animated: whether to animate the move.
    private func scrollToNewest(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let last = entries.last else { return }
        if animated {
            withAnimation(.mizarSnappy) { proxy.scrollTo(last.id, anchor: .bottom) }
        } else {
            proxy.scrollTo(last.id, anchor: .bottom)
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
