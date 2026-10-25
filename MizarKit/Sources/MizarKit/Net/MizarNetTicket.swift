//
//  MizarNetTicket.swift
//  MizarKit
//
//  Everything a dialer needs to find one endpoint.
//
//  A ticket is the MizarNet equivalent of a pairing QR code: it names the
//  far endpoint by its public key and carries whatever hints the issuer
//  knew — the relay origins that can carry signaling, and any direct
//  addresses that were reachable when the ticket was made. It is deliberately
//  *not* a credential: knowing a ticket lets you dial, but the QUIC handshake
//  and the Mizar protocol's own device-token check decide whether the
//  connection goes anywhere.
//
//  The wire form is base64url-wrapped JSON, so a ticket survives a URL query
//  (that is what `mizar-net://dial?t=...` is), a JSON field, and a clipboard.
//

import Foundation

/// How to reach one endpoint.
public struct MizarNetTicket: Sendable, Equatable, Codable {
    /// The ticket format version.
    public static let version = 1

    /// The format version of this ticket.
    public var v: Int
    /// The far endpoint's id: base64url of its 32-byte public key.
    public var endpointId: String
    /// Relay origins that can carry signaling for this endpoint.
    ///
    /// Informational: the dialer's own signaling channel is a separate
    /// decision. This field exists so a ticket handed over in person still
    /// tells a fresh install where the relays are.
    public var relays: [String]
    /// Direct `host:port` hints, best guess first.
    public var direct: [String]

    /// A ticket.
    /// - Parameters:
    ///   - endpointId: the far endpoint's id.
    ///   - relays: signaling relay origins.
    ///   - direct: direct address hints.
    public init(endpointId: String, relays: [String] = [], direct: [String] = []) {
        self.v = Self.version
        self.endpointId = endpointId
        self.relays = relays
        self.direct = direct
    }

    /// The base64url wire form.
    public func encode() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return MizarNetCodec.base64URLEncode(try encoder.encode(self))
    }

    /// Parse the base64url wire form.
    ///
    /// Rejects, rather than best-effort-decodes: a ticket that names no
    /// 32-byte key is a corrupt ticket, and a dialer that guessed at it would
    /// produce a connection failure that looks like a network problem.
    ///
    /// - Parameter encoded: the base64url string.
    /// - Returns: the ticket.
    public static func decode(_ encoded: String) throws -> MizarNetTicket {
        guard let data = MizarNetCodec.base64URLDecode(encoded) else {
            throw MizarNetError.ticketInvalid(reason: "not base64url")
        }
        let ticket: MizarNetTicket
        do {
            ticket = try JSONDecoder().decode(MizarNetTicket.self, from: data)
        } catch {
            throw MizarNetError.ticketInvalid(reason: "malformed JSON")
        }
        guard ticket.v == Self.version else {
            throw MizarNetError.ticketInvalid(reason: "unsupported version \(ticket.v)")
        }
        guard MizarNetCodec.base64URLDecode(ticket.endpointId)?.count == 32 else {
            throw MizarNetError.ticketInvalid(reason: "endpointId is not a 32-byte key")
        }
        return ticket
    }
}
