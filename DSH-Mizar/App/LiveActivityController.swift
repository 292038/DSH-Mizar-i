//
//  LiveActivityController.swift
//  DSH-Mizar
//
//  The island, driven from this side of the wall.
//
//  Everything about *what* the activity shows was decided in `MizarKit` before
//  this file existed: `LiveActivityDecision.make` reads the running sessions and
//  answers with a phase and whether the activity should come down. This file
//  does three things and no fourth:
//
//    - **Derives the running sessions from what the app already knows.** A row in
//      `session.list` says a session is running; the app's own conversation cache
//      says what the operator asked it and when the turn began. No request is
//      made for any of it -- the island is a display of what the phone has, and a
//      display that only updates when the network answers is a display that stops
//      exactly when the Mac is busy.
//
//    - **Asks the decision layer**, with the one flag it owns.
//
//    - **Makes the activity match**: `Activity.request` when there is none,
//      `Activity.update` when there is, `Activity.end` when the decision says so
//      -- and nothing at all when the operator has switched the feature off.
//
//  The ActivityKit calls themselves live in ``ActivityCalls`` at the bottom of
//  the file, and the split is not tidiness. `Activity` is not `Sendable` and its
//  `update`/`end` are nonisolated `async`, so a reference held by a main-actor
//  object cannot be handed to them: Swift 6's region checker refuses, correctly,
//  because the class could then be touched from two places at once. The
//  activities are therefore looked up *inside* those functions and never leave
//  them; what comes back is a line for the log.
//
//  ## Where an activity may be started from
//
//  Apple's rule is that a Live Activity is started from the **foreground**, and
//  that updating and ending one may happen in the background. The interesting
//  case for this app is a sync that finishes while the app is off screen: the
//  process is still alive for a moment, the conversation cache has just been
//  rewritten with a fresh figure and a new running turn, and the island is
//  exactly where the operator would want to see it.
//
//  So the request is made, whatever the app's state, and the answer is written to
//  the log *with the state the app was in when it asked* -- `.live` lines read
//  `started …; the app was background`. Nothing is pretended either way: if the
//  system refuses a background start, the failure is recorded, and the next
//  foreground refreshes, finds no activity and asks again. That is why there is
//  no retry queue here and no "start owed" flag: the foreground refresh *is* the
//  retry.
//
//  ## The flag
//
//  `appOpenedSinceLastFinish` is the caller's half of the decision layer's
//  contract. It is set when the operator opens the app, and cleared when a
//  dismissal has been acted on. It is *also* cleared when a running phase is
//  applied, and that is worth stating plainly because it is the case the
//  contract's prose implies rather than spells out: the flag means "the operator
//  has opened the app **since the last running session ended**", and the moment a
//  session is running again, that sentence is no longer true of the opening that
//  set the flag. Left set, it would take that session down the instant it
//  finished -- the check nobody ever saw, which is the failure the decision
//  layer's own documentation warns about.
//

import ActivityKit
import Foundation
import MizarKit
import UIKit

/// Starts, updates and ends this app's Live Activity.
///
/// `@MainActor` because the app's state is: it reads `sessions` and the settings
/// object, which are main-actor values, and it is called from the same places
/// the rest of the app's state is changed.
@MainActor
final class LiveActivityController {
    /// What the operator has switched on. Read at every decision, never copied:
    /// the switch has to be able to say no to an activity that is already up.
    private let settings: AppSettings
    /// Where every attempt is written down, including the ones that failed and
    /// the app state they failed in.
    private let log: ActivityLog

    /// Whether the operator has opened the app since the last running session
    /// ended, and the activity has not been taken down for it yet.
    private var appOpenedSinceLastFinish = false

    /// - Parameters:
    ///   - settings: the live copy of the operator's switches.
    ///   - log: the app's activity log.
    init(settings: AppSettings = .shared, log: ActivityLog = .shared) {
        self.settings = settings
        self.log = log
    }

    // MARK: - What the app tells this object

    /// The operator has opened the app.
    ///
    /// Only the flag, with no decision taken: at launch the session list has not
    /// been read yet, and "nothing is running" must not be confused with "nothing
    /// has been read". The refresh that can act on the flag arrives with the
    /// session list, milliseconds later.
    func appOpened() {
        appOpenedSinceLastFinish = true
    }

