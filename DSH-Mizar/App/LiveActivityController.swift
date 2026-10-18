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
//      exactly when the computer is busy. The reading itself lives in
//      `RunningSession.running(in:conversations:titles:now:)`, shared with the
//      background refresh so the two cannot disagree about which row is up. The
//      title is not in `session.list`; it arrives with the usage frame, and this
//      file is where the app's title list is joined to the running sessions.
//
//    - **Asks the decision layer**, with the one flag it owns.
//
//    - **Makes the activity match, and keeps the address it can be ended at**:
//      `Activity.request` when there is none, `Activity.update` when there is,
//      `Activity.end` when the decision says so -- and nothing at all when the
//      operator has switched the feature off. The request carries
//      `pushType: .token`, so ActivityKit also issues the token that addresses
//      *this card*, and this file reads it (never observes it -- see
//      ``ActivityCalls``), leaves it in the app's push registration, and forgets
//      it the moment the card is gone. That address is how a card gets ended
//      while the app is suspended, which is the half of this problem no local
//      code can reach.
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
//  **The phone in a pocket is the case that has to be said out loud.** A refresh
//  that runs off screen (`BackgroundRefresh`) can keep an activity that is
//  already up current, and this controller is what does it. It cannot make one
//  *appear* where none was ever started: the documented way to do that is
//  push-to-start -- a separate APNs token for *starting* activities, registered
//  with the host, and the host sending an APNs start event -- and this app has
//  none of that. A session that begins while the app has not been opened reaches
//  the island when it is next opened, and not before. Saying so here is the
//  point: a background refresh that is mistaken for a start is a promise the app
//  cannot keep.
//
//  **The activity's own push token is a different thing, and this build has
//  one.** An activity started with `pushType: .token` is handed a token that
//  addresses that card, and the app registers it with the host. The relay can
//  then send the APNs end event when the session finishes while the app has been
//  suspended -- the card comes down with no code of this app running at all.
//  That is the case `apply`'s local end cannot cover, and the reason the request
//  carries `.token` below. The *start* event still needs push-to-start, which is
//  still absent; the two tokens are not the same thing and registering one does
//  not conjure the other.
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
//  set the flag. Left set, it would announce the next session's finish as one the
//  operator had already seen -- and the decision layer would answer "dismiss"
//  about an ending nobody witnessed.
//
//  The card comes down on a finish whether or not the operator has seen it (see
//  `apply`), so the flag no longer decides whether a check stays up. It is still
//  kept true, because it is the decision layer's answer to "was that finish
//  witnessed", and an answer it computes from a flag this file left lying would
//  be the wrong answer.
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

    /// The token checks that follow a start, when there are any.
    ///
    /// One task, replaced on every start and cancelled when the card comes down.
    /// The token is looked for on a small fixed schedule rather than observed --
    /// see ``ActivityCalls/pushToken`` for why there is no `AsyncSequence` here
    /// -- and a task that outlived its start would be a read of an activity that
    /// may not be the one it was scheduled for.
    private var pushTokenChecks: Task<Void, Never>?

    /// How long after a start to look for the token again.
    ///
    /// ActivityKit does not hand the token over with `request`: it is sometimes
    /// there when the call returns and sometimes a moment later, and there is no
    /// callback that says which. Three reads, bounded, and no polling after
    /// them: a later arrival is picked up by the next `refresh`, which runs on
    /// the running poll, on every sync, and when the app comes back to the
    /// foreground. Waiting longer on a task started for one card is how a phone
    /// that starts and ends activities accumulates tasks.
    private static let pushTokenCheckDelays: [Duration] = [.milliseconds(500), .seconds(2), .seconds(5)]

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
    ///   - sessionsAreKnown: whether that list is something the host said, rather
    ///     than the empty array a model has before its first read.
    func appOpened(
        sessions: [SessionRow],
        conversations: any ConversationCache,
        sessionsAreKnown: Bool,
        titles: [String: String],
    ) async {
        appOpened()
        await refresh(
            sessions: sessions,
            conversations: conversations,
            sessionsAreKnown: sessionsAreKnown,
            titles: titles,
        )
    }

    /// Read what the app knows, decide, and make the activity match.
    ///
    /// Called after the session list arrives, after a conversation is folded into
    /// the cache, after a full sync, when the app comes to the foreground, and
    /// when the switch moves. Cheap enough to be called all of those times: it
    /// reads the local cache, and it asks ActivityKit for the state of the world
    /// rather than keeping a copy of it.
    ///
    /// Every call is also a chance to learn the activity's push token: it may
    /// arrive after the start that asked for it (the bounded retry covers the
    /// first few seconds) and it may disappear when the card does. See
    /// ``refreshPushToken()``.
    ///
    /// - Parameters:
    ///   - sessions: the session list as the host last gave it.
    ///   - conversations: where the prompts and the running turns are kept.
    ///   - sessionsAreKnown: whether that list is something the host said, rather
    ///     than the empty array a model has before its first read.
    ///   - titles: the app's title list, keyed by session id.
    ///   - now: the instant to measure the clocks to.
    func refresh(
        sessions: [SessionRow],
        conversations: any ConversationCache,
        sessionsAreKnown: Bool,
        titles: [String: String],
        now: Date = Date(),
    ) async {
        guard sessionsAreKnown else {
            // Nothing has been read yet: the list is empty because the app has
            // just started, not because the computer is idle, and the decision layer
            // cannot tell those apart from a list. Acting on the second one is not
            // hypothetical -- measured at launch, the foreground hook fires
            // before the first `session.list` comes back, an empty list read as
            // "everything finished and the app has been opened", and a running
            // activity was taken down and started again a fifth of a second
            // later.
            return
        }
        let running = await RunningSession.running(
            in: sessions,
            conversations: conversations,
            titles: titles,
            now: now,
        )
        let decision = LiveActivityDecision.make(
            sessions: running,
            appOpenedSinceLastFinish: appOpenedSinceLastFinish,
            now: now,
        )
        await apply(decision, runningRowCount: running.count)
        refreshPushToken()
    }

    // MARK: - Making the island match

    /// Carry out one decision.
    ///
    /// Two of the branches take the activity down, and both clear the stored push
    /// token as part of doing it: a token is an address for a card that is up, and
    /// one left behind is the host being told to push to a card that no longer
    /// exists. The token also changes while a card is up -- ActivityKit issues it
    /// after the request, and it may rotate -- so the `.running` branch reads it
    /// again on every refresh.
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
            guard ActivityCalls.hasPresentable else {
                forgetPushToken()
                return
            }
            log.add(.live, await ActivityCalls.endAll(with: decision.phase, why: "the operator switched it off"))
            forgetPushToken()
            return
        }

        if decision.shouldDismiss {
            // The operator has been back since the last finish, so anything still
            // up is a card whose moment has passed. With a finish now ending the
            // activity on the spot this is normally a dismissal of nothing, which
            // is why the emptiness check comes first: the log line is for the
            // times there *was* something left over.
            appOpenedSinceLastFinish = false
            guard ActivityCalls.hasPresentable else {
                forgetPushToken()
                return
            }
            log.add(.live, await ActivityCalls.endAll(with: decision.phase, why: "the app was opened after everything finished"))
            forgetPushToken()
            return
        }

        switch decision.phase {
        case .finished:
            // Nothing is running, so nothing should be counting: the activity is
            // ended, not updated to the check. The check is what the island shows
            // *while* the activity comes down -- `.immediate` here means the card
            // is gone, which is the answer to "did my work finish" that this app
            // can actually give.
            //
            // Still never *started* from here: a check for work that stopped
            // before the activity existed is not worth a second look, which is
            // the decision layer's rule.
            guard ActivityCalls.hasPresentable else {
                forgetPushToken()
                return
            }
            log.add(.live, await ActivityCalls.endAll(with: decision.phase, why: "nothing is running any more"))
            forgetPushToken()

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
                // The token is not part of the request's answer: it may be there
                // already and it may arrive a second from now, which is what the
                // bounded retry is for.
                capturePushToken()
                pollPushTokenAfterStart()
                return
            }
            if let line = await ActivityCalls.update(to: decision.phase, appState: state) { log.add(.live, line) }
            // Read on every refresh, not only after a start: the token may have
            // arrived since the last look, and a card the system ended underneath
            // this app leaves no other trace.
            capturePushToken()
        }
    }

    // MARK: - The card's push token

    /// Look for the activity's push token once, and keep it if there is one.
    ///
    /// Synchronous on purpose. `Activity.pushToken` is a property, and the
    /// `AsyncSequence` that also reports it (`pushTokenUpdates`) would put an
    /// `Activity` -- which is not `Sendable` -- into a task, which is the one
    /// thing this file's design refuses to do. A property read is a lookup of the
    /// activity that is up and nothing held after: the activity object never
    /// leaves ``ActivityCalls``.
    ///
    /// - Returns: whether a token was found; `false` means "not issued yet",
    ///   which is an answer, not a failure.
    @discardableResult
    private func capturePushToken() -> Bool {
        guard let token = ActivityCalls.pushToken else { return false }
        if LiveActivityPushTokenStore.store(token) {
            // Length only: a push token is an address for this card, and this log
            // is exportable. The device token is recorded the same way.
            log.add(.live, "live activity push token: \(token.count) characters")
        }
        return true
    }

    /// Look again, a few times, for a token that was not there at the start.
    ///
    /// One task, on the main actor, sleeping between reads -- the bounded version
    /// of what the `AsyncSequence` would have done. It ends as soon as a token is
    /// found, as soon as the card is gone (a token read after the end would be an
    /// address for a card that is down), and after the last delay however things
    /// went, so a start that never produces a token cannot leave a task behind.
    private func pollPushTokenAfterStart() {
        // The previous start's task is about that start's token. Nothing else is
        // scheduled, ever: this is the only creator.
        pushTokenChecks?.cancel()
        pushTokenChecks = Task { [weak self] in
            for delay in Self.pushTokenCheckDelays {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self else { return }
                if self.capturePushToken() { return }
                guard ActivityCalls.hasPresentable else {
                    self.forgetPushToken()
                    return
                }
            }
        }
    }

    /// The stored token, as of the activity that is up right now.
    ///
    /// Called after every decision, and it covers the case no other branch does:
    /// an activity that was ended from somewhere else -- the operator's swipe on
    /// the Lock Screen, the system's own lifetime limit, the relay's end push --
    /// leaves the app holding a token for a card that is gone. Clearing it posts
    /// the notification that re-registers this phone without it, which is what
    /// stops the host pushing to a dead address.
    private func refreshPushToken() {
        guard ActivityCalls.hasPresentable else {
            forgetPushToken()
            return
        }
        capturePushToken()
    }

    /// Forget the token, and stop looking for another one.
    ///
    /// Idempotent: an unchanged value posts nothing, so every end path may call
    /// it without the app sending a registration per refresh.
    private func forgetPushToken() {
        pushTokenChecks?.cancel()
        pushTokenChecks = nil
        if LiveActivityPushTokenStore.store(nil) {
            log.add(.live, "live activity push token: forgotten, no activity is up")
        }
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

/// Every call this app makes into ActivityKit.
///
/// Static methods on a caseless type rather than methods on the controller, for
/// one reason: nothing here touches the controller's state. Each function looks
/// up the activities itself, works with a `Sendable` phase, and answers with the
/// line to write in the log -- which is what keeps a non-`Sendable` `Activity`
/// from ever being handed across an isolation boundary.
///
/// The reads are synchronous -- `hasPresentable`, `pushToken`, and the lookup
/// under both -- because their answers are a `Bool` and a hex string, and the
/// activity that produced either is dropped inside the property. The async
/// functions are the ones whose ActivityKit methods are `async`.
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

    /// The push token of the activity that is up, hex-encoded, or `nil`.
    ///
    /// **Read, never observed.** ActivityKit also offers the token as an
    /// `AsyncSequence` (`Activity.pushTokenUpdates`), and that is the API this
    /// file cannot use: its elements are not `Sendable`, and consuming it from a
    /// main-actor controller puts a non-`Sendable` `Activity` in a task, where
    /// Swift 6's region checker has to either refuse it or be lied to. A
    /// synchronous property read has neither problem -- the activity is looked up
    /// and dropped inside this property, and what comes out is the `String` the
    /// wire carries. The price is that the token's arrival has to be noticed by
    /// looking, which is what the controller's bounded retry after a start and
    /// its read on every refresh are for.
    ///
    /// - Returns: lowercase hex, or `nil` when no activity is up or the one that
    ///   is has not been issued a token yet.
    static var pushToken: String? {
        for activity in presentable {
            guard let token = activity.pushToken else { continue }
            return LiveActivityPushToken.hex(token)
        }
        return nil
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
    /// Started with `pushType: .token` so ActivityKit issues the token that
    /// addresses this card -- the one the relay needs to end it while the app is
    /// suspended. That is the *activity's* token and not a push-to-start token;
    /// it cannot make an activity appear, only update or end one that exists.
    /// The token itself arrives later, sometimes a moment later, which is why
    /// ``pushToken`` is read again after this returns.
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
                pushType: .token,
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
    /// - Parameters:
    ///   - phase: what to show.
    ///   - appState: where the app was when it sent it. Carried here for the same
    ///     reason ``start(_:appState:runningRowCount:)`` carries it: whether an
    ///     update from the background actually lands is the measurement this
    ///     whole path exists to make, and the word has to be in the line to be
    ///     the evidence.
    /// - Returns: what to write in the log, or `nil` when there was nothing to do.
    static func update(to phase: LiveActivityPhase, appState: String) async -> String? {
        let content = ActivityContent(state: phase, staleDate: nil)
        var changed = 0
        for activity in presentable where !saysTheSame(activity, as: phase) {
            await activity.update(content)
            changed += 1
        }
        guard changed > 0 else { return nil }
        return "updated \(changed) activity while the app was \(appState): \(describe(phase))"
    }

    /// Take every activity of this type down.
    ///
    /// `Activity.activities`, not the presentable ones: an activity that has
    /// already ended is still on the Lock Screen until it is dismissed or the
    /// system clears it four hours later, and `.immediate` is what "the operator
    /// turned this off", "the app was opened" and "nothing is running any more"
    /// all mean.
    ///
    /// The stored push token is the caller's to forget: once the card is down the
    /// address is dead, and a host still holding it would keep sending end
    /// pushes to nothing.
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
                    && current.title == next.title
                    && abs(current.countingSince.timeIntervalSince(next.countingSince)) < 1
            }
        default:
            return false
        }
    }

    /// What a phase contains, without the prompts.
    ///
    /// The rows are described by session id, whole: the log is exportable and the
    /// operator's instructions are deliberately left out of it, while "which
    /// session was on the island and how many rows were there" is the part that
    /// explains a wrong card. Ids are already all over the request log, so this
    /// says nothing the export did not already contain.
    ///
    /// - Parameter phase: the phase.
    /// - Returns: one line.
    private static func describe(_ phase: LiveActivityPhase) -> String {
        switch phase {
        case .finished:
            return "nothing running"
        case .running(let rows):
            let described = rows.map(\.id).joined(separator: ", ")
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
