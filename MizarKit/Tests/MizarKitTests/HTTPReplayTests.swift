//
//  HTTPReplayTests.swift
//  MizarKitTests
//
//  The replay layer, exercised the way the replay test layer uses it: real
//  clients, real recorded bytes, no host.
//
//  Three claims matter and only one of them is visible in a happy path. A
//  recording must decode exactly as if the host had answered; a request that was
//  never recorded must fail with the replay error instead of dialing; and a miss
//  must not become a silent skip. The blackhole address below is the empirical
//  form of the second and third claims: `10.255.255.1` cannot answer, so any
//  response attributed to it came from a fixture.
//

import Foundation
import Testing
@testable import MizarKit

/// Locate `protocol/fixtures/http/` from this file's own path.
///
/// Same reason as `FixtureTests`: the files stay in the repository (one copy,
/// shared with anything else that reads them) instead of being copied into the
/// test bundle where they could drift.
private var httpFixturesDirectory: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // MizarKitTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // MizarKit
        .deletingLastPathComponent()  // repository root
        .appendingPathComponent("protocol/fixtures/http")
}

/// The origin every fixture in that directory was recorded at.
private let recordedOrigin = URL(string: "http://127.0.0.1:19395")!

/// The device the login fixture recorded.
///
/// `AccountClient` encodes this into the request body, and the fixture pins the
/// body, so it has to be the same five values the recorder sent.
private let recordedDevice = AccountDevicePayload(
    id: "install-1",
    name: "iPhone",
    model: "iPhone18,1",
    appVersion: "0.9.2",
)

/// The login body the fixture recorded, as wire JSON.
private let recordedLoginBody = #"{"identifier":"a@b.com","password":"wrong-password","device":{"id":"install-1","name":"iPhone","model":"iPhone18,1","platform":"ios","appVersion":"0.9.2"}}"#

@Suite("HTTP replay from HAR fixtures")
struct HTTPReplayTests {
    private func makeTransport(
        matching: HTTPReplayURLMatching = .exact,
    ) throws -> HTTPReplayTransport {
        try HTTPReplayTransport(fixturesDirectory: httpFixturesDirectory, matching: matching)
    }

    private func accountClient(
        origin: URL = recordedOrigin,
        transport: HTTPReplayTransport,
    ) -> AccountClient {
        AccountClient(baseURL: origin.appendingPathComponent("account/v1"), transport: transport)
    }

    // MARK: - Hits

    @Test("replays a recorded pairing through PairingClient")
    func pairing() async throws {
        let replay = try makeTransport()
        let host = try await PairingClient(transport: replay).pair(
            authority: "127.0.0.1:19395",
            code: "MOCK-CODE",
            deviceName: "iPhone",
            deviceModel: "iPhone18,1",
        )

        #expect(host.deviceToken == "mz_mock_token")
        #expect(host.deviceId == "mock-device-0000-4000-8000-000000000000")
        #expect(host.hostId == "mock-host-0000-4000-8000-000000000000")
        #expect(host.hostName == "Mock Mac (fixture)")

        let stats = await replay.stats()
        #expect(stats.attempts == 1)
        #expect(stats.hits == 1)
        #expect(stats.misses == 0)
    }

    @Test("replays a recorded account profile through AccountClient")
    func accountProfile() async throws {
        let replay = try makeTransport()
        let user = try await accountClient(transport: replay).me(token: "mza_mock_1")

        #expect(user.id == "mock-account-0000-4000-8000-000000000000")
        #expect(user.username == "mock-user")
        #expect(user.email == "mock@example.com")
        #expect(user.plan == .free)
        #expect(user.avatar.initials == "M")
        let device = try #require(user.devices.first)
        #expect(user.devices.count == 1)
        #expect(device.id == "install-1")
        #expect(device.current)

        let stats = await replay.stats()
        #expect(stats.hits == 1)
        #expect(stats.networkAttempts == 0)
    }

    @Test("replays a recorded 401 as the client's own refusal")
    func unauthorized() async throws {
        let replay = try makeTransport()
        let client = accountClient(transport: replay)

        do {
            _ = try await client.login(
                identifier: "a@b.com",
                password: "wrong-password",
                device: recordedDevice,
            )
            Issue.record("expected the recorded 401 to fail the login")
        } catch let error as AccountError {
            // The point of a scripted 401: the app's error keeps the server's
            // code, not a generic transport failure.
            #expect(error.code == AccountErrorCode.unauthenticated)
            #expect(error.status == 401)
            #expect(error.requiresReauthentication)
        }

        #expect(await replay.stats().hits == 1)
    }

    // MARK: - Misses and body matching

