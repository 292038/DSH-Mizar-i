//
//  MizarNetPunchPacket.swift
//  MizarKit
//
//  The wire format: one small datagram vocabulary.
//
//  Six types, one 15-byte header, all big-endian:
//
//    magic "MZP1" | type (1) | connection id (8) | payload length (2)
//
//  The connection id is what lets one socket carry every session — the
//  engine demultiplexes on it, the way a QUIC connection id does. The
//  packet number rides in the payload of data packets and doubles as the
//  AEAD nonce.
//
//  ClientHello and ServerHello are the punch itself: they are small enough
//  to be the probe (a hello doubles as the hole-punch packet — no separate
//  probe phase, no plaintext on the wire that a middlebox could mistake
//  for something else), and they carry the ephemeral key plus the identity
//  signature the handshake needs.
//
//  Everything is a pure function over Data, so the codec is tested without
//  a socket and the engine is tested with real bytes.
//

import Foundation

/// What a datagram is.
public enum MizarNetPacketType: UInt8, Sendable, CaseIterable {
    /// The dialler's punch packet: "I am this endpoint, here is my
    /// ephemeral key, signed."
    case clientHello = 1
    /// The acceptor's answer: the same, in the other direction.
    case serverHello = 2
    /// Sealed payload, with piggybacked acks.
    case data = 3
    /// An empty packet that keeps a NAT mapping warm.
    case keepalive = 4
    /// The last word: the sender is gone.
    case close = 5
    /// A standalone ack, when there is no data to carry it on.
    case ack = 6
}

/// The fixed header, parsed.
public struct MizarNetPacketHeader: Sendable, Equatable {
    public let type: MizarNetPacketType
    public let connectionId: UInt64
    public let payloadLength: Int
}

/// What a hello carries, whichever direction it travels.
public struct MizarNetHandshake: Sendable, Equatable {
    /// The sender's endpoint id.
    public let endpointId: String
    /// The sender's ephemeral X25519 public key, 32 bytes.
    public let ephemeralPublicKey: Data
    /// The Ed25519 signature over the canonical handshake message.
    public let signature: Data
}

/// A parsed data packet.
public struct MizarNetDataPacket: Sendable, Equatable {
    public let connectionId: UInt64
    public let packetNumber: UInt32
    /// Packet numbers the sender has delivered, piggybacked here.
    public let acks: [UInt32]
    /// The length of the whole message this chunk belongs to.
    public let messageLength: Int
    /// The sealed chunk, tag included.
    public let sealed: Data
    /// The bytes the AEAD authenticates: header + packet number + message
    /// length. Reconstructed by the parser so the opener passes exactly
    /// what the sealer passed.
    public let authenticatedData: Data
}

enum MizarNetPunchPacket {
    static let magic = Data("MZP1".utf8)
    static let headerLength = 15
    static let maxAcksPerPacket = 8
    /// Hard cap on a datagram, punch packets included.
    static let maxDatagramBytes = 1200

    // MARK: - Header

    static func header(type: MizarNetPacketType, connectionId: UInt64, payloadLength: Int) -> Data {
        var data = Data()
        data.append(magic)
        data.append(type.rawValue)
        data.appendUInt64(connectionId)
        data.appendUInt16(UInt16(payloadLength))
        return data
    }

    static func parseHeader(_ data: Data) -> MizarNetPacketHeader? {
        guard data.count >= headerLength, data.subdata(in: 0..<4) == magic else { return nil }
        guard let type = MizarNetPacketType(rawValue: data[4]) else { return nil }
        let connectionId = bigEndianUInt64(data, at: 5)
        let payloadLength = Int(bigEndianUInt16(data, at: 13))
        guard data.count == headerLength + payloadLength else { return nil }
        return MizarNetPacketHeader(type: type, connectionId: connectionId, payloadLength: payloadLength)
    }

    // MARK: - Handshake

    /// The bytes a hello signs: type, connection id, ephemeral key, endpoint
    /// id — everything that binds the hello to this connection and this
    /// identity. Domain-separated by the type byte so a ClientHello can
    /// never be replayed as a ServerHello.
    static func handshakeMessage(
        type: MizarNetPacketType,
        connectionId: UInt64,
        ephemeralPublicKey: Data,
        endpointId: String,
    ) -> Data {
        var message = Data([type.rawValue])
        message.appendUInt64(connectionId)
        message.append(ephemeralPublicKey)
        message.append(Data(endpointId.utf8))
        return message
    }

    static func hello(
        type: MizarNetPacketType,
        connectionId: UInt64,
        endpointId: String,
        ephemeralPublicKey: Data,
        signature: Data,
    ) -> Data {
        var payload = Data()
        payload.append(ephemeralPublicKey)
        payload.append(UInt8(endpointId.utf8.count))
        payload.append(Data(endpointId.utf8))
        payload.append(signature)
        return header(type: type, connectionId: connectionId, payloadLength: payload.count) + payload
    }

    static func clientHello(
        connectionId: UInt64,
        endpointId: String,
        ephemeralPublicKey: Data,
        signature: Data,
    ) -> Data {
        hello(type: .clientHello, connectionId: connectionId, endpointId: endpointId, ephemeralPublicKey: ephemeralPublicKey, signature: signature)
    }

    static func serverHello(
        connectionId: UInt64,
        endpointId: String,
        ephemeralPublicKey: Data,
        signature: Data,
    ) -> Data {
        hello(type: .serverHello, connectionId: connectionId, endpointId: endpointId, ephemeralPublicKey: ephemeralPublicKey, signature: signature)
    }

