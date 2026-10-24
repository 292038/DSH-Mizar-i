//
//  DiagnosisTests.swift
//  MizarKitTests
//
//  The failure this exists for: a phone on cellular timing out against a
//  tailnet address, and the app answering with a page of NSError.
//

import Foundation
import Testing
@testable import MizarKit

@Suite("Connection diagnosis")
struct DiagnosisTests {
    @Test("recognises the tailnet IPv4 block")
    func tailnetIPv4() {
        // 100.64.0.0/10, so the second octet runs 64 through 127.
        #expect(ConnectionDiagnosis.isTailnet("100.64.0.1:19390"))
        #expect(ConnectionDiagnosis.isTailnet("100.100.172.14:19390"))
        #expect(ConnectionDiagnosis.isTailnet("100.127.255.254"))
        #expect(!ConnectionDiagnosis.isTailnet("100.63.0.1"))
        #expect(!ConnectionDiagnosis.isTailnet("100.128.0.1"))
        #expect(!ConnectionDiagnosis.isTailnet("192.168.1.5"))
    }

    @Test("recognises the tailnet IPv6 prefix")
    func tailnetIPv6() {
        #expect(ConnectionDiagnosis.isTailnet("fd7a:115c:a1e0::7401:acde"))
        #expect(ConnectionDiagnosis.isTailnet("[fd7a:115c:a1e0::1]:19390"))
        #expect(!ConnectionDiagnosis.isTailnet("fd00::1"))
    }

    @Test("a timeout against a tailnet address means the phone is not on it")
    func timeoutOnTailnet() {
        let error = URLError(.timedOut)
        let diagnosis = ConnectionDiagnosis.of(error, authority: "100.100.172.14:19390")
        #expect(diagnosis == .outsideTailnet(authority: "100.100.172.14:19390"))
        // The message has to name the action, not the symptom.
        #expect(diagnosis.message.contains("Tailscale"))
        #expect(diagnosis.message.contains("100.100.172.14:19390"))
    }

    @Test("a timeout on a LAN address is a different problem with a different fix")
    func timeoutOnLAN() {
        let diagnosis = ConnectionDiagnosis.of(URLError(.timedOut), authority: "192.168.1.5:19390")
        #expect(diagnosis == .silent(authority: "192.168.1.5:19390"))
        // Opening Tailscale would not help here, so it must not be suggested.
        #expect(!diagnosis.message.contains("Tailscale"))
    }

    @Test("a refused connection means the tailnet is fine and the host is not")
    func refusedOnTailnet() {
        let diagnosis = ConnectionDiagnosis.of(
            URLError(.cannotConnectToHost),
            authority: "100.100.172.14:19390",
        )
        #expect(diagnosis == .tailnetPeerSilent(authority: "100.100.172.14:19390"))
        #expect(diagnosis.message.contains("DSH is running"))
    }

    @Test("no network is reported as no network")
    func offline() {
        #expect(ConnectionDiagnosis.of(URLError(.notConnectedToInternet), authority: "x") == .offline)
        #expect(ConnectionDiagnosis.of(URLError(.dataNotAllowed), authority: "x") == .offline)
    }

    @Test("an unresolvable name is reported as one")
    func unknownHost() {
        let diagnosis = ConnectionDiagnosis.of(URLError(.cannotFindHost), authority: "nope.local:1")
        #expect(diagnosis == .unknownHost(authority: "nope.local:1"))
        #expect(diagnosis.message.contains("nope.local:1"))
    }

    @Test("an unrelated error keeps the system's own words")
    func other() {
        struct Boom: LocalizedError { var errorDescription: String? { "something specific" } }
        #expect(ConnectionDiagnosis.of(Boom(), authority: "x") == .other(detail: "something specific"))
    }

    @Test("never shows a raw NSError dump")
    func noRawDump() {
        // The original bug: the screen showed the whole UserInfo dictionary.
        for authority in ["100.100.172.14:19390", "192.168.1.5:19390", "nope.local:1"] {
            let message = ConnectionDiagnosis.of(URLError(.timedOut), authority: authority).message
            #expect(!message.contains("UserInfo"))
            #expect(!message.contains("_kCFStreamErrorCodeKey"))
            #expect(!message.contains("NSURLErrorDomain"))
        }
    }
}

