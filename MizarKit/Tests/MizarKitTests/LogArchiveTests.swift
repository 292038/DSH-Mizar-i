//
//  LogArchiveTests.swift
//  MizarKitTests
//
//  The export button's two promises: the archive opens, and it carries no
//  credentials.
//
//  Both are checked against something other than the code under test. The zip is
//  read back by a reader written here from the format's specification -- local
//  headers, a central directory, CRC-32 per entry -- so a writer that disagreed
//  with the format would fail rather than agree with itself; and the archive's
//  text is searched for secrets rather than for the markers the scrubber happens
//  to leave behind.
//

import Compression
import Foundation
import Testing
@testable import MizarKit

/// A ZIP reader, for checking the writer.
///
/// Enough of the format to be a real check: the end-of-central-directory record,
/// one central directory entry per file, the local header each one points at,
/// DEFLATE where the method says so, and the CRC-32 the entry claims.
struct ZipReader {
    struct Item {
        let path: String
        let method: UInt16
        let contents: Data
    }

    enum Failure: Error {
        case truncated
        case noDirectory
        case badSignature(Int)
        case directoryMismatch
        case corrupt(String)
        case inflateFailed
    }

    let items: [Item]

    init(_ data: Data) throws {
        let bytes = [UInt8](data)
        func u16(_ at: Int) throws -> Int {
            guard at >= 0, at + 2 <= bytes.count else { throw Failure.truncated }
            return Int(bytes[at]) | Int(bytes[at + 1]) << 8
        }
        func u32(_ at: Int) throws -> UInt32 {
            guard at >= 0, at + 4 <= bytes.count else { throw Failure.truncated }
            return UInt32(bytes[at])
                | UInt32(bytes[at + 1]) << 8
                | UInt32(bytes[at + 2]) << 16
                | UInt32(bytes[at + 3]) << 24
        }

        // No archive comment is written, so the end record is the last 22 bytes.
        let end = bytes.count - 22
        guard end >= 0, try u32(end) == 0x0605_4B50 else { throw Failure.noDirectory }
        let count = try u16(end + 10)
        let size = Int(try u32(end + 12))
        var cursor = Int(try u32(end + 16))

        var items: [Item] = []
        for _ in 0..<count {
            guard try u32(cursor) == 0x0201_4B50 else { throw Failure.badSignature(cursor) }
            let method = UInt16(try u16(cursor + 10))
            let crc = try u32(cursor + 16)
            let compressed = Int(try u32(cursor + 20))
            let uncompressed = Int(try u32(cursor + 24))
            let nameLength = try u16(cursor + 28)
            let extraLength = try u16(cursor + 30)
            let commentLength = try u16(cursor + 32)
            let local = Int(try u32(cursor + 42))
            let name = String(decoding: bytes[(cursor + 46)..<(cursor + 46 + nameLength)], as: UTF8.self)

            guard try u32(local) == 0x0403_4B50 else { throw Failure.badSignature(local) }
            let localName = try u16(local + 26)
            let localExtra = try u16(local + 28)
            let start = local + 30 + localName + localExtra
            guard start + compressed <= bytes.count else { throw Failure.truncated }
            let payload = Data(bytes[start..<(start + compressed)])
            let contents = method == 8 ? try Self.inflate(payload, expecting: uncompressed) : payload
            guard contents.count == uncompressed, ZipWriter.crc32(contents) == crc else {
                throw Failure.corrupt(name)
            }
            items.append(Item(path: name, method: method, contents: contents))
            cursor += 46 + nameLength + extraLength + commentLength
        }
        guard cursor == Int(try u32(end + 16)) + size else { throw Failure.directoryMismatch }
        self.items = items
    }

    func item(_ path: String) -> Item? { items.first { $0.path == path } }

    func text(_ path: String) -> String? {
        item(path).map { String(decoding: $0.contents, as: UTF8.self) }
    }

    static func inflate(_ data: Data, expecting size: Int) throws -> Data {
        guard size > 0 else { return Data() }
        var destination = [UInt8](repeating: 0, count: size)
        let written = destination.withUnsafeMutableBufferPointer { out -> Int in
            data.withUnsafeBytes { raw -> Int in
                guard let source = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    out.baseAddress!, out.count,
                    source, data.count,
                    nil, COMPRESSION_ZLIB,
                )
            }
        }
        guard written == size else { throw Failure.inflateFailed }
        return Data(destination)
    }
}

@Suite("ZIP writer")
struct ZipWriterTests {
    @Test("computes the CRC-32 the format defines")
    func knownCrcs() {
        // The standard check value for CRC-32, and two from Python's zlib, so
        // this is not the implementation agreeing with itself.
        #expect(ZipWriter.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(ZipWriter.crc32(Data("hello world".utf8)) == 0x0D4A_1185)
        #expect(ZipWriter.crc32(Data()) == 0)
    }

