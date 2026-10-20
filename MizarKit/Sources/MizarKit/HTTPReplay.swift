//
//  HTTPReplay.swift
//  MizarKit
//
//  HTTP answered from HAR recordings instead of a network.
//
//  The app already reaches HTTP through the ``HTTPTransport`` seam (see
//  `PairingClient.swift`), so playback belongs on the same seam rather than in
//  `URLProtocol`: a transport owns no session, which makes "a miss never touches
//  the network" a property of the type instead of a rule that every code path —
//  and a future refactor — has to keep remembering. `docs/http-replay.md` records
//  the full comparison with a URLProtocol layer.
//
//  Replay is opt-in. ``URLSessionHTTPTransport`` stays the default transport the
//  app builds; this type exists for the replay test layer and for an explicitly
//  recorded demo run.
//

import Foundation

/// The environment variable that opts a process into HTTP replay.
///
/// The value is a directory of `.har` files. Unset, or empty, means the normal
/// app run: no replay transport is built.
public let mizarHTTPFixturesEnvironmentKey = "MIZAR_HTTP_FIXTURES"

/// How a request's absolute URL is compared with the one a fixture recorded.
///
/// Matching is exact by default: a replay is only a replay when it answers the
/// URL that was recorded. ``rewriting(recorded:requested:)`` is the explicit
/// opt-in for the one legitimate difference — a test replays a recording made at
/// the mock host's origin against an address that can never answer, which proves
/// the answer came from the fixture rather than from a socket.
public enum HTTPReplayURLMatching: Sendable, Equatable {
    /// Compare both URLs exactly.
    case exact

    /// Compare the fixture URL after replacing `recorded` with `requested`.
    ///
    /// The exchange the app made is `recorded`; the exchange under test dials
    /// `requested`. Only the origin (scheme, host, port) may differ — paths and
    /// query strings still have to match exactly.
    case rewriting(recorded: URL, requested: URL)
}

/// Why a replay could not answer.
///
/// One error type for everything, because a caller must be able to tell a
/// missing recording (the replay layer does not cover this request) from a
/// broken one (the recording no longer matches this build) without catching
/// network errors — there are none to catch.
public enum HTTPReplayError: Error, Sendable, Equatable, LocalizedError {
    /// No fixture matched the request. Replay has no network path to fall back to.
    case noFixture(method: String, url: String)

    /// A request carried no URL, so nothing could match it.
    case unaddressableRequest(method: String)

    /// The fixture directory could not be listed.
    case unreadableFixtures(path: String, reason: String)

    /// A file is not the HAR 1.2 subset this transport reads, or two recordings
    /// claim the same request.
    case malformedFixture(path: String, reason: String)

    /// The directory held no `.har` files.
    case emptyFixtures(path: String)

    public var errorDescription: String? {
        switch self {
        case .noFixture(let method, let url):
            return "no recorded response for \(method) \(url)"
        case .unaddressableRequest(let method):
            return "the \(method) request has no URL to replay"
        case .unreadableFixtures(let path, let reason):
            return "cannot read HTTP fixtures at \(path): \(reason)"
        case .malformedFixture(let path, let reason):
            return "malformed HAR fixture \(path): \(reason)"
        case .emptyFixtures(let path):
            return "no .har files in \(path)"
        }
    }
}

/// What a replay transport has been asked for.
///
/// Exposed because the layer's central promise is "zero network": a counter is
/// how a test states that, instead of inferring it from the source.
public struct HTTPReplayStats: Sendable, Equatable {
    /// Every request handed to the transport, hits and misses together.
    public let attempts: Int
    /// Requests answered from a fixture.
    public let hits: Int
    /// Requests with no matching fixture; each one threw ``HTTPReplayError/noFixture``.
    public let misses: Int

    /// Requests this transport sent over the network.
    ///
    /// Always zero: the transport owns no session and a miss throws. The property
    /// exists so a test can assert the promise as one number rather than leak the
    /// proof into a comment.
    public var networkAttempts: Int { 0 }
}

