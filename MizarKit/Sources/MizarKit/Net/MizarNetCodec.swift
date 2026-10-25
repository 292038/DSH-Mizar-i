//
//  MizarNetCodec.swift
//  MizarKit
//
//  The two encodings MizarNet puts on the wire.
//
//  Both exist to keep the kernel's small control payloads — an endpoint id, a
//  ticket, a candidate — inside a text frame or a URL query without any
//  escaping games. Base64url because a ticket has to survive a query string
//  and a JSON string unchanged; Crockford base32 because an endpoint id gets
//  read aloud and typed by a human eventually, and Crockford has no I, L, O
//  or U to confuse a reader.
//
//  Internal on purpose: nothing outside the kernel should be building these
//  by hand. They leak out only through the public types that wrap them.
//

import Foundation

enum MizarNetCodec {
    /// Crockford's base32 alphabet: no I, L, O or U.
    static let crockfordAlphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// URL-safe base64 without padding.
    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The inverse of ``base64URLEncode()``. Returns `nil` for anything that is
    /// not base64url text — a ticket that fails to decode is a broken ticket,
    /// and the caller decides what that means.
    static func base64URLDecode(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }

    /// The first `length` Crockford base32 characters of `data`.
    ///
    /// - Parameters:
    ///   - data: the bytes to encode. A 32-byte key yields 51 characters, so
    ///     any `length` up to that is available.
    ///   - length: how many characters to keep.
    /// - Returns: the prefix, in Crockford base32.
    static func crockfordBase32(_ data: Data, length: Int) -> String {
        var value = 0
        var bits = 0
        var output = ""
        for byte in data {
            value = (value << 8) | Int(byte)
            bits += 8
            while bits >= 5, output.count < length {
                bits -= 5
                output.append(crockfordAlphabet[(value >> bits) & 0x1F])
            }
            if output.count >= length { break }
        }
        return output
    }
}
