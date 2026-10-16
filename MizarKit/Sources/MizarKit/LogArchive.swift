//
//  LogArchive.swift
//  MizarKit
//
//  The archive behind the Settings screen's export button.
//
//  A bug report about a phone is a conversation with somebody who cannot see the
//  phone. "It does not connect" and "notifications stopped" are both answered by
//  the same four things -- what this build is, what it tried, what came back, and
//  what the host last said -- and none of them survive a screenshot. So the app
//  keeps a log and this file turns it into something that can be sent.
//
//  Three decisions are worth stating.
//
//  **It is a directory of plain files in a zip, not one blob.** An operator can
//  unzip it on the Mac and read `activity.log` with `less`; a machine can parse
//  `requests.jsonl`; and neither needs this app to interpret it. A binary or
//  opaque format would make the archive useful only to whoever wrote the reader.
//
//  **It is redacted on the way out, not on the way in.** The scrubber runs over
//  every byte of text in the archive -- including the JSON, and including the
//  README -- so there is no need to reason about which field a credential could
//  have reached. The device token grants remote control of an agent that can run
//  code on the host, and the pairing code is worse; neither may leave the phone
//  inside a file that exists to be emailed around.
//
//  **The log records what was asked, never what was said.** A request is logged
//  as its method and the *names* of its arguments: `session.prompt(text,
//  sessionId)` is a diagnostic fact, and the prompt itself is the operator's
//  conversation. Conversations are not in this archive, and the redaction pass
//  is the second line of defence rather than the first.
//

import Foundation

// MARK: - The log itself

/// One thing that happened, with the moment it happened.
public struct LogRecord: Sendable, Equatable, Codable {
    /// What kind of thing it was.
    ///
    /// Coarse on purpose: a category is for filtering a file somebody is reading,
    /// and a taxonomy with thirty entries is a taxonomy nobody uses.
    public enum Category: String, Sendable, Codable, CaseIterable {
        /// Launch, lifecycle, launch arguments.
        case app
        /// A settings change, by the operator.
        case settings
        /// Opening, losing or failing to open the host connection.
        case connection
        /// One call to the host.
        case request
        /// Registration with the relay, and what arrived from it.
        case push
        /// History downloads and their progress.
        case sync
        /// Reads and writes of the stored conversation and index.
        case cache
        /// Events the host pushed, and the pending-interaction set.
        case host
        /// Live Activity.
        case live
    }

    /// When.
    public let at: Date
    /// What kind of thing.
    public let category: Category
    /// What happened, already written for a human.
    public let message: String
    /// The call this is about, when it is about one.
    public let request: RequestDetail?

    /// - Parameters:
    ///   - at: when it happened.
    ///   - category: what kind of thing it was.
    ///   - message: what happened.
    ///   - request: the call, for category ``Category/request``.
    public init(
        at: Date = Date(),
        category: Category,
        message: String,
        request: RequestDetail? = nil,
    ) {
        self.at = at
        self.category = category
        self.message = message
        self.request = request
    }

    /// One line of `activity.log`.
    ///
    /// Timestamp, category, message, in columns: a log where the category is a
    /// different width on every line cannot be skimmed, and skimming is what
    /// anybody does with four thousand lines of it.
    public var line: String {
        let stamp = at.formatted(LogRecord.stampStyle)
        let column = category.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)
        return "\(stamp)  \(column)  \(message)"
    }

    /// ISO-8601 with milliseconds, in UTC.
    ///
    /// Milliseconds because the interesting failures here are round trips, and a
    /// log that says a request took no time at all is a log that cannot show
    /// which of two concurrent reads landed first.
    static let stampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
}

/// One call to the host, as it went.
public struct RequestDetail: Sendable, Equatable, Codable {
    /// Whether it worked.
    public enum Outcome: String, Sendable, Codable {
        /// The host answered.
        case ok
        /// It did not, or answered with a failure.
        case failed
    }

    /// The wire method, e.g. `session.messages`.
    public let method: String
    /// The names of the arguments, sorted. Never their values.
    public let arguments: [String]
    /// How long it took, when it finished at all.
    public let durationMs: Double?
    /// Whether it worked.
    public let outcome: Outcome
    /// The host's error code, when it failed.
    public let errorCode: String?
    /// The error, rendered the way the screen would have shown it.
    public let errorMessage: String?