/// An ``HTTPTransport`` that answers from HAR 1.2 recordings.
///
/// Load a directory of `.har` files and hand the transport to a client:
///
/// ```swift
/// let replay = try HTTPReplayTransport(fixturesDirectory: fixturesURL)
/// let pairing = PairingClient(transport: replay)
/// ```
///
/// A hit returns the recorded status, headers and body. A miss throws
/// ``HTTPReplayError/noFixture``; nothing is retried and no socket is opened.
/// Requests match on method and absolute URL, plus the request body when the
/// fixture recorded one (JSON bodies compare as JSON, not bytes).
public struct HTTPReplayTransport: HTTPTransport {
    /// The recordings, in load order.
    private let fixtures: [HARFixture]
    /// How request URLs are compared with recorded ones.
    private let matching: HTTPReplayURLMatching
    /// The counters behind ``stats()``.
    private let recorder: HTTPReplayRecorder

    /// How many recordings are loaded.
    public var fixtureCount: Int { fixtures.count }

    /// Load every `.har` file in a directory.
    ///
    /// Loading fails closed: a directory with no recordings, an unreadable file
    /// or a malformed one throws rather than producing a transport that misses
    /// every request. Non-HAR files in the directory are ignored.
    ///
    /// - Parameters:
    ///   - fixturesDirectory: the directory holding HAR 1.2 files.
    ///   - matching: how request URLs are compared; exact unless explicitly told otherwise.
    /// - Throws: ``HTTPReplayError`` when the fixtures cannot be loaded.
    public init(fixturesDirectory: URL, matching: HTTPReplayURLMatching = .exact) throws {
        self.fixtures = try Self.loadFixtures(in: fixturesDirectory)
        self.matching = matching
        self.recorder = HTTPReplayRecorder()
    }

