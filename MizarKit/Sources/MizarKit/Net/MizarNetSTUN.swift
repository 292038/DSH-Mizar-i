//
//  MizarNetSTUN.swift
//  MizarKit
//
//  The one question a STUN server can answer: what do I look like from the
//  outside?
//
//  A punch needs the *server-reflexive* address — the public ip:port the
//  NAT maps the socket to — because that is the address the far peer has to
//  send to. RFC 5389's Binding transaction is the whole protocol for
//  asking: a 20-byte request with a random transaction id, and a response
//  carrying XOR-MAPPED-ADDRESS.
//
//  Only the parts a punch client needs are implemented. No SOFTWARE, no
//  FINGERPRINT, no realm/authenticator: coturn, Google's servers and every
//  other mainstream responder answer a bare binding request, and every
//  attribute this engine does not understand is skipped by length, the way
//  the RFC requires.
//
//  Everything here is pure functions over Data — the socket that carries
//  the bytes is the engine's business — so the codec is testable without a
//  network, and the engine is testable against a fake responder.
//

import Foundation

/// The one question a STUN server can answer: what do I look like from the
/// outside?
///
/// A punch needs the *server-reflexive* address — the public ip:port the
/// NAT maps the socket to — because that is the address the far peer has to
/// send to. RFC 5389's Binding transaction is the whole protocol for
/// asking: a 20-byte request with a random transaction id, and a response
/// carrying XOR-MAPPED-ADDRESS.
///
/// Only the parts a punch client needs are implemented. No SOFTWARE, no
/// FINGERPRINT, no realm/authenticator: coturn, Google's servers and every
/// other mainstream responder answer a bare binding request, and every
/// attribute this engine does not understand is skipped by length, the way
/// the RFC requires.
///
/// Everything here is pure functions over Data — the socket that carries
/// the bytes is the engine's business — so the codec is testable without a
/// network, and the engine is testable against a fake responder.
///
/// Public because the NAT matrix lab (a separate target) speaks the same
/// wire format: its simulated NAT forwards real binding requests to a real
/// responder, and both sides of that conversation use these constants.
public enum MizarNetSTUN {
    /// The magic cookie every STUN message starts with, after the type.
    public static let magicCookie: UInt32 = 0x2112A442
    /// The fixed header: type, length, cookie, transaction id.
    public static let headerLength = 20
    /// Binding Request.
    public static let bindingRequestType: UInt16 = 0x0001
    /// Binding Success Response.
    public static let bindingSuccessResponseType: UInt16 = 0x0101
    /// MAPPED-ADDRESS — the pre-XOR form, still answered by old servers.
    public static let mappedAddressAttribute: UInt16 = 0x0001
    /// XOR-MAPPED-ADDRESS — the form everything modern answers with.
    public static let xorMappedAddressAttribute: UInt16 = 0x0020

    /// Whether a datagram is a STUN message rather than one of ours.
    ///
    /// Our packets start with the ASCII magic `MZP1`, which cannot collide
    /// with the cookie, so the first four bytes are a reliable discriminator.
    public static func looksLikeSTUN(_ data: Data) -> Bool {
        guard data.count >= headerLength else { return false }
        return bigEndianUInt32(data, at: 4) == magicCookie
    }

    /// The transaction id of a datagram, if it is long enough to carry one.
    public static func transactionId(of data: Data) -> Data? {
        guard data.count >= headerLength else { return nil }
        return data.subdata(in: 8..<headerLength)
    }

