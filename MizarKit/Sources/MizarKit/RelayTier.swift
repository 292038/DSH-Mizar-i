//
//  RelayTier.swift
//  MizarKit
//
//  The two public relays, and how a pairing moves between them.
//
//  A paid account's tunnel belongs on the account relay; a free account's on the
//  free relay. The host cannot know which one a phone's account is, so the phone
//  asks the host to move (`relay.set`) and keeps the base URL it stores in
//  `PairedHost.baseURL` in step with the answer.
//
//  Two rules keep that safe:
//
//  1. **Only these two origins are selectable.** The host owns the same
//     allowlist; this side never asks for anywhere else.
//  2. **The room is in the path, not the origin.** Moving relays keeps
//     `/r/<room>` and only swaps the scheme and host, which is what lets an old
//     stored URL be repaired by trying the other relay with the same room.
//

import Foundation

/// The relay tier a pairing's tunnel should use.
public enum RelayTier {
    /// The free relay's origin.
    public static let freeBaseURL = "https://dshmizar.shirazu-nagisa.com"
    /// The account (paid) relay's origin.
    public static let paidBaseURL = "https://dshmizar-1.shirazu-nagisa.com"

    /// The origin the tunnel should use for an account.
    /// - Parameter paid: whether the signed-in account is paid.
    /// - Returns: the matching relay origin.
    public static func baseURL(paid: Bool) -> String {
        paid ? paidBaseURL : freeBaseURL
    }

    /// Whether an origin is one of the two public relays.
    /// - Parameter baseURL: a relay origin or a room URL under one.
    /// - Returns: whether it is a public relay.
    public static func isPublicRelay(_ baseURL: String) -> Bool {
        canonicalOrigin(baseURL) == freeBaseURL || canonicalOrigin(baseURL) == paidBaseURL
    }

    /// Whether an origin is the account relay.
    /// - Parameter baseURL: a relay origin or a room URL under one.
    /// - Returns: whether it is the paid relay.
    public static func isPaidRelay(_ baseURL: String) -> Bool {
        canonicalOrigin(baseURL) == paidBaseURL
    }

    /// The scheme-and-host of a URL, lowercased, without a trailing slash.
    /// - Parameter value: the URL.
    /// - Returns: the origin, or `nil` when it does not parse.
    public static func canonicalOrigin(_ value: String) -> String? {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              scheme == "https" || scheme == "http"
        else { return nil }
        let port = components.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    /// The other public relay, preserving the room path.
    ///
    /// Used as a fallback when a phone's stored relay URL is stale because the
    /// host moved while the phone was offline. A URL outside the two public
    /// relays has no alternate: a self-hosted relay is the only place that host
    /// can be.
    ///
    /// - Parameter baseURL: the stored relay URL (origin, or origin plus `/r/<room>`).
    /// - Returns: the same path under the other public relay, or `nil`.
    public static func alternate(to baseURL: String) -> String? {
        guard let origin = canonicalOrigin(baseURL) else { return nil }
        let other: String
        switch origin {
        case freeBaseURL: other = paidBaseURL
        case paidBaseURL: other = freeBaseURL
        default: return nil
        }
        guard let components = URLComponents(string: baseURL) else { return nil }
        let path = components.percentEncodedPath
        return other + path
    }

    /// Rebase a room URL onto another relay origin, preserving its path.
    ///
    /// - Parameters:
    ///   - baseURL: an existing room URL, e.g. `https://dshmizar.../r/ROOM`.
    ///   - origin: the relay origin to move it to.
    /// - Returns: the room URL under `origin`, or `nil` when either does not parse.
    public static func rebased(_ baseURL: String, onto origin: String) -> String? {
        guard let components = URLComponents(string: baseURL),
              let originComponents = URLComponents(string: origin),
              let scheme = originComponents.scheme,
              let host = originComponents.host
        else { return nil }
        var port = ""
        if let value = originComponents.port { port = ":\(value)" }
        return "\(scheme)://\(host)\(port)\(components.percentEncodedPath)"
    }
}
