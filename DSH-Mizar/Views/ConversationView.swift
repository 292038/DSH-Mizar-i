//
//  ConversationView.swift
//  DSH-Mizar
//
//  What was said, and how long the agent took over it.
//
//  Two voices, drawn differently on purpose. The operator's words are a bubble
//  in the accent, on the right: short, theirs, and easy to find when scrolling
//  back for "what did I ask". The agent's answer is not a bubble at all -- it is
//  the page, full width, set like text to be read, because that is what it is:
//  long, structured, and the reason the screen exists.
//
//  A turn is drawn, not folded. The host sends a *summary* of each turn -- the
//  prompt, the turn's markers, and the model's last message -- with the per-step
//  narration left out entirely, so there is nothing to expand: the row says how
//  it went and the answer sits under it.
//
//  A failed turn gets the most prominent treatment of anything here. It is the
//  one state where the agent looks busy and is in fact doing nothing.
//

import SwiftUI
import MizarKit

struct ConversationView: View {
    /// The session on screen. Needed by the running-turn row: the paid
    /// full-detail feed is read per session, and a view that only held the
    /// conversation could not ask for it.
    let sessionId: String
    let items: [ConversationItem]
    /// The conversation grouped into turns. Empty when the host sent no turn
    /// numbers, in which case the flat list is drawn instead.
    var turns: [ConversationTurn] = []
    /// A turn to draw on its own, while a long jump to it is being staged.
    ///
    /// The conversation is lazy: a row a few screens away has been thrown away,
    /// and a row that has been thrown away has no frame for `scrollTo` to aim
    /// at. Drawing just the turn asked for -- at the top of the content, where a
    /// lazy stack always builds -- is what puts it back in the hierarchy long
    /// enough for the scroll to find it. See
    /// `SessionDetailView/jump(to:proxy:)`.
    var stagedTurn: String?
    let loading: Bool
    /// Why the conversation is empty, when it is empty because the read failed.
    var failure: String?
    /// Called when the top of the conversation comes into view, to fetch what
    /// came before.
    ///
    /// `nil` means the question could not be asked right now -- no connection
    /// yet, the cache not written yet, a page already in flight. `0` means the
    /// host was asked and has nothing older. The distinction is the whole point:
    /// the two were conflated, so a single badly-timed attempt ended the list
    /// permanently.
    var onLoadOlder: (() async -> Int?)?

    @State private var loadingOlder = false
    @State private var exhausted = false
    /// Pages fetched automatically since this row came on screen.
    ///
    /// The sentinel sits at the very top of the log and older messages are
    /// inserted *below* it, so it never leaves the screen and never re-appears.
    /// Re-driving on `items.count` keeps it asking, and the counter is what
    /// stops it from draining a fifty-page history in one go while the operator
    /// is looking at the top of it.
    @State private var automaticPages = 0
    private static let automaticPageLimit = 3
    /// Below the last row, and where the view scrolls on open.
    static let bottomAnchor = "conversation.bottom"

    /// Ask for the page before this one, once.
    private func fetchOlder(_ fetch: () async -> Int?, automatic: Bool = false) async {
        guard !loadingOlder else { return }
        if automatic, automaticPages >= Self.automaticPageLimit { return }
        if automatic { automaticPages += 1 }
        loadingOlder = true
        let arrived = await fetch()
        // Only a definite answer ends the list. `nil` leaves `exhausted` alone
        // so the next appearance -- or the operator's tap -- asks again.
        if arrived == 0 { exhausted = true }
        loadingOlder = false
    }

    /// What is drawn while a jump is staged: the turn asked for, first, and the
    /// couple after it.
    ///
    /// First, because a lazy stack builds what the content *starts* with
    /// whatever the scroll offset is -- and that row has to exist before it can
    /// be scrolled to. The couple after it come along so that flipping on down
    /// from the turn is as immediate as flipping down from anywhere else. The
    /// turns *before* it cannot come with it: they would push it off the top of
    /// a content that begins where the operator is going, and they arrive a
    /// frame later with the rest of the conversation.
    private var staged: [ConversationTurn] {
        guard let stagedTurn,
              let start = turns.firstIndex(where: { $0.id == stagedTurn })
        else { return [] }
        return Array(turns[start...min(turns.count - 1, start + 2)])
    }

