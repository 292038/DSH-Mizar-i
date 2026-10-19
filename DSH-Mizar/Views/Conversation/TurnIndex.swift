//
//  TurnIndex.swift
//  DSH-Mizar
//
//  The conversation's table of contents: one row per turn, the way a desktop
//  agent lists them down the side of a long session.
//
//  On a phone it is the sidebar's mirror image -- drag the conversation to the
//  left, or tap its title, and it comes out on the right while the conversation
//  steps aside as a card. On an iPad it is a column of its own, and when that
//  column is put away a slim rail of ticks stays at the conversation's edge to
//  scrub through the turns without opening anything.
//
//  Four small things it does that a plain list would not:
//
//    - **It knows where you are.** The turns on screen in the conversation are
//      bracketed on the index's timeline, and the bracket moves as you scroll,
//      so opening it answers "how far up am I" before anything is tapped.
//    - **It shows where the time went.** Under each prompt a hairline bar is as
//      long as the turn took, against the longest turn in the session: the one
//      that ran for twenty minutes is visible from across the room.
//    - **It lands softly.** A tap closes it, scrolls the conversation to that
//      turn, and lets the turn glow once so the eye finds it.
//    - **It filters to what went wrong.** One tap narrows it to the turns that
//      did not finish -- the ones worth going back to.
//
//  The conversation publishes into ``TurnIndex``; the shell, which owns the
//  drawers, draws it. Neither holds the other.
//

import SwiftUI
import MizarKit

/// What the open conversation has, and where the operator is in it.
@MainActor
@Observable
final class TurnIndex {
    /// The session the turns belong to.
    private(set) var sessionId: String?
    private(set) var title: String?
    private(set) var turns: [ConversationTurn] = []
    /// The turns on screen in the conversation right now.
    private(set) var visible: Set<String> = []
    /// The turn the operator asked to go to, and a count that makes asking
    /// for the same one twice a second request.
    private(set) var jumpTarget: String?
    private(set) var jumpCount = 0
    /// The turn that should glow, having just been jumped to.
    private(set) var glowing: String?

    func publish(sessionId: String, title: String?, turns: [ConversationTurn]) {
        if self.sessionId != sessionId {
            visible = []
            glowing = nil
        }
        self.sessionId = sessionId
        self.title = title
        if self.turns != turns { self.turns = turns }
    }

    func withdraw(sessionId: String) {
        guard self.sessionId == sessionId else { return }
        self.sessionId = nil
        turns = []
        visible = []
        title = nil
    }

    func setVisible(_ id: String, _ isVisible: Bool) {
        if isVisible { visible.insert(id) } else { visible.remove(id) }
    }

    /// Ask the conversation to show a turn.
    func jump(to id: String) {
        jumpTarget = id
        jumpCount &+= 1
    }

    /// The conversation has arrived at a turn: let it glow, briefly.
    func glow(_ id: String) {
        withMizarAnimation(.mizarSmooth) { glowing = id }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1400))
            if glowing == id { withMizarAnimation(.mizarGentle) { glowing = nil } }
        }
    }
}

// MARK: - What a turn says about itself

extension ConversationTurn {
    /// The operator's words that opened the turn, on one line.
    var promptLine: String? {
        for item in prompts {
            if case .message(_, .user, let text, _) = item {
                let line = text
                    .split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .first { !$0.isEmpty }
                if let line { return line }
            }
        }
        return nil
    }

    /// How long the turn took, or has taken so far.
    ///
    /// Nothing for a turn settled from a missing record: the end it was given is
    /// the next turn's start -- an upper bound, not a reading -- and a number
    /// here would be taken for a measurement on the index's bar and total.
    func spent(asOf now: Date) -> TimeInterval? {
        if isEndInferred { return nil }
        return isRunning ? elapsed(asOf: now) : duration
    }

    /// What kind of row this is, for its colour and its glyph.
    var state: TurnState {
        if isRunning { return .running }
        if isEndInferred { return .ended }
        return failed ? .unfinished : .done
    }
}

enum TurnState {
    case running, done, ended, unfinished

    var tint: Color {
        switch self {
        case .running: .accentColor
        case .done: Theme.running
        case .ended: Color.secondary
        case .unfinished: Theme.waiting
        }
    }
}

// MARK: - The panel