    /// The operator is looking at the app, and the app knows what is running.
    ///
    /// - Parameters:
    ///   - sessions: the session list as the host last gave it.
    ///   - conversations: where the prompts and the running turns are kept.
    func appOpened(sessions: [SessionRow], conversations: any ConversationCache) async {
        appOpened()
        await refresh(sessions: sessions, conversations: conversations)
    }

    /// Read what the app knows, decide, and make the activity match.
    ///
    /// Called after the session list arrives, after a conversation is folded into
    /// the cache, after a full sync, when the app comes to the foreground, and
    /// when the switch moves. Cheap enough to be called all of those times: it
    /// reads the local cache, and it asks ActivityKit for the state of the world
    /// rather than keeping a copy of it.
    ///
    /// - Parameters:
    ///   - sessions: the session list as the host last gave it.
    ///   - conversations: where the prompts and the running turns are kept.
    ///   - now: the instant to measure the clocks to.
    func refresh(
        sessions: [SessionRow],
        conversations: any ConversationCache,
        now: Date = Date(),
    ) async {
        let running = await runningSessions(in: sessions, conversations: conversations, now: now)
        let decision = LiveActivityDecision.make(
            sessions: running,
            appOpenedSinceLastFinish: appOpenedSinceLastFinish,
            now: now,
        )
        await apply(decision, runningRowCount: running.count)
    }

    // MARK: - Making the island match

    /// Carry out one decision.
    ///
    /// - Parameters:
    ///   - decision: what to show, and whether to take the activity down.
    ///   - runningRowCount: how many sessions the decision was made from, for the
    ///     log only.
    private func apply(_ decision: LiveActivityDecision, runningRowCount: Int) async {
        // The switch first, before anything else looks at the decision. "Off"
        // has to mean off in the strong sense -- an activity already on screen is
        // the thing the operator was turning off -- and it is read here rather
        // than when the activity started, because a copy taken then is a switch
        // that only takes effect at the next launch.
        guard settings.values.liveActivitiesEnabled else {
            appOpenedSinceLastFinish = false
            guard ActivityCalls.hasPresentable else { return }
            log.add(.live, await ActivityCalls.endAll(with: decision.phase, why: "the operator switched it off"))
            return
        }

        if decision.shouldDismiss {
            appOpenedSinceLastFinish = false
            guard ActivityCalls.hasPresentable else { return }
            log.add(.live, await ActivityCalls.endAll(with: decision.phase, why: "the app was opened after everything finished"))
            return
        }

        switch decision.phase {
        case .finished:
            // Never *started* from here: a check for work that stopped before the
            // activity existed is not worth a second look, and the decision layer
            // says so. Updating what is already up is the other half of that rule
            // -- without it the check would never reach the island, because the
            // app has nothing else to send.
            if let line = await ActivityCalls.update(to: decision.phase) { log.add(.live, line) }

        case .running:
            // See the note at the top of the file: a session is running again, so
            // the opening the flag records is no longer "since the last finish".
            appOpenedSinceLastFinish = false
            // The app state is read here, next to the call, because it is the
            // measurement: whether a background start works is not something the
            // documentation settles, and this word in the log is the answer.
            let state = appStateWord
            guard ActivityCalls.hasPresentable else {
                log.add(.live, await ActivityCalls.start(decision.phase, appState: state, runningRowCount: runningRowCount))
                return
            }
            if let line = await ActivityCalls.update(to: decision.phase) { log.add(.live, line) }
        }
    }

    // MARK: - What the app already knows

