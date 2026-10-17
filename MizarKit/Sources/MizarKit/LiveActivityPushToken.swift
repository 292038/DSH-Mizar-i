//
//  LiveActivityPushToken.swift
//  MizarKit
//
//  The address APNs issues one Live Activity, and the place this install keeps
//  it.
//
//  An activity started with `pushType: .token` is handed a second APNs token,
//  distinct from the device token: it addresses *that card*, not this phone, and
//  it is what lets the host update or end the activity while the app is
//  suspended. Without it the card can only be taken down by this app the next
//  time it notices the session stopped -- which for a phone in a pocket is the
//  next time the app is opened, so the clock keeps counting for a session that
//  ended hours ago. That is the bug this file is part of fixing.
//
//  Two things live here rather than in the app target, and both are about being
//  testable. The encoding is arithmetic on bytes. The store is a string in
//  `UserDefaults` plus the one notification that says a new address has to be
//  registered. Neither needs an `Activity`, and neither needs ActivityKit -- so
//  both are exercised by `swift test` on the host, where the app's own target
//  cannot be. `LiveActivityAttributes.swift` makes the same split for the type
//  the two processes share, and for the same reason.
//
//  The wire contract, frozen between this app, the plugin and the relay: the
//  `push.register` payload carries the token as optional `"liveActivityToken"`,
//  a string of lowercase hex. Absent means "no card is up -- stop pushing to the
//  one you had". The host validates it with `^[0-9a-f]{1,200}$`, so everything
//  this file stores or returns has already been normalised to that shape.
//

import Foundation

// MARK: - The token

/// An APNs Live Activity push token.
///
/// A namespace rather than a boxed value: the token is a `String` on the wire
/// and in `UserDefaults`, and the only two decisions about it are how bytes
/// become one and whether a string is one. Boxing it would create a second
/// representation of the same address.
public enum LiveActivityPushToken {
    /// The longest token the wire contract carries.
    ///
    /// APNs tokens are 32 bytes today, so 64 characters. The bound is the
    /// host's, deliberately wide enough that a future length is not silently
    /// rejected here before the host could accept it, and narrow enough that a
    /// stored file cannot be made to hold an unbounded string.
    public static let maximumLength = 200

    /// Bytes as the lowercase hex string APNs and the host both expect.
    ///
    /// The same encoding `PushController` gives the device token: `%02x` per
    /// byte, two characters each, no separators. Lowercase because the wire
    /// contract validates lowercase -- `Data.description`'s "<0a1b…>" is not a
    /// token at any layer, and an uppercase one would be refused by the host.
    ///
    /// - Parameter data: the token ActivityKit handed over.
    /// - Returns: the token, or the empty string for empty data -- which
    ///   ``validated(_:)`` refuses, so an empty activity token is never stored.
    public static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// The token a stored or reported string stands for, if it is one.
    ///
    /// Trims whitespace and lowercases before validating, because the value can
    /// come from a file rather than from ``hex(_:)``: a token that differs from
    /// the real one only by a newline or a capital was still the real token, and
    /// normalising it is what keeps it on the right side of the host's pattern.
    ///
    /// - Parameter raw: the candidate, normally straight from `Activity.pushToken`
    ///   or from `UserDefaults`.
    /// - Returns: the normalised token, or `nil` when the string is not one.
    public static func validated(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Hex is whole bytes, so an odd length is not a token however hex it
        // looks -- and a token APNs would never issue is one this app should
        // never register.
        guard (2...maximumLength).contains(candidate.count),
              candidate.count.isMultiple(of: 2),
              candidate.utf8.allSatisfy(isLowercaseHexByte)
        else { return nil }
        return candidate
    }

    /// Whether one UTF-8 byte is a lowercase hexadecimal digit.
    ///
    /// Deliberately not `Character.isHexDigit`: that is Unicode's `Hex_Digit`
    /// property, which includes the full-width forms (`ｄｅａｄｂｅｅｆ` answers
    /// `true`), while the host validates ASCII with `^[0-9a-f]{1,200}$`. A
    /// validation that accepted what the wire refuses is the silent clear this
    /// function exists to prevent -- so the check is on the bytes the wire
    /// carries.
    ///
    /// - Parameter byte: one byte of the candidate.
    /// - Returns: whether it is `0`-`9` or `a`-`f`.
    private static func isLowercaseHexByte(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
    }
}

// MARK: - Where it is kept

/// Where this install keeps the Live Activity's push token.
///
/// `UserDefaults`, not the Keychain, for the reason `PushRegistration` keeps the
/// device token there: the token is an address Apple issued to this install, not
/// a secret, and the Keychain survives a reinstall -- which would leave a token
/// for an activity that no longer exists being re-registered forever.
///
/// Public because the app's `push.register` call is the reader and this module
/// owns the format; testable because the defaults are a parameter rather than a
/// global, so a test writes a suite of its own instead of the machine's settings.
public enum LiveActivityPushTokenStore {
    /// Where the token lives in `UserDefaults`.
    public static let tokenKey = "mizar.liveActivityToken"

    /// Posted when the stored token changes, with no object.
    ///
    /// The app observes this and sends a new `push.register`: the token arrives
    /// after the activity starts, so the registration made on connect usually
    /// predates it, and a clear is the same news in reverse -- the host must
    /// stop pushing to a card that is already down.
    ///
    /// Posted only on an actual change. A refresh that reads the same token
    /// again is the app having looked twice, not news, and a notification per
    /// look would be a registration request per look.
    public static let changed = Notification.Name("mizar.liveActivity.token")

    /// The token as it is stored, if one is.
    ///
    /// Validated on the way out as well as on the way in: whatever is in the
    /// file is not sent to a host that would refuse it, and a value that is not
    /// a token reads as no token -- which is the truth about a card whose
    /// address cannot be used.
    ///
    /// - Parameter defaults: where to read. `UserDefaults.standard` in the app;
    ///   a suite of its own in a test.
    /// - Returns: the token, or `nil`.
    public static func stored(in defaults: UserDefaults = .standard) -> String? {
        LiveActivityPushToken.validated(defaults.string(forKey: tokenKey))
    }

    /// Remember the token a Live Activity reported, or forget the one it had.
    ///
    /// - Parameters:
    ///   - raw: the token from `Activity.pushToken`, already hex-encoded, or
    ///     `nil` when no activity is up. An invalid token is treated as `nil`:
    ///     a card has ended, not something the host could push to.
    ///   - defaults: where to write.
    /// - Returns: whether the stored value changed -- which is also whether
    ///   ``changed`` was posted.
    @discardableResult
    public static func store(_ raw: String?, in defaults: UserDefaults = .standard) -> Bool {
        let token = LiveActivityPushToken.validated(raw)
        guard stored(in: defaults) != token else { return false }
        if let token {
            defaults.set(token, forKey: tokenKey)
        } else {
            defaults.removeObject(forKey: tokenKey)
        }
        NotificationCenter.default.post(name: changed, object: nil)
        return true
    }
}
