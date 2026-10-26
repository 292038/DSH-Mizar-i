//
//  RoutePolicy.swift
//  MizarKit
//
//  Which of a pairing's routes the operator's switches allow at all.
//
//  The two transport switches used to be read as *preferences*: 局域网优先
//  decided whether a reconnect asked the local network question first, and 直连
//  decided whether a punched route was planned. Neither stopped a route from
//  being dialled. A phone paired over the LAN therefore kept reconnecting over
//  the LAN with 局域网优先 switched off -- the stored direct address was simply
//  first in the pairing, and nothing consulted the switch when the socket was
//  built. The switch looked like an off switch and behaved like a hint.
//
//  So the question is asked once, here, about a route: may this phone use it
//  while the switches are where they are. Everything that dials -- the reconnect
//  plan, an exact route, the route a pairing just used, and the decision to drop
//  a link that is up -- reads this and nothing else, because two readings of the
//  same two switches are two policies that can disagree.
//
//  Relay is always allowed. It is the route that works from anywhere, and a
//  policy that could disable it would leave a phone with no way to reach its
//  computer and no explanation on screen.
//

import Foundation

/// The operator's answer to "which routes may this phone dial".
public enum RoutePolicy {
    /// Whether one route is allowed.
    ///
    /// - Parameters:
    ///   - endpoint: the route.
    ///   - localNetworkFirst: the 局域网优先 switch. Off forbids the direct route
    ///     entirely -- not merely de-prioritises it.
    ///   - directConnection: the 直连 switch. Off forbids the punched route.
    /// - Returns: whether a reconnect may use this route.
    public static func allows(
        _ endpoint: PairedHost.Endpoint,
        localNetworkFirst: Bool,
        directConnection: Bool,
    ) -> Bool {
        switch endpoint {
        case .direct: localNetworkFirst
        case .p2p: directConnection
        case .relay: true
        }
    }

    /// The routes that are allowed, keeping the caller's order.
    ///
    /// - Parameters:
    ///   - endpoints: every route the pairing knows.
    ///   - localNetworkFirst: the 局域网优先 switch.
    ///   - directConnection: the 直连 switch.
    /// - Returns: the allowed routes, in the order they arrived; empty when the
    ///   pairing has no route the switches allow.
    public static func allowed(
        _ endpoints: [PairedHost.Endpoint],
        localNetworkFirst: Bool,
        directConnection: Bool,
    ) -> [PairedHost.Endpoint] {
        endpoints.filter {
            allows($0, localNetworkFirst: localNetworkFirst, directConnection: directConnection)
        }
    }
}
