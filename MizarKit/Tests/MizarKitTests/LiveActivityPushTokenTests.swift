//
//  LiveActivityPushTokenTests.swift
//  MizarKitTests
//
//  The address APNs issues for one Live Activity, and the keyboard-safe way it
//  travels: from `Activity.pushToken`, which is bytes, to the `push.register`
//  payload, which is a lowercase hex string the host can hand straight to APNs.
//
//  Two halves, both testable without ActivityKit. The encoding is arithmetic on
//  bytes, and the store is a string in `UserDefaults` plus the one notification
//  that tells the app a new address must be registered. Neither needs an
//  activity to exist, so both are pinned here, on the host, in a second.
//

import Foundation
import Testing
@testable import MizarKit

// MARK: - The encoding

@Suite("A Live Activity push token")
struct LiveActivityPushTokenTests {
    @Test("is the bytes as lowercase hex, two characters each")
    func hexIsLowercase() {
        // The same encoding `PushController` gives the device token: `%02x` over
        // the bytes. APNs issues tokens as bytes, and the host's contract is
        // lowercase hex -- a `Data` printed by `description` would be "<0a1b…>",
        // which is not a token and would be refused by every layer that saw it.
        #expect(LiveActivityPushToken.hex(Data([0x0a, 0x1b, 0x2c, 0xff])) == "0a1b2cff")
        #expect(LiveActivityPushToken.hex(Data([0x00])) == "00")
        #expect(LiveActivityPushToken.hex(Data([0xAB])) == "ab", "uppercase crept into the encoding")
        // Today's APNs tokens are 32 bytes; nobody here may assume that is
        // permanent, which is why the encoding is over `Data` and not a fixed
        // 64-character form.
        #expect(
            LiveActivityPushToken.hex(Data(repeating: 0xab, count: 32))
                == String(repeating: "ab", count: 32),
        )
    }

    @Test("is a token only when it is lowercase hex of a whole number of bytes")
    func validationAcceptsRealTokens() {
        let token = String(repeating: "0123456789abcdef", count: 4) // 64 characters
        #expect(LiveActivityPushToken.validated(token) == token)
        #expect(LiveActivityPushToken.validated("ab") == "ab")
        #expect(
            LiveActivityPushToken.validated(String(repeating: "a", count: LiveActivityPushToken.maximumLength))
                != nil,
            "the longest token the wire contract allows was refused",
        )
    }

    @Test("normalises what it stores to the wire's lowercase hex")
    func validationNormalises() {
        // The host validates `^[0-9a-f]{1,200}$`, so uppercase would be refused
        // there and silently clear the token this app worked to obtain. Trimming
        // is the same argument for the whitespace a copied or edited value
        // carries: a token that differs from the real one only by a newline is a
        // token that was never real.
        #expect(LiveActivityPushToken.validated("  DEADBEEF\n") == "deadbeef")
        #expect(LiveActivityPushToken.validated("\tab12cd34ef ") == "ab12cd34ef")
        #expect(LiveActivityPushToken.validated(nil) == nil)
    }

    @Test(
        "refuses anything that is not an APNs token",
        arguments: [
            "",
            " ",
            "not-hex",
            "0a1b2c4", // odd number of characters: not whole bytes
            "<0a1b2cff>", // a `Data` description, which is not a token
            "0a1b 2cff", // a separator no APNs token has
            "0a1b-2cff",
            "0x0a1b2cff",
            "ｄｅａｄｂｅｅｆ", // full-width letters are not hex
            String(repeating: "a", count: LiveActivityPushToken.maximumLength + 1),
        ],
    )
    func validationRefusesGarbage(_ raw: String) {
        #expect(LiveActivityPushToken.validated(raw) == nil)
    }
}

// MARK: - Where it is kept

