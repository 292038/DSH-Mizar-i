//
//  AccountStore.swift
//  MizarKit
//
//  Where the account token lives.
//
//  Two things are stored, separately, and the separation is the point:
//
//  - the **session** (bearer token plus the last profile) in the Keychain, with
//    the same `AfterFirstUnlockThisDeviceOnly` protection as the paired-host
//    token: it is a credential that can change a paid plan and delete an
//    account, and it must not ride a backup onto another phone;
//  - the **install id** in `UserDefaults`, because it is not secret — it is the
//    device id the relay uses to cap email-only accounts at two devices — and
//    keeping it out of the Keychain means it can be read from the main actor
//    without a Keychain round trip on a row that draws on every settings open.
//
//  The protocol exists for the usual reason: the Keychain is unavailable in
//  unit tests, so a store is injected and the tests use an in-memory one.
//

import Foundation
#if canImport(Security)
import Security
#endif

/// Storage for the signed-in account.
public protocol AccountStoring: Sendable {
    /// Read the stored session.
    /// - Returns: the session, or `nil` when this phone is signed out.
    func load() -> AccountSession?

    /// Store the session, replacing any previous one.
    /// - Parameter session: the session to store.
    /// - Throws: when storage refuses the write. A caller that ignores this would
    ///   believe it is signed in until the next launch.
    func save(_ session: AccountSession) throws

    /// Forget the session.
    func clear()

    /// The install id: a UUID generated once per install and sent with every
    /// sign-in as the device id.
    var installId: String { get }
}

/// A store that keeps the session in memory only.
///
/// For tests and previews. Deliberately the only fallback: a Keychain write that
/// fails throws rather than quietly degrading to memory, because a session that
/// appears to work and is gone on the next launch is worse than a sign-in that
/// says it could not be saved.
public final class InMemoryAccountStore: AccountStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var session: AccountSession?
    private let id: String

    /// - Parameters:
    ///   - session: a session to start signed in with.
    ///   - installId: the install id to report.
    public init(session: AccountSession? = nil, installId: String = "00000000-0000-4000-8000-000000000000") {
        self.session = session
        self.id = installId
    }

    public func load() -> AccountSession? {
        lock.lock()
        defer { lock.unlock() }
        return session
    }

    public func save(_ session: AccountSession) throws {
        lock.lock()
        defer { lock.unlock() }
        self.session = session
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        session = nil
    }

    public var installId: String { id }
}

/// The Keychain-backed store.
///
/// One generic-password item holds the JSON blob `{token,profile}`. The install id
/// lives in `UserDefaults` under ``installIdKey``.
public struct KeychainAccountStore: AccountStoring {
    /// The Keychain service name.
    private let service: String
    /// The Keychain account name.
    private let account: String
    /// The `UserDefaults` key holding the install id.
    private let installIdKey: String
    /// The `UserDefaults` suite, when one is used; `nil` means standard.
    private let suiteName: String?

    /// - Parameters:
    ///   - service: the Keychain service name.
    ///   - account: the Keychain account name.
    ///   - installIdKey: the defaults key for the install id.
    ///   - suiteName: a `UserDefaults` suite, for a test that must not write to
    ///     the simulator's real defaults.
    public init(
        service: String = "dsh-mizar",
        account: String = "account-session",
        installIdKey: String = "mizar.account.installId",
        suiteName: String? = nil,
    ) {
        self.service = service
        self.account = account
        self.installIdKey = installIdKey
        self.suiteName = suiteName
    }

    /// The defaults holding the install id.
    private var defaults: UserDefaults {
        if let suiteName, let suite = UserDefaults(suiteName: suiteName) { return suite }
        return .standard
    }

    /// The install id, created on first read.
    ///
    /// A UUID with dashes: 36 characters, all of them in the relay's
    /// `[A-Za-z0-9._-]` set for `x-mizar-client-id`, so the same value can serve
    /// as both the device id and the traffic client id without a second format.
    public var installId: String {
        if let stored = defaults.string(forKey: installIdKey), !stored.isEmpty { return stored }
        let created = UUID().uuidString.lowercased()
        defaults.set(created, forKey: installIdKey)
        return created
    }

    public func load() -> AccountSession? {
        #if canImport(Security)
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        // A blob this build cannot read is treated as signed out rather than as
        // a hard error: the worst outcome of that is one sign-in, and the worst
        // outcome of throwing here is an app that cannot start its account
        // controller because a Keychain item from an older build is malformed.
        return try? AccountCoding.decoder().decode(AccountSession.self, from: data)
        #else
        return nil
        #endif
    }

    public func save(_ session: AccountSession) throws {
        #if canImport(Security)
        let data = try AccountCoding.encoder().encode(session)

        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary,
        )
        if updateStatus == errSecSuccess { return }

        var query = baseQuery
        query[kSecValueData as String] = data
        // Readable after the first unlock so a foreground refresh can run while
        // the phone is locked in a pocket, but never migrated to another device.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw MizarError(
                code: "KEYCHAIN_WRITE_FAILED",
                message: "could not store the account in the keychain (status \(addStatus))",
            )
        }
        #else
        _ = session
        throw MizarError(
            code: "KEYCHAIN_UNAVAILABLE",
            message: "no keychain on this platform",
        )
        #endif
    }

    public func clear() {
        #if canImport(Security)
        // A missing item is success. Logout cannot fail because the phone was
        // already signed out.
        SecItemDelete(baseQuery as CFDictionary)
        #endif
    }

    #if canImport(Security)
    /// The base query identifying the one session item.
    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
    #endif
}
