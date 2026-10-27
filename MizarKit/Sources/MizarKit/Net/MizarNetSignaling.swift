//
//  MizarNetSignaling.swift
//  MizarKit
//
//  What two endpoints say to each other before they can talk directly.
//
//  Hole punching needs a side channel: the two peers must learn each other's
//  candidate addresses and agree on *when* to start sending, or the packets
//  cross in flight and both NATs drop them. That side channel is signaling,
//  and it is deliberately the only part of MizarNet that needs a server.
//
//  For DSH-Mizar the server already exists. The relay holds a long-lived
//  connection to the computer (the tunnel) and one to the phone (the bridged
//  room socket), and the room id is derived from the same token both ends
//  already present — so signaling rides the relay, addressed by room, and
//  costs one new frame type. That is why this file defines a *transport
//  protocol* rather than a relay client: the kernel does not care what
//  carries the bytes, only that they arrive in order.
//
//  The messages are small by construction — a hello is a key id plus a
//  handful of candidates, a few kilobytes at most — because they share the
//  relay's frame budget with the Mizar protocol itself.
//

import Foundation

/// One endpoint's announcement of itself.
public struct MizarNetHello: Sendable, Equatable, Codable {
    /// The announcing endpoint's id.
    public let endpointId: String
    /// The addresses it can be reached on, best first.
    public let candidates: [MizarNetCandidate]
    /// The pairing token, when the phone is the one announcing itself.
    ///
    /// The desktop's signal endpoint sits on the machine's whole network, so a
    /// channel that has not said who it is must not be told where this one is:
    /// the phone presents the same device token the Mizar handshake uses, and
    /// the desktop stays silent until it verifies. The desktop's own hello
    /// carries no token — by then the phone has already proved it belongs.
    public let token: String?

    public init(endpointId: String, candidates: [MizarNetCandidate], token: String? = nil) {
        self.endpointId = endpointId
        self.candidates = candidates
        self.token = token
    }
}

/// A signaling message.
///
/// The envelope is `{"v":1,"type":...}`; `v` mismatches are dropped by the
/// decoder's caller, the same tolerance the Mizar protocol itself has for
/// unknown frames. Adding a variant later is additive.
public enum MizarNetSignal: Sendable, Equatable {
    /// "I am this key, and here is where I am."
    case hello(MizarNetHello)
    /// "Here are more places I am." Sent after the hello when a STUN answer
    /// or a network change produces addresses the peer does not have yet.
    case candidates([MizarNetCandidate])
    /// "I am going away." Best-effort; a dead peer says nothing at all.
    case bye(reason: String)

    /// The signaling format version.
    public static let version = 1

    private enum CodingKeys: String, CodingKey {
        case v, type, endpointId, candidates, reason, token
    }
}

extension MizarNetSignal: Codable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.version, forKey: .v)
        switch self {
        case .hello(let hello):
            try container.encode("hello", forKey: .type)
            try container.encode(hello.endpointId, forKey: .endpointId)
            try container.encode(hello.candidates, forKey: .candidates)
            // Absent, not `null`, when there is no token: an old desktop reads
            // this frame too, and a key it does not know is the one shape it
            // already tolerates.
            try container.encodeIfPresent(hello.token, forKey: .token)
        case .candidates(let candidates):
            try container.encode("candidates", forKey: .type)
            try container.encode(candidates, forKey: .candidates)
        case .bye(let reason):
            try container.encode("bye", forKey: .type)
            try container.encode(reason, forKey: .reason)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .v)
        guard version == Self.version else {
            throw MizarNetError.signalingFailed(reason: "unsupported version \(version)")
        }
        switch try container.decode(String.self, forKey: .type) {
        case "hello":
            let hello = MizarNetHello(
                endpointId: try container.decode(String.self, forKey: .endpointId),
                candidates: try container.decodeIfPresent([MizarNetCandidate].self, forKey: .candidates) ?? [],
                token: try container.decodeIfPresent(String.self, forKey: .token),
            )
            self = .hello(hello)
        case "candidates":
            self = .candidates(try container.decodeIfPresent([MizarNetCandidate].self, forKey: .candidates) ?? [])
        case "bye":
            self = .bye(reason: try container.decode(String.self, forKey: .reason))
        default:
            throw MizarNetError.signalingFailed(reason: "unknown signal type")
        }
    }
}

