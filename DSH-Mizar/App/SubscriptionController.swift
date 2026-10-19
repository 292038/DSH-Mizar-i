//
//  SubscriptionController.swift
//  DSH-Mizar
//
//  The Apple subscription: buying it, restoring it, and telling the relay.
//
//  The purchase is real. The one requirement the product cannot compromise is
//  that the button opens Apple's payment sheet — a "subscribe" button that shows
//  a local success screen and takes no money is a button that gets the app
//  rejected and, worse, lies to the operator. So the flow is exactly StoreKit 2's:
//
//    Product.products(for:)  ->  product.purchase(options:)  ->  App Store sheet
//    ->  verified transaction  ->  POST /appstore/transaction  ->  refreshed plan
//
//  The server, not the phone, decides paid state: it verifies the JWS against
//  Apple's certificate chain and applies the expiry. The phone's job is to carry
//  the transaction there and to draw what comes back.
//
//  `SubscriptionStore` is the seam. StoreKit cannot be driven in a UI test on a
//  simulator without a StoreKit configuration, so a debug-only mock implements
//  the same protocol and is selected by a launch argument; the production path
//  is the real one.
//

import Foundation
import MizarKit
import Observation
import StoreKit

/// One product, as the subscription section needs to draw it.
///
/// A local model rather than `StoreKit.Product` so the mock can exist and so the
/// view cannot accidentally read a field that a non-StoreKit source cannot
/// provide.
struct SubscriptionProduct: Sendable, Equatable {
    /// The App Store product id.
    let id: String
    /// The product's name.
    let displayName: String
    /// Apple's localised price string, e.g. `¥6.00`.
    ///
    /// Always this and never a hard-coded number: the price is set in App Store
    /// Connect per storefront, and a `¥6` string in the app would be wrong in
    /// every other currency and stale after any price change.
    let displayPrice: String
    /// Apple's description for the product.
    let description: String
}

/// What one purchase attempt produced.
enum SubscriptionPurchase: Sendable, Equatable {
    /// Apple verified a transaction; the JWS still has to reach the relay.
    case purchased(signedTransaction: String)
    /// Waiting on approval (Ask to Buy, or a payment problem).
    case pending
    /// The operator dismissed the sheet.
    case cancelled
    /// Apple could not verify the transaction.
    case unverified
}

/// The StoreKit surface the controller uses.
protocol SubscriptionStore: Sendable {
    /// Load one product.
    /// - Parameter id: the App Store product id.
    /// - Returns: the product, or `nil` when the App Store does not offer it.
    func product(id: String) async throws -> SubscriptionProduct?

    /// Buy one product, optionally binding it to an account.
    /// - Parameters:
    ///   - id: the product id.
    ///   - appAccountToken: the account UUID, so the relay can bind the
    ///     transaction to the account without trusting a client-supplied id.
    /// - Returns: what the attempt produced.
    func purchase(id: String, appAccountToken: UUID?) async throws -> SubscriptionPurchase

    /// Ask the App Store to sync; the restore path.
    func syncAppStore() async throws

    /// Every currently-entitled, non-revoked, unexpired transaction as a JWS.
    /// - Parameter productId: the product to filter to.
    /// - Returns: the signed transactions.
    func currentSignedTransactions(productId: String) async -> [String]

    /// Live transaction updates, as signed JWS strings.
    /// - Parameter productId: the product to filter to.
    /// - Returns: the stream; it never finishes on its own in practice.
    func transactionUpdates(productId: String) -> AsyncStream<String>
}

// MARK: - Real StoreKit

/// StoreKit 2, as the controller sees it.
struct StoreKitSubscriptionStore: SubscriptionStore {
    func product(id: String) async throws -> SubscriptionProduct? {
        guard let product = try await Product.products(for: [id]).first else { return nil }
        return SubscriptionProduct(
            id: product.id,
            displayName: product.displayName,
            displayPrice: product.displayPrice,
            description: product.description,
        )
    }

