//
//  BackgroundRefresh.swift
//  DSH-Mizar
//
//  The app's half of a refresh that runs with nobody looking.
//
//  iOS suspends this process the moment the app leaves the screen -- measured on
//  the simulator at 35.9 s of background wall time with no app code running at
//  all, resuming on the instant it was foregrounded -- so anything that has to
//  happen off screen has to be holding one of the two things the system lends
//  an app for it:
//
//    1. **A background task assertion.** Taken the moment the app is
//       backgrounded, it keeps the process running for the system's short window
//       (about thirty seconds) while one refresh runs, and it is released the
//       moment that refresh finishes. The expiration handler is honoured: the
//       work is cancelled, the assertion is released, and the island is left as
//       it was rather than half-updated.
//
//    2. **A `BGAppRefreshTask`.** The system runs these on its own schedule --
//       minutes to hours, and it decides -- which is the only way the island
//       stays current after the first window has gone. The request's
//       `earliestBeginDate` is a *hint*; nothing here can make the system run
//       one sooner, and on the simulator they never fire at all (`simctl` has no
//       way to trigger one; the registration and the handler's code path are
//       what can be verified, and that is what is verified). The task is
//       completed the moment the system's expiration handler runs, not when the
//       work notices it was cancelled: the handler is the deadline, and a
//       completion that waits for the work is a completion the system has
//       already given up on. See ``run(_:reason:)``.
//
//  ## What this can and cannot do
//
//  It can **update an activity that is already up**, and it does: the sync
//  re-reads the session list and the running sessions' pages, and the controller
//  turns that into a fresh `ContentState` and sends it, while the app is off
//  screen. It can also **end** one from here, which is the other half of a
//  finish: a sync that reads a session stopping ends the card on the spot,
//  without waiting for the app to be opened. It no longer *starts* one: Apple's
//  contract is that an activity starts in the foreground, and a refresh used to
//  ask anyway and log the answer. The answer never produced a card, so the
//  request is gone from this path -- see ``LiveActivityController`` -- and the
//  next foreground refresh is the retry. **When no activity was ever started, the
//  only way to make one appear on a phone that has not been opened is
//  push-to-start**: a token for *starting* activities (a different APNs token from
//  the one an activity issues for its own updates), registered with the host, and
//  the host sending an APNs start event. This app has none of that -- the host
//  side has no such event, and the activity push token the controller registers
//  identifies a card that already exists -- so that case remains impossible, and
//  nothing here pretends otherwise. A background refresh that finds nothing
//  running, or that finds a running session and no activity, does not queue a
//  start for later: the next foreground refresh is the retry, exactly as the
//  controller says.
//
//  ## Why `BGAppRefreshTask` and not a timer or a `UIBackgroundModes` trick
//
//  A `Timer` does not fire while the process is suspended, and there is no
//  background mode that grants periodic execution to an app that is not doing
//  one of the four things the modes name (audio, location, VoIP, or a
//  `BGProcessingTask`'s long-running work). `BGAppRefreshTask` is the supported
//  way to be woken for a short refresh, and it is the only one that costs the
//  operator nothing: no battery-draining keep-alive, no location permission
//  asked for a clock. It is registered at launch because that is when the system
//  requires it, and rescheduled from the background so the next wake exists
//  before this one finishes.
//

import BackgroundTasks
import MizarKit
import UIKit

/// Runs one short sync off screen, under an assertion or a background task.
///
/// `@MainActor` throughout: the model it drives is main-actor state, the
/// ActivityKit calls it ends up in are made from there, and UIKit's two
/// background APIs are main-thread contracts. The system callbacks do not hop
/// before doing the one thing they exist for: the launch handler is asserted
/// main (`using: nil` means the main queue), the assertion's expiration handler
/// works inline under `MainActor.assumeIsolated`, and the background task's
/// expiration handler completes its task synchronously and only the log line
/// after it is hopped -- because completion delayed by a hop is completion late.
@MainActor
final class BackgroundRefresh {
    /// The single runner, for the same reason the model is single: the app has
    /// one connection, one pairing and one activity, and two runners would take
    /// two assertions for one refresh.
    static let shared = BackgroundRefresh()

