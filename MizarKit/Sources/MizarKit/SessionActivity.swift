//
//  SessionActivity.swift
//  MizarKit
//
//  The paid full-detail feed for a running turn.
//
//  The summary-only history is what the phone draws: for a finished turn, the
//  prompt, a marker or two and the model's last message. A turn that is *still
//  running* has no answer yet, so the summary row can say how long it has been
//  going and nothing about what it is doing. `session.activity` fills that gap
//  for paid accounts: the host returns a compact, capped list of the running
//  turn's process details -- thinking, commands, their output, tool calls --
//  already truncated and shaped for a one-line display.
//
//  Three properties matter and are all tested:
//
//  - **It is a side channel.** Nothing here is cached, persisted or replayed: a
//    turn that ends takes its details with it, and the app clears them. The
//    history the phone keeps is still the summary-only one.
//  - **`at` is epoch milliseconds on the wire**, like every other timestamp the
//    host emits. Decoding it as seconds would put every detail in January 1970;
//    the model converts inside `init(from:)` rather than relying on a decoder
//    strategy, because this value travels through `JSONValue.decoded(as:)`,
//    which builds a plain `JSONDecoder`.
//  - **A kind this build does not know is not an error.** The host will grow
//    categories; an unknown string decodes as ``ActivityKind/other`` so a newer
//    host still draws a readable row instead of failing the whole answer.
//

import Foundation

/// What kind of process detail one entry is.
public enum ActivityKind: String, Codable, Sendable, Equatable, CaseIterable {
    /// The model's reasoning, joined from streamed deltas.
    case thinking
    /// A shell-like tool call.
    case command
    /// Output produced by a tool.
    case output
    /// Any other tool call.
    case tool
    /// A kind this build does not know. Not sent by the host.
    case other

