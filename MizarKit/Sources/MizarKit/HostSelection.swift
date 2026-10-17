//
//  HostSelection.swift
//  MizarKit
//
//  Which paired machine the app opens.
//
//  A phone may be paired with several Macs, and it talks to exactly one of them
//  at a time: the session list, the pending approvals, the Live Activity and the
//  push registration all belong to whichever machine the live socket is dialled
//  to. "The machine paired last" is a fact about the past, not about where the
//  operator was working -- pair a second Mac once and every later launch opened
//  that one, even when the operator had been using the first. That is a wrong
//  connection rather than a preference: the app looked connected while its
//  sessions, its notifications and its Live Activity belonged to another Mac.
//
//  So the choice is remembered explicitly: the machine the operator last opened
//  is the machine the next launch opens. The most recently paired host remains
//  the fallback for a fresh install and for a remembered machine that has been
//  forgotten since.
//

import Foundation

/// The rule that answers "which paired machine does this launch open?".
public enum HostSelection {
    /// The machine to open.
    ///
    /// - Parameters:
    ///   - hosts: every paired machine, in any order.
    ///   - lastOpenedId: the host the operator last opened, when this install
    ///     remembers one.
    /// - Returns: the remembered machine when it is still paired; otherwise the
    ///   most recently paired one; `nil` when nothing is paired at all.
    public static func preferred(in hosts: [PairedHost], lastOpenedId: String?) -> PairedHost? {
        if let lastOpenedId, let remembered = hosts.first(where: { $0.hostId == lastOpenedId }) {
            return remembered
        }
        // Deliberately the same fallback the launch path always had: a phone
        // with no memory (a fresh install, or one whose remembered Mac was
        // forgotten) opens the machine it was most recently given.
        return hosts.max { $0.pairedAt < $1.pairedAt }
    }
}

/// Where this install remembers the machine it last opened.
///
/// `UserDefaults` rather than the Keychain: it is a preference, not a credential,
/// and the machine it names already has its secret in the Keychain. Losing this
/// value costs one fallback, not a pairing.
public enum LastOpenedHostStore {
    /// Where the host id lives in `UserDefaults`.
    public static let hostIdKey = "mizar.lastOpenedHostId"

    /// The remembered host id, if one is stored.
    ///
    /// - Parameter defaults: where to read. `UserDefaults.standard` in the app;
    ///   a suite of its own in a test.
    /// - Returns: the id, or `nil` when nothing usable is stored.
    public static func stored(in defaults: UserDefaults = .standard) -> String? {
        let value = defaults.string(forKey: hostIdKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty ?? true) ? nil : value
    }

    /// Remember the machine the operator just opened, or forget the memory.
    ///
    /// Written whenever a machine is opened or paired, not when a connection
    /// succeeds: it records where the operator chose to be, which is the
    /// question the next launch has. A machine that is offline at launch shows
    /// its own failure on its own screen; silently opening a different Mac
    /// instead is exactly the behaviour this file exists to remove.
    ///
    /// - Parameters:
    ///   - hostId: the machine's id, or `nil` to forget.
    ///   - defaults: where to write.
    /// - Returns: whether the stored value changed.
    @discardableResult
    public static func store(_ hostId: String?, in defaults: UserDefaults = .standard) -> Bool {
        let trimmed = hostId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = (trimmed?.isEmpty ?? true) ? nil : trimmed
        guard stored(in: defaults) != next else { return false }
        if let next {
            defaults.set(next, forKey: hostIdKey)
        } else {
            defaults.removeObject(forKey: hostIdKey)
        }
        return true
    }
}