    /// - Parameters:
    ///   - method: the wire method.
    ///   - arguments: the argument names.
    ///   - durationMs: how long it took.
    ///   - outcome: whether it worked.
    ///   - errorCode: the host's code, when it failed.
    ///   - errorMessage: the error text, when it failed.
    public init(
        method: String,
        arguments: [String] = [],
        durationMs: Double? = nil,
        outcome: Outcome,
        errorCode: String? = nil,
        errorMessage: String? = nil,
    ) {
        self.method = method
        self.arguments = arguments.sorted()
        self.durationMs = durationMs
        self.outcome = outcome
        self.errorCode = errorCode
        self.errorMessage = errorMessage
    }

    /// The one-line form used in `activity.log`.
    public var summary: String {
        let call = arguments.isEmpty ? method : "\(method)(\(arguments.joined(separator: ", ")))"
        let took = durationMs.map { String(format: " in %.0f ms", $0) } ?? ""
        switch outcome {
        case .ok:
            return "\(call) → ok\(took)"
        case .failed:
            let code = errorCode.map { " \($0)" } ?? ""
            let why = errorMessage.map { ": \($0)" } ?? ""
            return "\(call) → failed\(took)\(code)\(why)"
        }
    }
}

// MARK: - Redaction

/// Takes the secrets out of a string.
///
/// The rules are patterns rather than field names, because the ways a credential
/// reaches a log line are not enumerable: a token arrives inside an error
/// message from a URLSession, inside a `mizar://` URI quoted by a failing
/// connection, inside a JSON body echoed by a host. Matching the *shape* catches
/// all of them, including the ones nobody predicted.
///
/// What is removed:
///
///   - anything beginning `mz_`, which is the device token's prefix
///     (`dsh/src/auth/devices.ts`'s `TOKEN_PREFIX`);
///   - a JWT, which is the other shape a credential takes;
///   - any run of 32 or more hex characters, which is what an APNs device token
///     is (64 of them) and what a hash looks like;
///   - the value of `c=`, `code=` or `token=` in a query string or a form body,
///     which is how a pairing code travels;
///   - `Bearer <something>`, and the same three names as JSON fields.
public enum LogScrubber {
    /// Replace anything that looks like a credential.
    /// - Parameter text: the text to clean.
    /// - Returns: the text, with credentials replaced by a marker.
    public static func redact(_ text: String) -> String {
        var out = text
        out = out.replacing(/mz_[A-Za-z0-9._~+\/-]{4,}/, with: "mz_<redacted>")
        out = out.replacing(
            /eyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}/,
            with: "<redacted-jwt>",
        )
        out = out.replacing(/[0-9A-Fa-f]{32,}/, with: "<redacted-hex>")
        // The key is kept and only the value is replaced, in all four of these:
        // `?c=<redacted>` still says a pairing URI went past, which is the fact
        // worth having, and the code itself is the one thing that must not.
        // Written with capture groups rather than lookbehind, which Swift's
        // regex engine does not implement.
        out = out.replacing(/(\bc=)[^&\s"]+/) { "\($0.output.1)<redacted-code>" }
        out = out.replacing(/(\bcode=)[^&\s"]+/) { "\($0.output.1)<redacted-code>" }
        out = out.replacing(/(\btoken=)[^&\s"]+/) { "\($0.output.1)<redacted-token>" }
        out = out.replacing(/((?i:bearer)\s)[A-Za-z0-9._~+\/-]{8,}/) { "\($0.output.1)<redacted-token>" }
        out = out.replacing(/("(?:deviceToken|pairingCode|token)"\s*:\s*")[^"]*/) { match in
            "\(match.output.1)<redacted>"
        }
        return out
    }

    /// Whether the text still contains something that looks like a credential.
    ///
    /// Used by the tests, and by nothing else: an archive the scrubber cannot
    /// prove clean is an archive that does not get written.
    ///
    /// - Parameter text: the text to check.
    /// - Returns: whether a credential-shaped string is still in there.
    public static func containsSecret(_ text: String) -> Bool {
        if text.contains(/mz_[A-Za-z0-9._~+\/-]{4,}/) { return true }
        if text.contains(/[0-9A-Fa-f]{32,}/) { return true }
        if text.contains(/eyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}/) { return true }
        return false
    }
}

// MARK: - What the archive describes

/// The build, the phone and the permission state.
///
/// Gathered in the app -- it is the only place that can see `Bundle.main`,
/// `UIDevice` and `UNUserNotificationCenter` -- and passed in, so this file
/// stays testable on a Mac.
public struct EnvironmentFacts: Codable, Sendable, Equatable {
    /// `CFBundleShortVersionString`.
    public var appVersion: String
    /// `CFBundleVersion`.
    public var appBuild: String
    /// The bundle identifier.
    public var bundleIdentifier: String
    /// The hardware model, e.g. `iPhone17,1`, or `iOS Simulator`.
    public var deviceModel: String
    /// `UIDevice.systemName`.
    public var systemName: String
    /// `UIDevice.systemVersion`.
    public var systemVersion: String
    /// The operator's locale.
    public var locale: String
    /// The preferred languages, in order.
    public var languages: [String]
    /// The time zone the phone is in.
    public var timeZone: String
    /// Whether iOS has granted notification permission, and how much of it.
    public var notificationAuthorization: String
    /// Whether the alerts permission is on.
    public var notificationsAllowed: Bool?
    /// Whether sound is on.
    public var soundAllowed: Bool?
    /// Whether this phone has a push token at all.
    public var pushTokenRegistered: Bool
    /// How long the token is. The token itself is a credential and is never here.
    public var pushTokenLength: Int
    /// `sandbox` or `production`, which decide which APNs service will accept it.
    public var pushEnvironment: String
    /// The launch flags this process was started with, by name only.
    ///
    /// Names, not values: `-mizarPairURI` carries a pairing code, and a
    /// diagnostic file that leaks the thing it exists to protect is worse than
    /// no diagnostic file. The scrubber would catch it anyway; not writing it is
    /// better than catching it.
    public var launchFlags: [String]

    /// An empty set of facts, for a caller that knows nothing yet.
    public init(
        appVersion: String = "unknown",
        appBuild: String = "unknown",
        bundleIdentifier: String = "unknown",
        deviceModel: String = "unknown",
        systemName: String = "unknown",
        systemVersion: String = "unknown",
        locale: String = "",
        languages: [String] = [],
        timeZone: String = "",
        notificationAuthorization: String = "unknown",
        notificationsAllowed: Bool? = nil,
        soundAllowed: Bool? = nil,
        pushTokenRegistered: Bool = false,
        pushTokenLength: Int = 0,
        pushEnvironment: String = "unknown",
        launchFlags: [String] = [],
    ) {
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.bundleIdentifier = bundleIdentifier
        self.deviceModel = deviceModel
        self.systemName = systemName
        self.systemVersion = systemVersion
        self.locale = locale
        self.languages = languages
        self.timeZone = timeZone
        self.notificationAuthorization = notificationAuthorization
        self.notificationsAllowed = notificationsAllowed
        self.soundAllowed = soundAllowed
        self.pushTokenRegistered = pushTokenRegistered
        self.pushTokenLength = pushTokenLength
        self.pushEnvironment = pushEnvironment
        self.launchFlags = launchFlags
    }
}

/// What the app is joined to, and what the host last said.
public struct HostSummary: Codable, Sendable, Equatable {
    /// A machine, as this phone knows it. Never its token.
    public struct Machine: Codable, Sendable, Equatable {
        /// The host's identity.
        public var hostId: String
        /// The name shown on this phone.
        public var name: String
        /// `direct` or `relay`, when a route is in use.
        public var route: String?
        /// The address being dialled, when known.
        public var address: String?
        /// When the pairing was made.
        public var pairedAt: Date

        /// - Parameters:
        ///   - hostId: the host's identity.
        ///   - name: the display name.
        ///   - route: which route is in use.
        ///   - address: the address.
        ///   - pairedAt: when pairing completed.
        public init(
            hostId: String,
            name: String,
            route: String? = nil,
            address: String? = nil,
            pairedAt: Date,
        ) {
            self.hostId = hostId
            self.name = name
            self.route = route
            self.address = address
            self.pairedAt = pairedAt
        }
    }

    /// An approval that was waiting when the archive was made.
    public struct Approval: Codable, Sendable, Equatable {
        /// The request being answered.
        public var requestId: String
        /// The session it belongs to.
        public var sessionId: String?
        /// The tool that wants to run.
        public var toolName: String
        /// Why, as the tool explained it.
        public var reason: String?
        /// How long it had been waiting, in seconds.
        public var waitingSeconds: Double?

        /// - Parameters:
        ///   - requestId: the request.
        ///   - sessionId: the session.
        ///   - toolName: the tool.
        ///   - reason: why.
        ///   - waitingSeconds: how long it had waited.
        public init(
            requestId: String,
            sessionId: String? = nil,
            toolName: String,
            reason: String? = nil,
            waitingSeconds: Double? = nil,
        ) {
            self.requestId = requestId
            self.sessionId = sessionId
            self.toolName = toolName
            self.reason = reason
            self.waitingSeconds = waitingSeconds
        }
    }

    /// A question batch that was waiting when the archive was made.
    public struct Question: Codable, Sendable, Equatable {
        /// The call the answer goes back on.
        public var callId: String
        /// The session it belongs to.
        public var sessionId: String?
        /// How many questions are in the batch.
        public var count: Int
        /// The first question, shortened. Model questions are shown on screen
        /// and are part of what went wrong, so a summary of one is diagnostic
        /// rather than private -- but it is a summary, not a transcript.
        public var firstPrompt: String?

        /// - Parameters:
        ///   - callId: the call.
        ///   - sessionId: the session.
        ///   - count: how many questions.
        ///   - firstPrompt: the first question, shortened.
        public init(callId: String, sessionId: String? = nil, count: Int, firstPrompt: String? = nil) {
            self.callId = callId
            self.sessionId = sessionId
            self.count = count
            self.firstPrompt = firstPrompt
        }
    }

    /// An event the host pushed, and when.
    public struct Event: Codable, Sendable, Equatable {
        /// When it arrived.
        public var at: Date
        /// Its name, e.g. `interactions.changed`.
        public var name: String

        /// - Parameters:
        ///   - at: when it arrived.
        ///   - name: its name.
        public init(at: Date, name: String) {
            self.at = at
            self.name = name
        }
    }

    /// Whether a connection is open.
    public var connected: Bool
    /// The app's phase, as the screen would describe it.
    public var phase: String
    /// The machine in use.
    public var current: Machine?
    /// Every machine paired with this phone.
    public var pairedHosts: [Machine]
    /// The protocol version the host reported.
    public var protocolVersion: Int?
    /// How many sessions the host lists.
    public var sessionCount: Int
    /// How many of them have a title.
    public var titledSessionCount: Int
    /// How many workspaces the host reports, or `nil` when it has not said.
    public var workspaceCount: Int?
    /// The last thing that went wrong, when something did.
    public var lastError: String?
    /// The approvals waiting.
    public var pendingApprovals: [Approval]
    /// The questions waiting.
    public var pendingQuestions: [Question]
    /// The most recent host events, newest first.
    public var recentEvents: [Event]

    /// An empty summary.
    public init(
        connected: Bool = false,
        phase: String = "unknown",
        current: Machine? = nil,
        pairedHosts: [Machine] = [],
        protocolVersion: Int? = nil,
        sessionCount: Int = 0,
        titledSessionCount: Int = 0,
        workspaceCount: Int? = nil,
        lastError: String? = nil,
        pendingApprovals: [Approval] = [],
        pendingQuestions: [Question] = [],
        recentEvents: [Event] = [],
    ) {
        self.connected = connected
        self.phase = phase
        self.current = current
        self.pairedHosts = pairedHosts
        self.protocolVersion = protocolVersion
        self.sessionCount = sessionCount
        self.titledSessionCount = titledSessionCount
        self.workspaceCount = workspaceCount
        self.lastError = lastError
        self.pendingApprovals = pendingApprovals
        self.pendingQuestions = pendingQuestions
        self.recentEvents = recentEvents
    }
}

// MARK: - The archive

/// One file inside the archive.
public struct LogArchiveFile: Sendable, Equatable {
    /// Its path inside the archive's folder, e.g. `logs/activity.log`.
    public let path: String
    /// Its bytes.
    public let contents: Data

    /// - Parameters:
    ///   - path: the path inside the archive.
    ///   - contents: the bytes.
    public init(path: String, contents: Data) {
        self.path = path
        self.contents = contents
    }

    /// - Parameters:
    ///   - path: the path inside the archive.
    ///   - text: the text, as UTF-8.
    public init(path: String, text: String) {
        self.init(path: path, contents: Data(text.utf8))
    }
}

/// An archive that now exists on disk.
public struct LogArchive: Sendable, Equatable, Identifiable {
    /// Identity, for SwiftUI's `sheet(item:)`.
    public let id: UUID
    /// Where it is. In the temporary directory, and removable by iOS at any time.
    public let url: URL
    /// Its file name, for the screen and the share sheet.
    public let fileName: String
    /// How many bytes it is.
    public let byteCount: Int
    /// How many files are inside it.
    public let fileCount: Int
    /// When it was made.
    public let createdAt: Date
    /// How many log lines went into it.
    public let recordCount: Int

    /// - Parameters:
    ///   - id: identity. Generated when not supplied.
    ///   - url: where it is.
    ///   - fileName: its name.
    ///   - byteCount: its size.
    ///   - fileCount: how many files are inside.
    ///   - createdAt: when it was made.
    ///   - recordCount: how many log lines are in it.
    public init(
        id: UUID = UUID(),
        url: URL,
        fileName: String,
        byteCount: Int,
        fileCount: Int,
        createdAt: Date,
        recordCount: Int,
    ) {
        self.id = id
        self.url = url
        self.fileName = fileName
        self.byteCount = byteCount
        self.fileCount = fileCount
        self.createdAt = createdAt
        self.recordCount = recordCount
    }

    /// A size a person can read, e.g. `12 KB`.
    public var readableSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB]
        return formatter.string(fromByteCount: Int64(byteCount))
    }
}

/// What can go wrong writing an archive.
public enum LogArchiveError: Error, Equatable {
    /// The temporary directory could not be written to.
    case writeFailed(String)
}

/// Builds and writes the log archive.
public enum LogArchiveWriter {
    /// The prefix every archive's name starts with.
    public static let fileNamePrefix = "dsh-mizar-logs"

    /// Build the files that go inside one archive.
    ///
    /// - Parameters:
    ///   - records: the app's log, oldest first.
    ///   - environment: the build, the phone and the permission state.
    ///   - settings: what the operator has switched on.
    ///   - host: what the host last said.
    ///   - now: the moment the archive is being made.
    /// - Returns: the files, in the order they should appear in the zip.
    public static func files(
        records: [LogRecord],
        environment: EnvironmentFacts,
        settings: MizarSettings,
        host: HostSummary,
        now: Date = Date(),
    ) -> [LogArchiveFile] {
        [
            LogArchiveFile(path: "README.txt", text: readme(now: now)),
            LogArchiveFile(path: "environment.json", text: json(environment)),
            LogArchiveFile(path: "settings.json", text: json(settings)),
            LogArchiveFile(path: "host.json", text: json(host)),
            LogArchiveFile(path: "activity.log", text: activityLog(records)),
            LogArchiveFile(path: "requests.jsonl", text: requests(records)),
        ]
        // One pass over everything, here rather than at each producer, so that a
        // file added later cannot quietly skip it. See ``LogScrubber``: the
        // question "could a token have reached this field" is not one this file
        // should have to answer.
        .map { LogArchiveFile(path: $0.path, text: LogScrubber.redact(String(decoding: $0.contents, as: UTF8.self))) }
    }

    /// Write an archive to a file.
    ///
    /// - Parameters:
    ///   - records: the app's log, oldest first.
    ///   - environment: the build, the phone and the permission state.
    ///   - settings: what the operator has switched on.
    ///   - host: what the host last said.
    ///   - directory: where to put it. The temporary directory, in the app.
    ///   - now: the moment it is being made.
    /// - Returns: the archive.
    /// - Throws: ``LogArchiveError`` when it could not be written, or
    ///   ``ZipWriterError`` for an entry the format cannot hold.
    public static func write(
        records: [LogRecord],
        environment: EnvironmentFacts,
        settings: MizarSettings,
        host: HostSummary,
        to directory: URL,
        now: Date = Date(),
    ) throws -> LogArchive {
        let name = fileName(at: now)
        let folder = String(name.dropLast(".zip".count))
        let entries = files(records: records, environment: environment, settings: settings, host: host, now: now)
            .map { ZipEntry(path: "\(folder)/\($0.path)", contents: $0.contents) }
        let data = try ZipWriter.archive(entries, modifiedAt: now)
        let url = directory.appending(path: name)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw LogArchiveError.writeFailed(String(describing: error))
        }
        return LogArchive(
            url: url,
            fileName: name,
            byteCount: data.count,
            fileCount: entries.count,
            createdAt: now,
            recordCount: records.count,
        )
    }

    /// The file name for an archive made at a moment.
    ///
    /// Sortable, and second-resolution: a folder of these reads in the order
    /// they were made, which is the only property anybody wants from the name.
    ///
    /// - Parameter date: the moment.
    /// - Returns: e.g. `dsh-mizar-logs-20251017-013005.zip`, in UTC.
    public static func fileName(at date: Date) -> String {
        var style = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
        style.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let stamp = date.formatted(style)
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "T", with: "-")
            .replacingOccurrences(of: "Z", with: "")
        return "\(fileNamePrefix)-\(stamp).zip"
    }

