//
//  MizarNetFixtureEmitter.swift
//  MizarKitTests
//
//  Emits the cross-language fixture for the MizarNet wire format.
//
//  The TypeScript half of the kernel (`dsh/src/transport/p2p/`) is a second
//  implementation of the same bytes. Two implementations reading one artifact
//  is what makes the contract testable: this file writes the bytes, the Node
//  suite reproduces them, and neither language can drift from the other
//  without a red test. It is the same arrangement `FixtureTests.swift` uses
//  for the Mizar v1 frames, for the same reason.
//
//  Run with:
//
//      MIZAR_P2P_FIXTURES=1 scripts/swift.sh test --filter MizarNetFixtureEmitter
//
//  Then copy `protocol/fixtures/p2p-wire.json` into the plugin repository
//  (`dsh/protocol/fixtures/p2p-wire.json`) — the same duplication the Mizar v1
//  fixtures already live with, because the two repositories are separate.
//
//  Everything in the fixture is throwaway test material: the seeds are byte
//  patterns, and the "shared secret" never came from a real agreement. It is
//  pinned only so both sides can compute the same keys from it.
//

import CryptoKit
import Foundation
import Testing

@testable import MizarKit

@Suite(.enabled(if: ProcessInfo.processInfo.environment["MIZAR_P2P_FIXTURES"] != nil))
struct MizarNetFixtureEmitter {
    /// Where the fixture belongs, found from this file's own path.
    private var fixturesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MizarKitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // MizarKit
            .deletingLastPathComponent() // iOS
            .appendingPathComponent("protocol/fixtures/p2p")
    }

    @Test("emit the MizarNet wire fixture")
    func emit() throws {
        // --- identity: a host key derived from a known secret ---------------
        let secret = Data(repeating: 0x11, count: 32)
        let identity = MizarNetIdentity.derived(from: secret, purpose: .host)
        let message = Data("a message the host signed".utf8)
        let signature = try identity.sign(message)

        // --- the dialer's hello --------------------------------------------
        // A connection id above 2^53 on purpose: JavaScript cannot hold it in
        // a `number`, so the fixture forces the TypeScript side to use bigint
        // rather than quietly rounding a connection id into a different one.
        let connectionId: UInt64 = 0xFEDC_BA98_7654_3210
        let dialerIdentity = MizarNetIdentity.derived(from: Data(repeating: 0x22, count: 32), purpose: .device)
        let ephemeral = MizarNetCrypto.ephemeralKeyPair()
        let ephemeralPublicKey = ephemeral.publicKey.rawRepresentation
        let helloMessage = MizarNetPunchPacket.handshakeMessage(
            type: .clientHello,
            connectionId: connectionId,
            ephemeralPublicKey: ephemeralPublicKey,
            endpointId: dialerIdentity.endpointId,
        )
        let helloSignature = try dialerIdentity.sign(helloMessage)
        let clientHello = MizarNetPunchPacket.clientHello(
            connectionId: connectionId,
            endpointId: dialerIdentity.endpointId,
            ephemeralPublicKey: ephemeralPublicKey,
            signature: helloSignature,
        )

        // --- session keys ---------------------------------------------------
        // The fixture uses a byte pattern rather than a real agreement, so the
        // TypeScript side can reproduce it without an X25519 exchange. The
        // check below is what keeps the two forms of the derivation — the one
        // production uses, and the byte-level one a second implementation can
        // follow — from drifting apart.
        let sharedSecret = Data((0..<32).map { UInt8($0) })
        let localEndpointId = dialerIdentity.endpointId
        let remoteEndpointId = identity.endpointId
        let salt = MizarNetCrypto.sessionSalt(localEndpointId: localEndpointId, remoteEndpointId: remoteEndpointId)
        let byteKeys = MizarNetCrypto.sessionKeyBytes(
            sharedSecret: sharedSecret,
            salt: salt,
            localIsDialer: true,
        )

        let agreementA = Curve25519.KeyAgreement.PrivateKey()
        let agreementB = Curve25519.KeyAgreement.PrivateKey()
        let agreement = try agreementA.sharedSecretFromKeyAgreement(with: agreementB.publicKey)
        let agreementBytes = agreement.withUnsafeBytes { Data($0) }
        let viaAgreement = MizarNetCrypto.sessionKeys(sharedSecret: agreement, salt: salt, localIsDialer: true)
        let viaBytes = MizarNetCrypto.sessionKeyBytes(sharedSecret: agreementBytes, salt: salt, localIsDialer: true)
        #expect(viaAgreement.seal.withUnsafeBytes { Data($0) } == viaBytes.seal)
        #expect(viaAgreement.open.withUnsafeBytes { Data($0) } == viaBytes.open)
        #expect(byteKeys.seal.count == 32)
        #expect(byteKeys.open.count == 32)
        #expect(byteKeys.seal != byteKeys.open)

        // --- a data packet, sealed with the dialer's key --------------------
        let sealKey = SymmetricKey(data: byteKeys.seal)
        let plaintext = Data("hello mizar".utf8)
        let packetNumber: UInt32 = 7
        let acks: [UInt32] = [3, 4, 5]
        let payloadLength = 4 + 1 + acks.count * 4 + 4 + plaintext.count + 16
        let header = MizarNetPunchPacket.header(type: .data, connectionId: connectionId, payloadLength: payloadLength)
        var authenticated = header
        authenticated.appendUInt32BE(packetNumber)
        authenticated.appendUInt32BE(UInt32(plaintext.count))
        let sealed = try MizarNetCrypto.seal(
            plaintext,
            key: sealKey,
            packetNumber: packetNumber,
            authenticatedData: authenticated,
        )
        let dataPacket = MizarNetPunchPacket.data(
            connectionId: connectionId,
            packetNumber: packetNumber,
            acks: acks,
            messageLength: plaintext.count,
            sealed: sealed,
        )

        // --- an X25519 agreement, for the second implementation --------------
        // The handshake's shared secret, pinned so the TypeScript side can be
        // checked without a live exchange. Both sides clamp the scalar the same
        // way (RFC 7748), which is exactly the sort of thing that is worth
        // proving rather than assuming.
        let localScalar = Data((0..<32).map { UInt8(0x40 &+ $0) })
        let peerScalar = Data((0..<32).map { UInt8(0x90 &+ $0) })
        let localAgreementKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: localScalar)
        let peerAgreementKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: peerScalar)
        let agreed = try localAgreementKey.sharedSecretFromKeyAgreement(with: peerAgreementKey.publicKey)
        let agreedBytes = agreed.withUnsafeBytes { Data($0) }

        // --- the rest of the vocabulary -------------------------------------
        let keepalive = MizarNetPunchPacket.keepalive(connectionId: connectionId)
        let ackPacket = MizarNetPunchPacket.ack(connectionId: connectionId, acks: acks)
        let closePacket = MizarNetPunchPacket.close(connectionId: connectionId, reason: "bye")

        let fixture: [String: Any] = [
            "version": 1,
            "note": "MizarNet wire fixture · emitted by MizarKitTests MizarNetFixtureEmitter · byte patterns, not secrets",
            // CryptoKit signs Ed25519 with a randomized nonce, so the two
            // signatures here are *one valid sample each*, not reproducible
            // bytes. The cross-language contract is verification: the other
            // implementation must accept these, and must not be expected to
            // sign the same message into the same 64 bytes.
            "signatureNote": "Ed25519 signatures are randomized; verify them, do not compare them",
            "identity": [
                "secretHex": secret.hex,
                "purpose": MizarNetIdentity.Purpose.host.rawValue,
                "endpointId": identity.endpointId,
                "shortId": identity.shortId,
                "messageHex": message.hex,
                "signatureHex": signature.hex,
            ],
            "clientHello": [
                "connectionId": String(connectionId),
                "endpointId": dialerIdentity.endpointId,
                "ephemeralPublicKeyHex": ephemeralPublicKey.hex,
                "handshakeMessageHex": helloMessage.hex,
                "signatureHex": helloSignature.hex,
                "packetHex": clientHello.hex,
            ],
            "session": [
                "sharedSecretHex": sharedSecret.hex,
                "localEndpointId": localEndpointId,
                "remoteEndpointId": remoteEndpointId,
                "saltHex": salt.hex,
                "dialerToAcceptorKeyHex": byteKeys.seal.hex,
                "acceptorToDialerKeyHex": byteKeys.open.hex,
            ],
            "agreement": [
                "localSecretHex": localAgreementKey.rawRepresentation.hex,
                "localPublicKeyHex": localAgreementKey.publicKey.rawRepresentation.hex,
                "remotePublicKeyHex": peerAgreementKey.publicKey.rawRepresentation.hex,
                "sharedSecretHex": agreedBytes.hex,
            ],
            "data": [
                "connectionId": String(connectionId),
                "packetNumber": Int(packetNumber),
                "acks": acks.map { Int($0) },
                "messageLength": plaintext.count,
                "plaintextHex": plaintext.hex,
                "authenticatedDataHex": authenticated.hex,
                "sealedHex": sealed.hex,
                "packetHex": dataPacket.hex,
            ],
            "control": [
                "keepaliveHex": keepalive.hex,
                "ackHex": ackPacket.hex,
                "closeHex": closePacket.hex,
            ],
        ]

        let directory = fixturesDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: fixture,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes],
        )
        let target = directory.appendingPathComponent("wire.json")
        try data.write(to: target)
        print("P2P-FIXTURE wrote \(target.path) (\(data.count) bytes)")
    }
}

private extension Data {
    /// Lowercase hex, for a fixture a human may need to read.
    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }

    mutating func appendUInt32BE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }
}
