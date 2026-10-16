//
//  AppEnvironment.swift
//  DSH-Mizar
//
//  What this build is, what this phone is, and whether iOS will let it speak.
//
//  Gathered in one place because three callers want overlapping halves of it:
//  the About section (version and build), the Notifications section (whether the
//  system permission is actually granted) and the log export (all of it). Read at
//  the moment they are asked for rather than cached -- the permission in
//  particular changes while the app is running, in another app, and a cached
//  answer is how a screen ends up insisting notifications are on when they are
//  not.
//

import Foundation
import MizarKit
import UIKit
import UserNotifications

/// What iOS currently thinks of this app's notifications.
///
/// Worth showing on the settings screen rather than hiding: every switch on that
/// screen is a filter this app applies to pushes that arrive, and a filter is
/// meaningless if the permission underneath it is off. An operator who switched
/// 任务完成 back on and still hears nothing deserves to see which of the two
/// layers is responsible.
struct NotificationPermission: Sendable, Equatable {
    /// The system's answer.
    enum Status: Sendable, Equatable {
        /// Never asked, so nothing can arrive yet.
        case notAsked
        /// Granted in full.
        case allowed
        /// Granted quietly: delivered to the notification centre, not to the screen.
        case provisional
        /// Refused, in iOS Settings.
        case denied
        /// A status this build does not know.
        case unknown
    }

    /// The system's answer.
    var status: Status
    /// Whether alerts are permitted.
    var alertsAllowed: Bool
    /// Whether sound is permitted.
    var soundAllowed: Bool

    /// How the status reads on screen.
    var description: String {
        switch status {
        case .notAsked: String(localized: "Not asked yet")
        case .allowed: String(localized: "Allowed")
        case .provisional: String(localized: "Quiet delivery")
        case .denied: String(localized: "Off in iOS Settings")
        case .unknown: String(localized: "Unknown")
        }
    }

    /// The name the system uses, for the log.
    ///
    /// Not localized: this string goes into a diagnostic file read by somebody
    /// comparing it against Apple's documentation.
    var diagnosticName: String {
        switch status {
        case .notAsked: "notDetermined"
        case .allowed: "authorized"
        case .provisional: "provisional"
        case .denied: "denied"
        case .unknown: "unknown"
        }
    }

    /// Ask iOS.
    /// - Returns: the current permission.
    static func current() async -> NotificationPermission {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let status: Status = switch settings.authorizationStatus {
        case .notDetermined: .notAsked
        case .authorized: .allowed
        case .provisional: .provisional
        // An App Clip's permission, which this app cannot have -- but a switch
        // over a system enum has to say what every case means, and "quiet
        // delivery" is the honest reading of a permission that shows a
        // notification without asking first.
        case .ephemeral: .provisional
        case .denied: .denied
        @unknown default: .unknown
        }
        return NotificationPermission(
            status: status,
            // `.enabled` rather than "not disabled": a setting the operator has
            // not been asked about yet is `.notSupported` here, and calling that
            // "allowed" would make the screen claim more than it knows.
            alertsAllowed: settings.alertSetting == .enabled,
            soundAllowed: settings.soundSetting == .enabled,
        )
    }
}

/// The facts the log archive records about the running app.
enum AppEnvironment {
    /// Read everything the archive says about this build and this phone.
    /// - Returns: the facts.
    @MainActor
    static func facts() async -> EnvironmentFacts {
        let permission = await NotificationPermission.current()
        let token = PushRegistration.storedToken
        return EnvironmentFacts(
            appVersion: AppModel.appVersion,
            appBuild: AppModel.appBuild,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
            deviceModel: AppModel.deviceModel,
            systemName: UIDevice.current.systemName,
            systemVersion: UIDevice.current.systemVersion,
            locale: Locale.current.identifier,
            languages: Locale.preferredLanguages,
            timeZone: TimeZone.current.identifier,
            notificationAuthorization: permission.diagnosticName,
            notificationsAllowed: permission.alertsAllowed,
            soundAllowed: permission.soundAllowed,
            // Whether, and how long -- never the token. It is the credential that
            // lets a relay wake this phone, and an archive exists to be sent to
            // somebody else.
            pushTokenRegistered: token != nil,
            pushTokenLength: token?.count ?? 0,
            pushEnvironment: PushRegistration.environment,
            // Flag names only. `-mizarPairURI` carries a pairing code, and a
            // diagnostic file that leaks it is worse than no diagnostic file.
            launchFlags: ProcessInfo.processInfo.arguments.filter { $0.hasPrefix("-") },
        )
    }
}
