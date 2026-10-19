//
//  AccountStoreTests.swift
//  MizarKitTests
//
//  The stored-session half of the account feature. The Keychain itself is not
//  touched here — a unit test that reads and writes a real Keychain item can
//  prompt a developer and cannot run in CI — so what is tested is the contract
//  the app depends on: an in-memory stand-in behaves like the real store, the
//  install id is stable across reads, and the install id is a legal relay client
//  id because the two are the same value on the wire.
//

import Foundation
import Testing
@testable import MizarKit

@Suite("AccountStore")
struct AccountStoreTests {
    private static func session(token: String = "mza_test") -> AccountSession {
        AccountSession(
            token: token,
            profile: AccountUser(id: "u1", username: "shirazu", plan: .free),
        )
    }

    @Test("an in-memory store starts signed out, saves and clears")
    func inMemoryLifecycle() throws {
        let store = InMemoryAccountStore()
        #expect(store.load() == nil)

        try store.save(Self.session())
        #expect(store.load()?.token == "mza_test")
        #expect(store.load()?.profile.username == "shirazu")

        store.clear()
        #expect(store.load() == nil)
    }

    @Test("saving a second session replaces the first")
    func replacesSession() throws {
        let store = InMemoryAccountStore()
        try store.save(Self.session(token: "mza_one"))
        try store.save(Self.session(token: "mza_two"))
        #expect(store.load()?.token == "mza_two")
    }

    @Test("the install id is stable across reads")
    func installIdStable() {
        let suite = "mizar.tests.install.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = KeychainAccountStore(installIdKey: "installId", suiteName: suite)

        let first = store.installId
        let second = store.installId
        #expect(first == second)
        #expect(UUID(uuidString: first) != nil)
        // The same value is sent as `x-mizar-client-id`, and the relay rejects a
        // malformed one: a broken value here would silently drop guest traffic
        // attribution for every request.
        #expect(RelayIdentity.isValidClientId(first))
    }

    @Test("a default install id is generated without a stored one")
    func installIdCreatedFromScratch() {
        let suite = "mizar.tests.install.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = UserDefaults(suiteName: suite)!
        #expect(defaults.string(forKey: "mizar.account.installId") == nil)

        let store = KeychainAccountStore(suiteName: suite)
        let id = store.installId
        #expect(defaults.string(forKey: "mizar.account.installId") == id)
    }

    @Test("an empty bearer token is not a usable session")
    func emptyTokenUnusable() {
        let session = AccountSession(token: "", profile: AccountUser(id: "u", username: "x"))
        #expect(!session.isUsable)
        #expect(AccountSession(token: "mza_t", profile: session.profile).isUsable)
    }
}
