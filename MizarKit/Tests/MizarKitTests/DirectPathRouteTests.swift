//
//  DirectPathRouteTests.swift
//  MizarKitTests
//
//  The punched route as a route: what a pairing knows, what it plans, and what
//  it dials.
//
//  Three things are worth testing here and none of them is the punch itself --
//  ``MizarNetQUICEngineTests`` covers that over real UDP. What is tested is the
//  seam between a pairing and the kernel:
//
//  - a pairing recorded before this feature existed still decodes, because the
//    field is optional and synthesised decoding treats a missing optional as
//    absent rather than as corruption;
//  - a pairing that knows a key plans the punched route *between* the direct
//    address and the relay, and drops it entirely when the operator has not
//    asked for it;
//  - the connection hands the kernel a `mizar-net://` URL rather than a
//    WebSocket one, which is the whole difference between this route and the
//    other two.
//

import Foundation
import Testing
@testable import MizarKit

/// A pairing, with whatever the test needs set.
private func pairing(
    authority: String? = nil,
    baseURL: String? = nil,
    netEndpointId: String? = nil,
) -> PairedHost {
    PairedHost(
        hostId: "host-1",
        hostName: "Studio",
        authority: authority,
        deviceId: "device-1",
        deviceToken: "token-1",
        baseURL: baseURL,
        netEndpointId: netEndpointId,
    )
}

@Suite("The pairing record")
struct PairedHostDirectPathTests {
    @Test("a record written before the direct path still decodes")
    func decodesWithoutTheField() throws {
        // The shape a 0.9.6 pairing has on disk: no `netEndpointId` at all.
        let text = """
        {"hostId":"host-1","hostName":"Studio","deviceId":"device-1",\
        "deviceToken":"token-1","pairedAt":700000000,"baseURL":"https://relay.example.com/r/ROOM"}
        """
        let host = try JSONDecoder().decode(PairedHost.self, from: Data(text.utf8))
        // Absent is absent, not an error and not an empty string: a pairing that
        // has never heard of the direct path must survive the upgrade intact.
        #expect(host.netEndpointId == nil)
        #expect(host.baseURL == "https://relay.example.com/r/ROOM")
        #expect(host.deviceToken == "token-1")
    }

    @Test("round-trips the identity")
    func roundTripsTheField() throws {
        let host = pairing(baseURL: "https://relay.example.com/r/ROOM", netEndpointId: "KEY")
        let data = try JSONEncoder().encode(host)
        let decoded = try JSONDecoder().decode(PairedHost.self, from: data)
        #expect(decoded == host)
        #expect(decoded.netEndpointId == "KEY")
    }

    @Test("every copy carries the identity with it")
    func copiesKeepTheField() {
        let host = pairing(baseURL: "https://relay.example.com/r/ROOM", netEndpointId: "KEY")
        // Three hand-written copies, and a missing field in any of them would
        // cost the route silently -- after a rename, an address change or a
        // relay move, which is exactly when nobody would look here.
        #expect(host.renamed(to: "Desk").netEndpointId == "KEY")
        #expect(host.moved(to: "10.0.0.9:19390").netEndpointId == "KEY")
        #expect(host.moved(toRelay: "https://other.example.com/r/ROOM").netEndpointId == "KEY")
        #expect(host.remembering(netEndpointId: "KEY2").netEndpointId == "KEY2")
        // And the rest of the record survives the new copy too.
        let remembered = host.remembering(netEndpointId: "KEY2")
        #expect(remembered.deviceToken == host.deviceToken)
        #expect(remembered.baseURL == host.baseURL)
    }
}