    @Test("a request that was never recorded fails as a replay error")
    func miss() async throws {
        let replay = try makeTransport()
        let client = PairingClient(transport: replay)
        let unrecorded = "http://127.0.0.1:19999/mizar/v1/hello"

        await #expect(throws: HTTPReplayError.noFixture(method: "GET", url: unrecorded)) {
            _ = try await client.hello(authority: "127.0.0.1:19999")
        }

        let stats = await replay.stats()
        #expect(stats.attempts == 1)
        #expect(stats.hits == 0)
        #expect(stats.misses == 1)
        #expect(stats.networkAttempts == 0)
    }

    @Test("a recorded request body is part of the match")
    func bodyMatching() async throws {
        let replay = try makeTransport()
        let loginURL = recordedOrigin.appendingPathComponent("account/v1/login")

        func request(body: String?) -> URLRequest {
            var request = URLRequest(url: loginURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = body.map { Data($0.utf8) }
            return request
        }

        // 1. The recorded body answers, even re-encoded with different member
        // order: JSON is content, not bytes.
        let reordered = """
            {"device": {"appVersion": "0.9.2", "platform": "ios", "model": "iPhone18,1",
                        "name": "iPhone", "id": "install-1"},
             "password": "wrong-password", "identifier": "a@b.com"}
            """
        let (recordedData, recordedResponse) = try await replay.data(for: request(body: recordedLoginBody))
        #expect(recordedResponse.statusCode == 401)
        let recordedError = try JSONDecoder().decode([String: String].self, from: recordedData)
        #expect(recordedError["error"] == "UNAUTHENTICATED")
        let (_, reorderedResponse) = try await replay.data(for: request(body: reordered))
        #expect(reorderedResponse.statusCode == 401)

        // 2. The same route with different credentials is not the recorded
        // exchange, so it is a miss rather than the 401 the recorder saw.
        var wrongPassword = request(body: recordedLoginBody)
        wrongPassword.httpBody = Data(#"{"identifier":"a@b.com","password":"right-password","device":{"id":"install-1","name":"iPhone","model":"iPhone18,1","platform":"ios","appVersion":"0.9.2"}}"#.utf8)
        await #expect(throws: HTTPReplayError.self) {
            _ = try await replay.data(for: wrongPassword)
        }

        // 3. Same URL, wrong method is also a miss.
        var wrongMethod = request(body: nil)
        wrongMethod.httpMethod = "GET"
        await #expect(throws: HTTPReplayError.self) {
            _ = try await replay.data(for: wrongMethod)
        }

        let stats = await replay.stats()
        #expect(stats.attempts == 4)
        #expect(stats.hits == 2)
        #expect(stats.misses == 2)
    }

    // MARK: - Offline proof

    @Test("a blackhole address can only have been answered from a fixture")
    func blackhole() async throws {
        // `10.255.255.1` is a route-null address: nothing here listens, and a
        // real connection attempt would hang until the timeout. The transport
        // answering instantly with the recorded profile is the proof that this
        // layer never dials, and that replay works with no host reachable.
        let blackhole = URL(string: "http://10.255.255.1:19395")!
        let replay = try makeTransport(
            matching: .rewriting(recorded: recordedOrigin, requested: blackhole),
        )
        let user = try await accountClient(origin: blackhole, transport: replay).me(token: "mza_mock_1")

        #expect(user.username == "mock-user")
        let stats = await replay.stats()
        #expect(stats.attempts == 1)
        #expect(stats.hits == 1)
        #expect(stats.networkAttempts == 0)
    }

    // MARK: - Opt-in

    @Test("opt-in comes from MIZAR_HTTP_FIXTURES and is absent when unset")
    func environmentOptIn() throws {
        #expect(try HTTPReplayTransport.fromEnvironment([:]) == nil)

        let replay = try #require(try HTTPReplayTransport.fromEnvironment([
            mizarHTTPFixturesEnvironmentKey: httpFixturesDirectory.path,
        ]))
        #expect(replay.fixtureCount == 3)
    }

    @Test("two recordings of the same request are rejected at load")
    func duplicateRecordings() throws {
        // First-match-wins would make the answer depend on file names, so a
        // directory that records the same exchange twice is a recording mistake.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mizar-http-replay-duplicates-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let pair = httpFixturesDirectory.appendingPathComponent("pair-success.har")
        try FileManager.default.copyItem(at: pair, to: directory.appendingPathComponent("a.har"))
        try FileManager.default.copyItem(at: pair, to: directory.appendingPathComponent("b.har"))

        #expect(throws: HTTPReplayError.self) {
            _ = try HTTPReplayTransport(fixturesDirectory: directory)
        }
    }

    @Test("a broken opt-in is an error, not a replay that misses everything")
    func brokenOptIn() {
        #expect(throws: HTTPReplayError.self) {
            _ = try HTTPReplayTransport.fromEnvironment([
                mizarHTTPFixturesEnvironmentKey: "/nonexistent/mizar-http-fixtures",
            ])
        }
    }
}