/// The index, as it is drawn in the drawer on a phone and in the column on an
/// iPad.
struct TurnIndexPanel: View {
    /// Called once a turn has been chosen, so the phone's drawer can close.
    var onPick: () -> Void = {}

    @Environment(TurnIndex.self) private var index
    @State private var onlyUnfinished = false
    @Namespace private var filter

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 12)
            if index.turns.isEmpty {
                empty
            } else {
                timeline
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebarBackground)
        .accessibilityIdentifier("turnIndex.panel")
    }

    // MARK: Header

    private var header: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Turns")
                        .font(.title2.weight(.bold))
                    Text("\(index.turns.count)")
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .contentTransition(.numericText())
                    Spacer(minLength: 0)
                }
                if let title = index.title {
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                stats(now: context.date)
                if unfinishedCount > 0 {
                    filterBar
                        .transition(.rise)
                }
            }
        }
        .animation(.mizarSmooth, value: unfinishedCount)
    }

    private func stats(now: Date) -> some View {
        let total = index.turns.compactMap { $0.spent(asOf: now) }.reduce(0, +)
        return HStack(spacing: 14) {
            Label {
                Text(TurnIndexFormat.spell(total))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            } icon: {
                Image(systemName: "clock")
            }
            if let running = index.turns.last(where: \.isRunning) {
                Button {
                    pick(running)
                } label: {
                    HStack(spacing: 5) {
                        TwinStar(size: 10)
                        Text("Running now")
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())
                    .contentShape(.capsule)
                }
                .buttonStyle(.pressable)
                .foregroundStyle(Color.accentColor)
                .accessibilityIdentifier("turnIndex.running")
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
    }

    private var unfinishedCount: Int { index.turns.count { $0.state == .unfinished } }

    /// Two choices in a capsule, with a highlight that slides between them.
    private var filterBar: some View {
        HStack(spacing: 2) {
            filterButton(String(localized: "All"), selected: !onlyUnfinished) { onlyUnfinished = false }
            filterButton(String(format: String(localized: "Unfinished %lld"), unfinishedCount), selected: onlyUnfinished) {
                onlyUnfinished = true
            }
        }
        .padding(3)
        .background(.fill.tertiary, in: Capsule())
    }

    private func filterButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withMizarAnimation(.mizarSnappy, action)
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(selected ? .primary : .secondary)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background {
                    if selected {
                        Capsule()
                            .fill(Theme.selectionFill)
                            .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                            .matchedGeometryEffect(id: "filter", in: filter)
                    }
                }
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .mizarFeedback(.selection, trigger: selected)
    }

    // MARK: Timeline

    private var shown: [ConversationTurn] {
        onlyUnfinished ? index.turns.filter { $0.state == .unfinished } : index.turns
    }

    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let turns = shown
                    let longest = max(1, turns.compactMap { $0.spent(asOf: context.date) }.max() ?? 1)
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(turns.enumerated()), id: \.element.id) { offset, turn in
                            TurnIndexRow(
                                turn: turn,
                                number: number(of: turn),
                                spent: turn.spent(asOf: context.date),
                                longest: longest,
                                onScreen: index.visible.contains(turn.id),
                                previousOnScreen: offset > 0 && index.visible.contains(turns[offset - 1].id),
                                nextOnScreen: offset < turns.count - 1 && index.visible.contains(turns[offset + 1].id),
                                isFirst: offset == 0,
                                isLast: offset == turns.count - 1,
                                appearDelay: Double(min(offset, 14)) * 0.025,
                            ) {
                                pick(turn)
                            }
                            .id(turn.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 24)
                }
            }
            .scrollIndicators(.hidden)
            .scrollEdgeEffectStyle(.soft, for: .vertical)
            // Opened, the index is already at the part of the session the
            // operator is reading -- not at the top of a list of forty turns.
            .onAppear { centre(proxy) }
            .onChange(of: index.sessionId) { _, _ in centre(proxy) }
            .onChange(of: onlyUnfinished) { _, _ in centre(proxy) }
        }
    }

    private func centre(_ proxy: ScrollViewProxy) {
        let target = shown.last { index.visible.contains($0.id) } ?? shown.last
        guard let target else { return }
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo(target.id, anchor: .center)
        }
    }

    private func number(of turn: ConversationTurn) -> Int {
        turn.turn ?? ((index.turns.firstIndex { $0.id == turn.id } ?? 0) + 1)
    }

    private func pick(_ turn: ConversationTurn) {
        index.jump(to: turn.id)
        onPick()
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "list.bullet.indent")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text("No turns yet")
                .font(.headline)
            Text("Each prompt you send starts one, and it is listed here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }
}

