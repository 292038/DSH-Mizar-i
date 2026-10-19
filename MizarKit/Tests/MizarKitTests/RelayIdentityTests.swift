//
//  RelayIdentityTests.swift
//  MizarKitTests
//
//  One hash and two headers, and both are load-bearing: the relay buckets traffic
//  by the hash, so a mismatch between the phone's hash and the relay's is a
//  paying account metered as an anonymous one. The known-answer test pins the
//  exact SHA-256 spelling (lowercase hex, 64 characters) rather than trusting
//  that both sides read the same documentation.
//

import Foundation
import Testing
@testable import MizarKit

@Suite("RelayIdentity")
struct RelayIdentityTests {
    @Test("hashes a token as lowercase SHA-256 hex")
    func tokenHash() {
        // The standard SHA-256 test vector: a different casing or an uppercase
        // encoding would produce 64 different characters and a different bucket.
        #expect(RelayIdentity.hash(of: "abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let hash = RelayIdentity.hash(of: "mza_token")
        #expect(hash.count == 64)
        #expect(hash.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    @Test("sends both headers when signed in")
    func signedInHeaders() {
        let identity = RelayIdentity(clientId: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8", accountToken: "mza_abc")
        let headers = identity.headers
        #expect(headers[RelayIdentity.clientIdHeader] == "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")
        #expect(headers[RelayIdentity.accountHeader] == RelayIdentity.hash(of: "mza_abc"))
        #expect(identity.accountHash == RelayIdentity.hash(of: "mza_abc"))
    }

    @Test("sends only the client id when signed out")
    func signedOutHeaders() {
        let identity = RelayIdentity(clientId: "install-1234")
        #expect(identity.accountHash == nil)
        #expect(identity.headers == [RelayIdentity.clientIdHeader: "install-1234"])
    }

    @Test("an empty token is treated as no account")
    func emptyToken() {
        let identity = RelayIdentity(clientId: "install-1234", accountToken: "")
        #expect(identity.accountToken == nil)
        #expect(identity.accountHash == nil)
        #expect(identity.headers[RelayIdentity.accountHeader] == nil)
    }

    @Test("drops a client id the relay would reject")
    func invalidClientIdDropped() {
        // Too short, too long, and a bad character: each would be a 400 from the
        // relay, and dropping the header degrades a request to anonymous instead
        // of refusing it.
        #expect(RelayIdentity(clientId: "short").headers.isEmpty)
        #expect(RelayIdentity(clientId: String(repeating: "a", count: 65)).headers.isEmpty)
        #expect(RelayIdentity(clientId: "has space").headers.isEmpty)
        #expect(RelayIdentity(clientId: "").headers.isEmpty)
    }

    @Test("accepts the documented client id character set")
    func clientIdValidation() {
        #expect(RelayIdentity.isValidClientId("abcdefgh")) // 8 is the floor
        #expect(RelayIdentity.isValidClientId(String(repeating: "a", count: 64)))
        #expect(RelayIdentity.isValidClientId("6BA7B810-9DAD-11D1-80B4-00C04FD430C8"))
        #expect(RelayIdentity.isValidClientId("a.b_c-1234"))
        #expect(!RelayIdentity.isValidClientId("abcdefg")) // 7 is too short
        #expect(!RelayIdentity.isValidClientId("abcdefg!"))
    }

    @Test("builds a guest identity from an install id")
    func guestIdentity() {
        let identity = RelayIdentity.guest(clientId: "install-1234")
        #expect(identity.accountToken == nil)
        #expect(identity.headers[RelayIdentity.clientIdHeader] == "install-1234")
    }
}
