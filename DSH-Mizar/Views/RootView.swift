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
                ProgressView("Connecting…")
            case .unpaired:
                // Nothing paired at all: the only useful thing on screen is the
                // way to fix that.
                UnpairedView()
            case .connecting where model.host == nil:
                ProgressView("Connecting…")
            case .ready, .connecting:
                // The one-time download covers the app rather than sitting in a
                // sheet. It runs straight after pairing, when every screen
                // behind it would be empty, and an empty screen under a small
                // dialog reads as a broken app.
                if model.firstLoad {
                    FirstLoadView(progress: model.syncProgress)
                } else {
                    MainTabs()
                }
            case .failed(let message):
                // A phone with something stored shows it, with the failure as a
                // banner over the top. Only a phone that has never synced gets
                // the screen below, because only then is there nothing to look
                // at.
                //
                // The distinction matters more than it looks. Reading a
                // conversation is entirely local once it has been synced, so
                // replacing it with "Cannot reach the Mac" takes away an answer
                // the operator already has -- and the phone is opened on trains,
                // in lifts, and on the far side of a relay having a bad day.
                if model.hasStoredIndex {
                    MainTabs()
                } else {
                    UnreachableView(message: message)
                }
            }
        }
        .task { await model.start() }
        .task { await model.requestFirstRunPermissions() }
        .task { await model.ensurePushRegistration() }
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

/// The dead end, for a phone that has never synced anything.
///
/// There is nothing behind it to show: no sessions, no titles, no figures. A
/// phone that *has* synced gets its data instead, with the failure as a banner
/// over the top.
///
/// - Parameter message: why the Mac could not be reached.
private struct UnreachableView: View {
    let message: String

    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("Cannot reach the Mac", systemImage: "exclamationmark.triangle")
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
            if !model.hosts.isEmpty {
                NavigationLink("Choose another Mac") {
                    HostListView()
                }
            } else {
                NavigationLink("Scan a code") {
                    PairingView()
                }
            }
        }
    }
}

/// The two halves of the app, once a Mac is paired.
///
/// A tab bar rather than a menu because there are exactly two places to be, and
/// because it is the shape every phone app has: the operator already knows what
/// it means, so it costs nothing to learn and nothing to explain.
///
/// The selection bar is the system's. On iOS 26 that is the platform's Liquid
/// Glass tab bar, drawn and animated by SwiftUI; on anything older it is the
/// standard bar. Neither is imitated -- a hand-built approximation of a system
/// control is a control that will look wrong on the next release, which is the
/// one thing about this app that would date fastest.
///
/// What *is* this app's is when that bar comes and goes. It is put away inside a
/// conversation in compact widths (see `SessionDetailView`), and the system
/// applies that in one frame. `TabBarTransition` watches the same state and gives
/// the bar a transition to arrive and leave by; it sits here, above the tab view,
/// because it has to be in the hierarchy before and after the change rather than
/// only on one side of it.
struct MainTabs: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// Which of the two places is on screen.
    ///
    /// Owned rather than left inside `TabView`, because the bar's journey depends
    /// on it and so does the cached still the journey is made of. Two cases that
    /// were wrong without it: a notification opening a session while Settings is
    /// on screen hid a bar nothing was pushing, and the still taken on the
    /// Settings tab -- with its tab selected -- was what the Conversation tab's
    /// first exit travelled with. Reading the selection makes both an update the
    /// transition sees.
    @State private var tab: TabSelection = .conversation

    /// Which tab, by a name both the tab view and the bar's decision can use.
    private enum TabSelection: Hashable {
        case conversation
        case settings
    }

    /// Whether the selection bar belongs on screen.
    ///
    /// The same rule `SessionDetailView` applies to the real bar, kept in one
    /// place: put away only in a compact width, and only while a conversation is
    /// open in this tab. On an iPad the listing is still on screen beside the
    /// conversation, and a session selected by a notification while Settings is
    /// showing is not a page being pushed from this tab.
    private var barIsVisible: Bool {
        guard tab == .conversation else { return true }
        guard sizeClass == .compact else { return true }
        return model.selectedSessionId == nil
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            // Reading forward through a long list is what this screen is for, so
            // the bar steps out of the way and comes back on the way up. It is
            // the listing behaviour only: a conversation hides the bar outright
            // (see `SessionDetailView`), because the selector chooses between
            // the two *places*, and a conversation is a place inside the first
            // one.
            tabs.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            tabs
        }
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            Tab("Conversation", systemImage: "bubble.left.and.bubble.right", value: TabSelection.conversation) {
                MainView()
            }
            Tab("Settings", systemImage: "gearshape", value: TabSelection.settings) {
                SettingsView()
            }
        }
        // Nothing drawn and nothing to touch: it exists to catch the moment the
        // bar's place in the layout changes, while the bar is still on screen,
        // and move the bar through it. Drawn over the tab view so the picture of
        // the bar can be laid in the bar's own place.
        .overlay {
            TabBarTransition(barIsVisible: barIsVisible)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

#Preview {
    RootView().environment(AppModel())
}