/// One turn on the timeline.
private struct TurnIndexRow: View {
    let turn: ConversationTurn
    let number: Int
    let spent: TimeInterval?
    let longest: TimeInterval
    /// Whether the conversation is showing this turn now, and its neighbours:
    /// together they draw the bracket of "where you are".
    let onScreen: Bool
    let previousOnScreen: Bool
    let nextOnScreen: Bool
    let isFirst: Bool
    let isLast: Bool
    let appearDelay: Double
    let action: () -> Void

    @State private var grown = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                rail
                VStack(alignment: .leading, spacing: 5) {
                    Text(turn.promptLine ?? String(format: String(localized: "Turn %lld"), number))
                        .font(.subheadline.weight(onScreen ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    meta
                    bar
                }
                .padding(.vertical, 11)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.sm + 2, style: .continuous)
                    .fill(onScreen ? Theme.selectionFill.opacity(0.7) : .clear)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.pressable(scale: 0.98))
        .animation(.mizarSmooth, value: onScreen)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Shows this turn in the conversation"))
        .accessibilityIdentifier("turnIndex.row.\(turn.id)")
        .onAppear {
            guard !grown else { return }
            withAnimation(Motion.pick(.mizarGentle).delay(appearDelay)) { grown = true }
        }
    }

    /// The timeline: a line through every row, a node per turn, and the line
    /// lit where the conversation is.
    private var rail: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(segment(lit: onScreen && previousOnScreen))
                    .frame(width: onScreen && previousOnScreen ? 2.5 : 1.5, height: 17)
                    .opacity(isFirst ? 0 : 1)
                Rectangle()
                    .fill(segment(lit: onScreen && nextOnScreen))
                    .frame(width: onScreen && nextOnScreen ? 2.5 : 1.5)
                    .frame(maxHeight: .infinity)
                    .opacity(isLast ? 0 : 1)
            }
            node
                .padding(.top, 11)
        }
        .frame(width: 18)
    }

    private func segment(lit: Bool) -> Color {
        lit ? Color.accentColor : Color.secondary.opacity(0.22)
    }

    @ViewBuilder private var node: some View {
        switch turn.state {
        case .running:
            TwinStar(size: 13)
        case .done:
            Circle()
                .fill(onScreen ? Color.accentColor : Theme.running.opacity(0.85))
                .frame(width: 9, height: 9)
                .overlay {
                    Circle().strokeBorder(Theme.sidebarBackground, lineWidth: 2).padding(-2)
                }
                .scaleEffect(onScreen ? 1.25 : 1)
        case .ended:
            // Over, but the log never said how: a hollow node rather than the
            // filled "done" dot or the orange "unfinished" mark. See
            // ``ConversationTurn/isEndInferred``.
            Circle()
                .strokeBorder(Color.secondary.opacity(0.8), lineWidth: 1.5)
                .frame(width: 9, height: 9)
                .overlay {
                    Circle().strokeBorder(Theme.sidebarBackground, lineWidth: 2).padding(-2)
                }
                .scaleEffect(onScreen ? 1.25 : 1)
        case .unfinished:
            Image(systemName: "exclamationmark")
                .font(.system(size: 8, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 13, height: 13)
                .background(Theme.waiting, in: Circle())
        }
    }

    private var meta: some View {
        HStack(spacing: 6) {
            Text(verbatim: "#\(number)")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(turn.state.tint)
            if let spent {
                Text(TurnIndexFormat.spell(spent))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            if let steps = turn.stepCount, steps > 0 {
                Text("\(steps) steps")
            }
            if let began = turn.beganAt {
                Text(began, format: .dateTime.hour().minute())
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }

    /// As long as the turn took, against the longest turn in the session.
    private var bar: some View {
        GeometryReader { geometry in
            let share = min(1, max(0.02, (spent ?? 0) / longest))
            Capsule()
                .fill(turn.state.tint.opacity(turn.state == .running ? 0.7 : 0.45).gradient)
                .frame(width: grown ? geometry.size.width * share : 0, height: 3)
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }
}

enum TurnIndexFormat {
    /// "48 s", "3 min 12 s", "1 h 4 min".
    static func spell(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return String(format: String(localized: "%lld s"), total) }
        if total < 3600 { return String(format: String(localized: "%lld min %lld s"), total / 60, total % 60) }
        return String(format: String(localized: "%lld h %lld min"), total / 3600, (total % 3600) / 60)
    }
}

// MARK: - The iPad rail

/// The index, folded down to a rail of ticks at the conversation's edge.
///
/// For an iPad with the index column put away: one tick per turn, coloured by
/// how it went, with the turns on screen lit. Run a finger -- or the pointer --
/// down it and a callout names the turn under it, with a tick of haptics as it
/// passes each one; let go, or click, and the conversation goes there.
struct TurnRail: View {
    @Environment(TurnIndex.self) private var index
    @State private var hovered: Int?
    @State private var scrubbing = false

    private static let tickHeight: CGFloat = 4
    private static let spacing: CGFloat = 5

    var body: some View {
        let turns = index.turns
        if turns.count > 1 {
            GeometryReader { geometry in
                let height = min(geometry.size.height, CGFloat(turns.count) * (Self.tickHeight + Self.spacing) + 20)
                ZStack(alignment: .trailing) {
                    if let hovered, turns.indices.contains(hovered) {
                        callout(for: turns[hovered], number: turns[hovered].turn ?? hovered + 1)
                            .offset(x: -30, y: tickY(hovered, count: turns.count, height: height) - height / 2)
                            .transition(.pop)
                    }
                    ticks(turns, height: height)
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .trailing)
            }
            .frame(width: 280)
            .animation(.mizarSnappy, value: hovered)
        }
    }

    private func ticks(_ turns: [ConversationTurn], height: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(turns.enumerated()), id: \.element.id) { offset, turn in
                let on = index.visible.contains(turn.id)
                Capsule()
                    .fill(on ? Color.accentColor : turn.state.tint.opacity(turn.state == .done ? 0.35 : 0.8))
                    .frame(width: hovered == offset ? 18 : (on ? 13 : 8), height: Self.tickHeight)
                    .frame(maxHeight: .infinity, alignment: .center)
                    .frame(width: 22, alignment: .trailing)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .frame(height: height)
        .glassEffect(.regular.interactive(), in: Capsule())
        .contentShape(.capsule)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    scrubbing = true
                    hovered = tickIndex(at: value.location.y, count: turns.count, height: height)
                }
                .onEnded { value in
                    let picked = tickIndex(at: value.location.y, count: turns.count, height: height)
                    if turns.indices.contains(picked) { index.jump(to: turns[picked].id) }
                    scrubbing = false
                    hovered = nil
                },
        )
        .onContinuousHover { phase in
            guard !scrubbing else { return }
            switch phase {
            case .active(let location):
                hovered = tickIndex(at: location.y, count: turns.count, height: height)
            case .ended:
                hovered = nil
            }
        }
        .mizarFeedback(.selection, trigger: hovered) { _, new in new != nil && scrubbing }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Turns"))
        .accessibilityValue(Text("\(turns.count)"))
        .accessibilityIdentifier("turnIndex.rail")
    }

    private func tickIndex(at y: CGFloat, count: Int, height: CGFloat) -> Int {
        let usable = max(1, height - 20)
        let fraction = min(0.999, max(0, (y - 10) / usable))
        return Int(fraction * CGFloat(count))
    }

    private func tickY(_ offset: Int, count: Int, height: CGFloat) -> CGFloat {
        let usable = height - 20
        return 10 + usable * (CGFloat(offset) + 0.5) / CGFloat(max(1, count))
    }

    private func callout(for turn: ConversationTurn, number: Int) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: "#\(number)")
                .font(.caption.monospacedDigit().weight(.bold))
                .foregroundStyle(turn.state.tint)
            Text(turn.promptLine ?? String(format: String(localized: "Turn %lld"), number))
                .font(.subheadline)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .frame(maxWidth: 240, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .liquidCapsule()
        .allowsHitTesting(false)
    }
}