    @Test("round-trips entries, compressing what is worth compressing")
    func roundTrip() throws {
        let repeated = String(repeating: "the same line over and over\n", count: 200)
        let archive = try ZipWriter.archive(
            [
                ZipEntry(path: "README.txt", text: "hello world\n"),
                ZipEntry(path: "logs/activity.log", text: repeated),
                ZipEntry(path: "logs/empty.txt", text: ""),
            ],
            modifiedAt: Date(timeIntervalSince1970: 1_760_000_000),
        )
        let reader = try ZipReader(archive)
        #expect(reader.items.map(\.path) == ["README.txt", "logs/activity.log", "logs/empty.txt"])
        #expect(reader.text("README.txt") == "hello world\n")
        #expect(reader.text("logs/activity.log") == repeated)
        #expect(reader.text("logs/empty.txt") == "")
        // Two hundred repetitions of one line must deflate; a forty-byte file
        // must not be inflated into something larger.
        #expect(reader.item("logs/activity.log")?.method == 8)
        #expect(reader.item("README.txt")?.method == 0)
        #expect(archive.count < repeated.utf8.count)
    }

    @Test("writes an archive with no entries")
    func emptyArchive() throws {
        let reader = try ZipReader(try ZipWriter.archive([]))
        #expect(reader.items.isEmpty)
    }

    @Test("refuses an entry it cannot represent instead of truncating it")
    func refusesOversizedNames() {
        let long = String(repeating: "a", count: 70_000)
        #expect(throws: ZipWriterError.entryTooLarge(path: long, bytes: 70_000)) {
            try ZipWriter.archive([ZipEntry(path: long, text: "x")])
        }
    }
}

@Suite("Log redaction")
struct LogScrubberTests {
    @Test(
        "removes a credential wherever it appears in a line",
        arguments: [
            "hello token mz_9f8e7d6c5b4a world",
            "deviceToken: mz_mock_token",
            #"{"deviceToken":"mz_abc123","ok":true}"#,
            "Bearer mz_abcdefghijkl",
        ],
    )
    func removesTokens(line: String) {
        let redacted = LogScrubber.redact(line)
        #expect(!redacted.contains("mz_9f8e"), "\(redacted)")
        #expect(!redacted.contains("mz_mock_token"), "\(redacted)")
        #expect(!redacted.contains("mz_abc123"), "\(redacted)")
        #expect(!redacted.contains("mz_abcdefghijkl"), "\(redacted)")
        #expect(!LogScrubber.containsSecret(redacted))
    }

    @Test("removes a device token and a JWT by shape")
    func removesByShape() {
        let hex = String(repeating: "a1b2c3d4", count: 8)          // 64 characters
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl"
        let redacted = LogScrubber.redact("push \(hex) and \(jwt)")
        #expect(!redacted.contains(hex))
        #expect(!redacted.contains(jwt))
        #expect(redacted.contains("<redacted-hex>"))
        #expect(redacted.contains("<redacted-jwt>"))
    }

    @Test("removes a pairing code and keeps the fact that there was one")
    func removesPairingCodes() {
        let uri = "mizar://pair?h=127.0.0.1%3A19395&c=MOCK-CODE&n=Mock%20Mac&v=1"
        let redacted = LogScrubber.redact(uri)
        #expect(!redacted.contains("MOCK-CODE"))
        #expect(redacted.contains("c=<redacted-code>"))
        #expect(redacted.contains("127.0.0.1"))
        let body = "token=abc123&code=XYZ-9"
        let form = LogScrubber.redact(body)
        #expect(!form.contains("abc123"))
        #expect(!form.contains("XYZ-9"))
        #expect(form.contains("token=<redacted-token>"))
        #expect(form.contains("code=<redacted-code>"))
    }

    @Test("leaves an ordinary line alone")
    func keepsOrdinaryText() {
        // A scrubber that mangles the log is a scrubber that gets turned off.
        let line = "2025-10-17T01:02:03.456Z  request     session.messages(sessionId) → failed in 60012 ms UNAVAILABLE: the Mac did not answer"
        #expect(LogScrubber.redact(line) == line)
        #expect(!LogScrubber.containsSecret(line))
    }
}

@Suite("Log archive")
struct LogArchiveTests {
    /// A fixed moment, so the file names and the JSON are reproducible.
    private static let now = Date(timeIntervalSince1970: 1_760_000_000)

