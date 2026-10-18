//
//  RootView.swift
//  DSH-Mizar
//

import SwiftUI
import MizarKit

/// Chooses between pairing and the main screen.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch model.phase {
            case .launching:
                LaunchingView()
            case .unpaired:
                // Nothing paired at all: the only useful thing on screen is the
                // way to fix that.
                UnpairedView()
            case .connecting where model.host == nil:
                LaunchingView()
            case .ready, .connecting:
                // The one-time download covers the app rather than sitting in a
                // sheet. It runs straight after pairing, when every screen
                // behind it would be empty, and an empty screen under a small
                // dialog reads as a broken app.
                if model.firstLoad {
                    FirstLoadView(progress: model.syncProgress)
                } else {
                    MizarShell()
                }
            case .failed(let message):
                // A phone with something stored shows it, with the failure as a
                // banner over the top. Only a phone that has never synced gets
                // the screen below, because only then is there nothing to look
                // at.
                //
                // The distinction matters more than it looks. Reading a
                // conversation is entirely local once it has been synced, so
                // replacing it with "Cannot reach the computer" takes away an answer
                // the operator already has -- and the phone is opened on trains,
                // in lifts, and on the far side of a relay having a bad day.
                if model.hasStoredIndex {
                    MizarShell()
                } else {
                    UnreachableView(message: message)
                }
            }
        }
        .animation(.mizarSmooth, value: phaseKey)
        .task { await model.start() }
        .task { await model.requestFirstRunPermissions() }
        .task { await model.ensurePushRegistration() }
        // Initial as well as changes: a launch starts active, and that is the
        // state the running poll needs before the first session list arrives.
        .onChange(of: scenePhase, initial: true) { _, phase in
            model.setAppActive(phase == .active)
        }
        .onChange(of: scenePhase) { _, phase in
            // The Live Activity's off-screen half. Called synchronously and
            // before the presence report, because the assertion it takes has to
            // be held while the process still has time: an assertion taken after
            // an `await` is an assertion taken from a process iOS may already
            // have suspended.
            switch phase {
            case .background:
                BackgroundRefresh.shared.didEnterBackground()
            case .active:
                BackgroundRefresh.shared.willEnterForeground()
            case .inactive:
                break
            @unknown default:
                break
            }
            // Tell the host whether anybody is looking. It is what stops a
            // notification being pushed about a screen that is already open --
            // and the report has to be sent on the way out as well as the way
            // in, which is why this fires on every change rather than only on
            // becoming active.
            Task { await model.setPresence(foreground: phase == .active) }
        }
        .onChange(of: model.settings.values.liveActivitiesEnabled) { _, _ in
            // The switch, acted on where it is read. Off has to take down an
            // activity that is already up -- a switch that only stops the *next*
            // one from starting is a switch that leaves the thing the operator
            // just turned off on their Lock Screen -- and on has to be able to
            // start one without waiting for the next sync. The change itself is
            // already in the log; see `AppSettings.note(changeFrom:)`.
            Task { await model.refreshLiveActivity() }
        }
        .onReceive(NotificationCenter.default.publisher(for: PushAppDelegate.tokenReceived)) { _ in
            // iOS has just issued a token, and the host has never heard of it.
            Task { await model.syncPushRegistration() }
        }
        .onReceive(NotificationCenter.default.publisher(for: PushAppDelegate.openSession)) { note in
            // A tap on a notification is a request for one session in
            // particular. Selecting it here rather than in the delegate keeps
            // the delegate free of the app's state -- and it works whether or
            // not the app was already running, because this view is the root of
            // both.
            guard let sessionId = note.object as? String else { return }
            model.selectedSessionId = sessionId
        }
    }
}

/// Which of the root's screens is up, as something an animation can watch.
private extension RootView {
    var phaseKey: Int {
        switch model.phase {
        case .launching: 0
        case .unpaired: 1
        case .connecting where model.host == nil: 2
        case .ready, .connecting: model.firstLoad ? 3 : 4
        case .failed: model.hasStoredIndex ? 4 : 5
        }
    }
}

/// The moment between opening the app and knowing which computer it is for.
private struct LaunchingView: View {
    var body: some View {
        VStack(spacing: 20) {
            MizarMarkSearching()
                .frame(width: 64)
            Text("Connecting…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The dead end, for a phone that has never synced anything.
///
/// There is nothing behind it to show: no sessions, no titles, no figures. A
/// phone that *has* synced gets its data instead, with the failure as a banner
/// over the top.
///
/// - Parameter message: why the computer could not be reached.
private struct UnreachableView: View {
    let message: String

    @Environment(AppModel.self) private var model
    @State private var showingHosts = false
    @State private var showingPairing = false

    var body: some View {
        ContentUnavailableView {
            Label("Cannot reach the computer", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            // Neither button forgets the pairing, and that is the fix for a bug
            // that cost people their setup: this screen used to offer "Pair
            // again", which called `unpair()` and wiped the stored credential.
            // One dropped request -- a phone changing networks is enough --
            // landed here, and the obvious button made it permanent.
            //
            // The label changes while it works. A retry against a phone that has
            // lost its network takes seconds, and a button that looks identical
            // before, during and after is a button that reads as broken whatever
            // it is doing.
            Button {
                Task {
                    // The list is loaded here rather than inside `reconnect`,
                    // because a refresh that fails calls back into `reconnect`
                    // and doing that while the reconnect flag is held deadlocked
                    // the app.
                    if await model.reconnect(patient: true) {
                        await model.refreshSessions()
                    }
                }
            } label: {
                if model.reconnecting {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Trying…")
                    }
                } else {
                    Text("Try again")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.reconnecting)
            .accessibilityIdentifier("failure.retry")
            // Sheets, not links: this screen has no navigation stack, so the
            // links it used to carry went nowhere.
            if !model.hosts.isEmpty {
                Button("Choose another computer") { showingHosts = true }
            } else {
                Button("Scan a code") { showingPairing = true }
            }
        }
        .sheet(isPresented: $showingHosts) {
            NavigationStack { HostListView() }
        }
        .sheet(isPresented: $showingPairing) {
            PairingView()
        }
    }
}

#Preview {
    RootView().environment(AppModel())
}