    /// The running sessions, as the island needs them.
    ///
    /// One per session whose row says it is running, with the operator's most
    /// recent instruction to it and the figure the running turn's own row is
    /// drawn from -- `ConversationTurn.elapsed(asOf:)`, which is the clock behind
    /// "深度求索中，用时 xx 分 xx 秒".
    ///
    /// Two deliberate omissions, both of them things the app cannot answer:
    ///
    ///   - **Subagents are left out.** Their rows say `running` too, but the app
    ///     never syncs a subagent's conversation (`syncAllConversations` fetches
    ///     top-level sessions only), so a subagent has no prompt and no start
    ///     time here. It would arrive on the island as a row reading "0:03" for
    ///     work that has been going for ten minutes, and -- because the decision
    ///     layer keeps the two longest-running rows -- it could push the session
    ///     the operator is actually watching off the card.
    ///   - **A session with nothing cached is seeded at zero.** The row says it is
    ///     running and the phone has not fetched its page yet, so there is no
    ///     figure to seed from; `RunningSession` says what to do about that, and
    ///     counting from the moment the app saw it is that answer.
    ///
    /// - Parameters:
    ///   - sessions: the session list as the host last gave it.
    ///   - conversations: the cache the prompts are read from.
    ///   - now: the instant the figures are measured to, and the instant they are
    ///     seeded from.
    /// - Returns: the sessions to hand to the decision layer.
    private func runningSessions(
        in sessions: [SessionRow],
        conversations: any ConversationCache,
        now: Date,
    ) async -> [RunningSession] {
        var out: [RunningSession] = []
        for row in sessions where row.running && row.parentSessionId == nil {
            let cached = await conversations.load(sessionId: row.sessionId)
            let turn = cached?.turns?.last { $0.isRunning }
            out.append(
                RunningSession(
                    id: row.sessionId,
                    prompt: prompt(of: turn, in: cached) ?? "",
                    elapsedWhenSeeded: turn?.elapsed(asOf: now) ?? 0,
                    seededAt: now,
                ),
            )
        }
        return out
    }

    /// The operator's most recent instruction to a session.
    ///
    /// The running turn's last prompt, and when the cache holds no running turn
    /// -- a session that started since the last sync, whose `turn/start` is in a
    /// page the phone has not fetched -- the last thing the operator said in the
    /// conversation the phone does have. Both are their own words; nothing here
    /// makes one up. `nil` when the cache holds neither, and the row then draws a
    /// time and nothing else, which is true.
    ///
    /// - Parameters:
    ///   - turn: the running turn, when the cache has one.
    ///   - cached: the cached conversation.
    /// - Returns: the instruction, or `nil`.
    private func prompt(of turn: ConversationTurn?, in cached: CachedConversation?) -> String? {
        if let asked = turn?.prompts.last?.words { return asked }
        return cached?.items.last { $0.role == .user }?.words
    }

    /// Where the app was when it asked ActivityKit for something.
    private var appStateWord: String {
        switch UIApplication.shared.applicationState {
        case .active: "foreground"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
    }
}

// MARK: - The ActivityKit side

/// Every call this app makes into ActivityKit, off the main actor.
///
/// Static methods on a caseless type rather than methods on the controller, for
/// one reason: nothing here touches the controller's state. Each function looks
/// up the activities itself, works with a `Sendable` phase, and answers with the
/// line to write in the log -- which is what keeps a non-`Sendable` `Activity`
/// from ever being handed across an isolation boundary.
private enum ActivityCalls {
    /// One activity of this app's one type.
    typealias Island = Activity<DSHMizarActivityAttributes>

    /// Whether an activity is on screen.
    ///
    /// A `Bool` rather than the activities themselves: the caller is the main
    /// actor, and the array may not leave here.
    static var hasPresentable: Bool {
        !presentable.isEmpty
    }

    /// The activities that are up right now.
    ///
    /// Filtered by state rather than taken whole: `activities` also returns the
    /// ones that have ended and are waiting to be cleared, and updating one of
    /// those is a request the system answers by ignoring it.
    private static var presentable: [Island] {
        Island.activities.filter { $0.activityState == .active || $0.activityState == .stale }
    }

    /// Ask for a new activity.
    ///
    /// - Parameters:
    ///   - phase: what it should show.
    ///   - appState: where the app was, for the log line.
    ///   - runningRowCount: how many sessions it was built from, for the log line.
    /// - Returns: what to write in the log.
    static func start(_ phase: LiveActivityPhase, appState: String, runningRowCount: Int) async -> String {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            // A different switch from the app's own: this one is iOS Settings >
            // DSH-Mizar > Live Activities. Nothing can be done about it here, and
            // the next refresh will find it in the same state.
            return "not started: Live Activities are off for this app in iOS Settings"
        }
        do {
            let activity = try Island.request(
                attributes: DSHMizarActivityAttributes(),
                content: ActivityContent(state: phase, staleDate: nil),
                pushType: nil,
            )
            return "started \(activity.id.prefix(8)) with \(describe(phase))"
                + " while the app was \(appState)"
        } catch {
            // Apple's rule is that a Live Activity starts in the foreground, so
            // this is the expected answer when a sync finishes while the app is
            // off screen. The app state is in the line because that is the whole
            // question; the next foreground refreshes and asks again.
            return "could not start \(runningRowCount) running session(s) while the app was \(appState): \(describe(error))"
        }
    }

