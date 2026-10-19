//
//  LANRouteTests.swift
//  MizarKitTests
//
//  The rule that decides whether a direct address is the operator's own network,
//  and the optional field that lets a relayed phone discover one.
//
//  This rule is load-bearing for a product decision: on a LAN route the app
//  unlocks the features the relay's bandwidth normally pays for, so a false
//  positive here grants a paid feature for free, and a false negative leaves a
//  free account looking at a lock it should not see. Every address shape the
//  pairing can carry is pinned below, including the two that must never count:
//  loopback (the simulator's fixture) and the relay.
//

import Foundation
import Testing

@testable import MizarKit

@Suite("Local-network routes")
struct LANRouteTests {
    @Test(
        "a direct address that is not loopback is a local route",
        arguments: [
            "192.168.1.42:19390",
            "10.0.0.5:19390",
            "172.16.31.7:19390",
            "169.254.11.2:19390",
            "100.64.0.9:19390",           // a tailnet address: direct, not relayed
            "Shirazus-Mac-mini.local:19390",
            "my-computer:19390",
            "fe80::1:19390",
            "[fe80::1%en0]:19390",
            "[fd00::42]:19390",
        ],
    )
    func directIsLocal(authority: String) {
        #expect(LocalNetwork.isLocal(authority: authority))
        #expect(!LocalNetwork.isLoopback(authority: authority))
    }

    @Test(
        "loopback and the unspecified address are not a local network",
        arguments: [
            "127.0.0.1:19395",
            "127.1.2.3:19390",
            "localhost:19395",
            "LOCALHOST:19395",
            "[::1]:19395",
            "0.0.0.0:19390",
            "[::ffff:127.0.0.1]:19390",
        ],
    )
    func loopbackIsNotLocal(authority: String) {
        #expect(!LocalNetwork.isLocal(authority: authority))
        #expect(LocalNetwork.isLoopback(authority: authority))
    }

    @Test("an address without a usable host is not local")
    func emptyOrUnreadableIsNotLocal() {
        #expect(!LocalNetwork.isLocal(authority: ""))
        #expect(!LocalNetwork.isLocal(authority: "   "))
        #expect(!LocalNetwork.isLocal(authority: "[fe80::1"))
        #expect(LocalNetwork.reasonNotLocal(authority: "") == "unreadable address")
    }

    @Test("a loopback reason is different from an unreadable one")
    func reasonExplainsTheRefusal() {
        #expect(LocalNetwork.reasonNotLocal(authority: "127.0.0.1:1") == "loopback address")
        #expect(LocalNetwork.reasonNotLocal(authority: "192.168.1.2:1") == nil)
    }

    @Test("only the direct endpoint can be local")
    func relayIsNeverLocal() {
        let direct = PairedHost.Endpoint.direct(authority: "192.168.1.42:19390")
        let loopback = PairedHost.Endpoint.direct(authority: "127.0.0.1:19395")
        let relay = PairedHost.Endpoint.relay(baseURL: "https://relay.example.com/r/ROOM")
        #expect(direct.isLocalNetwork)
        #expect(!loopback.isLocalNetwork)
        #expect(!relay.isLocalNetwork)
    }
}

@Suite("Host.info addresses")
struct HostInfoAddressesTests {
    @Test("the addresses field decodes when the host sends it")
    func decodesAddresses() throws {
        let json = Data(#"""
        {
          "hostId": "h1",
          "hostName": "Mac",
          "home": "/Users/you",
          "protocolVersion": 1,
          "addresses": ["192.168.1.42:19390", "10.0.0.5:19390"]
        }
        """#.utf8)
        let info = try JSONDecoder().decode(HostInfo.self, from: json)
        #expect(info.addresses == ["192.168.1.42:19390", "10.0.0.5:19390"])
    }

    @Test("an older host's answer decodes with no addresses at all")
    func decodesWithoutAddresses() throws {
        // The golden fixture is a real 0.8.4 host's answer: no `addresses` key.
        // Decoding it must produce nil, not a decode failure -- the same answer
        // a host that has not been updated sends.
        let json = Data(#"""
        {"hostId":"h1","hostName":"Mac","home":"/Users/you","protocolVersion":1}
        """#.utf8)
        let info = try JSONDecoder().decode(HostInfo.self, from: json)
        #expect(info.addresses == nil)
        #expect(info.hostId == "h1")
    }
}