@Suite("Routes a pairing offers")
struct PairingEndpointTests {
    @Test("plans the punched route between the address and the relay")
    func order() {
        let host = pairing(
            authority: "192.168.1.5:19390",
            baseURL: "https://relay.example.com/r/ROOM",
            netEndpointId: "KEY",
        )
        #expect(host.endpoints == [
            .direct(authority: "192.168.1.5:19390"),
            .p2p(relayBaseURL: "https://relay.example.com/r/ROOM", endpointId: "KEY"),
            .relay(baseURL: "https://relay.example.com/r/ROOM"),
        ])
    }

    @Test("offers no punched route without a key or without a room")
    func needsBothHalves() {
        // A host that has not reported an identity: the route cannot exist,
        // because there is nothing to authenticate the far end by.
        let noKey = pairing(
            authority: "192.168.1.5:19390",
            baseURL: "https://relay.example.com/r/ROOM",
        )
        #expect(!noKey.endpoints.contains { $0.isDirectPath })
        #expect(noKey.endpoints.count == 2)

        // A key but no relay: no room carries the signaling, so there is
        // nowhere to exchange candidates. The relay is not a fallback here, it
        // is the side channel.
        let noRoom = pairing(authority: "192.168.1.5:19390", netEndpointId: "KEY")
        #expect(!noRoom.endpoints.contains { $0.isDirectPath })
        #expect(noRoom.endpoints.count == 1)
    }

    @Test("a punched route is neither the local network nor the relay")
    func classification() {
        let punched = PairedHost.Endpoint.p2p(relayBaseURL: "https://relay.example.com/r/ROOM", endpointId: "KEY")
        #expect(punched.isDirectPath)
        // Not local: the two ends may be in different cities. The features that
        // ask "are we on the same LAN" must keep answering no.
        #expect(!punched.isLocalNetwork)
        // Not the relay: its bytes do not pass through one. `ReconnectPlan`
        // uses this to decide what is worth holding the relay back for.
        #expect(!ReconnectPlan.isRelay(punched))
    }
}

@Suite("The signaling URL")
struct SignalingURLTests {
    @Test("is the room with the signaling path appended")
    func forms() {
        let url = PairingURI.relaySignalWebSocketURL(baseURL: "https://relay.example.com/r/ROOM")
        #expect(url?.absoluteString == "wss://relay.example.com/r/ROOM/mizar-net/signal")
        // The room's own path survives: this is the same room the tunnel is in,
        // which is what pairs the two sockets at the relay.
        #expect(mizarNetSignalPath == "/mizar-net/signal")
    }

    @Test("keeps a local relay on ws")
    func plainText() {
        #expect(
            PairingURI.relaySignalWebSocketURL(baseURL: "http://127.0.0.1:8787/r/ROOM")?.absoluteString
                == "ws://127.0.0.1:8787/r/ROOM/mizar-net/signal",
        )
    }

    @Test("refuses a base that is not a URL")
    func rejects() {
        #expect(PairingURI.relaySignalWebSocketURL(baseURL: "not a url") == nil)
    }
}

@Suite("Planning with the punched route")
struct DirectPathPlanTests {
    private let direct = PairedHost.Endpoint.direct(authority: "192.168.1.5:19390")
    private let punched = PairedHost.Endpoint.p2p(
        relayBaseURL: "https://relay.example.com/r/ROOM",
        endpointId: "KEY",
    )
    private let relay = PairedHost.Endpoint.relay(baseURL: "https://relay.example.com/r/ROOM")

    @Test("plans it when the operator asked for it")
    func allowed() {
        let routes = ReconnectPlan.routes(
            endpoints: [direct, punched, relay],
            active: nil,
            allowingDirectPath: true,
        )
        #expect(routes == [direct, punched, relay])
        #expect(ReconnectPlan.attempts(routeCount: routes.count, patient: false) == 3)
    }

    @Test("drops it, and its memory, when the operator did not")
    func withheld() {
        let routes = ReconnectPlan.routes(
            endpoints: [direct, punched, relay],
            active: nil,
            allowingDirectPath: false,
        )
        #expect(routes == [direct, relay])
        // Switching the feature off has to take effect on the next reconnect,
        // not on the next pairing: a last-working route of `.p2p` must not be
        // planned either.
        let remembered = ReconnectPlan.routes(
            endpoints: [direct, punched, relay],
            active: punched,
            allowingDirectPath: false,
        )
        #expect(remembered == [direct, relay])
    }