    /// Build the transport when the process environment asks for one.
    ///
    /// - Parameter environment: the environment to read; the process's by default.
    /// - Returns: `nil` when ``mizarHTTPFixturesEnvironmentKey`` is unset or empty,
    ///   so opt-in stays in the composition root instead of this type guessing.
    /// - Throws: ``HTTPReplayError`` when the variable is set but its directory
    ///   cannot be loaded. A broken opt-in is reported, never silently ignored.
    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment,
    ) throws -> HTTPReplayTransport? {
        guard let raw = environment[mizarHTTPFixturesEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
        else { return nil }
        let path = (raw as NSString).expandingTildeInPath
        return try HTTPReplayTransport(fixturesDirectory: URL(fileURLWithPath: path, isDirectory: true))
    }

    /// The counters so far.
    public func stats() async -> HTTPReplayStats {
        await recorder.snapshot()
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let method = request.httpMethod ?? "GET"
        guard let url = request.url else {
            await recorder.record(.miss)
            throw HTTPReplayError.unaddressableRequest(method: method)
        }

        let target = matchTarget(for: url)
        guard let fixture = fixtures.first(where: {
            $0.matches(method: method, url: target, body: request.httpBody)
        }) else {
            await recorder.record(.miss)
            throw HTTPReplayError.noFixture(method: method, url: url.absoluteString)
        }

        let response: HTTPURLResponse
        do {
            response = try fixture.response(for: url)
        } catch {
            await recorder.record(.miss)
            throw error
        }
        await recorder.record(.hit)
        return (fixture.body, response)
    }

    // MARK: - Matching

    /// The URL string this request is matched with under ``matching``.
    private func matchTarget(for url: URL) -> String {
        switch matching {
        case .exact:
            return url.absoluteString
        case .rewriting(let recorded, let requested):
            let request = url.absoluteString
            let prefix = Self.origin(of: requested)
            guard request.hasPrefix(prefix) else { return request }
            // Only a whole origin may be replaced: `:19395` must not match
            // `:193950`, and a host must be followed by a path or nothing.
            let remainder = request.dropFirst(prefix.count)
            guard remainder.isEmpty || remainder.first == "/" else { return request }
            return Self.origin(of: recorded) + remainder
        }
    }

    /// An origin without a trailing slash, so rewriting does not produce `//`.
    private static func origin(of url: URL) -> String {
        let value = url.absoluteString
        return value.hasSuffix("/") ? String(value.dropLast()) : value
    }

    // MARK: - Loading

    /// Decode every HAR file in a directory into matchable fixtures.
    private static func loadFixtures(in directory: URL) throws -> [HARFixture] {
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles],
            )
        } catch {
            throw HTTPReplayError.unreadableFixtures(
                path: directory.path,
                reason: error.localizedDescription,
            )
        }

        let files = contents
            .filter { $0.pathExtension.lowercased() == "har" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else {
            throw HTTPReplayError.emptyFixtures(path: directory.path)
        }

        var fixtures: [HARFixture] = []
        for file in files {
            fixtures.append(contentsOf: try load(file))
        }
        try requireUnique(fixtures)
        return fixtures
    }

    /// Decode one HAR file.
    private static func load(_ file: URL) throws -> [HARFixture] {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            throw HTTPReplayError.unreadableFixtures(path: file.path, reason: error.localizedDescription)
        }

        let har: HARFile
        do {
            har = try JSONDecoder().decode(HARFile.self, from: data)
        } catch {
            throw HTTPReplayError.malformedFixture(path: file.path, reason: String(describing: error))
        }

        guard har.log.version == "1.2" else {
            let found = har.log.version ?? "missing"
            throw HTTPReplayError.malformedFixture(
                path: file.path,
                reason: "log.version is \(found), expected 1.2",
            )
        }

        return try har.log.entries.map { try HARFixture(entry: $0, source: file.path) }
    }

    /// Refuse two recordings for the same request.
    ///
    /// First-match-wins would make which recording answers depend on file names;
    /// a fixture set that ambiguous is a recording mistake, not a replay.
    private static func requireUnique(_ fixtures: [HARFixture]) throws {
        var seen: [String: HARFixture] = [:]
        for fixture in fixtures {
            if let first = seen[fixture.identity] {
                throw HTTPReplayError.malformedFixture(
                    path: fixture.source,
                    reason: "\(fixture.identity) is also recorded in \(first.source)",
                )
            }
            seen[fixture.identity] = fixture
        }
    }
}

// MARK: - Counters

/// The counters for one transport.
///
/// An actor because the transport is `Sendable` and the counts are written from
/// the request's task: the request never reads them, so the lock is the cheapest
/// correct thing here.
private actor HTTPReplayRecorder {
    enum Outcome {
        case hit
        case miss
    }

    private var attempts = 0
    private var hits = 0
    private var misses = 0

    func record(_ outcome: Outcome) {
        attempts += 1
        switch outcome {
        case .hit: hits += 1
        case .miss: misses += 1
        }
    }

    func snapshot() -> HTTPReplayStats {
        HTTPReplayStats(attempts: attempts, hits: hits, misses: misses)
    }
}

// MARK: - One recording

/// A loaded HAR entry, decoded once so a hit cannot fail halfway.
private struct HARFixture: Sendable {
    /// The request method, as recorded.
    let method: String
    /// The request URL, as recorded.
    let url: String
    /// The recorded request body, when the entry defines one.
    let requestBody: Data?
    /// Whether ``requestBody`` is JSON and therefore compared as JSON.
    let requestBodyIsJSON: Bool
    /// The recorded HTTP status.
    let status: Int
    /// The recorded response headers; repeated names keep the last value because
    /// `HTTPURLResponse` only carries a dictionary.
    let headerFields: [String: String]
    /// The recorded response body.
    let body: Data
    /// The file this entry came from, for errors.
    let source: String

    /// A key that two recordings of the same request would share.
    var identity: String {
        let body = requestBody.map { $0.base64EncodedString() } ?? "-"
        return "\(method.uppercased()) \(url) \(body)"
    }

