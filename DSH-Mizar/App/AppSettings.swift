//
//  AppSettings.swift
//  DSH-Mizar
//
//  The live copy of what the operator has switched on.
//
//  `MizarKit` owns the model -- the value, the storage keys, the defaults, and
//  which notification is which kind. This owns the object the app reads: one
//  instance, written through one property, persisted on every write.
//
//  It is a single shared object on purpose. Two things consult it that have no
//  relationship to each other: the Settings screen, which writes it, and the
//  notification delegate, which reads it at the moment a push arrives -- and the
//  delegate is created by UIKit before any of this app's views exist. A copy per
//  caller would mean a switch that changes the screen and not the behaviour,
//  which is the one failure this whole file exists to prevent.
//
//  Written through `values` rather than through a setter per switch: `didSet`
//  fires for a nested write as well (`values.notifications.set(false, for:)`),
//  so persistence and logging happen exactly once no matter which switch moved.
//

import Foundation
import Observation
import MizarKit

@MainActor
@Observable
final class AppSettings {
    /// The settings the app runs on.
    static let shared = AppSettings()

    /// Every setting, as one value.
    ///
    /// Assigning to it -- or to anything inside it -- writes to storage and logs
    /// the change. There is no other way to change a setting.
    var values: MizarSettings {
        didSet {
            guard values != oldValue else { return }
            values.save(to: storage)
            note(changeFrom: oldValue)
        }
    }

    private let storage: any SettingsStorage

    /// - Parameter storage: where the values are kept. `UserDefaults` in the app;
    ///   a dictionary in a test.
    init(storage: any SettingsStorage = UserDefaultsSettingsStorage()) {
        self.storage = storage
        values = MizarSettings.load(from: storage)
    }

    /// Whether one kind of notification should be shown.
    /// - Parameter kind: the kind to ask about.
    /// - Returns: whether the operator wants it.
    func isEnabled(_ kind: NotificationKind) -> Bool {
        values.notifications.isEnabled(kind)
    }

    /// Whether the Live Activity may run.
    var liveActivitiesEnabled: Bool { values.liveActivitiesEnabled }

    /// Whether a reconnect should ask the local network before the relay.
    var localNetworkFirst: Bool { values.localNetworkFirst }

    /// Write a change to the log.
    ///
    /// One line per switch that moved, and none for the ones that did not: this
    /// is the answer to "I turned that off, why did it still arrive", and a log
    /// that recorded four lines for every tap would be one nobody reads.
    private func note(changeFrom old: MizarSettings) {
        if old.liveActivitiesEnabled != values.liveActivitiesEnabled {
            ActivityLog.shared.add(.settings, "live activity \(values.liveActivitiesEnabled ? "on" : "off")")
        }
        if old.localNetworkFirst != values.localNetworkFirst {
            ActivityLog.shared.add(
                .settings,
                "local network first \(values.localNetworkFirst ? "on" : "off")",
            )
        }
        for kind in NotificationKind.allCases
        where old.notifications.isEnabled(kind) != values.notifications.isEnabled(kind) {
            let state = values.notifications.isEnabled(kind) ? "on" : "off"
            ActivityLog.shared.add(.settings, "notifications: \(kind.rawValue) \(state)")
        }
    }
}