    /// The turns actually drawn: the conversation, or the staged window when
    /// there is one.
    private var drawnTurns: [ConversationTurn] {
        staged.isEmpty ? turns : staged
    }

    var body: some View {
        // Lazy, not eager: a conversation can hold hundreds of items.
        LazyVStack(alignment: .leading, spacing: 14) {
            // Not while a jump is staged: the row sits at the very top and
            // would ask for a page of history the screen is in the middle of
            // leaving.
            if !exhausted, let onLoadOlder, !items.isEmpty, staged.isEmpty {
                loadOlderRow(onLoadOlder)
            }

            if loading && items.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
            } else if items.isEmpty, let failure {
                // Not "this session has no messages": that is a statement about
                // the operator's session, made out of a request that never came
                // back -- and on a phone that is ordinary.
                ContentUnavailableView {
                    Label("Could not load the conversation", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(failure)
                }
                .transition(.rise)
            } else if items.isEmpty {
                ContentUnavailableView(
                    "Nothing yet",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("This session has no messages."),
                )
                .transition(.rise)
            } else if turns.isEmpty {
                ForEach(items) { item in
                    ConversationRow(item: item, isLastPrompt: false)
                        .transition(.rise)
                }
            } else {
                // One list either way, narrowed to the staged turn while a jump
                // is playing: the same `ForEach` with the same identities, so
                // the row being jumped to is *kept* across the swap rather than
                // destroyed and built again.
                ForEach(drawnTurns) { turn in
                    TurnSection(turn: turn, sessionId: sessionId)
                        .transition(.rise)
                }
            }

            // Where the view scrolls to on open.
            Color.clear
                .frame(height: 1)
                .id(Self.bottomAnchor)
        }
    }

    /// The top of the list, where older messages arrive.
    ///
    /// Always a visible row, never a bare spinner: a spinner whose appearance
    /// was the only trigger went quiet for good the first time it returned
    /// without fetching. A row that can be tapped cannot fail that way.
    private func loadOlderRow(_ onLoadOlder: @escaping () async -> Int?) -> some View {
        Button {
            Task { await fetchOlder(onLoadOlder) }
        } label: {
            HStack(spacing: 6) {
                if loadingOlder {
                    ProgressView().controlSize(.mini)
                        .transition(.pop)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.caption2.weight(.bold))
                        .transition(.pop)
                }
                Text("Load earlier messages")
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .liquidCapsule(interactive: true)
            .animation(.mizarSnappy, value: loadingOlder)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("conversation.loadOlder")
        // Keyed on the item count, not on appearance: older messages arrive
        // below this row, so it never disappears and `onAppear` would fire
        // exactly once. Each page changes the count, so each page re-arms it.
        .task(id: items.count) {
            await fetchOlder(onLoadOlder, automatic: true)
        }
        .onDisappear {
            // Scrolled away. Someone who comes back to the top is asking again,
            // and the automatic allowance should be theirs.
            automaticPages = 0
        }
    }
}

/// One turn: the prompt, the row that says how it is going, and the answer.
private struct TurnSection: View {
    let turn: ConversationTurn
    /// The session this turn belongs to, for the paid activity feed.
    let sessionId: String
    @Environment(TurnIndex.self) private var index

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(turn.prompts.enumerated()), id: \.element.id) { index, item in
                ConversationRow(item: item, isLastPrompt: index == turn.prompts.count - 1)
            }

            // Prompt, row, answer -- and the row does not move. The answer was
            // once drawn above the row and once hidden inside it; both made the
            // row jump or hid the one thing a monitoring app must show. The paid
            // full-detail area is added *below* the row for the same reason:
            // opening it must never move or replace the status row.
            TurnActivitySummary(turn: turn, sessionId: sessionId)

