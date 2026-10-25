//
//  MizarNetPunchPacketTests.swift
//  MizarKitTests
//
//  The wire format.
//
//  Two things are pinned here. First, the hello round trip *with its
//  signature*: the engine's admission check is a signature over the
//  canonical handshake message, so if the message the parser reconstructs
//  differs from the one the signer signed by a single byte, every dial is
//  rejected and nothing works. Second, the data packet's authenticated
//  data: the sealer computes it from a provisional header, the parser
//  reconstructs it from the wire bytes, and a mismatch between the two is
//  invisible until a session fails to decrypt under load.
//

import CryptoKit
import Foundation
import Testing

@testable import MizarKit

struct MizarNetPunchPacketTests {
    private let identity = MizarNetIdentity.generate()
    private let connectionId: UInt64 = 0x0123456789ABCDEF

    private func signedHello(
        type: MizarNetPacketType,
        endpoint: MizarNetIdentity,
        connectionId: UInt64,
    ) throws -> Data {
        let ephemeral = MizarNetCrypto.ephemeralKeyPair()
        let message = MizarNetPunchPacket.handshakeMessage(
            type: type,
            connectionId: connectionId,
            ephemeralPublicKey: ephemeral.publicKey.rawRepresentation,
            endpointId: endpoint.endpointId,
        )
        return MizarNetPunchPacket.hello(
            type: type,
            connectionId: connectionId,
            endpointId: endpoint.endpointId,
            ephemeralPublicKey: ephemeral.publicKey.rawRepresentation,
            signature: try endpoint.sign(message),
        )
    }

    // MARK: - Header

    @Test("the header round trips")
    func headerRoundTrip() {
        let packet = MizarNetPunchPacket.header(type: .keepalive, connectionId: connectionId, payloadLength: 0)
        let header = MizarNetPunchPacket.parseHeader(packet)
        #expect(header?.type == .keepalive)
        #expect(header?.connectionId == connectionId)
        #expect(header?.payloadLength == 0)
    }

    @Test("a packet whose length does not match its payload is rejected")
    func lengthMismatchIsRejected() {
        var packet = MizarNetPunchPacket.header(type: .data, connectionId: connectionId, payloadLength: 4)
        packet.append(Data([0, 0, 0, 1, 2])) // one byte too many
        #expect(MizarNetPunchPacket.parseHeader(packet) == nil)
        #expect(MizarNetPunchPacket.parseHeader(Data("nope".utf8)) == nil)
        #expect(MizarNetPunchPacket.parseHeader(Data(repeating: 0, count: 14)) == nil)
    }

    // MARK: - Handshake

    @Test("a hello survives the wire form, signature and all")
    func helloRoundTrip() throws {
        for type in [MizarNetPacketType.clientHello, MizarNetPacketType.serverHello] {
            let packet = try signedHello(type: type, endpoint: identity, connectionId: connectionId)
            let parsed = MizarNetPunchPacket.parseHello(packet)
            #expect(parsed?.header.type == type)
            #expect(parsed?.header.connectionId == connectionId)
            #expect(parsed?.handshake.endpointId == identity.endpointId)
            #expect(parsed?.handshake.ephemeralPublicKey.count == 32)

            // The reconstructed message verifies — this is the engine's
            // whole admission check, so it has to hold byte for byte.
            let message = MizarNetPunchPacket.handshakeMessage(
                type: type,
                connectionId: connectionId,
                ephemeralPublicKey: parsed!.handshake.ephemeralPublicKey,
                endpointId: parsed!.handshake.endpointId,
            )
            #expect(MizarNetIdentity.verify(signature: parsed!.handshake.signature, message: message, endpointId: identity.endpointId))
        }
    }

    @Test("a hello signed for another connection does not verify")
    func helloIsBoundToItsConnection() throws {
        let packet = try signedHello(type: .clientHello, endpoint: identity, connectionId: connectionId)
        let parsed = try #require(MizarNetPunchPacket.parseHello(packet))
        let message = MizarNetPunchPacket.handshakeMessage(
            type: .clientHello,
            connectionId: connectionId &+ 1,
            ephemeralPublicKey: parsed.handshake.ephemeralPublicKey,
            endpointId: parsed.handshake.endpointId,
        )
        #expect(!MizarNetIdentity.verify(signature: parsed.handshake.signature, message: message, endpointId: identity.endpointId))
    }

    @Test("a hello truncated mid-signature is not a hello")
    func truncatedHelloIsRejected() throws {
        let packet = try signedHello(type: .clientHello, endpoint: identity, connectionId: connectionId)
        #expect(MizarNetPunchPacket.parseHello(packet.subdata(in: 0..<(packet.count - 10))) == nil)
    }

    // MARK: - Data

