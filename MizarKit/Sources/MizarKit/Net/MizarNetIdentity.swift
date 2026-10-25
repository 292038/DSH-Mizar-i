//
//  MizarNetIdentity.swift
//  MizarKit
//
//  Who a MizarNet endpoint is.
//
//  A MizarNet endpoint is an Ed25519 key pair, and nothing else. There is no
//  account, no phone number, no third party who can say who an endpoint is:
//  the public key *is* the identity, the same way it is in WireGuard, in
//  iroh and in libp2p. That matters here because the whole point of the
//  direct path is that no server is in a position to authenticate the peers
//  to each other — the ticket names a key, and the QUIC handshake proves
//  possession of it.
//
//  The key is *derived*, not generated, when the secret already exists: the
//  desktop derives its endpoint key from the host secret that already backs
//  the pairing codes, and the phone derives its key from the device token the
//  pairing handed it. Possession of the secret therefore implies possession
//  of the endpoint key, which is exactly the trust the pairing already
//  established — one less credential for a user to lose.
//
//  Derivation is a plain SHA-256 over secret ‖ purpose ‖ 0x01. The inputs are
//  already 32 uniform bytes, so a full KDF buys nothing here; the purpose
//  string is what keeps the host key and a device key apart, and the counter
//  byte leaves room to re-derive with a different construction later without
//  disturbing existing keys.
//

import CryptoKit
import Foundation
import Security

/// A MizarNet endpoint's key pair.
public struct MizarNetIdentity: Sendable, Equatable {
    /// The endpoint id: the raw 32-byte Ed25519 public key, base64url encoded.
    ///
    /// This is what a ticket names and what a peer dials. It is 43 characters.
    public let endpointId: String

    /// A short, human-readable form of ``endpointId``: 8 Crockford base32
    /// characters (40 bits) of the public key. Enough to tell two endpoints
    /// apart in a log line or a support conversation; not enough to be
    /// mistaken for the identity itself.
    public let shortId: String

    /// The 32-byte seed. Never leaves the kernel.
    private let seed: Data

    private init(seed: Data) {
        let key = try! Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let publicKey = key.publicKey.rawRepresentation
        self.seed = seed
        self.endpointId = MizarNetCodec.base64URLEncode(publicKey)
        self.shortId = MizarNetCodec.crockfordBase32(publicKey, length: 8)
    }

    /// A fresh random identity, for a first run.
    public static func generate() -> MizarNetIdentity {
        var seed = Data(count: 32)
        _ = seed.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, 32, buffer.baseAddress!)
        }
        return MizarNetIdentity(seed: seed)
    }

    /// The purpose a derived key serves. The string is part of the hash, so it
    /// is part of the wire contract: changing one invalidates every key
    /// derived under the old value.
    public enum Purpose: String, Sendable, CaseIterable {
        /// The desktop host's endpoint key, derived from the host secret.
        case host = "mizar-net/host/v1"
        /// A phone's endpoint key, derived from its device token.
        case device = "mizar-net/device/v1"
    }

    /// Derive an identity deterministically from an existing secret.
    ///
    /// The same secret and purpose always produce the same key pair, which is
    /// what makes this usable across reinstalls and across the pairing: the
    /// host secret outlives the process, so the host's endpoint id is stable
    /// without storing anything new.
    ///
    /// - Parameters:
    ///   - secret: high-entropy bytes — a host secret, or the SHA-256 of a
    ///     device token. Not a password.
    ///   - purpose: what the key is for.
    /// - Returns: the derived identity.
    public static func derived(from secret: Data, purpose: Purpose) -> MizarNetIdentity {
        var material = Data()
        material.append(secret)
        material.append(Data(purpose.rawValue.utf8))
        material.append(0x01)
        let digest = SHA256.hash(data: material)
        return MizarNetIdentity(seed: Data(digest))
    }

    /// The raw public key bytes.
    public var publicKey: Data {
        MizarNetCodec.base64URLDecode(endpointId) ?? Data()
    }

    /// Sign a message with the endpoint key.
    ///
    /// Used to prove possession of the identity the ticket named: the dialer
    /// signs a challenge that carries its own id, and a peer that is being
    /// impersonated cannot produce the signature.
    ///
    /// - Parameter message: the bytes to sign.
    /// - Returns: the 64-byte signature.
    public func sign(_ message: Data) throws -> Data {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        return try key.signature(for: message)
    }

    /// Verify a signature against an endpoint id.
    ///
    /// - Parameters:
    ///   - signature: the 64-byte signature to check.
    ///   - message: the message that was signed.
    ///   - endpointId: the base64url public key to verify against.
    /// - Returns: whether the signature is valid for that key and message.
    public static func verify(signature: Data, message: Data, endpointId: String) -> Bool {
        guard let raw = MizarNetCodec.base64URLDecode(endpointId),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else {
            return false
        }
        return key.isValidSignature(signature, for: message)
    }
}