    func purchase(id: String, appAccountToken: UUID?) async throws -> SubscriptionPurchase {
        guard let product = try await Product.products(for: [id]).first else {
            throw StoreKitSubscriptionError.productUnavailable
        }
        var options: Set<Product.PurchaseOption> = []
        if let appAccountToken {
            // The one field that lets the relay bind the Apple transaction to an
            // account without trusting anything the client says. It is the
            // account UUID, and the relay verifies it against the JWS.
            options.insert(.appAccountToken(appAccountToken))
        }
        switch try await product.purchase(options: options) {
        case .success(let verification):
            switch verification {
            case .verified(let transaction):
                let signed = Self.signed(transaction)
                // Finished even when the relay will sync later: an unfinished
                // transaction is redelivered on every launch, and the server is
                // idempotent by transaction id.
                await transaction.finish()
                return .purchased(signedTransaction: signed)
            case .unverified:
                return .unverified
            }
        case .pending:
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            return .cancelled
        }
    }

    func syncAppStore() async throws {
        try await AppStore.sync()
    }

    func currentSignedTransactions(productId: String) async -> [String] {
        var out: [String] = []
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            guard transaction.productID == productId else { continue }
            // Revoked and expired transactions are still "current entitlements"
            // in some upgrade cases; the relay re-checks, but sending them only
            // buys a pointless round trip.
            if transaction.revocationDate != nil { continue }
            if let expiry = transaction.expirationDate, expiry <= Date() { continue }
            out.append(Self.signed(transaction))
        }
        return out
    }

    func transactionUpdates(productId: String) -> AsyncStream<String> {
        AsyncStream { continuation in
            let task = Task {
                for await result in Transaction.updates {
                    guard case .verified(let transaction) = result else { continue }
                    if transaction.productID == productId,
                       let signed = Self.signedData(transaction) {
                        continuation.yield(signed)
                    }
                    // Every update is finished, including another product's:
                    // an unfinished one is redelivered forever.
                    await transaction.finish()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// A transaction as the JWS string the relay verifies.
    private static func signed(_ transaction: Transaction) -> String {
        signedData(transaction) ?? ""
    }

    private static func signedData(_ transaction: Transaction) -> String? {
        String(data: transaction.jsonRepresentation, encoding: .utf8)
    }
}

/// Why StoreKit could not produce a product.
enum StoreKitSubscriptionError: LocalizedError {
    /// The App Store does not offer the product in this storefront, or the
    /// product id has not propagated yet.
    case productUnavailable

    var errorDescription: String? {
        switch self {
        case .productUnavailable:
            String(localized: "This subscription is not available from the App Store right now.")
        }
    }
}

#if DEBUG
/// A stand-in subscription used by the UI tests.
///
/// Selected by launching with `-mizarMockSubscription`. It exists because a
/// simulator UI test has no App Store account and no payment sheet: without a
/// seam, the only assertion a test could make about the subscription CTA is that
/// it exists. With one, the test can press it and watch the account become paid,
/// which is the behaviour that matters.
struct MockSubscriptionStore: SubscriptionStore {
    /// The price the mock reports. Read from a launch argument so a test can pin
    /// what it expects without matching the default string.
    var displayPrice: String = "¥6.00"

    func product(id: String) async throws -> SubscriptionProduct? {
        SubscriptionProduct(
            id: id,
            displayName: String(localized: "Mizar Paid"),
            displayPrice: displayPrice,
            description: String(localized: "A monthly subscription that supports the project and unlocks attachments."),
        )
    }

    func purchase(id: String, appAccountToken: UUID?) async throws -> SubscriptionPurchase {
        // A mock JWS: any non-empty string. The account controller is talking to
        // the mock host, which accepts it.
        .purchased(signedTransaction: "mock.jws.\(appAccountToken?.uuidString ?? "guest")")
    }

    func syncAppStore() async throws {}

    func currentSignedTransactions(productId: String) async -> [String] { [] }

    func transactionUpdates(productId: String) -> AsyncStream<String> {
        AsyncStream { $0.finish() }
    }
}
#endif

// MARK: - Controller

/// The subscription section's state.
@MainActor
@Observable
final class SubscriptionController {
    /// The one product this app sells.
    static let productId = "me.shirazu.dshmizar.paid.monthly"

    /// Where "manage subscription" goes.
    ///
    /// Apple's own account page, which is the only place a subscription can be
    /// cancelled. The app cannot cancel it, and a button that pretends to is a
    /// support ticket.
    static let manageSubscriptionsURL = URL(string: "https://apps.apple.com/account/subscriptions")!

    /// The privacy policy shown in the subscription disclosure.
    ///
    /// Hosted on the project's own relay host (主力0), not on the account host:
    /// the account API is on a different machine (主力1), and the legal pages are
    /// static HTML that belongs with the site.
    static let privacyURL = URL(string: "https://dsh-mizar.shirazu-nagisa.com/privacy/")!

    /// The terms of use, alongside the privacy policy.
    static let termsURL = URL(string: "https://dsh-mizar.shirazu-nagisa.com/terms/")!

    /// How far the purchase flow has got.
    enum Phase: Equatable {
        /// The product has not been read yet.
        case idle
        /// Reading the product from the App Store.
        case loading
        /// The product is loaded and a purchase can start.
        case ready
        /// Apple's sheet is up, or the purchase is being carried to the relay.
        case purchasing
        /// The purchase is waiting on approval.
        case pending
        /// The relay applied the purchase.
        case purchased
        /// Something went wrong; the sentence is in ``lastError``.
        case failed
    }

    /// The product, once read.
    private(set) var product: SubscriptionProduct?
    /// Where the flow is.
    private(set) var phase: Phase = .idle
    /// A failure as a sentence.
    private(set) var lastError: String?
    /// Something worth saying that is not a failure — a pending purchase, a
    /// successful restore, a purchase the relay has not seen yet.
    private(set) var notice: String?
    /// Whether the mock store is in use, so a debug build can say so.
    private(set) var isMocked = false

    private let store: any SubscriptionStore
    /// The account the purchase is bound to.
    ///
    /// Weak, because the account controller owns the subscription's caller and a
    /// strong back-reference would tie the two together for the process's life.
    weak var account: AccountController?
    private var updateTask: Task<Void, Never>?

    /// - Parameter store: the StoreKit surface, or a mock. `nil` chooses the
    ///   real one, or the mock when a debug build was launched with
    ///   `-mizarMockSubscription`.
    init(store: (any SubscriptionStore)? = nil) {
        #if DEBUG
        if store == nil, ProcessInfo.processInfo.arguments.contains("-mizarMockSubscription") {
            self.store = MockSubscriptionStore(displayPrice: Self.mockPrice)
            self.isMocked = true
            return
        }
        #endif
        self.store = store ?? StoreKitSubscriptionStore()
    }

    #if DEBUG
    /// The mock price, from `-mizarMockSubscriptionPrice`, defaulting to `¥6.00`.
    private static var mockPrice: String {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-mizarMockSubscriptionPrice"),
           arguments.indices.contains(index + 1) {
            return arguments[index + 1]
        }
        return "¥6.00"
    }
    #endif

    /// Point the controller at the account and start listening for renewals.
    ///
    /// Called once, when the app model is built.
    /// - Parameter account: the account controller.
    func attach(to account: AccountController) {
        self.account = account
        startListening()
    }

    /// Read the product.
    ///
    /// Safe to call repeatedly: the App Store read happens once per controller
    /// unless it failed, so opening the account screen again does not make the
    /// price row flash.
    func load() async {
        guard product == nil, phase == .idle || phase == .failed else { return }
        phase = .loading
        do {
            product = try await store.product(id: Self.productId)
            // A missing product is a failed *load*, not a ready state: the App
            // Store may not have propagated a new product yet, and opening the
            // screen again is the natural retry. Marking it ready meant the
            // retry never happened for the life of the process.
            phase = product == nil ? .failed : .ready
            if product == nil {
                lastError = String(localized: "This subscription is not available from the App Store right now.")
            }
        } catch {
            phase = .failed
            lastError = describe(error)
        }
    }

    /// Buy the subscription.
    ///
    /// The account must be signed in: the purchase is bound to the account's
    /// UUID so the relay can apply it to the right user. A signed-out tap gets a
    /// sentence, not a sheet.
    ///
    /// - Returns: whether the relay now says the account is paid.
    @discardableResult
    func purchase() async -> Bool {
        guard let account else { return false }
        guard account.isLoggedIn else {
            lastError = String(localized: "Sign in first: the subscription is bound to your account.")
            return false
        }
        guard let token = account.user?.uuid else {
            lastError = String(localized: "This account's id could not be read, so the purchase cannot be linked to it.")
            return false
        }
        if product == nil {
            await load()
        }
        guard phase == .ready || phase == .purchased || phase == .failed else { return false }
        phase = .purchasing
        lastError = nil
        notice = nil
        do {
            let outcome = try await store.purchase(id: Self.productId, appAccountToken: token)
            switch outcome {
            case .purchased(let signed):
                phase = .purchased
                // The App Store took the money; the relay applies the expiry. A
                // failure here is a sync failure, not a purchase failure, and the
                // next launch retries it — so the wording must not suggest the
                // purchase did not happen.
                if await account.submitAppStoreTransaction(signed) {
                    notice = String(localized: "You're subscribed. Thank you for supporting DSH-Mizar.")
                    return true
                }
                notice = String(localized: "The App Store purchase went through, but the account server has not recorded it yet. It will sync automatically.")
                return false
            case .pending:
                phase = .pending
                notice = String(localized: "The purchase is waiting for approval. The plan updates once it is approved.")
                return false
            case .cancelled:
                phase = .ready
                return false
            case .unverified:
                phase = .ready
                lastError = String(localized: "The App Store could not verify this purchase. Try restoring purchases.")
                return false
            }
        } catch {
            phase = .failed
            lastError = describe(error)
            return false
        }
    }

    /// Restore purchases: ask the App Store to sync, then carry what it holds to
    /// the relay.
    ///
    /// - Returns: whether an entitlement was found and applied.
    @discardableResult
    func restore() async -> Bool {
        guard let account, account.isLoggedIn else {
            lastError = String(localized: "Sign in first to restore purchases.")
            return false
        }
        phase = .loading
        lastError = nil
        notice = nil
        do {
            try await store.syncAppStore()
        } catch {
            phase = .ready
            lastError = describe(error)
            return false
        }
        let signed = await store.currentSignedTransactions(productId: Self.productId)
        guard !signed.isEmpty else {
            phase = .ready
            notice = String(localized: "No App Store subscription was found for this Apple ID.")
            return false
        }
        let applied = await account.syncAppStoreTransactions(signed)
        phase = applied ? .purchased : .ready
        if applied {
            notice = String(localized: "Purchases restored.")
        } else {
            lastError = String(localized: "The App Store subscription was found, but the account server could not be reached. Try again later.")
        }
        return applied
    }

    /// Sync what the App Store already holds without a user-facing flow.
    ///
    /// Called after a sign-in and on launch, because a subscription bought on
    /// another device — or before a reinstall — is only in Apple's records and
    /// the relay needs to see it.
    func syncEntitlements() async {
        guard let account, account.isLoggedIn else { return }
        let signed = await store.currentSignedTransactions(productId: Self.productId)
        guard !signed.isEmpty else { return }
        _ = await account.syncAppStoreTransactions(signed)
    }

    /// Forget a message the screen has shown.
    func clearFeedback() {
        lastError = nil
        notice = nil
    }

    /// The price to draw.
    ///
    /// The product's own localised string. The ellipsis while it loads is
    /// deliberate: showing `¥6.00` before Apple has said so would be a hard-coded
    /// price, which is the one thing this section must never do.
    var priceText: String { product?.displayPrice ?? "…" }

    /// Whether a subscription can be bought right now.
    var canPurchase: Bool {
        guard product != nil else { return false }
        return phase != .purchasing && phase != .pending
    }

    /// Whether the account's paid plan comes from the App Store.
    var accountPaidViaAppStore: Bool { account?.user?.paidViaAppStore ?? false }

    // MARK: - Updates

    /// Listen for renewals and changes.
    ///
    /// A renewal is a transaction the operator never sees: Apple charges, sends a
    /// notice to this app, and the relay has to be told or the plan silently
    /// lapses at the end of the current period.
    private func startListening() {
        updateTask?.cancel()
        let stream = store.transactionUpdates(productId: Self.productId)
        updateTask = Task { [weak self] in
            for await signed in stream {
                guard let self else { return }
                guard self.account?.isLoggedIn == true else { continue }
                _ = await self.account?.submitAppStoreTransaction(signed)
                self.phase = .purchased
            }
        }
    }

    /// A failure as a sentence.
    private func describe(_ error: any Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