    @Test("a data packet carries its acks and its sealed chunk")
    func dataRoundTrip() throws {
        let key = MizarNetCryptoTests.Agreement.make()
        let chunk = Data("the chunk".utf8)
        let acks: [UInt32] = [3, 4, 5]
        // The sealer's layout rule, mirrored here so the test builds a
        // packet the way the session does — header first, because the
        // header is inside the authenticated data.
        let payloadLength = 4 + 1 + acks.count * 4 + 4 + chunk.count + 16
        let header = MizarNetPunchPacket.header(type: .data, connectionId: connectionId, payloadLength: payloadLength)
        var authenticated = header
        authenticated.appendUInt32(42)
        authenticated.appendUInt32(UInt32(chunk.count))
        let sealed = try MizarNetCrypto.seal(chunk, key: key, packetNumber: 42, authenticatedData: authenticated)
        let packet = MizarNetPunchPacket.data(connectionId: connectionId, packetNumber: 42, acks: acks, messageLength: chunk.count, sealed: sealed)

        let parsed = MizarNetPunchPacket.parseData(packet)
        #expect(parsed?.connectionId == connectionId)
        #expect(parsed?.packetNumber == 42)
        #expect(parsed?.acks == acks)
        #expect(parsed?.messageLength == chunk.count)
        #expect(try MizarNetCrypto.open(parsed!.sealed, key: key, packetNumber: 42, authenticatedData: parsed!.authenticatedData) == chunk)
    }

    @Test("a data packet with no acks parses")
    func dataWithoutAcks() throws {
        let key = MizarNetCryptoTests.Agreement.make()
        let chunk = Data("x".utf8)
        let payloadLength = 4 + 1 + 0 + 4 + chunk.count + 16
        let header = MizarNetPunchPacket.header(type: .data, connectionId: connectionId, payloadLength: payloadLength)
        var authenticated = header
        authenticated.appendUInt32(0)
        authenticated.appendUInt32(1)
        let sealed = try MizarNetCrypto.seal(chunk, key: key, packetNumber: 0, authenticatedData: authenticated)
        let packet = MizarNetPunchPacket.data(connectionId: connectionId, packetNumber: 0, acks: [], messageLength: 1, sealed: sealed)
        let parsed = MizarNetPunchPacket.parseData(packet)
        #expect(parsed?.acks == [])
        #expect(try MizarNetCrypto.open(parsed!.sealed, key: key, packetNumber: 0, authenticatedData: parsed!.authenticatedData) == chunk)
    }

    // MARK: - Control

    @Test("acks, keepalives and closes round trip")
    func controlPackets() {
        let acks: [UInt32] = [9, 10]
        let ackPacket = MizarNetPunchPacket.ack(connectionId: connectionId, acks: acks)
        let parsedAcks = MizarNetPunchPacket.parseAcks(ackPacket)
        #expect(parsedAcks?.connectionId == connectionId)
        #expect(parsedAcks?.acks == acks)

        let keepalive = MizarNetPunchPacket.keepalive(connectionId: connectionId)
        #expect(MizarNetPunchPacket.parseHeader(keepalive)?.type == .keepalive)
        #expect(keepalive.count == MizarNetPunchPacket.headerLength)

        let close = MizarNetPunchPacket.close(connectionId: connectionId, reason: "the network changed")
        let parsedClose = MizarNetPunchPacket.parseClose(close)
        #expect(parsedClose?.connectionId == connectionId)
        #expect(parsedClose?.reason == "the network changed")
    }

    @Test("a close with no reason parses as empty")
    func closeWithoutReason() {
        let close = MizarNetPunchPacket.close(connectionId: connectionId, reason: "")
        #expect(MizarNetPunchPacket.parseClose(close)?.reason == "")
    }
}

extension MizarNetCryptoTests {
    /// One direction's key, the way a session holds a pair: seal with it,
    /// open with it, in the tests below.
    enum Agreement {
        static func make() -> SymmetricKey {
            let dialer = MizarNetIdentity.derived(from: Data(repeating: 1, count: 32), purpose: .host)
            let acceptor = MizarNetIdentity.derived(from: Data(repeating: 2, count: 32), purpose: .device)
            let dialerEphemeral = MizarNetCrypto.ephemeralKeyPair()
            let acceptorEphemeral = MizarNetCrypto.ephemeralKeyPair()
            let salt = MizarNetCrypto.sessionSalt(localEndpointId: dialer.endpointId, remoteEndpointId: acceptor.endpointId)
            let shared = try! dialerEphemeral.sharedSecretFromKeyAgreement(with: acceptorEphemeral.publicKey)
            // The dialer-to-acceptor direction: one key, both sides of the
            // test's round trip.
            return MizarNetCrypto.sessionKeys(sharedSecret: shared, salt: salt, localIsDialer: true).seal
        }
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value >> 8))
        append(UInt8(value & 0xFF))
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(value >> 24))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }
}