    // MARK: - The individual files

    /// The note that explains what the reader is holding.
    private static func readme(now: Date) -> String {
        """
        DSH-Mizar diagnostic log export
        Made: \(now.formatted(LogRecord.stampStyle))

        What is in here
        ---------------
        environment.json  This build, this phone, the OS, and the notification
                          permission state. Start here: half of all "it does not
                          work" reports are answered by the version and the
                          permission.
        settings.json     Which notifications the operator has switched on, and
                          whether the Live Activity is allowed.
        host.json         The Mac this phone is paired with, what the host last
                          reported, and anything that was waiting on the
                          operator's answer.
        activity.log      Everything the app did, in order, with timestamps.
                          Reading it top to bottom is the whole story of a
                          session: what was asked, what came back, what was
                          written down.
        requests.jsonl    One JSON object per line, one per call to the host:
                          method, argument names, duration, outcome. For asking
                          "which request is failing" without reading prose.

        What is deliberately not in here
        --------------------------------
        The device token and any pairing code. The credential store's contents.
        The operator's conversations, prompts and answers -- a request appears as
        its method and the names of its arguments, never their values.

        Redaction runs over every byte of text in this archive, including the
        JSON files, so a credential cannot survive inside a field this note does
        not mention. Anything removed is marked <redacted>.

        This file is plain text and this archive is a zip made on the phone. It
        can be read with `unzip -l` and `less` on any machine.
        """
    }