    /// Parse a hello. The signature is *not* verified here — that is the
    /// identity layer's job, and it needs the endpoint id this parser
    /// returns.
    static func parseHello(_ data: Data) -> (header: MizarNetPacketHeader, handshake: MizarNetHandshake)? {
        guard let header = parseHeader(data),
              header.type == .clientHello || header.type == .serverHello else { return nil }
        let payload = data.subdata(in: headerLength..<data.count)
        guard payload.count >= 32 + 1 + 64 else { return nil }
        let ephemeralPublicKey = payload.subdata(in: 0..<32)
        let idLength = Int(payload[32])
        // An endpoint id is 43 characters; zero is a broken hello, and an
        // empty `subdata` range traps on current SDKs anyway.
        guard idLength > 0, payload.count >= 33 + idLength + 64 else { return nil }
        let endpointId = String(data: payload.subdata(in: 33..<(33 + idLength)), encoding: .utf8) ?? ""
        let signature = payload.subdata(in: (33 + idLength)..<(33 + idLength + 64))
        return (header, MizarNetHandshake(endpointId: endpointId, ephemeralPublicKey: ephemeralPublicKey, signature: signature))
    }

    // MARK: - Data

    /// Build a data packet.
    ///
    /// Layout after the header: packet number (4), ack count (1), the acked
    /// packet numbers (4 each), message length (4), then the sealed chunk.
    /// The message length is outside the AEAD but inside the authenticated
    /// data, so a chunk cannot be re-framed into a different message.
    static func data(
        connectionId: UInt64,
        packetNumber: UInt32,
        acks: [UInt32],
        messageLength: Int,
        sealed: Data,
    ) -> Data {
        var payload = Data()
        payload.appendUInt32(packetNumber)
        payload.append(UInt8(min(acks.count, maxAcksPerPacket)))
        for ack in acks.prefix(maxAcksPerPacket) {
            payload.appendUInt32(ack)
        }
        payload.appendUInt32(UInt32(messageLength))
        payload.append(sealed)
        return header(type: .data, connectionId: connectionId, payloadLength: payload.count) + payload
    }

    static func parseData(_ data: Data) -> MizarNetDataPacket? {
        guard let header = parseHeader(data), header.type == .data else { return nil }
        let payload = data.subdata(in: headerLength..<data.count)
        guard payload.count >= 4 + 1 + 4 else { return nil }
        let packetNumber = bigEndianUInt32(payload, at: 0)
        let ackCount = Int(payload[4])
        let acksEnd = 5 + ackCount * 4
        guard acksEnd + 4 <= payload.count else { return nil }
        var acks: [UInt32] = []
        for index in 0..<ackCount {
            acks.append(bigEndianUInt32(payload, at: 5 + index * 4))
        }
        let messageLength = Int(bigEndianUInt32(payload, at: acksEnd))
        let sealed = payload.subdata(in: (acksEnd + 4)..<payload.count)
        guard !sealed.isEmpty else { return nil }
        var authenticated = data.subdata(in: 0..<headerLength)
        authenticated.append(payload.subdata(in: 0..<4))
        authenticated.append(payload.subdata(in: acksEnd..<(acksEnd + 4)))
        return MizarNetDataPacket(
            connectionId: header.connectionId,
            packetNumber: packetNumber,
            acks: acks,
            messageLength: messageLength,
            sealed: sealed,
            authenticatedData: authenticated,
        )
    }

    // MARK: - Control packets

    static func ack(connectionId: UInt64, acks: [UInt32]) -> Data {
        var payload = Data()
        payload.append(UInt8(min(acks.count, maxAcksPerPacket)))
        for ack in acks.prefix(maxAcksPerPacket) {
            payload.appendUInt32(ack)
        }
        return header(type: .ack, connectionId: connectionId, payloadLength: payload.count) + payload
    }

    static func parseAcks(_ data: Data) -> (connectionId: UInt64, acks: [UInt32])? {
        guard let header = parseHeader(data), header.type == .ack else { return nil }
        let payload = data.subdata(in: headerLength..<data.count)
        guard !payload.isEmpty else { return nil }
        let ackCount = Int(payload[0])
        guard payload.count >= 1 + ackCount * 4 else { return nil }
        var acks: [UInt32] = []
        for index in 0..<ackCount {
            acks.append(bigEndianUInt32(payload, at: 1 + index * 4))
        }
        return (header.connectionId, acks)
    }

    static func keepalive(connectionId: UInt64) -> Data {
        header(type: .keepalive, connectionId: connectionId, payloadLength: 0)
    }

    static func close(connectionId: UInt64, reason: String) -> Data {
        var payload = Data()
        let reasonData = Data(reason.utf8)
        payload.append(UInt8(min(reasonData.count, 255)))
        payload.append(reasonData.prefix(255))
        return header(type: .close, connectionId: connectionId, payloadLength: payload.count) + payload
    }

    static func parseClose(_ data: Data) -> (connectionId: UInt64, reason: String)? {
        guard let header = parseHeader(data), header.type == .close else { return nil }
        let payload = data.subdata(in: headerLength..<data.count)
        guard !payload.isEmpty else { return (header.connectionId, "") }
        let length = Int(payload[0])
        guard length > 0, payload.count >= 1 + length else { return (header.connectionId, "") }
        let reason = String(data: payload.subdata(in: 1..<(1 + length)), encoding: .utf8) ?? ""
        return (header.connectionId, reason)
    }

    // MARK: - Byte order

    private static func bigEndianUInt16(_ data: Data, at offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private static func bigEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24) | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8) | UInt32(data[offset + 3])
    }

    private static func bigEndianUInt64(_ data: Data, at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 {
            value = (value << 8) | UInt64(data[offset + index])
        }
        return value
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

    mutating func appendUInt64(_ value: UInt64) {
        for shift in (0..<8).reversed() {
            append(UInt8((value >> (shift * 8)) & 0xFF))
        }
    }
}