            ForEach(turn.steps) { item in
                ConversationRow(item: item, isLastPrompt: false)
                    .transition(.rise(distance: 14, blur: 6))
            }
        }
        .animation(.mizarSmooth, value: turn.steps.count)
        // Arrived at from the index: a soft light behind the turn, once.
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .fill(Color.accentColor.opacity(index.glowing == turn.id ? 0.1 : 0))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(index.glowing == turn.id ? 0.35 : 0), lineWidth: 1)
                }
                .padding(.horizontal, -10)
                .padding(.vertical, -8)
                .allowsHitTesting(false)
        }
        // Which turns are on screen, for the index's "you are here" -- and
        // which ones the conversation has built at all. The two differ: a row
        // scrolled far enough away is destroyed, and the index asks before it
        // tries to scroll to one, because a scroll to a row that no longer
        // exists goes nowhere. See ``TurnIndex/travels(to:)``.
        .onAppear { index.setRealized(turn.id, true) }
        .onScrollVisibilityChange(threshold: 0.25) { visible in
            index.setVisible(turn.id, visible)
        }
        .onDisappear {
            index.setVisible(turn.id, false)
            index.setRealized(turn.id, false)
        }
    }
}

/// "DeepSeeking for 2 min 14 s", "Completed in 2 min 14 s", or why it did not.
private struct TurnSummary: View {
    let turn: ConversationTurn
    /// Whether the row offers the paid detail, so a chevron shows that there is
    /// more behind it. Off for free accounts and for turns with no detail.
    var showsChevron = false
    /// Which way the chevron points, and where the detail is going.
    var expanded = false

    var body: some View {
        HStack(spacing: 7) {
            // The state, as a glyph that changes rather than appears: the twin
            // star while it works, settling into a tick when it is done.
            ZStack {
                if turn.isRunning {
                    TwinStar(size: 13)
                        .transition(.pop)
                } else if turn.isEndInferred {
                    // A later turn proves this one is over, but the log never
                    // said how. A hollow tick rather than a filled one: the row
                    // may not claim a completion the host did not report.
                    Image(systemName: "checkmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .symbolRenderingMode(.hierarchical)
                        .transition(.pop)
                } else {
                    Image(systemName: turn.failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(turn.failed ? Theme.waiting : Theme.running)
                        .symbolRenderingMode(.hierarchical)
                        .transition(.pop)
                }
            }
            .frame(width: 16, height: 16)

            headline
            Spacer(minLength: 8)
            // Only when the log actually said. A turn whose markers were trimmed
            // away by the pager shows no number rather than a zero it would be
            // counted as -- "no steps" is a claim this row cannot make.
            if let stepCount = turn.stepCount, stepCount > 0 {
                Text("\(stepCount) steps")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .contentTransition(.numericText())
            }
            if showsChevron {
                // A chevron that turns rather than swaps: the row is the same
                // row open and shut, and the glyph saying so should be the same
                // glyph. Rotated, not replaced, so no second element appears.
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .animation(.mizarSnappy, value: expanded)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
        .animation(.mizarBouncy, value: turn.isRunning)
        .animation(.mizarSnappy, value: turn.stepCount)
        // One small tap when a turn the operator is watching finishes. Only on
        // the change, never on the first draw of a finished turn -- and never
        // for a turn settled from a missing record, which nobody just watched.
        .mizarFeedback(.success, trigger: turn.isRunning) { old, new in
            old && !new && !turn.failed && !turn.isEndInferred
        }
    }

    /// The state of the turn, and for a running one a clock that moves.
    ///
    /// One `Text` -- the headline is the row's whole statement, and it is read
    /// as one sentence. Ticked locally rather than by asking the computer: the host
    /// already said when the turn started.
    @ViewBuilder private var headline: some View {
        if turn.isRunning, turn.beganAt != nil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                // Through `elapsed(asOf:)`, which clamps at zero: the start came
                // off the host's clock and `context.date` is the phone's.
                let running = turn.elapsed(asOf: context.date) ?? 0
                Text(String(format: String(localized: "DeepSeeking for %@"), Self.spell(running)))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText(countsDown: false))
                    .animation(.mizarSnappy, value: Int(running))
                    .shimmering()
            }
        } else {
            Text(staticHeadline)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .contentTransition(.interpolate)
        }
    }

    /// The headline for a turn whose text does not change.
    private var staticHeadline: String {
        // A turn with a number and no end is running; this case is reached when
        // it also has no start to measure from.
        if turn.isRunning { return String(localized: "DeepSeeking") }
        // A turn whose end record never arrived, but which a later turn proves
        // is over. No duration: the end this row was given is an upper bound,
        // not a measurement, and a figure here would read as one.
        if turn.isEndInferred { return String(localized: "Ended") }
        if turn.failed {
            return turn.duration.map {
                String(format: String(localized: "Unfinished after %@"), Self.spell($0))
            } ?? String(localized: "Unfinished")
        }
        return turn.duration.map {
            String(format: String(localized: "Completed in %@"), Self.spell($0))
        } ?? String(localized: "Completed")
    }

    /// Minutes and seconds, because that is the unit a turn is measured in.
    static func spell(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return String(format: String(localized: "%lld s"), total) }
        return String(format: String(localized: "%lld min %lld s"), total / 60, total % 60)
    }
}