    @Test("still puts the relay first when a local link has just died")
    func preferringRelay() {
        let routes = ReconnectPlan.routes(
            endpoints: [direct, punched, relay],
            active: direct,
            preferringRelay: true,
            allowingDirectPath: true,
        )
        // The relay is the route that does not share the network that broke;
        // the punched one does, because its signaling rides the same network.
        #expect(routes.first == relay)
        #expect(routes.contains(punched))
    }
}

@Suite("Dialing a punched route")
struct P2PDialTests {
    @Test("hands the transport a mizar-net URL, not a WebSocket one")
    func dialsTheTicketScheme() async {
        // A real key: the ticket format refuses anything that is not 32 bytes of
        // base64url, so a placeholder would fail at the transport rather than at
        // the thing under test.
        let endpointId = MizarNetIdentity.generate().endpointId
        let socket = StubTransport()
        let connection = MizarConnection(
            configuration: .init(
                authority: nil,
                token: "token-1",
                // Short enough that the missing welcome ends the attempt rather
                // than the test.
                handshakeTimeout: .milliseconds(50),
                p2p: P2PRoute(
                    relayBaseURL: "https://relay.example.com/r/ROOM",
                    endpointId: endpointId,
                ),
            ),
            makeTransport: { socket },
        )
        _ = try? await connection.connect()

        let dialed = await socket.dialed
        #expect(dialed.count == 1)
        #expect(dialed.first?.scheme == MizarNetDialURL.scheme)
        // The ticket names the far end by key; the room travels as a hint so a
        // ticket read off this URL elsewhere still says where the relays are.
        var ticket: MizarNetTicket?
        if let url = dialed.first { ticket = try? MizarNetDialURL.ticket(from: url) }
        #expect(ticket?.endpointId == endpointId)
        #expect(ticket?.relays == ["https://relay.example.com/r/ROOM"])
        // No identity headers: nothing on this route reaches the relay that
        // would need to know who is paying.
        #expect(await socket.dialedHeaders.first?.isEmpty ?? false)
    }

    @Test("a relay route still dials the tunnel")
    func relayUnchanged() async {
        let socket = StubTransport()
        let connection = MizarConnection(
            configuration: .init(
                authority: nil,
                token: "token-1",
                baseURL: "https://relay.example.com/r/ROOM",
                handshakeTimeout: .milliseconds(50),
            ),
            makeTransport: { socket },
        )
        _ = try? await connection.connect()
        let dialed = await socket.dialed
        #expect(dialed.first?.absoluteString == "wss://relay.example.com/r/ROOM/mizar/v1/ws")
    }
}

@Suite("The phone's own identity")
struct DeviceIdentityTests {
    @Test("is stable for one pairing and distinct per purpose")
    func derivation() {
        let first = MizarNetIdentity.device(forDeviceToken: "token-1")
        let second = MizarNetIdentity.device(forDeviceToken: "token-1")
        #expect(first.endpointId == second.endpointId)

        // A different token is a different phone.
        #expect(MizarNetIdentity.device(forDeviceToken: "token-2").endpointId != first.endpointId)

        // A digest is used, not the token itself: the seed must not be the
        // bytes of a credential that can control a host.
        let raw = MizarNetIdentity.derived(from: Data("token-1".utf8), purpose: .device)
        #expect(raw.endpointId != first.endpointId)

        // And the purpose is part of the derivation, so a phone key can never
        // collide with a host key derived from the same secret.
        #expect(MizarNetIdentity.derived(from: Data(repeating: 7, count: 32), purpose: .host).endpointId
            != MizarNetIdentity.derived(from: Data(repeating: 7, count: 32), purpose: .device).endpointId)
    }
}
