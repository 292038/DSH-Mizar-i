//
//  PairedHostTests.swift
//  MizarKitTests
//
//  The pairing record: what survives a rename, a move, and what the app dials.
//
//  A pairing is the one thing in this app that cannot be re-derived from the
//  host: losing it means scanning a code again. So everything that produces a
//  *copy* of one -- the operator renaming a machine, the host's address moving
//  from a LAN address to a tailnet one, a relay being added -- has to carry the
//  credential and the operator's own name across, and none of that was covered.
//

import Foundation
import Testing
@testable import MizarKit

@Suite("A paired host")
struct PairedHostTests {
    /// One pairing, with everything set: an operator-chosen name, both routes,
    /// and a credential.
    private static func host() -> PairedHost {
        PairedHost(
            hostId: "host-1",
            hostName: "Shirazus-Mac-mini.local",
            authority: "192.168.1.20:19390",
            deviceId: "device-1",
            deviceToken: "mz_token",
            pairedAt: Date(timeIntervalSince1970: 1_700_000_000),
            baseURL: "https://relay.example.com/r/ROOM",
            label: "Studio",
            desktop: HostDesktop(os: "macOS", client: "DSH"),
        )
    }

    @Test("keeps the credential and the operator's name across a rename")
    func rename() {
        let renamed = Self.host().renamed(to: "Desk")
        #expect(renamed.label == "Desk")
        #expect(renamed.displayName == "Desk")
        #expect(renamed.deviceToken == "mz_token")
        #expect(renamed.deviceId == "device-1")
        #expect(renamed.hostId == "host-1")
        #expect(renamed.desktop == HostDesktop(os: "macOS", client: "DSH"))

        // Clearing the name falls back to the host's own.
        #expect(Self.host().renamed(to: nil).displayName == "Shirazus-Mac-mini.local")
        // A name that is only whitespace is not a name.
        #expect(Self.host().renamed(to: "   ").displayName == "Shirazus-Mac-mini.local")
    }

    @Test("keeps the operator's name when the host's address moves")
    func move() {
        // A tailnet address is stable and a LAN address is not, so this is the
        // path a computer that changed networks takes -- and the name the operator
        // chose is the whole reason the machine is recognisable afterwards.
        let moved = Self.host().moved(to: "100.64.0.9:19390")
        #expect(moved.authority == "100.64.0.9:19390")
        #expect(moved.label == "Studio", "the operator's name was dropped by a move")
        #expect(moved.displayName == "Studio")
        #expect(moved.deviceToken == "mz_token")
        #expect(moved.baseURL == "https://relay.example.com/r/ROOM")
        #expect(moved.desktop == HostDesktop(os: "macOS", client: "DSH"))
    }

    @Test("keeps the operator's name when the relay changes")
    func moveToRelay() {
        let moved = Self.host().moved(toRelay: "https://other.example.com/r/ROOM2")
        #expect(moved.baseURL == "https://other.example.com/r/ROOM2")
        #expect(moved.label == "Studio", "the operator's name was dropped by a relay change")
        #expect(moved.authority == "192.168.1.20:19390")
        #expect(moved.deviceToken == "mz_token")
        #expect(moved.desktop == HostDesktop(os: "macOS", client: "DSH"))

        // Removing the relay leaves a direct-only pairing, name intact.
        let directOnly = Self.host().moved(toRelay: nil)
        #expect(directOnly.baseURL == nil)
        #expect(directOnly.endpoints == [.direct(authority: "192.168.1.20:19390")])
        #expect(directOnly.label == "Studio")
    }

    @Test("dials the direct address first and the relay second")
    func endpoints() {
        #expect(Self.host().endpoints == [
            .direct(authority: "192.168.1.20:19390"),
            .relay(baseURL: "https://relay.example.com/r/ROOM"),
        ])

        // A relay-only pairing has one route, and a base URL this client cannot
        // dial is not a route at all: it would be a dial that always fails.
        let relayOnly = PairedHost(
            hostId: "host-2",
            hostName: "mac",
            authority: nil,
            deviceId: "device-2",
            deviceToken: "mz_token",
            baseURL: "ftp://relay.example.com/r/ROOM",
        )
        #expect(relayOnly.endpoints.isEmpty)
    }

    @Test("learns what the computer is without losing the credential")
    func rememberDesktop() {
        let updated = Self.host().remembering(desktop: HostDesktop(os: "Windows", client: "Codex"))
        #expect(updated.desktop == HostDesktop(os: "Windows", client: "Codex"))
        #expect(updated.deviceToken == "mz_token")
        #expect(updated.label == "Studio")
        #expect(updated.endpoints == Self.host().endpoints)
    }

    @Test("round-trips the desktop through the pairing blob")
    func desktopRoundTrip() throws {
        let data = try JSONEncoder().encode(Self.host())
        let decoded = try JSONDecoder().decode(PairedHost.self, from: data)
        #expect(decoded == Self.host())
    }

    @Test("draws the system first and drops blank labels")
    func desktopLabels() {
        #expect(
            HostDesktop(os: "macOS", client: "DSH").labels == ["macOS", "DSH"]
        )
        // A partial answer must not draw an empty capsule beside a real one.
        #expect(HostDesktop(os: " ", client: "DSH").labels == ["DSH"])
        #expect(HostDesktop(os: "macOS", client: "").labels == ["macOS"])
        #expect(HostDesktop(os: "", client: "").isEmpty)
    }

    @Test("reads a pairing written before the desktop field existed")
    func oldPairingWithoutDesktop() throws {
        // The Keychain holds every pairing written by every previous version.
        // Adding a field must not make one of those decode as "unpaired", which
        // would send the operator back to scan a code.
        let json = #"{"hostId":"host-1","hostName":"mac","authority":null,"deviceId":"device-1","deviceToken":"mz_token","pairedAt":0}"#
        let decoded = try JSONDecoder().decode(PairedHost.self, from: Data(json.utf8))
        #expect(decoded.hostId == "host-1")
        #expect(decoded.desktop == nil)
    }
}