@Suite("Where the Live Activity token is kept", .serialized)
struct LiveActivityPushTokenStoreTests {
    /// A defaults domain of this test's own.
    ///
    /// Not `UserDefaults.standard`: a test that writes the real defaults reads
    /// the machine it runs on, leaves a token behind for the next test to find,
    /// and cannot run twice in a row. A unique suite per test is the same rule
    /// `UserDefaultsSettingsStorage` is given its storage for.
    private func temporaryDefaults() -> UserDefaults {
        let name = "mizar.tests.liveActivityToken.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("starts with no token")
    func startsEmpty() {
        #expect(LiveActivityPushTokenStore.stored(in: temporaryDefaults()) == nil)
    }

    @Test("keeps a token across the process that wrote it")
    func roundTrips() throws {
        let defaults = temporaryDefaults()
        let token = String(repeating: "deadbeef", count: 8)

        #expect(LiveActivityPushTokenStore.store(token, in: defaults))
        // Read back through `UserDefaults` by key, not through a cache in the
        // type: the contract that matters is that the value survives the process
        // that put it there, which is what makes a reconnect able to re-announce
        // a card the app is no longer awake to describe.
        #expect(defaults.string(forKey: LiveActivityPushTokenStore.tokenKey) == token)
        #expect(LiveActivityPushTokenStore.stored(in: defaults) == token)
    }

    @Test("refuses to keep something that is not a token")
    func refusesGarbage() {
        let defaults = temporaryDefaults()

        #expect(!LiveActivityPushTokenStore.store("<0a1b2cff>", in: defaults))
        #expect(LiveActivityPushTokenStore.stored(in: defaults) == nil)
        #expect(defaults.string(forKey: LiveActivityPushTokenStore.tokenKey) == nil)
    }

    @Test("clears the token when the activity is gone")
    func clears() {
        let defaults = temporaryDefaults()
        #expect(LiveActivityPushTokenStore.store("deadbeef", in: defaults))

        // `nil` is the app's way of saying "no card is up", and it has to mean
        // the same to the host: absent from the next `push.register`, so a token
        // whose card is already down is not pushed to.
        #expect(LiveActivityPushTokenStore.store(nil, in: defaults))
        #expect(LiveActivityPushTokenStore.stored(in: defaults) == nil)
        #expect(defaults.string(forKey: LiveActivityPushTokenStore.tokenKey) == nil)
        // Nothing was held, so there is nothing to clear, and nothing to say.
        #expect(!LiveActivityPushTokenStore.store(nil, in: defaults))
    }

    @Test("a corrupted value in the defaults reads as no token")
    func corruptedValueIsNoToken() {
        let defaults = temporaryDefaults()
        defaults.set("not a token", forKey: LiveActivityPushTokenStore.tokenKey)

        // The store is the last line of defence: whatever is in the file is
        // validated before it reaches a host that would refuse it anyway, and a
        // value that fails is treated as nothing rather than sent and rejected.
        #expect(LiveActivityPushTokenStore.stored(in: defaults) == nil)
    }

    @Test("tells the app when the token changes, and not when it does not")
    func announcesChanges() async {
        let defaults = temporaryDefaults()
        let token = "ab12cd34ef"
        #expect(LiveActivityPushTokenStore.store(token, in: defaults))

        // A new token is a new address the host must be told about; the same
        // token again is the app having looked twice. The registration is a
        // request, so the difference is a request saved on every refresh.
        let unchanged = LiveActivityPushTokenStore.store(token, in: defaults)
        #expect(!unchanged)

        await confirmation("a changed token is announced") { confirm in
            let observer = NotificationCenter.default.addObserver(
                forName: LiveActivityPushTokenStore.changed,
                object: nil,
                queue: nil,
            ) { _ in confirm() }
            defer { NotificationCenter.default.removeObserver(observer) }

            // One post for the change, and none for the repeat made inside the
            // same scope: a confirmation of one fails if the second one fires.
            #expect(LiveActivityPushTokenStore.store("feedface", in: defaults))
            #expect(!LiveActivityPushTokenStore.store("feedface", in: defaults))
        }
    }

    @Test("announces a clear as a change")
    func announcesClears() async {
        let defaults = temporaryDefaults()
        #expect(LiveActivityPushTokenStore.store("deadbeef", in: defaults))

        await confirmation("the clear is announced") { confirm in
            let observer = NotificationCenter.default.addObserver(
                forName: LiveActivityPushTokenStore.changed,
                object: nil,
                queue: nil,
            ) { _ in confirm() }
            defer { NotificationCenter.default.removeObserver(observer) }
            #expect(LiveActivityPushTokenStore.store(nil, in: defaults))
        }
    }
}

// MARK: - Where the token that starts one is kept

@Suite("Where the push-to-start token is kept", .serialized)
struct LiveActivityStartTokenStoreTests {
    private func temporaryDefaults() -> UserDefaults {
        let name = "mizar.tests.liveActivityStartToken.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("starts with no token")
    func startsEmpty() {
        #expect(LiveActivityStartTokenStore.stored(in: temporaryDefaults()) == nil)
    }

    @Test("keeps a token across the process that wrote it")
    func roundTrips() {
        let defaults = temporaryDefaults()
        let token = String(repeating: "0123456789abcdef", count: 4)

        #expect(LiveActivityStartTokenStore.store(token, in: defaults))
        #expect(defaults.string(forKey: LiveActivityStartTokenStore.tokenKey) == token)
        #expect(LiveActivityStartTokenStore.stored(in: defaults) == token)
    }

    @Test("lives beside the activity token rather than in it")
    func separateKey() {
        // The two are different things: one addresses a card that exists and the
        // other the card that does not. A store that reused the key would have
        // the app forget how to start a card every time one ended.
        let defaults = temporaryDefaults()
        #expect(LiveActivityPushTokenStore.tokenKey != LiveActivityStartTokenStore.tokenKey)

        #expect(LiveActivityPushTokenStore.store("deadbeef", in: defaults))
        #expect(LiveActivityStartTokenStore.store("feedface", in: defaults))
        #expect(LiveActivityPushTokenStore.stored(in: defaults) == "deadbeef")
        #expect(LiveActivityStartTokenStore.stored(in: defaults) == "feedface")

        // Clearing one says nothing about the other.
        #expect(LiveActivityPushTokenStore.store(nil, in: defaults))
        #expect(LiveActivityStartTokenStore.stored(in: defaults) == "feedface")
    }

    @Test("refuses what is not a token, and normalises what is one")
    func refusesGarbage() {
        let defaults = temporaryDefaults()
        #expect(!LiveActivityStartTokenStore.store("<0a1b>", in: defaults))
        #expect(!LiveActivityStartTokenStore.store("aabbc", in: defaults))
        #expect(LiveActivityStartTokenStore.stored(in: defaults) == nil)

        // Capitals and padding are the same token, and the host validates
        // lowercase: normalising is what keeps a value read back from the file
        // on the right side of a pattern it did not write itself.
        #expect(LiveActivityStartTokenStore.store(" AABB \n", in: defaults))
        #expect(LiveActivityStartTokenStore.stored(in: defaults) == "aabb")
    }
}