/// The running-turn row and, when the advanced feature set is available, its
/// expandable detail.
///
/// This is the one place the full-detail feed meets the screen. It decides what
/// the feature set may see, polls while the turn is running, and renders the
/// detail below the summary row — never in place of it. The summary row is the
/// only thing on this screen that must not move while a turn is in flight: it is
/// where the operator reads "how long has this been going", and opening a detail
/// under it is fine while moving or replacing it is not.
///
/// Locked accounts take the else branch and never start the poll: ``AppModel``
/// refuses the read too, so there are two independent guards against a paid-only
/// method being called without the feature set. A direct link on the operator's
/// own network unlocks the set without a plan: the relay is not carrying that
/// traffic, and the full transfer is exactly the detail the plan is sold for.
private struct TurnActivitySummary: View {
    let turn: ConversationTurn
    let sessionId: String

    @Environment(AppModel.self) private var model
    /// Whether the detail is out. Reset when the turn ends, because there is
    /// nothing left for it to describe.
    @State private var expanded = false

    /// The details for this session, when there are any to show.
    private var entries: [ActivityEntry] {
        // Touch the observable revision before the method read, so the row
        // re-evaluates when the first activity answer lands.
        _ = model.activityRevision
        return model.activity(for: sessionId)?.entries ?? []
    }

    /// Whether the chevron and the detail exist at all.
    ///
    /// All three conditions are about the same idea: the advanced feature set, a
    /// turn that is running, and at least one detail worth opening. A chevron
    /// that opens an empty area is worse than no chevron.
    private var canExpand: Bool {
        turn.isRunning && model.advancedFeaturesUnlocked && !entries.isEmpty
    }

