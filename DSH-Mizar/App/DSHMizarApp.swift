//
//  DSHMizarApp.swift
//  DSH-Mizar
//
//  Monitor and guide a DSH agent from a phone.
//
//  The app is a thin client on purpose. Everything that requires judgement —
//  which sessions exist, what a model costs, whether an approval is safe — is
//  decided by the host, and this app renders the answer. That is what makes it
//  possible for DSH to change underneath without shipping a new build.
//

import SwiftUI
import MizarKit

@main
struct DSHMizarApp: App {
    /// One model for the whole app: a single connection, a single pairing.
    ///
    /// `AppModel.shared` rather than a fresh instance, because a background
    /// launch can run a refresh before any view -- and therefore before anything
    /// that would have constructed a model -- has appeared. See
    /// ``BackgroundRefresh``.
    @State private var model = AppModel.shared

    /// The pieces of push that SwiftUI has no hook for: the device token, what
    /// a notification looks like while the app is open, and what a tap does.
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onOpenURL { url in
                    // The same payload the QR carries, arriving as a link. One
                    // parse path for both means a scanned code and a tapped
                    // link cannot behave differently.
                    guard let target = PairingURI.parse(url.absoluteString) else { return }
                    Task { await model.pair(with: target, deviceName: "iPhone") }
                }
        }
    }
}