    public init(from decoder: any Decoder) throws {
        let raw = try? decoder.singleValueContainer().decode(String.self)
        self = raw.flatMap(ActivityKind.init(rawValue:)) ?? .other
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// One compact process detail from the running turn.
public struct ActivityEntry: Codable, Sendable, Equatable, Identifiable {
    /// Stable identity, so a list can diff and animate insertions. The host
    /// builds it from the record's seq and kind (`seq-<n>` or `seq-<n>-<kind>`).
    public let id: String
    /// The log position, when the host could attribute one.
    public let seq: Int?
    /// When the record was written.
    ///
    /// Optional because this is decoration on a row that already has its own
    /// clock, and a detail with no time is still worth drawing; a required date
    /// would let one malformed entry fail the whole answer.
    public let at: Date?
    /// What kind of detail this is.
    public let kind: ActivityKind
    /// The tool name for `command`/`tool`; may be empty for `thinking`/`output`.
    public let title: String
    /// A compact one-line description, already truncated by the host (240 chars).
    public let text: String

    public init(
        id: String,
        seq: Int? = nil,
        at: Date? = nil,
        kind: ActivityKind,
        title: String = "",
        text: String = "",
    ) {
        self.id = id
        self.seq = seq
        self.at = at
        self.kind = kind
        self.title = title
        self.text = text
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // `id` is required by the contract, but a missing one must not sink the
        // answer: fall back to the seq, which is what the id is derived from.
        seq = try container.decodeIfPresent(Int.self, forKey: .seq)
        id = (try container.decodeIfPresent(String.self, forKey: .id))
            ?? (seq.map { "seq-\($0)" } ?? UUID().uuidString)
        if let millis = try container.decodeIfPresent(Double.self, forKey: .at) {
            at = Date(timeIntervalSince1970: millis / 1000)
        } else {
            at = nil
        }
        kind = (try? container.decode(ActivityKind.self, forKey: .kind)) ?? .other
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case seq
        case at
        case kind
        case title
        case text
    }
}

/// The host's answer to `session.activity`.
public struct SessionActivityResult: Codable, Sendable, Equatable {
    /// The session the answer is about, echoed back.
    public let sessionId: String
    /// The last log position the host read, when it could name one.
    public let asOfSeq: Int?
    /// The currently running turn, or `nil` when nothing is running.
    ///
    /// `nil` is the signal to clear the detail area: the turn this feed belongs
    /// to is over, and its details are no longer anybody's business.
    public let turn: Int?
    /// The running turn's details, oldest first. Empty when nothing is running.
    public let entries: [ActivityEntry]
    /// Whether older entries may still be read -- for a forward read, the
    /// entries were trimmed to fit or the host's log page has older records; for
    /// a backwards page, the page was full and contributed entries of the turn.
    ///
    /// Widened from "the entries were trimmed" when backwards paging arrived:
    /// the phone now needs to know whether asking for an older page is worth a
    /// round trip, not only whether this answer was cut short.
    public let hasMore: Bool
    /// The smallest log position in the page the host read, when it named one.
    ///
    /// The cursor for the next older page: the phone sends this value back as
    /// `beforeSeq`. Optional because an older host does not send it -- paging
    /// then has to start from the oldest entry's own seq, and stops when an
    /// answer stops making progress.
    public let oldestSeq: Int?

    public init(
        sessionId: String,
        asOfSeq: Int? = nil,
        turn: Int? = nil,
        entries: [ActivityEntry] = [],
        hasMore: Bool = false,
        oldestSeq: Int? = nil,
    ) {
        self.sessionId = sessionId
        self.asOfSeq = asOfSeq
        self.turn = turn
        self.entries = entries
        self.hasMore = hasMore
        self.oldestSeq = oldestSeq
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId) ?? ""
        asOfSeq = try container.decodeIfPresent(Int.self, forKey: .asOfSeq)
        turn = try container.decodeIfPresent(Int.self, forKey: .turn)
        entries = try container.decodeIfPresent([ActivityEntry].self, forKey: .entries) ?? []
        hasMore = try container.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
        oldestSeq = try container.decodeIfPresent(Int.self, forKey: .oldestSeq)
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId
        case asOfSeq
        case turn
        case entries
        case hasMore
        case oldestSeq
    }

    /// An answer saying nothing is running, for tests and for an early exit.
    /// - Parameter sessionId: the session it is about.
    /// - Returns: an empty answer.
    public static func empty(sessionId: String) -> SessionActivityResult {
        SessionActivityResult(sessionId: sessionId)
    }

    /// Whether a turn is running, and therefore whether an answer is worth
    /// keeping.
    public var hasRunningTurn: Bool { turn != nil }
}

// MARK: - The call

public extension MizarConnection {
    /// Read the running turn's compact process details.
    ///
    /// Paid accounts only, by product decision: the app checks the plan before
    /// asking. This method itself does not know about plans -- it is the wire
    /// call, and a host that does not implement it answers `NOT_IMPLEMENTED`,
    /// which the app treats as "no detail feed" rather than as an error worth
    /// showing.
    ///
    /// - Parameters:
    ///   - sessionId: the session to read.
    ///   - maxEntries: how many entries to ask for; omitted lets the host use
    ///     its default (200) and its own caps.
    ///   - beforeSeq: read the page before this log position instead of the
    ///     newest one -- the lazy-loading read for a long turn. Requires
    ///     `turn`; a host from before this field existed ignores both and
    ///     answers the newest page, which the caller detects as no progress.
    ///   - turn: the running turn an older page belongs to, echoed by the host.
    /// - Returns: the running turn's details.
    /// - Throws: ``MizarError`` when the host refuses, or a timeout.
    func sessionActivity(
        sessionId: String,
        maxEntries: Int? = nil,
        beforeSeq: Int? = nil,
        turn: Int? = nil,
    ) async throws -> SessionActivityResult {
        var fields: [String: JSONValue] = ["sessionId": .string(sessionId)]
        if let maxEntries { fields["maxEntries"] = .number(Double(maxEntries)) }
        if let beforeSeq {
            fields["beforeSeq"] = .number(Double(beforeSeq))
            if let turn { fields["turn"] = .number(Double(turn)) }
        }
        return try await call("session.activity", payload: .object(fields), as: SessionActivityResult.self)
    }
}
