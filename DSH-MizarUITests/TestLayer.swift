//
//  TestLayer.swift
//  DSH-MizarUITests
//
//  The two layers a test run can be in. The default is playback: fixtures and
//  the local mock host only, never a real network. `MIZAR_TEST_MODE=live` is
//  the explicit opt-in for the live layer, which the nightly/pre-release run
//  sets. A live test that runs without it must skip loudly, never fall through
//  to a real host by accident.
//

import XCTest

enum TestLayer {
    /// `replay` unless the runner explicitly asked for `live`. The same value is
    /// exported by scripts/test-select.sh (MIZAR_TEST_MODE), and reaches the
    /// test runner through the TEST_RUNNER_ prefixed copy xcodebuild forwards.
    static let mode = ProcessInfo.processInfo.environment["MIZAR_TEST_MODE"] ?? "replay"

    static var isLive: Bool { mode == "live" }

    /// Guard for a test that needs a reachable real host. Call it first: without
    /// the live layer the test skips, so the default regression run stays
    /// offline and deterministic instead of timing out against production.
    static func requireLive(_ what: String) throws {
        guard isLive else {
            throw XCTSkip("live layer: \(what) needs MIZAR_TEST_MODE=live")
        }
    }

    /// A live-only value (host URL, pairing URI, credentials). Missing values
    /// are reported as skips, not as failures, because the live layer is run
    /// only where the environment is provided.
    static func requireValue(_ key: String) throws -> String {
        guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else {
            throw XCTSkip("live layer: \(key) is not set")
        }
        return value
    }
}