    /// Whether this recording answers one request.
    func matches(method requestMethod: String, url requestURL: String, body requestBody: Data?) -> Bool {
        guard method.caseInsensitiveCompare(requestMethod) == .orderedSame,
              url == requestURL
        else { return false }
        // A fixture without `postData` only pins method and URL; one with it pins
        // the body too, so a test can make "same route, different credentials" a miss.
        guard let recordedBody = self.requestBody else { return true }
        guard let requestBody else { return false }
        guard requestBodyIsJSON else { return recordedBody == requestBody }
        return Self.jsonBodiesMatch(recordedBody, requestBody)
    }

    /// Compare two JSON bodies structurally.
    ///
    /// The same request encoded by two `JSONEncoder`s, or written by hand in the
    /// fixture, is the same request; member order and whitespace are not content.
    private static func jsonBodiesMatch(_ recorded: Data, _ request: Data) -> Bool {
        let decoder = JSONDecoder()
        guard let expected = try? decoder.decode(JSONValue.self, from: recorded),
              let actual = try? decoder.decode(JSONValue.self, from: request)
        else { return false }
        return expected == actual
    }

    /// Build the response for a request URL.
    func response(for url: URL) throws -> HTTPURLResponse {
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headerFields,
        ) else {
            throw HTTPReplayError.malformedFixture(
                path: source,
                reason: "the recorded response could not be built",
            )
        }
        return response
    }

    /// Decode one HAR entry, rejecting anything this transport cannot replay.
    init(entry: HAREntry, source: String) throws {
        self.source = source
        method = entry.request.method
        url = entry.request.url

        guard !method.isEmpty, !url.isEmpty else {
            throw HTTPReplayError.malformedFixture(path: source, reason: "entry has no method or URL")
        }
        guard (100...599).contains(entry.response.status) else {
            throw HTTPReplayError.malformedFixture(
                path: source,
                reason: "response.status \(entry.response.status) is not an HTTP status",
            )
        }
        status = entry.response.status

        var headers: [String: String] = [:]
        for header in entry.response.headers {
            // Empty-valued headers are legal HAR; the dictionary keeps them as
            // empty strings rather than dropping them silently.
            headers[header.name] = header.value
        }
        headerFields = headers

        if let text = entry.response.content.text {
            if entry.response.content.encoding?.lowercased() == "base64" {
                guard let decoded = Data(base64Encoded: text) else {
                    throw HTTPReplayError.malformedFixture(
                        path: source,
                        reason: "content.encoding is base64 but content.text is not base64",
                    )
                }
                body = decoded
            } else {
                body = Data(text.utf8)
            }
        } else {
            body = Data()
        }

        if let postData = entry.request.postData, let text = postData.text, !text.isEmpty {
            requestBody = Data(text.utf8)
            requestBodyIsJSON = (postData.mimeType ?? "").lowercased().contains("json")
        } else {
            requestBody = nil
            requestBodyIsJSON = false
        }
    }
}

// MARK: - HAR 1.2 subset

/// The part of HAR 1.2 this transport reads.
///
/// Deliberately not the whole format: only `log.version`, the request line, the
/// recorded request body and the response are needed to replay an exchange.
/// Everything else in a real recording (`cookies`, `timings`, `cache`, page
/// references) decodes away, so files recorded by browser dev tools still load.
private struct HARFile: Decodable {
    struct Log: Decodable {
        let version: String?
        let entries: [HAREntry]
    }

    let log: Log
}

private struct HAREntry: Decodable {
    struct Request: Decodable {
        struct PostData: Decodable {
            let mimeType: String?
            let text: String?
        }

        let method: String
        let url: String
        let postData: PostData?
    }

    struct Response: Decodable {
        struct Header: Decodable {
            let name: String
            let value: String
        }

        struct Content: Decodable {
            let encoding: String?
            let text: String?
        }

        let status: Int
        let headers: [Header]
        let content: Content
    }

    let request: Request
    let response: Response
}