    /// The identifier registered in `Info.plist` under
    /// `BGTaskSchedulerPermittedIdentifiers`. The two have to be the same
    /// string, and a mismatch is silent at build time and a refusal at launch.
    static let refreshIdentifier = "me.shirazu.dshmizar.refresh"

    /// How long one refresh may run before it stops starting new work.
    ///
    /// Under the system's ~30 s window rather than at it: the last few seconds
    /// belong to cancelling what is in flight and releasing the assertion, and a
    /// refresh that plans to use them for a request is a refresh that gets cut
    /// off mid-request.
    static let budget: TimeInterval = 25

    /// How soon the next periodic refresh may be asked for.
    ///
    /// Fifteen minutes, and it is a floor rather than a schedule: the system
    /// treats `earliestBeginDate` as a request and weighs it against how the
    /// operator uses the app, the battery and the network. There is no value
    /// here that makes a refresh happen sooner.
    static let earliestRefresh: TimeInterval = 15 * 60

    private let log: ActivityLog
    private let settings: AppSettings

    /// Whether ``register()`` succeeded. Kept only for the log: registering
    /// twice is a programmer error, and the second call would otherwise be
    /// indistinguishable from the first in a bug report.
    private var registered = false

    /// The assertion the current refresh is running under, or `.invalid`.
    private var assertion: UIBackgroundTaskIdentifier = .invalid

    /// The refresh in flight, when there is one.
    private var work: Task<Void, Never>?

    /// Which refresh owns the assertion.
    ///
    /// A background/foreground cycle can start a second refresh before the first
    /// has noticed it was cancelled. Without this, the first one's `defer`-style
    /// release would end the *second* one's assertion -- the system kills an app
    /// whose background time is revoked while it is still working, and the
    /// cancellation of a task is not a signal that can be waited for.
    private var generation = 0

    init(log: ActivityLog = .shared, settings: AppSettings = .shared) {
        self.log = log
        self.settings = settings
    }

    // MARK: - The periodic refresh