    /// A random 12-byte transaction id.
    public static func randomTransactionId() -> Data {
        var id = Data(count: 12)
        _ = id.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, 12, buffer.baseAddress!)
        }
        return id
    }

    /// A Binding Request.
    ///
    /// Zero attributes, so the length field is zero: the simplest request
    /// the RFC allows.
    public static func bindingRequest(transactionId: Data) -> Data {
        var message = Data()
        message.appendUInt16(bindingRequestType)
        message.appendUInt16(0) // message length: no attributes
        message.appendUInt32(magicCookie)
        message.append(transactionId)
        return message
    }

    /// The outcome of a binding transaction.
    public struct MappedAddress {
        public let ip: String
        public let port: UInt16
    }

    /// Parse a Binding Success Response.
    ///
    /// - Parameters:
    ///   - data: the datagram.
    ///   - expectedTransactionId: the id the request carried. A response
    ///     for a different transaction is somebody else's answer.
    /// - Returns: the mapped address, or `nil` when this is not a usable
    ///   answer — wrong type, wrong transaction, or no address attribute.
    public static func parseBindingResponse(
        _ data: Data,
        expectedTransactionId: Data,
    ) -> MappedAddress? {
        guard data.count >= headerLength else { return nil }
        guard bigEndianUInt16(data, at: 0) == bindingSuccessResponseType else { return nil }
        guard bigEndianUInt32(data, at: 4) == magicCookie else { return nil }
        guard data.subdata(in: 8..<headerLength) == expectedTransactionId else { return nil }

        let messageLength = Int(bigEndianUInt16(data, at: 2))
        let end = min(data.count, headerLength + messageLength)
        var offset = headerLength
        var fallback: MappedAddress?
        while offset + 4 <= end {
            let type = bigEndianUInt16(data, at: offset)
            let length = Int(bigEndianUInt16(data, at: offset + 2))
            let valueStart = offset + 4
            // A zero-length attribute carries no value; skipping it by its
            // padded size is also how the RFC walks the list. (And an empty
            // `subdata` range is a trap on current SDKs, not an empty Data.)
            if length > 0, valueStart + length <= end {
                let value = data.subdata(in: valueStart..<(valueStart + length))
                switch type {
                case xorMappedAddressAttribute:
                    if let address = parseXORAddress(value) { return address }
                case mappedAddressAttribute:
                    fallback = parsePlainAddress(value)
                default:
                    break
                }
            }
            // Attributes are padded to a four-byte boundary.
            offset = valueStart + ((length + 3) / 4) * 4
        }
        return fallback
    }

    /// XOR-MAPPED-ADDRESS: one reserved byte, family, then port and address
    /// XOR'd with the cookie. The XOR exists so a middlebox cannot rewrite
    /// the address without breaking the packet; the client reverses it with
    /// the same constant.
    ///
    /// Layout (RFC 5389 §15.2): 1 reserved byte, 1 family byte, 2 bytes
    /// x-port, 4 bytes x-address.
    private static func parseXORAddress(_ value: Data) -> MappedAddress? {
        guard value.count >= 8, value[1] == 0x01 else { return nil } // IPv4 only
        let xPort = bigEndianUInt16(value, at: 2)
        let port = xPort ^ UInt16(magicCookie >> 16)
        var cookieBytes = Data()
        cookieBytes.appendUInt32(magicCookie)
        let addressBytes = Data(value.subdata(in: 4..<8)).enumerated().map { index, byte in
            byte ^ cookieBytes[index]
        }
        return MappedAddress(ip: dottedQuad(Data(addressBytes)), port: port)
    }

    /// MAPPED-ADDRESS, the pre-XOR form. Kept as a fallback for responders
    /// that still answer the old way.
    private static func parsePlainAddress(_ value: Data) -> MappedAddress? {
        guard value.count >= 8, value[1] == 0x01 else { return nil }
        let port = bigEndianUInt16(value, at: 2)
        return MappedAddress(ip: dottedQuad(Data(value.subdata(in: 4..<8))), port: port)
    }

    /// Render four address bytes as dotted-quad text.
    ///
    /// The null-terminated buffer is trimmed before decoding rather than
    /// handed to `String(cString:)`, which the current SDKs deprecate.
    private static func dottedQuad(_ bytes: Data) -> String {
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        bytes.withUnsafeBytes { buffer in
            _ = inet_ntop(AF_INET, buffer.baseAddress, &text, socklen_t(INET_ADDRSTRLEN))
        }
        return String(decoding: text.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func bigEndianUInt16(_ data: Data, at offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private static func bigEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24) | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8) | UInt32(data[offset + 3])
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