    /// What the poll is keyed on: it runs while this turn is running and the
    /// advanced feature set is available, and stops — clearing what it found —
    /// the moment either stops being true. `.task(id:)` cancels and restarts on
    /// a change, which is exactly the lifecycle wanted here. The set is lost on a
    /// route change away from the LAN just as it is on a plan ending, and the
    /// same change stops the poll in both cases.
    private var pollKey: String? {
        guard turn.isRunning, model.advancedFeaturesUnlocked else { return nil }
        return "\(turn.turn ?? -1)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row
            if expanded, canExpand {
                TurnActivityDetail(entries: entries)
                    .padding(.top, 8)
                    // In from under the row and up under it again on the way
                    // out: the detail belongs to the row, and leaving should
                    // look like going back where it came from.
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity.combined(with: .move(edge: .top)),
                    ))
            }
        }
        .animation(.mizarSmooth, value: expanded)
        .task(id: pollKey) { await poll() }
        .onChange(of: pollKey) { oldKey, newKey in
            // This turn was the one polling, and it is not any more: it ended,
            // the advanced feature set stopped being available, or the view went
            // away. Only this view clears the cache -- a finished turn must not,
            // because the list builds old rows as it scrolls and each of them
            // would wipe the running turn's detail under the operator.
            if oldKey != nil, newKey == nil {
                model.clearActivity(for: sessionId)
            }
        }
        .onChange(of: canExpand) { _, canExpand in
            // The turn ended, or the feature set did. Collapse, so a shut turn
            // cannot leave a detail area floating under a finished row.
            if !canExpand, expanded {
                withAnimation(.mizarSmooth) { expanded = false }
            }
        }
        .onDisappear {
            // Scrolled away or navigated away while it was the running turn: the
            // next appearance starts from a fresh read rather than from a
            // minute-old set of lines. A finished turn's row says nothing here.
            if turn.isRunning {
                model.clearActivity(for: sessionId)
            }
        }
    }

    /// The row itself: a button when there is something to open, plain otherwise.
    ///
    /// A button only for an unlocked running turn with detail. The row's own content
    /// is unchanged in both branches — same glyph, same clock, same count — so a
    /// turn does not look different merely because somebody subscribed.
    @ViewBuilder private var row: some View {
        if canExpand {
            Button {
                withAnimation(.mizarBouncy) { expanded.toggle() }
            } label: {
                TurnSummary(turn: turn, showsChevron: true, expanded: expanded)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("turn.\(turn.id)")
            .accessibilityLabel(expanded
                ? String(localized: "Hide turn details")
                : String(localized: "Show turn details"))
        } else {
            TurnSummary(turn: turn)
                .accessibilityIdentifier("turn.\(turn.id)")
        }
    }

    /// Read the details while the turn runs.
    ///
    /// Every second while the running row is on screen. The detail feed is the
    /// full-transfer view (paid, or open on a LAN link) and a command's output
    /// needs to land while it is still the thing being talked about; one second is the cadence the host's
    /// 256 KiB capped answer was sized for. A failed read changes nothing —
    /// ``AppModel/refreshActivity(for:)`` keeps the last answer on screen.
    private func poll() async {
        // A finished turn has nothing to read, and clearing is not this view's
        // job when it never started: the change that stopped it clears.
        guard pollKey != nil else { return }
        while !Task.isCancelled {
            await model.refreshActivity(for: sessionId)
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
        }
    }
}

/// One item, drawn by kind.
private struct ConversationRow: View {
    let item: ConversationItem
    /// Whether this is the last of the operator's messages before the agent
    /// answers, which is the bubble that carries the tail.
    let isLastPrompt: Bool

    var body: some View {
        switch item {
        case .message(_, .user, let text, _):
            UserBubble(text: text, tail: isLastPrompt)
        case .message(_, .assistant, let text, _):
            AgentText(text: text)
        case .message(_, .system, let text, _):
            SystemNote(text: text)
        case .failure(_, let message, let at):
            FailureCard(message: message, at: at)
        }
    }
}

// MARK: - Messages