    /// Tell the system this app has a periodic refresh, and what to run.
    ///
    /// Must be called before `application(_:didFinishLaunchingWithOptions:)`
    /// returns; the system reads the registered handlers when the background
    /// launch is being prepared, and a handler registered later is a handler
    /// that never runs.
    func register() {
        guard !registered else { return }
        registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.refreshIdentifier,
            using: nil,
        ) { [weak self] task in
            // The launch handler is called on the main queue because `using:` is
            // `nil`. Asserted rather than hopped: a `BGTask` may not be sent to
            // another isolation domain, and hopping would have to carry it.
            MainActor.assumeIsolated {
                self?.handle(task)
            }
        }
        log.add(
            .app,
            registered
                ? "background refresh registered: \(Self.refreshIdentifier)"
                : "background refresh NOT registered: \(Self.refreshIdentifier) is not in BGTaskSchedulerPermittedIdentifiers",
        )
    }

    /// Ask for the next periodic refresh.
    ///
    /// Called when the app is backgrounded, where the pairing is loaded, the list
    /// is the host's and the answer is a real one. A *wake* does not come through
    /// here: it knows the pairing from the store rather than from the model, and
    /// asks ``submit()`` directly. The previous request for the same identifier is
    /// cancelled first: only one may be pending, and a submission that is
    /// silently dropped looks exactly like one that was accepted.
    ///
    /// The one line that matters most in this file is `hasRunningSession`: a
    /// phone leaving the screen with nothing running is a phone with no card to
    /// keep current, so no request goes in and no background launch happens.
    func schedule() {
        guard BackgroundSync.shouldRun(
            paired: AppModel.shared.host != nil,
            liveActivitiesEnabled: settings.values.liveActivitiesEnabled,
            hasRunningSession: runningSessionExists,
        ) else {
            return
        }
        submit()
    }

    /// Whether the list the model holds has a session the island could draw.
    ///
    /// Read through the model, not through a second count: `sessions` is the same
    /// list the sync and the controller use, so the three cannot disagree about
    /// what "running" means. On a background launch the list is nobody's answer
    /// -- see ``run(_:reason:)``, which passes `nil` rather than a zero -- so this
    /// one is for callers that have a screen behind them.
    private var runningSessionExists: Bool {
        !BackgroundSync.conversationRefreshTargets(in: AppModel.shared.sessions).isEmpty
    }

    /// Put the next request in, whatever the loaded state says.
    ///
    /// Separate from ``schedule()`` because the two ask different questions. A
    /// foreground caller knows the pairing, so `schedule()`'s guard is a real
    /// answer. A wake that can run has just read it from the store, and on a
    /// background launch `host` is nil however the store answered -- so asking
    /// ``schedule()``'s question there would drop the one submission a runnable
    /// wake gets.
    private func submit() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshIdentifier)
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshIdentifier)
        request.earliestBeginDate = Date().addingTimeInterval(Self.earliestRefresh)
        do {
            try BGTaskScheduler.shared.submit(request)
            let minutes = Int(Self.earliestRefresh / 60)
            log.add(.sync, "background refresh: asked for one, no sooner than \(minutes) min from now")
        } catch {
            // The honest line. A simulator that refuses, or a system that says
            // this app has asked too often: either way the island will only be
            // refreshed by the next foreground visit, and the log should say so
            // rather than let "it stopped updating" look like a bug in the
            // activity.
            log.add(.sync, "background refresh: not scheduled (\(error))")
        }
    }

    /// Run the refresh the system woke the app for.
    ///
    /// The decision about *what* this wake may do is made inside
    /// ``run(_:reason:)``, in the work task, because it needs one thing this
    /// function cannot get synchronously: what the credentials store says. See
    /// ``AppModel/storedPairing()``. `AppModel.shared` exists this early -- it is
    /// built with the App value -- but its *content* may not: `start()`, which
    /// loads the pairing and opens the socket, runs from `RootView`'s `.task`,
    /// and a wake that arrives before any scene has appeared has not run it.
    /// Deciding from the model here is what used to make a cold wake write "no
    /// computer is paired" about a phone that has one -- true of the model, false
    /// of the phone, and the log is the only thing a wake leaves behind.
    ///
    /// - Parameter task: the task the system handed over.
    private func handle(_ task: BGTask) {
        guard let refresh = task as? BGAppRefreshTask else {
            // A processing task was registered under this identifier, which
            // this app never does. Ending it is the only thing left.
            task.setTaskCompleted(success: false)
            return
        }
        run(refresh, reason: "a background refresh")
    }

    // MARK: - Entering and leaving the background

    /// The app has just been backgrounded.
    ///
    /// Takes the assertion synchronously, while the process is definitely still
    /// running: the refresh itself is asynchronous, and an assertion taken after
    /// the first `await` is an assertion taken from a process that may already
    /// be suspended.
    func didEnterBackground() {
        let model = AppModel.shared
        let running = runningSessionExists
        guard BackgroundSync.shouldRun(
            paired: model.host != nil,
            liveActivitiesEnabled: settings.values.liveActivitiesEnabled,
            hasRunningSession: running,
        ) else {
            let why: String
            if model.host == nil {
                why = "no computer is paired"
            } else if !settings.values.liveActivitiesEnabled {
                why = "the Live Activity is switched off"
            } else {
                why = "nothing is running, so there is no card to keep current"
            }
            log.add(.live, "background sync: skipped, " + why)
            return
        }
        schedule()
        // Anything still running from an earlier background period is stale:
        // the foreground has been open since, so its data is already out of
        // date. Cancelled rather than left to finish, and the assertion it holds
        // is released below by the generation check rather than by its own end.
        work?.cancel()
        beginAssertion()
        guard assertion != .invalid else { return }
        generation += 1
        let mine = generation
        let expiresAt = Date().addingTimeInterval(Self.budget)
        work = Task { @MainActor in
            let line = await model.backgroundRefresh(expiresAt: expiresAt, reason: "entering the background")
            self.log.add(.sync, line)
            guard self.generation == mine else { return }
            self.work = nil
            self.endAssertion()
        }
    }

    /// The app is coming back, so the off-screen work is over.
    ///
    /// The symptom this prevents is a refresh from the past landing on top of
    /// the screen the operator has just opened: the foreground refresh is about
    /// to read the world anyway, and a stale answer arriving after it would be
    /// the older one.
    func willEnterForeground() {
        guard work != nil || assertion != .invalid else { return }
        let was = generation
        work?.cancel()
        work = nil
        generation += 1
        log.add(.live, "background sync: the app came back; the off-screen work for generation \(was) was cancelled")
        endAssertion()
    }

    // MARK: - The system's timer

    /// Run one refresh under the system's task, and honour its expiration.
    ///
    /// Two deadlines sit on this function and they are not the same one. The
    /// app's own budget (``budget``) is when the work stops *starting* anything.
    /// The system's expiration handler is when the task has to be **completed**,
    /// and it can arrive at any moment -- including inside a cache write that
    /// cancellation cannot interrupt. So completion is reported from the handler
    /// itself, synchronously, and from the work when that finishes first:
    /// ``WakeCompletion`` makes the two one call.
    ///
    /// - Parameters:
    ///   - task: the refresh task.
    ///   - reason: what woke it, for the log.
    private func run(_ task: BGAppRefreshTask, reason: String) {
        let model = AppModel.shared
        let expiresAt = Date().addingTimeInterval(Self.budget)
        let completion = WakeCompletion(task: task)
        let work = Task { @MainActor in
            // The store, not the model: on a cold wake the model has not been
            // loaded and `host` is nil whatever the truth is. See
            // ``BackgroundSync/wake(pairing:modelIsLoaded:liveActivitiesEnabled:hasRunningSession:)``.
            let pairing = await model.storedPairing()
            switch BackgroundSync.wake(
                pairing: pairing,
                modelIsLoaded: model.host != nil,
                liveActivitiesEnabled: self.settings.values.liveActivitiesEnabled,
                // `sessionsAreKnown` distinguishes "the host said nothing is
                // running" from "nothing has been read", and the difference is
                // the whole gate: an unknown list is a reason to run (the run
                // reads it), a known empty one is a reason not to.
                hasRunningSession: model.sessionsAreKnown ? self.runningSessionExists : nil,
            ) {
            case .skip(let why):
                // Nothing to run, and no next request either. A bright line is
                // drawn between "there is nothing to ask for", "this launch
                // cannot ask" and "nothing is running" -- the last one is the
                // ordinary case and the one this file saves the most launches
                // on, because a phone in a pocket with nothing running has no
                // card to keep current. All three end here: every submission is
                // another launch this app can be woken for, and the next trip to
                // the background asks again.
                self.log.add(.sync, "background refresh: not running -- " + why.line)
                completion.finish(success: true)

            case .refresh:
                // Before the work, not after: a refresh that is killed part-way
                // through (the system may do that) would otherwise leave no next
                // request, and the periodic refresh would stop for good on the
                // first bad run.
                self.submit()
                let line = await model.backgroundRefresh(expiresAt: expiresAt, reason: reason)
                self.log.add(.sync, line)
                // Cancelled means the system called time: `false` is the honest
                // answer and is also what the system uses to decide how often to
                // wake this app again. Reporting success for work that was cut
                // short teaches it the wrong lesson.
                completion.finish(success: !Task.isCancelled)
            }
        }
        task.expirationHandler = { [weak self] in
            // Completed here, synchronously, and before the log. The handler is
            // the deadline: the app has seconds from this call to report, and
            // waiting for the work to notice its cancellation is what turns an
            // expired background refresh into a watchdog kill. The work may be
            // inside a read-modify-write of a cache file that cancellation
            // cannot interrupt, and the system is not waiting for it.
            work.cancel()
            let reported = completion.finish(success: false)
            // The record is allowed to be late. The completion was not.
            Task { @MainActor in
                self?.log.add(
                    .sync,
                    "background refresh: the system called time; the sync stopped where it was"
                        + (reported ? "" : " (completion had already been reported)"),
                )
            }
        }
    }

    // MARK: - The assertion

    /// Take the assertion, and say so.
    ///
    /// `beginBackgroundTask` answers `.invalid` when iOS is out of background
    /// time for this app, which is not an error the app can fix -- and is worth
    /// a line, because "the island stopped updating" and "the assertion was
    /// refused" look identical from the Lock Screen.
    private func beginAssertion() {
        guard assertion == .invalid else { return }
        assertion = UIApplication.shared.beginBackgroundTask(withName: "mizar.live-activity-sync") { [weak self] in
            // Called on the main thread when the system is about to take the
            // time back. The work is stopped and the assertion released here;
            // doing neither is how an app gets terminated.
            MainActor.assumeIsolated {
                self?.expire()
            }
        }
        if assertion == .invalid {
            log.add(.live, "background sync: iOS refused a background task; the island was not refreshed")
        } else {
            log.add(.live, "background sync: background task taken while the app was \(stateWord)")
        }
    }

    /// The system is taking the assertion back.
    ///
    /// Cancels the work and releases the assertion immediately. The refresh
    /// checks `Task.isCancelled` between requests, so what it does not do is
    /// start another one; whatever it was in the middle of is torn down by the
    /// suspension that follows. Nothing here touches the activity: an activity
    /// that is up stays up, showing the last state the app gave it, which is the
    /// only honest thing to leave on a Lock Screen nobody is refreshing.
    private func expire() {
        work?.cancel()
        log.add(.live, "background sync: out of time; the sync stopped and the assertion was released")
        endAssertion()
    }

    /// Release the assertion, once.
    ///
    /// Idempotent because two callers can reach it -- the refresh finishing and
    /// the expiration handler -- and `endBackgroundTask` for an assertion that
    /// has already been ended is an error the system records against the app.
    private func endAssertion() {
        guard assertion != .invalid else { return }
        UIApplication.shared.endBackgroundTask(assertion)
        assertion = .invalid
    }

    /// Where the app is, for the log.
    private var stateWord: String {
        switch UIApplication.shared.applicationState {
        case .active: "on screen"
        case .inactive: "inactive"
        case .background: "off screen"
        @unknown default: "in an unknown state"
        }
    }
}

