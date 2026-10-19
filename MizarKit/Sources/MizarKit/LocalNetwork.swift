//
//  LocalNetwork.swift
//  MizarKit
//
//  Whether a direct address is the operator's own network.
//
//  The app reaches a computer over one of two kinds of route: straight at an
//  address the pairing knows, or through the relay. The direct route costs the
//  operator nothing beyond their own network, and the relay is what a paid
//  account buys bandwidth on -- so "which of the two is in use" is the
//  difference between a feature that is free and one that is paid. That makes
//  this classification a product decision, not a networking detail, and it
//  belongs here where both the rule and its tests live rather than in a view.
//
//  Loopback is deliberately not local. On a phone it never appears at all; on
//  the simulator it is how the app talks to the test fixture running on the
//  Mac, and counting it would turn every UI test into a LAN-enabled account.
//  Everything else that is direct counts: a Wi-Fi address, a link-local
//  address, a `.local` name, a tailnet address. They all share the property
//  this rule is about -- the bytes do not pass through the relay.
//

import Foundation

/// The rule that says whether a direct address is on the operator's own network.
public enum LocalNetwork {
    /// Whether an authority is a local-network route.
    ///
    /// - Parameter authority: `host:port`, as the pairing carries it. An IPv6
    ///   literal arrives bracketed (`[fe80::1%en0]:19390`).
    /// - Returns: `true` for an address the relay is not carrying, `false` for
    ///   loopback, an empty host, or an address that cannot be read.
    public static func isLocal(authority: String) -> Bool {
        guard let host = host(of: authority) else { return false }
        return !isLoopback(host)
    }

    /// Whether an authority dials this device itself.
    ///
    /// - Parameter authority: `host:port`.
    /// - Returns: `true` for the loopback range, `localhost`, and the
    ///   unspecified addresses that resolve to this device.
    public static func isLoopback(authority: String) -> Bool {
        guard let host = host(of: authority) else { return false }
        return isLoopback(host)
    }

    /// Why an authority is not a local-network route, when it is not.
    ///
    /// A string for the log and the connection window's diagnostics: "the relay"
    /// and "this device itself" are different answers to the same question, and
    /// the simulators' fixtures are the only place the second one appears.
    ///
    /// - Parameter authority: `host:port`.
    /// - Returns: a short reason, or `nil` when the address is local.
    public static func reasonNotLocal(authority: String) -> String? {
        guard let host = host(of: authority) else { return "unreadable address" }
        return isLoopback(host) ? "loopback address" : nil
    }

    // MARK: - Internals

    /// The host part of an authority, normalised for comparison.
    ///
    /// A hand-written split rather than `URL`, because an authority here is not
    /// a URL and was chosen to avoid the scheme the app cannot know: `URL` will
    /// happily read `host:port` as a scheme and a path, and an IPv6 literal is
    /// bracketed precisely so that its colons survive being put in one place.
    ///
    /// - Parameter authority: `host:port`.
    /// - Returns: the lowercased host, without brackets or an IPv6 zone index,
    ///   or `nil` when there is nothing to compare.
    private static func host(of authority: String) -> String? {
        var raw = authority.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if raw.hasPrefix("[") {
            guard let end = raw.firstIndex(of: "]") else { return nil }
            raw = String(raw[raw.index(after: raw.startIndex)..<end])
        } else {
            // One colon is a port separator; two or more is an unbracketed IPv6
            // literal, where the last colon may be a port and may not.
            let colons = raw.filter { $0 == ":" }.count
            if colons == 1, let colon = raw.lastIndex(of: ":") {
                raw = String(raw[..<colon])
            }
        }
        if let zone = raw.firstIndex(of: "%") { raw = String(raw[..<zone]) }
        raw = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        return raw.isEmpty ? nil : raw
    }

    /// Whether a normalised host is this device itself.
    ///
    /// - Parameter host: the host part, lowercased.
    /// - Returns: `true` for the loopback range and the unspecified addresses.
    private static func isLoopback(_ host: String) -> Bool {
        if host == "localhost" || host == "::1" || host == "::" || host == "0.0.0.0" {
            return true
        }
        // The whole 127/8 range is loopback, not only 127.0.0.1.
        if host.hasPrefix("127.") { return true }
        // An IPv4-mapped IPv6 loopback (`::ffff:127.0.0.1`) is the same place.
        if host.hasPrefix("::ffff:") { return isLoopback(String(host.dropFirst("::ffff:".count))) }
        return false
    }
}
