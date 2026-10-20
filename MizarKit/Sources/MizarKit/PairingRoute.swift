//
//  PairingRoute.swift
//  MizarKit
//
//  Which way a pairing attempt dials, and in what order.
//
//  A plugin 0.8.5+ QR carries two addresses: `h`, the address the computer is
//  listening on, and `u`, the relay base URL the same room is reachable through.
//  iOS 0.9.3 read both and used one -- the direct route whenever `h` was
//  present -- so a phone that could not reach the LAN address (cellular, a
//  client-isolated Wi-Fi, a denied local-network permission, an address that had
//  gone stale) could never complete first pairing, although the relay in the
//  same code was answering. Reconnect has always tried both; pairing must too.
//
//  So the plan is a decision, pure and testable without a network:
//
//    - the direct route first when the QR carries one, because the operator's
//      own network is faster and involves nobody else;
//    - the relay behind it, which is the route that still works when the first
//      one cannot -- and on a phone that has never reached this computer, it is
//      the only evidence the computer is reachable at all;
//    - each route carrying its own timeout, because a dead LAN address that is
//      allowed the default thirty seconds leaves the operator looking at a
//      pairing screen they have already given up on by the time the relay is
//      tried.
//
//  A route is only a way to dial, not an answer. Whether one failure should fall
//  through to the next route is decided in ``PairingClient``, from whether the
//  host answered at all.
//

import Foundation

/// One way a pairing attempt can reach the computer.
public enum PairingRoute: Sendable, Equatable {
    /// Straight to `host:port` -- the same Wi-Fi, or a tailnet.
    case direct(authority: String)
    /// Through a reverse tunnel; the room is part of the base URL.
    case relay(baseURL: String)

    /// How long one attempt over this route may take.
    ///
    /// The same two leashes the socket connection gives its routes: six seconds
    /// is enough for a direct address on a network that is going to answer at
    /// all, and a relay that is reachable but slow is worth waiting for. The
    /// numbers mirror `AppModel.makeConnection` and have to stay in step with
    /// it -- an attempt that waits longer than the connection already does
    /// turns the fallback into a stall.
    public var timeout: TimeInterval {
        switch self {
        case .direct: Self.directTimeout
        case .relay: Self.relayTimeout
        }
    }

    /// The direct attempt's leash, in seconds.
    public static let directTimeout: TimeInterval = 6
    /// The relay attempt's leash, in seconds.
    public static let relayTimeout: TimeInterval = 20

    /// `host:port`, for a direct route.
    public var authority: String? {
        if case .direct(let authority) = self { return authority }
        return nil
    }

    /// The relay base URL, for a relayed route.
    public var baseURL: String? {
        if case .relay(let baseURL) = self { return baseURL }
        return nil
    }

    /// Whether this route goes through the relay.
    public var isRelay: Bool {
        if case .relay = self { return true }
        return false
    }

    /// The address to name when this route is logged or explained.
    public var address: String { authority ?? baseURL ?? "" }

    /// How the route reads in a log line, e.g. `direct 10.0.0.5:19390`.
    public var description: String { "\(isRelay ? "relay" : "direct") \(address)" }

    /// The route as a stored pairing records it.
    ///
    /// A pairing keeps the same two fields the QR carried, and the socket
    /// connection addresses its routes as ``PairedHost/Endpoint``. Conversion
    /// rather than a second enum, so the route that just paired and the
    /// reconnect plan speak the same type.
    public var endpoint: PairedHost.Endpoint {
        switch self {
        case .direct(let authority): .direct(authority: authority)
        case .relay(let baseURL): .relay(baseURL: baseURL)
        }
    }

    /// The HTTP URL for one step of pairing over this route.
    ///
    /// - Parameter path: the path to append, beginning with a slash.
    /// - Returns: the URL.
    /// - Throws: ``MizarError`` `BAD_AUTHORITY` when the route cannot be dialled
    ///   at all. A scanned address is untrusted input, and this is where it
    ///   stops being a route and becomes a failure with something to say.
    public func url(path: String) throws -> URL {
        let url: URL?
        switch self {
        case .direct(let authority):
            url = PairingURI.httpURL(authority: authority, path: path)
        case .relay(let baseURL):
            url = PairingURI.relayHTTPURL(baseURL: baseURL, path: path)
        }
        guard let url else {
            throw MizarError(
                code: "BAD_AUTHORITY",
                message: "\"\(address)\" is not an address this app can dial",
            )
        }
        return url
    }
}

/// The ordered route plan a pairing follows.
public enum PairingRoutes {
    /// The routes a scanned QR carries, in the order to try them.
    ///
    /// Direct first when the code carries one, then the relay. Either may be
    /// absent -- a LAN-only plugin puts just `h`, a relay-only setup just `u` --
    /// and the parser guarantees at least one is present, so an empty plan means
    /// the target was built by hand without a dialable address.
    ///
    /// - Parameter target: the decoded QR.
    /// - Returns: the routes to try, or an empty array when the target names no
    ///   address this client can dial.
    public static func plan(for target: PairingTarget) -> [PairingRoute] {
        var routes: [PairingRoute] = []
        // The direct address is not validated here: an unusable one is a route
        // that can never be dialled, and ``PairingClient`` falls through it to
        // the relay for the same reason it falls through a transport failure --
        // nothing was sent, so no host has answered yet.
        if let authority = target.authority, !authority.isEmpty {
            routes.append(.direct(authority: authority))
        }
        if let baseURL = target.baseURL, !baseURL.isEmpty, PairingURI.isUsableBaseURL(baseURL) {
            routes.append(.relay(baseURL: baseURL))
        }
        return routes
    }
}