// MARK: - Reporting the system's task

/// Reports one `BGTask`'s completion exactly once.
///
/// Two callers can reach the end of a refresh -- the work, when it finishes, and
/// the expiration handler, when the system runs out of patience -- and Apple
/// counts a second `setTaskCompleted` against the app. Locked rather than
/// main-actor isolated on purpose: the expiration handler has to report
/// completion from whatever context the system calls it in, and hopping to the
/// main actor first is exactly the delay this type exists to remove.
private final class WakeCompletion: @unchecked Sendable {
    private let lock = NSLock()
    /// The task, held until the one call that ends it.
    private var task: BGAppRefreshTask?

    init(task: BGAppRefreshTask) {
        self.task = task
    }

    /// Report completion.
    ///
    /// - Parameter success: whether the refresh did what it was woken for.
    /// - Returns: whether this call was the one that reported it; `false` means
    ///   the other caller already had.
    @discardableResult
    func finish(success: Bool) -> Bool {
        lock.lock()
        let task = self.task
        self.task = nil
        lock.unlock()
        guard let task else { return false }
        task.setTaskCompleted(success: success)
        return true
    }
}

// MARK: - The log's words for a wake's reasons

private extension BackgroundSync.Wake.SkipReason {
    /// The end of a log line: why this wake did not run.
    ///
    /// Written as what the phone's state is, not as what the app decided: a log
    /// somebody reads months later needs the fact, and the fact for the last two
    /// is "a wake arrived at a launch that had not read the pairing", which is a
    /// different thing from "the operator has no computer".
    var line: String {
        switch self {
        case .unpaired: "no computer is paired"
        case .liveActivitiesOff: "the Live Activity is switched off"
        case .pairingUnknown:
            "the pairing could not be read (the keychain does not answer before the first unlock after a restart)"
        case .modelNotLoaded:
            "this launch has not read the pairing (no screen has appeared); the next trip to the background asks again"
        case .nothingRunning:
            "nothing is running, so there is no card to keep current"
        }
    }
}