    /// A log with one of everything, and a credential in three places it could
    /// plausibly have leaked from.
    private static func records() -> [LogRecord] {
        let hex = String(repeating: "0123456789abcdef", count: 4)
        return [
            LogRecord(
                at: now.addingTimeInterval(-30),
                category: .app,
                message: "launch: 3 flags, paired host present",
            ),
            LogRecord(
                at: now.addingTimeInterval(-28),
                category: .connection,
                message: "dialling 127.0.0.1:19395 directly",
            ),
            LogRecord(
                at: now.addingTimeInterval(-27),
                category: .connection,
                message: "failed: mizar://pair?h=127.0.0.1:19395&c=MOCK-CODE rejected, token mz_mock_token",
            ),
            LogRecord(
                at: now.addingTimeInterval(-20),
                category: .request,
                message: "session.messages(sessionId) → ok in 42 ms",
                request: RequestDetail(
                    method: "session.messages",
                    arguments: ["sessionId", "maxMessages"],
                    durationMs: 42,
                    outcome: .ok,
                ),
            ),
            LogRecord(
                at: now.addingTimeInterval(-10),
                category: .request,
                message: "push.register(arguments) → failed",
                request: RequestDetail(
                    method: "push.register",
                    arguments: ["environment", "locale", "token"],
                    durationMs: 900,
                    outcome: .failed,
                    errorCode: "UNAVAILABLE",
                    errorMessage: "the relay did not answer; device token \(hex)",
                ),
            ),
            LogRecord(
                at: now.addingTimeInterval(-5),
                category: .settings,
                message: "notifications: turn-finished off",
            ),
            LogRecord(
                at: now,
                category: .push,
                message: "suppressed question (switch off)",
            ),
        ]
    }

    private static func environment() -> EnvironmentFacts {
        EnvironmentFacts(
            appVersion: "0.7.2",
            appBuild: "13",
            bundleIdentifier: "me.shirazu.dshmizar",
            deviceModel: "iPhone18,1",
            systemName: "iOS",
            systemVersion: "26.0",
            locale: "zh-Hans_CN",
            languages: ["zh-Hans", "en"],
            timeZone: "Asia/Shanghai",
            notificationAuthorization: "authorized",
            notificationsAllowed: true,
            soundAllowed: true,
            pushTokenRegistered: true,
            pushTokenLength: 64,
            pushEnvironment: "sandbox",
            launchFlags: ["-mizarPairURI", "-mizarFreshStart"],
        )
    }

    private static func host() -> HostSummary {
        HostSummary(
            connected: true,
            phase: "ready",
            current: HostSummary.Machine(
                hostId: "h1",
                name: "Mock Mac",
                route: "direct",
                address: "127.0.0.1:19395",
                pairedAt: now.addingTimeInterval(-3600),
            ),
            pairedHosts: [
                HostSummary.Machine(
                    hostId: "h1",
                    name: "Mock Mac",
                    route: "direct",
                    address: "127.0.0.1:19395",
                    pairedAt: now.addingTimeInterval(-3600),
                ),
            ],
            protocolVersion: 1,
            sessionCount: 3,
            titledSessionCount: 2,
            workspaceCount: 4,
            lastError: "the Mac did not answer",
            pendingApprovals: [
                HostSummary.Approval(
                    requestId: "r1",
                    sessionId: "s1",
                    toolName: "bash",
                    reason: "wants to run rm -rf",
                    waitingSeconds: 12,
                ),
            ],
            pendingQuestions: [
                HostSummary.Question(callId: "c1", sessionId: "s1", count: 2, firstPrompt: "Which branch?"),
            ],
            recentEvents: [HostSummary.Event(at: now, name: "interactions.changed")],
        )
    }

    private static func settings() -> MizarSettings {
        var settings = MizarSettings(liveActivitiesEnabled: false)
        settings.notifications.set(false, for: .question)
        return settings
    }