/// Whether a message body is worth drawing as blocks.
///
/// Cheap and deliberately narrow: a false negative shows backticks, a false
/// positive costs one parse. The line-anchored markers are checked per line
/// rather than by substring -- `"\n# "` never matched a body that *was* a
/// heading, which is the common case of a short reply.
enum MessageMarkdown {
    static func looksLikeMarkdown(_ text: String) -> Bool {
        if text.contains("**") || text.contains("`") || text.contains("](") || text.contains("|") {
            return true
        }
        return text.split(separator: "\n", omittingEmptySubsequences: true).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") || trimmed.hasPrefix("> ") || trimmed.hasPrefix("```") {
                return true
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                return true
            }
            return trimmed.range(of: #"^\d{1,3}[.)]\s"#, options: .regularExpression) != nil
        }
    }
}

/// Selectable text: blocks when the body is Markdown, one run of text otherwise.
///
/// The block form carries the raw text as its accessibility label, so what
/// VoiceOver reads -- and what a test finds -- is what was said, not the
/// rendering of it.
private struct MessageText: View {
    let text: String

    var body: some View {
        if MessageMarkdown.looksLikeMarkdown(text) {
            MarkdownMessage(text)
        } else {
            Text(text)
                .textSelection(.enabled)
        }
    }
}

/// The operator's words.
private struct UserBubble: View {
    let text: String
    /// Whether the corner nearest the answer tightens, the quiet tail that says
    /// "this is the message that was answered".
    let tail: Bool

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 56)
            MessageText(text: text)
                .foregroundStyle(Theme.onAccent)
                .tint(Theme.onAccent)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background {
                    UnevenRoundedRectangle(
                        topLeadingRadius: Theme.Radius.lg,
                        bottomLeadingRadius: Theme.Radius.lg,
                        bottomTrailingRadius: tail ? 6 : Theme.Radius.lg,
                        topTrailingRadius: Theme.Radius.lg,
                        style: .continuous,
                    )
                    .fill(Color.accentColor.gradient)
                }
        }
    }
}

/// The agent's answer: the page, not a bubble.
private struct AgentText: View {
    let text: String

    var body: some View {
        MessageText(text: text)
            .font(.body)
            .lineSpacing(4)
            .foregroundStyle(.primary)
            // A readable measure on a wide screen; edge to edge on a phone.
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
    }
}

/// What the system said, as an aside.
private struct SystemNote: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("system")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            MessageText(text: text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
    }
}

/// A turn that produced nothing.
private struct FailureCard: View {
    let message: String
    /// When the turn failed. Only a failure that just happened shakes: one
    /// scrolled back into view is news nobody needs announced twice.
    let at: Date
    @State private var shakes = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("The turn ended without a response", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.failed)
            Text(message)
                .font(.caption)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.failed.opacity(0.09), in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .strokeBorder(Theme.failed.opacity(0.28), lineWidth: 1)
        }
        // A small shake when it first comes on screen: two swings of four points,
        // the "no" of a head being shaken. Still under Reduce Motion.
        .keyframeAnimator(initialValue: CGFloat(0), trigger: shakes) { content, x in
            content.offset(x: x)
        } keyframes: { _ in
            KeyframeTrack {
                CubicKeyframe(4, duration: 0.07)
                CubicKeyframe(-4, duration: 0.1)
                CubicKeyframe(3, duration: 0.1)
                CubicKeyframe(-2, duration: 0.09)
                CubicKeyframe(0, duration: 0.09)
            }
        }
        .onAppear {
            guard !Motion.reduced, Date().timeIntervalSince(at) < 20 else { return }
            shakes += 1
        }
    }
}

// MARK: - Shimmer

extension View {
    /// A band of light sweeping across, for text that is still being worked on.
    ///
    /// Drawn over the content and masked by it, so the content itself -- and
    /// what it says to VoiceOver -- is untouched.
    func shimmering(active: Bool = true) -> some View {
        modifier(Shimmer(active: active))
    }
}

private struct Shimmer: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if active && !reduceMotion {
            content
                .overlay {
                    GeometryReader { geometry in
                        let width = geometry.size.width
                        LinearGradient(
                            colors: [.clear, Color.accentColor.opacity(0.95), .white.opacity(0.9), Color.accentColor.opacity(0.95), .clear],
                            startPoint: .leading,
                            endPoint: .trailing,
                        )
                        .frame(width: max(40, width * 0.45))
                        .keyframeAnimator(initialValue: CGFloat(0), repeating: true) { band, phase in
                            band.offset(x: -width * 0.45 + phase * width * 1.45)
                        } keyframes: { _ in
                            CubicKeyframe(1, duration: 1.6)
                            LinearKeyframe(1, duration: 0.6)
                        }
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
        } else {
            content
        }
    }
}