    /// The activity log, as lines.
    private static func activityLog(_ records: [LogRecord]) -> String {
        let header = """
        # DSH-Mizar activity log — \(records.count) entries, oldest first.
        # Timestamps are ISO-8601 UTC. Categories: \(LogRecord.Category.allCases.map(\.rawValue).joined(separator: ", ")).

        """
        return header + records.map(\.line).joined(separator: "\n") + "\n"
    }

    /// The request log, as JSON lines.
    private static func requests(_ records: [LogRecord]) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom(Self.encodeStamp)
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let lines = records.compactMap { record -> String? in
            guard let detail = record.request,
                  let encoded = try? encoder.encode(LoggedRequest(at: record.at, request: detail))
            else { return nil }
            return String(decoding: encoded, as: UTF8.self)
        }
        return lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    }

    /// Write a date as the same ISO-8601 stamp the log lines use.
    ///
    /// `.iso8601` would be one line shorter, and would then disagree with
    /// `activity.log` about the format of the same moment -- which is exactly
    /// the sort of thing that costs somebody twenty minutes while they line two
    /// files up by eye.
    private static func encodeStamp(_ date: Date, _ encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(date.formatted(LogRecord.stampStyle))
    }

    /// One line of `requests.jsonl`.
    ///
    /// Flat rather than nested: this file exists to be queried, and
    /// `jq 'select(.outcome=="failed") | .method'` is the query. A `request`
    /// object inside each line would make every one of them longer to write.
    private struct LoggedRequest: Encodable {
        let at: Date
        let method: String
        let arguments: [String]
        let durationMs: Double?
        let outcome: String
        let errorCode: String?
        let errorMessage: String?

        init(at: Date, request: RequestDetail) {
            self.at = at
            method = request.method
            arguments = request.arguments
            durationMs = request.durationMs
            outcome = request.outcome.rawValue
            errorCode = request.errorCode
            errorMessage = request.errorMessage
        }
    }

    /// Encode a value as readable JSON.
    ///
    /// Pretty-printed and key-sorted: a diagnostic file gets read by a person as
    /// often as by a script, and a single line of two kilobytes is not read by
    /// either.
    private static func json(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom(Self.encodeStamp)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "{}\n" }
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}
