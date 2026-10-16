//
//  PushController.swift
//  DSH-Mizar
//
//  This phone's end of a notification.
//
//  Three things, and each is somewhere SwiftUI has no hook:
//
//    1. **The device token.** iOS hands it to the `UIApplicationDelegate` and
//       nowhere else, so an adaptor is the only way to get one at all.
//    2. **What a notification looks like while the app is open.** Without a
//       `UNUserNotificationCenterDelegate`, iOS shows nothing at all for a
//       notification that arrives in the foreground -- so an approval asked for
//       while the operator is reading a different session would be silently
//       swallowed.
//    3. **What a tap does.** A notification that opens the app and leaves the
//       operator on the session list is a notification that wasted a tap.
//

import Foundation
import UIKit
import UserNotifications
import MizarKit

/// The application delegate, for the parts SwiftUI cannot reach.
final class PushAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Posted when iOS issues a device token, with the token as the object.
    static let tokenReceived = Notification.Name("mizar.push.token")

    /// Posted when the operator taps a notification, with the session id.
    static let openSession = Notification.Name("mizar.push.open")

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil,
    ) -> Bool {
        // Before anything can arrive. iOS does not queue a foreground
        // notification for a delegate that is set later.
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data,
    ) {
        // Lowercase hex, which is what APNs and the relay both expect. `%02x`
        // over the bytes, not `description` over the `Data`: the latter gives
        // "<0a1b2c…>", which is not a token.
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        PushRegistration.storedToken = token
        NotificationCenter.default.post(name: Self.tokenReceived, object: token)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error,
    ) {
        // Deliberately quiet. The two ways this fails are a simulator without a
        // push-capable runtime and a device whose provisioning profile has no
        // `aps-environment` entitlement, and neither is something the operator
        // can act on from a phone -- but both are worth a line in the device
        // log, which is where a "why is it silent" question gets answered.
        NSLog("[mizar] remote notifications unavailable: %@", String(describing: error))
    }

    /// Show a notification that arrives while the app is open -- or drop it,
    /// because the operator switched that kind off.
    ///
    /// Without this, iOS shows nothing for a foreground notification. The plugin
    /// declines to send while the app reports itself in the foreground, which
    /// covers most of it -- but the report is a round trip, and an approval
    /// asked for in the second between the app opening and the Mac hearing about
    /// it would otherwise vanish.
    ///
    /// This is also where the four switches in the settings screen mean
    /// something. The relay copies the plugin's `kind` into the payload, so the
    /// decision is made here, on the phone, at the moment the notification
    /// arrives -- not by asking the Mac to stop sending, which would need a round
    /// trip, a protocol change and a host that believed the phone. Reading
    /// `AppSettings.shared` at delivery time rather than caching it is what makes
    /// a switch take effect on the next notification instead of the next launch.
    ///
    /// The two strings are read out of the notification here, before the hop to
    /// the main actor: `UNNotification` and its `userInfo` are not `Sendable`,
    /// and only a `String` and the classified kind need to cross. A push whose
    /// kind this build does not recognise is shown -- see
    /// ``NotificationKind/classify(kind:title:reason:)``.
    ///
    /// One limit worth stating: a notification that arrives while the app is in
    /// the background is delivered by iOS without asking this delegate anything,
    /// so this suppresses what would appear over the app, and the switches
    /// describe what the operator wants to see rather than what the Mac sends.
    /// Filtering the background case is the host's side of the wire.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
    ) async -> UNNotificationPresentationOptions {
        let content = notification.request.content
        let userInfo = content.userInfo
        let kind = NotificationKind.classify(
            kind: userInfo["kind"] as? String,
            title: content.title,
            reason: userInfo["reason"] as? String,
        )
        let described = kind?.rawValue ?? (userInfo["kind"] as? String ?? "unknown")
        let wanted = await MainActor.run { kind.map(AppSettings.shared.isEnabled) ?? true }
        await MainActor.run {
            ActivityLog.shared.add(
                .push,
                wanted
                    ? "presented \(described)"
                    : "suppressed \(described): switched off in settings",
            )
        }
        return wanted ? [.banner, .list, .sound] : []
    }

    /// Open the session the notification was about.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
    ) async {
        let sessionId = response.notification.request.content.userInfo["sessionId"] as? String
        guard let sessionId, !sessionId.isEmpty else { return }
        await MainActor.run {
            ActivityLog.shared.add(.push, "opened from a notification: session \(sessionId)")
            NotificationCenter.default.post(name: Self.openSession, object: sessionId)
        }
    }
}

/// What this phone has told the host about itself.
enum PushRegistration {
    /// Where the token is kept.
    ///
    /// `UserDefaults`, not the Keychain: a device token is not a secret -- it is
    /// an address Apple issued to this install, useless without the provider key
    /// that signs for it -- and the Keychain survives a reinstall, which would
    /// leave a token that no longer exists being re-registered forever.
    private static let tokenKey = "mizar.pushToken"

    static var storedToken: String? {
        get { UserDefaults.standard.string(forKey: tokenKey) }
        set {
            if let newValue { UserDefaults.standard.set(newValue, forKey: tokenKey) }
            else { UserDefaults.standard.removeObject(forKey: tokenKey) }
        }
    }

    /// Which APNs service issued this build's tokens.
    ///
    /// Debug builds are signed with a development profile and get sandbox
    /// tokens; a release build gets production ones. The two services do not
    /// accept each other's tokens, and the relay has to be told which one to
    /// talk to -- see `docs/relay-deployment.md` §10.2.
    static var environment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    /// The language to write notifications in.
    ///
    /// The first preferred language, which is what the app's own interface is
    /// already following -- a notification in a different language from the
    /// screen it opens is worse than either.
    static var locale: String {
        Locale.preferredLanguages.first ?? "en"
    }
}
