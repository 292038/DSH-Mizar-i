//
//  LiveNetworkTests.swift
//  MizarKitTests
//
//  The only place in this package that may touch a real host.
//
//  Every other test answers from a scripted transport or a HAR recording. This
//  suite is the explicit live layer, and it runs only when the runner says so:
//
//      MIZAR_TEST_MODE=live \
//      MIZAR_LIVE_BASE_URL=http://192.168.1.20:19390 \
//          scripts/swift.sh test --filter LiveNetwork
//
//  The switch is the same `MIZAR_TEST_MODE` the UI tests read (`TestLayer` in
//  DSH-MizarUITests), so scripts/test-select.sh turns both layers on together.
//  Without it the tests are skipped, never silently pointed at production: a
//  plain `swift test` stays offline and deterministic. A missing address skips
//  too, with a message naming both variables — the UI layer's
//  `TestLayer.requireValue` makes the same call for a live value that was not
//  provided.
//

import Foundation
import Testing
@testable import MizarKit

/// The layer switch, mirroring `TestLayer` in the UI test target.
enum LiveLayer {
    /// `replay` unless the environment explicitly asks for the live layer.
    static var mode: String {
        ProcessInfo.processInfo.environment["MIZAR_TEST_MODE"] ?? "replay"
    }

    /// Whether a real host may be dialed.
    static var isLive: Bool { mode == "live" }

    /// The host to dial: `host:port`, or an `http://` URL that carries one.
    static var baseURL: String? {
        let value = ProcessInfo.processInfo.environment["MIZAR_LIVE_BASE_URL"] ?? ""
        return value.isEmpty ? nil : value
    }

    /// Both halves of the opt-in: the layer switch and an address to dial.
    ///
    /// A missing value for the live layer is a skip, not a failure — the same
    /// choice `TestLayer.requireValue` makes in the UI test target, so pointing
    /// `scripts/test-select.sh --live` at a run with no address does not fail
    /// the unit suite before the UI layer gets its chance.
    static var canRunLiveTest: Bool { isLive && baseURL != nil }
}

@Suite("Live network (opt-in)")
struct LiveNetworkTests {
    @Test(
        "hello from a real host",
        .enabled(
            if: LiveLayer.canRunLiveTest,
            "live layer: needs MIZAR_TEST_MODE=live and MIZAR_LIVE_BASE_URL",
        ),
    )
    func hello() async throws {
        // The trait already skipped when this was nil; `#require` keeps the
        // body honest if the gate and the address ever drift apart.
        let raw = try #require(
            LiveLayer.baseURL,
            "live layer: set MIZAR_LIVE_BASE_URL (host:port or http:// URL)",
        )
        let authority = try #require(
            Self.authority(from: raw),
            "MIZAR_LIVE_BASE_URL is not a usable host: \(raw)",
        )

        let hello = try await PairingClient().hello(authority: authority)
        #expect(hello.protocolVersion == mizarProtocolVersion)
        #expect(!hello.hostId.isEmpty)
        #expect(!hello.hostName.isEmpty)
    }

    /// Reduce an environment-provided URL to the `host:port` the client dials.
    private static func authority(from value: String) -> String? {
        let candidate = value.contains("://") ? value : "http://\(value)"
        guard let url = URL(string: candidate), let host = url.host(), !host.isEmpty else {
            return nil
        }
        return url.port.map { "\(host):\($0)" } ?? host
    }
}