    /// Send every activity what it should be showing.
    ///
    /// Skipped when an activity already says it: the elapsed times move with the
    /// clock rather than with the host, so an update per read would be an update
    /// per read of a number nobody draws. See ``saysTheSame(_:as:)``.
    ///
    /// - Parameter phase: what to show.
    /// - Returns: what to write in the log, or `nil` when there was nothing to do.
    static func update(to phase: LiveActivityPhase) async -> String? {
        let content = ActivityContent(state: phase, staleDate: nil)
        var changed = 0
        for activity in presentable where !saysTheSame(activity, as: phase) {
            await activity.update(content)
            changed += 1
        }
        guard changed > 0 else { return nil }
        return "updated \(changed) activity: \(describe(phase))"
    }

    /// Take every activity of this type down.
    ///
    /// `Activity.activities`, not the presentable ones: an activity that has
    /// already ended is still on the Lock Screen until it is dismissed or the
    /// system clears it four hours later, and `.immediate` is what "the operator
    /// turned this off" and "the app was opened" both mean.
    ///
    /// - Parameters:
    ///   - phase: the state to end with.
    ///   - why: what to write in the log.
    /// - Returns: what to write in the log.
    static func endAll(with phase: LiveActivityPhase, why: String) async -> String {
        let content = ActivityContent(state: phase, staleDate: nil)
        let all = Island.activities
        for activity in all {
            await activity.end(content, dismissalPolicy: .immediate)
        }
        return "ended \(all.count) activity: \(why)"
    }

    /// Whether an activity already says this.
    ///
    /// `elapsed` is left out of the comparison and nothing else is: it is the one
    /// field that moves on its own -- the decision layer measures it to `now`, so
    /// two reads a second apart never produce equal rows -- while `countingSince`,
    /// the instant the widget's own ticking text counts from, is what the island
    /// actually says. A second of tolerance on it, because the figure the app
    /// seeds from arrives with whole-second resolution and the seed moves by a
    /// second on an ordinary sync.
    ///
    /// - Parameters:
    ///   - activity: the activity on screen.
    ///   - phase: what the decision layer says it should show.
    /// - Returns: whether there is nothing to send.
    private static func saysTheSame(_ activity: Island, as phase: LiveActivityPhase) -> Bool {
        switch (activity.content.state, phase) {
        case (.finished, .finished):
            return true
        case (.running(let mine), .running(let theirs)):
            guard mine.count == theirs.count else { return false }
            return zip(mine, theirs).allSatisfy { current, next in
                current.id == next.id
                    && current.prompt == next.prompt
                    && abs(current.countingSince.timeIntervalSince(next.countingSince)) < 1
            }
        default:
            return false
        }
    }

    /// What a phase contains, without the prompts.
    ///
    /// The rows are described by identity: the log is exportable and the
    /// operator's instructions are theirs, while "which session was on the island
    /// and how many rows were there" is the part that explains a wrong card.
    ///
    /// - Parameter phase: the phase.
    /// - Returns: one line.
    private static func describe(_ phase: LiveActivityPhase) -> String {
        switch phase {
        case .finished:
            return "nothing running"
        case .running(let rows):
            let described = rows.map { String($0.id.prefix(8)) }.joined(separator: ", ")
            return "\(rows.count) row(s): \(described)"
        }
    }

    /// An ActivityKit failure, as one line.
    ///
    /// `ActivityAuthorizationError`'s own description is the interesting part --
    /// `denied`, `unsupported`, `targetMaximumExceeded` -- so it is kept rather
    /// than flattened into "could not start".
    ///
    /// - Parameter error: what was thrown.
    /// - Returns: the description.
    private static func describe(_ error: any Error) -> String {
        (error as? ActivityAuthorizationError).map(String.init(describing:)) ?? error.localizedDescription
    }
}

private extension ConversationItem {
    /// The words of a message, and nothing for anything that is not one.
    var words: String? {
        if case .message(_, _, let text, _) = self { return text }
        return nil
    }

    /// Who said it, for the one question this file asks of the flat item list.
    var role: ConversationItem.Role? {
        if case .message(_, let role, _, _) = self { return role }
        return nil
    }
}
