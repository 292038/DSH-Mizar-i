//
//  AppleSignIn.swift
//  DSH-Mizar
//
//  Sign in with Apple, with the nonce dance done correctly.
//
//  Apple hands the app a JWT whose `nonce` claim is the SHA-256 of a random
//  string *the app chose*. The app sends the raw string to the relay, which
//  hashes it and compares; that is what proves the token was minted for this
//  sign-in attempt rather than lifted from another app. Get it backwards -- send
//  the hash to the server, or put the raw value in the request -- and every
//  Apple sign-in is refused with `APPLE_TOKEN_INVALID`.
//
//  The identity token is a credential and is never logged, never put in an
//  accessibility label, and never stored: it travels once, over HTTPS, to the
//  relay, which verifies it and keeps only the Apple `sub`.
//

import AuthenticationServices
import CryptoKit
import Security
import SwiftUI

/// The nonce a Sign in with Apple request is bound to.
enum AppleSignInNonce {
    /// The alphabet used for the fallback generator.
    private static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")

    /// Make a fresh random nonce.
    ///
    /// - Returns: 32 bytes, base64url-encoded without padding (43 characters).
    static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status == errSecSuccess {
            return Data(bytes).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        // The system RNG is one syscall away from failing, but a sign-in must
        // not depend on it: a UUID plus random characters is still unique enough
        // for a value that lives for one request.
        return (0..<43).map { _ in String(alphabet.randomElement() ?? "0") }.joined()
    }

    /// The hex SHA-256 Apple compares against the token's `nonce` claim.
    ///
    /// - Parameter nonce: the raw nonce.
    /// - Returns: lowercase hex.
    static func sha256Hex(_ nonce: String) -> String {
        SHA256.hash(data: Data(nonce.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// The Sign in with Apple button, wired to the account controller.
///
/// Rendered by `SignInWithAppleButton` rather than drawn by hand: Apple's button
/// has a required appearance and a system-provided accessibility shape, and a
/// custom one is a review rejection.
struct AppleSignInView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    /// Called with a sentence when the attempt failed. A cancellation does not
    /// call it: putting a red line under the button because somebody tapped
    /// "Cancel" is an app arguing with its operator.
    var onFailure: (String) -> Void = { _ in }

    /// The raw nonce for the attempt in flight.
    @State private var rawNonce = AppleSignInNonce.generate()

    var body: some View {
        SignInWithAppleButton(.signIn) { request in
            // A fresh nonce per attempt. Reusing one would let a token minted
            // for a previous, failed attempt be replayed.
            rawNonce = AppleSignInNonce.generate()
            request.requestedScopes = [.fullName, .email]
            request.nonce = AppleSignInNonce.sha256Hex(rawNonce)
        } onCompletion: { result in
            Task { await complete(result) }
        }
        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
        .frame(height: 46)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .accessibilityIdentifier("account.apple")
        .accessibilityLabel("Sign in with Apple")
    }

    /// Carry the Apple result to the account controller.
    ///
    /// - Parameter result: what `ASAuthorizationController` produced.
    private func complete(_ result: Result<ASAuthorization, any Error>) async {
        switch result {
        case .failure(let error):
            if let authorizationError = error as? ASAuthorizationError,
               authorizationError.code == .canceled {
                return
            }
            onFailure(String(localized: "Sign in with Apple did not complete. Try again."))
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let data = credential.identityToken,
                  let identityToken = String(data: data, encoding: .utf8) else {
                onFailure(String(localized: "Apple did not return a usable identity. Try again."))
                return
            }
            // `fullName` is only given on the very first authorization for an
            // Apple ID; afterwards it is nil and the server keeps whatever it
            // was told then.
            let fullName = credential.fullName.flatMap(Self.formattedName)
            let signedIn = await model.account.signInWithApple(
                identityToken: identityToken,
                nonce: rawNonce,
                fullName: fullName,
            )
            if !signedIn {
                onFailure(model.account.lastError ?? String(localized: "Sign in with Apple could not be completed."))
            }
        }
    }

    /// Render the name components Apple gave, or `nil` when they are empty.
    ///
    /// - Parameter components: the components from the credential.
    /// - Returns: a single display string, or `nil`.
    private static func formattedName(_ components: PersonNameComponents) -> String? {
        let formatted = PersonNameComponentsFormatter().string(from: components)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return formatted.isEmpty ? nil : formatted
    }
}
