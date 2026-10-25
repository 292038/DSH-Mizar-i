//
//  MizarNetCryptoTests.swift
//  MizarKitTests
//
//  The handshake arithmetic.
//
//  If any of this is wrong, every session is either forgeable or
//  undecryptable, and both failures look like "the network is flaky" from
//  the outside. So the agreement, the key separation and the seal are each
//  tested directly — including the negative cases, which are the ones a
//  happy-path round trip cannot distinguish from a broken implementation.
//

import CryptoKit
import Foundation
import Testing

@testable import MizarKit

struct MizarNetCryptoTests {
    private let dialer = MizarNetIdentity.derived(from: Data(repeating: 1, count: 32), purpose: .host)
    private let acceptor = MizarNetIdentity.derived(from: Data(repeating: 2, count: 32), purpose: .device)

    /// Both sides of an agreement, the way a session builds them.
    private func agreement() throws -> (
        dialerSeal: SymmetricKey,
        dialerOpen: SymmetricKey,
        acceptorSeal: SymmetricKey,
        acceptorOpen: SymmetricKey,
    ) {
        let dialerEphemeral = MizarNetCrypto.ephemeralKeyPair()
        let acceptorEphemeral = MizarNetCrypto.ephemeralKeyPair()
        let salt = MizarNetCrypto.sessionSalt(localEndpointId: dialer.endpointId, remoteEndpointId: acceptor.endpointId)
        let dialerShared = try dialerEphemeral.sharedSecretFromKeyAgreement(with: acceptorEphemeral.publicKey)
        let acceptorShared = try acceptorEphemeral.sharedSecretFromKeyAgreement(with: dialerEphemeral.publicKey)
        let dialerKeys = MizarNetCrypto.sessionKeys(sharedSecret: dialerShared, salt: salt, localIsDialer: true)
        let acceptorKeys = MizarNetCrypto.sessionKeys(sharedSecret: acceptorShared, salt: salt, localIsDialer: false)
        return (dialerKeys.seal, dialerKeys.open, acceptorKeys.seal, acceptorKeys.open)
    }

    @Test("both sides agree, and each direction has its own key")
    func agreementIsMutual() throws {
        let keys = try agreement()
        // The dialer seals with what the acceptor opens, and vice versa.
        let message = Data("a frame".utf8)
        let sealed = try MizarNetCrypto.seal(message, key: keys.dialerSeal, packetNumber: 7, authenticatedData: Data("header".utf8))
        #expect(try MizarNetCrypto.open(sealed, key: keys.acceptorOpen, packetNumber: 7, authenticatedData: Data("header".utf8)) == message)

        // The dialer's own open key is not its seal key: a reflected packet
        // does not decrypt.
        #expect(try MizarNetCrypto.open(sealed, key: keys.dialerOpen, packetNumber: 7, authenticatedData: Data("header".utf8)) == nil)
    }

    @Test("the salt binds a session to its two peers")
    func saltBindsThePeers() throws {
        let salt = MizarNetCrypto.sessionSalt(localEndpointId: dialer.endpointId, remoteEndpointId: acceptor.endpointId)
        // Sorted inside, so both sides derive the same salt.
        let mirrored = MizarNetCrypto.sessionSalt(localEndpointId: acceptor.endpointId, remoteEndpointId: dialer.endpointId)
        #expect(salt == mirrored)
        // A third peer changes it, so a session's keys cannot be replayed
        // against another pairing.
        let other = MizarNetIdentity.generate()
        let withOther = MizarNetCrypto.sessionSalt(localEndpointId: dialer.endpointId, remoteEndpointId: other.endpointId)
        #expect(withOther != salt)
    }

    @Test("a seal covers the authenticated data and the packet number")
    func sealCoversEverything() throws {
        let keys = try agreement()
        let message = Data("a frame".utf8)
        let header = Data("header".utf8)
        let sealed = try MizarNetCrypto.seal(message, key: keys.dialerSeal, packetNumber: 7, authenticatedData: header)

        // A rewritten header does not verify.
        #expect(try MizarNetCrypto.open(sealed, key: keys.acceptorOpen, packetNumber: 7, authenticatedData: Data("head3r".utf8)) == nil)
        // Neither does a different packet number — the nonce is the number.
        #expect(try MizarNetCrypto.open(sealed, key: keys.acceptorOpen, packetNumber: 8, authenticatedData: header) == nil)
        // A flipped bit does not verify.
        var corrupted = sealed
        corrupted[0] ^= 0xFF
        #expect(try MizarNetCrypto.open(corrupted, key: keys.acceptorOpen, packetNumber: 7, authenticatedData: header) == nil)
        // A truncated packet is not a packet.
        #expect(try MizarNetCrypto.open(sealed.subdata(in: 0..<10), key: keys.acceptorOpen, packetNumber: 7, authenticatedData: header) == nil)
    }

    @Test("an empty message seals and opens")
    func emptyMessageRoundTrips() throws {
        let keys = try agreement()
        let header = Data("header".utf8)
        let sealed = try MizarNetCrypto.seal(Data(), key: keys.dialerSeal, packetNumber: 0, authenticatedData: header)
        #expect(try MizarNetCrypto.open(sealed, key: keys.acceptorOpen, packetNumber: 0, authenticatedData: header) == Data())
    }
}