/// The two halves of a relayed trip.
///
/// The relay answers a WebSocket upgrade with a status when it is up and
/// something behind it is not: `404` for a room with no computer attached. That
/// answer used to reach the screen as `URLError(-1011)`, whose only sentence is
/// "there was a bad response from the server" -- true of a computer that is
/// switched off and of a server that cannot be reached, which are the two
/// situations an operator needs told apart.
@Suite("Relayed connection diagnosis")
struct RelayedDiagnosisTests {
    @Test("a relay that answers 404 means the computer is not connected")
    func computerAbsent() {
        let diagnosis = ConnectionDiagnosis.of(
            WebSocketUpgradeRefused(status: 404, url: URL(string: "wss://relay.example/r/ROOM")!),
            authority: "https://relay.example",
            over: .server,
        )
        #expect(diagnosis == .serverReachedComputerAbsent)
        #expect(!diagnosis.message.isEmpty)
    }

    @Test("410 says the same thing in the other vocabulary")
    func gone() {
        #expect(WebSocketUpgradeRefused(status: 410).meansComputerAbsent)
        #expect(!WebSocketUpgradeRefused(status: 402).meansComputerAbsent)
        #expect(!WebSocketUpgradeRefused(status: 503).meansComputerAbsent)
    }

    @Test("a server that refuses for its own reasons is not the computer's fault")
    func serverRefused() {
        for status in [402, 403, 429, 500, 503] {
            let diagnosis = ConnectionDiagnosis.of(
                WebSocketUpgradeRefused(status: status),
                authority: "https://relay.example",
                over: .server,
            )
            #expect(diagnosis == .serverUnreachable, "status \(status)")
        }
    }

    @Test("a relay that cannot be reached is not the computer's fault either")
    func serverUnreachable() {
        for code in [URLError.timedOut, .cannotConnectToHost, .networkConnectionLost, .cannotFindHost] {
            let diagnosis = ConnectionDiagnosis.of(URLError(code), authority: "https://relay.example", over: .server)
            #expect(diagnosis == .serverUnreachable, "\(code)")
        }
    }

    @Test("no network is still said plainly, whichever hop failed")
    func offlineOverServer() {
        #expect(
            ConnectionDiagnosis.of(
                URLError(.notConnectedToInternet),
                authority: "https://relay.example",
                over: .server,
            ) == .offline,
        )
    }

    @Test("a handshake that never completed over a relay is the computer, not the server")
    func silentHandshake() {
        // The relay defers its upgrade until the computer accepts, so this is
        // rare -- and it is the one host-shaped failure that is really about the
        // hop: the server accepted the socket and nothing behind it said hello.
        let diagnosis = ConnectionDiagnosis.of(
            MizarError(code: "REQUEST_TIMEOUT", message: "the host did not say hello in time", retryable: true),
            authority: "https://relay.example",
            over: .server,
        )
        #expect(diagnosis == .serverReachedComputerAbsent)
    }

    @Test("a host's own refusal is still its own words")
    func hostRefusal() {
        let diagnosis = ConnectionDiagnosis.of(
            MizarError(code: "UNAUTHENTICATED", message: "this device is not paired"),
            authority: "https://relay.example",
            over: .server,
        )
        #expect(diagnosis == .other(detail: "this device is not paired"))
    }

    @Test("a direct route keeps the diagnosis it always had")
    func directUnchanged() {
        // No server in the middle, so a refusal is another program on that port
        // and the advice is the one an address that does not answer gets.
        #expect(
            ConnectionDiagnosis.of(
                WebSocketUpgradeRefused(status: 404),
                authority: "192.168.1.5:19390",
            ) == .silent(authority: "192.168.1.5:19390"),
        )
        #expect(
            ConnectionDiagnosis.of(URLError(.timedOut), authority: "192.168.1.5:19390")
                == .silent(authority: "192.168.1.5:19390"),
        )
    }
}
