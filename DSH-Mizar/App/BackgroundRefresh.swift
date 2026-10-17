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
//       what can be verified, and that is what is verified).
//
//  ## What this can and cannot do
//
//  It can **update an activity that is already up**, and it does: the sync
//  re-reads the session list and the running sessions' pages, and the controller
//  turns that into a fresh `ContentState` and sends it, while the app is off
//  screen. It can also **end** one from here, which is the other half of a
//  finish: a sync that reads a session stopping ends the card on the spot,
//  without waiting for the app to be opened. It can also attempt to *start* one
//  -- the controller asks whenever there is nothing on screen, and the attempt is
//  logged with the app state it was made in -- but Apple's contract is that an
//  activity is started from the foreground, and a background refresh is not
//  that. **When no activity was ever started, the only way to make one appear on
//  a phone that has not been opened is push-to-start**: a token for *starting*
//  activities (a different APNs token from the one an activity issues for its own
//  updates), registered with the host, and the host sending an APNs start event.
//  This app has none of that -- the host side has no such event, and the activity
//  push token the controller registers identifies a card that already exists --
//  so that case remains impossible, and nothing here pretends otherwise. A
//  background refresh that finds nothing running, or that finds a running session
//  and no activity, does not queue a start for later: the next foreground refresh
//  is the retry, exactly as the controller says.
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
/// background APIs are main-thread contracts. The one hop in the file is in the
/// two system callbacks, which are called on the main queue and say so with
/// `MainActor.assumeIsolated` rather than by spawning a task.
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
    /// Called when the app is backgrounded and again at the start of every
    /// background refresh, so the next request exists even if this one is ended
    /// by the system or by a crash. The previous request for the same identifier
    /// is cancelled first: only one may be pending, and a submission that is
    /// silently dropped looks exactly like one that was accepted.
    func schedule() {
        guard BackgroundSync.shouldRun(
            paired: AppModel.shared.host != nil,
            liveActivitiesEnabled: settings.values.liveActivitiesEnabled,
        ) else {
            return
        }
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
    /// - Parameter task: the task the system handed over.
    private func handle(_ task: BGTask) {
        guard let refresh = task as? BGAppRefreshTask else {
            // A processing task was registered under this identifier, which
            // this app never does. Ending it is the only thing left.
            task.setTaskCompleted(success: false)
            return
        }
        // `AppModel.shared` exists this early -- it is built with the App value
        // -- but its *content* may not: `start()`, which loads the pairing and
        // opens the socket, runs from `RootView`'s `.task`, and a wake that
        // arrives before any scene has appeared has not run it. A refresh that
        // finds no pairing then has nothing to ask and says so; the next real
        // launch connects. Waiting here would be worse: the wait would be spent
        // out of the task's own window, on a screen that is not going to appear.
        let model = AppModel.shared
        guard BackgroundSync.shouldRun(
            paired: model.host != nil,
            liveActivitiesEnabled: settings.values.liveActivitiesEnabled,
        ) else {
            log.add(
                .sync,
                "background refresh: not wanted"
                    + (model.host == nil ? " -- no Mac is paired" : " -- the Live Activity is switched off"),
            )
            task.setTaskCompleted(success: true)
            return
        }
        // Before the work, not after: a refresh that is killed part-way through
        // (the system may do that) would otherwise leave no next request, and
        // the periodic refresh would stop for good on the first bad run.
        schedule()
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
        guard BackgroundSync.shouldRun(
            paired: model.host != nil,
            liveActivitiesEnabled: settings.values.liveActivitiesEnabled,
        ) else {
            log.add(
                .live,
                "background sync: skipped, "
                    + (model.host == nil ? "no Mac is paired" : "the Live Activity is switched off"),
            )
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
    /// - Parameters:
    ///   - task: the refresh task.
    ///   - reason: what woke it, for the log.
    private func run(_ task: BGAppRefreshTask, reason: String) {
        let model = AppModel.shared
        let expiresAt = Date().addingTimeInterval(Self.budget)
        let work = Task { @MainActor in
            let line = await model.backgroundRefresh(expiresAt: expiresAt, reason: reason)
            self.log.add(.sync, line)
            // Cancelled means the system called time: `false` is the honest
            // answer and is also what the system uses to decide how often to
            // wake this app again. Reporting success for work that was cut short
            // teaches it the wrong lesson.
            task.setTaskCompleted(success: !Task.isCancelled)
        }
        task.expirationHandler = { [weak self] in
            // The handler is called on the main queue (the task was registered
            // that way) but with no isolation of its own, so the hop is a task.
            Task { @MainActor in
                work.cancel()
                self?.log.add(.sync, "background refresh: the system called time; the sync stopped where it was")
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