    @Test("carries every file the export promises")
    func containsEveryFile() {
        let files = LogArchiveWriter.files(
            records: Self.records(),
            environment: Self.environment(),
            settings: Self.settings(),
            host: Self.host(),
            now: Self.now,
        )
        #expect(
            files.map(\.path) == [
                "README.txt", "environment.json", "settings.json",
                "host.json", "activity.log", "requests.jsonl",
            ],
        )
        let log = files.first { $0.path == "activity.log" }?.contents ?? Data()
        let lines = String(decoding: log, as: UTF8.self).split(separator: "\n")
        // Header comment plus one line per record, and every line stamped.
        #expect(lines.count == Self.records().count + 2)
        #expect(lines.contains { $0.contains("2025-10-09T08:53:20") })
    }

    @Test("contains no credential, in any file")
    func carriesNoSecrets() throws {
        let files = LogArchiveWriter.files(
            records: Self.records(),
            environment: Self.environment(),
            settings: Self.settings(),
            host: Self.host(),
            now: Self.now,
        )
        for file in files {
            let text = String(decoding: file.contents, as: UTF8.self)
            #expect(!text.contains("mz_mock_token"), "\(file.path) leaked the device token")
            #expect(!text.contains("MOCK-CODE"), "\(file.path) leaked the pairing code")
            #expect(!text.contains(String(repeating: "0123456789abcdef", count: 4)), "\(file.path) leaked a hash")
            #expect(!LogScrubber.containsSecret(text), "\(file.path) still looks like it holds a secret")
        }
    }

    @Test("writes JSON a person and a script can both read")
    func jsonIsReadable() throws {
        let files = LogArchiveWriter.files(
            records: Self.records(),
            environment: Self.environment(),
            settings: Self.settings(),
            host: Self.host(),
            now: Self.now,
        )
        for path in ["environment.json", "settings.json", "host.json"] {
            let text = try #require(files.first { $0.path == path }?.contents)
            let parsed = try JSONSerialization.jsonObject(with: text)
            #expect(parsed is [String: Any], "\(path) is not a JSON object")
            #expect(String(decoding: text, as: UTF8.self).contains("\n"), "\(path) is not pretty-printed")
        }
        let environment = try #require(files.first { $0.path == "environment.json" }?.contents)
        let decoded = try JSONDecoder().decode(EnvironmentFacts.self, from: environment)
        #expect(decoded.appVersion == "0.7.2")
        #expect(decoded.appBuild == "13")
        #expect(decoded.deviceModel == "iPhone18,1")
        #expect(decoded.systemVersion == "26.0")
        // The switch positions are written by name, so the file answers "why did
        // this not arrive" without the app to interpret it.
        let settings = try #require(files.first { $0.path == "settings.json" }?.contents)
        let settingsText = String(decoding: settings, as: UTF8.self)
        #expect(settingsText.contains("\"question\" : false"))
        #expect(settingsText.contains("\"liveActivitiesEnabled\" : false"))
    }

    @Test("writes one JSON line per host call")
    func requestLines() throws {
        let files = LogArchiveWriter.files(
            records: Self.records(),
            environment: Self.environment(),
            settings: Self.settings(),
            host: Self.host(),
            now: Self.now,
        )
        let text = String(decoding: try #require(files.first { $0.path == "requests.jsonl" }?.contents), as: UTF8.self)
        let lines = text.split(separator: "\n")
        #expect(lines.count == 2)
        let first = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
        #expect(first?["method"] as? String == "session.messages")
        #expect(first?["outcome"] as? String == "ok")
        #expect(first?["durationMs"] as? Double == 42)
        #expect((first?["arguments"] as? [String]) == ["maxMessages", "sessionId"])
        let second = try JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any]
        #expect(second?["method"] as? String == "push.register")
        #expect(second?["outcome"] as? String == "failed")
        #expect(second?["errorCode"] as? String == "UNAVAILABLE")
    }

    @Test("writes a zip that opens, with the files under one folder")
    func writesAnOpenableZip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "mizar-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let archive = try LogArchiveWriter.write(
            records: Self.records(),
            environment: Self.environment(),
            settings: Self.settings(),
            host: Self.host(),
            to: directory,
            now: Self.now,
        )
        #expect(archive.fileName.hasPrefix("dsh-mizar-logs-"))
        #expect(archive.fileName.hasSuffix(".zip"))
        #expect(archive.fileCount == 6)
        #expect(archive.recordCount == Self.records().count)
        #expect(FileManager.default.fileExists(atPath: archive.url.path))
        let onDisk = try Data(contentsOf: archive.url)
        #expect(onDisk.count == archive.byteCount)

        let reader = try ZipReader(onDisk)
        let folder = String(archive.fileName.dropLast(4))
        #expect(reader.items.count == 6)
        for path in ["README.txt", "environment.json", "settings.json", "host.json", "activity.log", "requests.jsonl"] {
            #expect(reader.item("\(folder)/\(path)") != nil, "\(path) is missing from the archive")
        }
        let readme = try #require(reader.text("\(folder)/README.txt"))
        #expect(readme.contains("DSH-Mizar diagnostic log export"))
        // The log is a file somebody can read, so it is text rather than JSON.
        let activity = try #require(reader.text("\(folder)/activity.log"))
        #expect(activity.contains("dialling 127.0.0.1:19395 directly"))
        #expect(activity.contains("suppressed question"))
    }

    @Test("names an archive so a folder of them reads in order")
    func fileNames() {
        // 1_760_000_000 is 2025-10-09T08:53:20Z, and the name is UTC so that two
        // phones in different places produce names that sort together.
        #expect(LogArchiveWriter.fileName(at: Self.now) == "dsh-mizar-logs-20251009-085320.zip")
        let later = Self.now.addingTimeInterval(3661)
        #expect(LogArchiveWriter.fileName(at: later) > LogArchiveWriter.fileName(at: Self.now))
    }
}