/// The JSON text form used on the wire.
enum MizarNetSignalingJSON {
    static func encode(_ signal: MizarNetSignal) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(signal)
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func decode(_ text: String) throws -> MizarNetSignal {
        guard let data = text.data(using: .utf8) else {
            throw MizarNetError.signalingFailed(reason: "not utf-8")
        }
        return try JSONDecoder().decode(MizarNetSignal.self, from: data)
    }
}

/// Whatever carries signaling bytes.
///
/// One consumer by design: ``MizarNetConnection`` drains the stream. An
/// `AsyncStream` has a single iterator, which is exactly the ownership the
/// kernel wants — the connection owns the signaling channel for its lifetime.
public protocol MizarNetSignalingTransport: Sendable {
    /// Send one signal.
    func send(_ signal: MizarNetSignal) async throws
    /// The signals arriving from the peer.
    func signals() -> AsyncStream<MizarNetSignal>
    /// Close the channel.
    func close() async
}

/// Signaling over any ``WebSocketTransport``.
///
/// The relay's signal endpoint (a room-scoped WebSocket that forwards opaque
/// frames to the other side) is not deployed yet, so this actor takes the
/// socket as a parameter rather than building one: it is testable against the
/// scripted stub today, and wiring it to `URLSessionWebSocketTransport` when
/// the relay ships is a two-line change at the call site.
///
/// The pump task exists because a `WebSocketTransport` answers one frame per
/// `receive()` call while the kernel wants a stream; this actor is the
/// adapter between the two shapes.
public actor WebSocketSignalingTransport: MizarNetSignalingTransport {
    private let socket: any WebSocketTransport
    /// The stream is a constant, so handing it out crosses no isolation
    /// boundary: `signals()` is `nonisolated` for exactly that reason.
    private nonisolated let stream: AsyncStream<MizarNetSignal>
    private let continuation: AsyncStream<MizarNetSignal>.Continuation
    private var pump: Task<Void, Never>?
    private var closed = false

    /// Wrap a socket.
    /// - Parameter socket: the (not yet connected) socket to carry signals.
    public init(socket: any WebSocketTransport) {
        self.socket = socket
        let made = AsyncStream<MizarNetSignal>.makeStream(of: MizarNetSignal.self, bufferingPolicy: .unbounded)
        self.stream = made.stream
        self.continuation = made.continuation
    }

    /// Connect the underlying socket and start pumping frames into signals.
    public func open(url: URL, headers: [String: String] = [:]) async throws {
        guard pump == nil, !closed else { return }
        try await socket.connect(url: url, headers: headers)
        let socket = self.socket
        let continuation = self.continuation
        pump = Task.detached {
            while true {
                let text: String?
                do {
                    text = try await socket.receive()
                } catch {
                    // A transport failure ends the channel: there is no
                    // reconnect here because the *connection* owns retry
                    // policy, and a signaling channel that silently skips
                    // messages is worse than one that reports itself gone.
                    break
                }
                guard let text else { break }
                if let signal = try? MizarNetSignalingJSON.decode(text) {
                    continuation.yield(signal)
                }
                // An undecodable frame is dropped, not fatal: the relay may
                // one day multiplex other traffic on the same socket.
            }
            continuation.finish()
        }
    }

    public func send(_ signal: MizarNetSignal) async throws {
        guard !closed else {
            throw MizarNetError.signalingFailed(reason: "the channel is closed")
        }
        try await socket.send(text: try MizarNetSignalingJSON.encode(signal))
    }

    public nonisolated func signals() -> AsyncStream<MizarNetSignal> {
        stream
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        pump?.cancel()
        pump = nil
        await socket.close()
        continuation.finish()
    }
}
