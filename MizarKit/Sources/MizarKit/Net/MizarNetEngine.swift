//
//  MizarNetEngine.swift
//  MizarKit
//
//  The boundary between MizarNet and whatever punches the hole.
//
//  This protocol is the whole reason the kernel can live inside MizarKit
//  without deciding anything about QUIC, UDP sockets, or the Rust core that
//  is planned as the production engine: an engine is a thing that can dial a
//  ticket, hand out streams, and report its health. The loopback engine in
//  the tests satisfies it with two in-memory pipes; a QUIC engine will
//  satisfy it with sockets and a punch state machine; both drive the same
//  connection, the same transport seam and the same tests.
//
//  Every method is async and every engine is an actor. That is deliberate:
//  a punch involves waits measured in round trips, and an engine that blocks
//  a caller while it waits would block the connection actor that owns it.
//

import Foundation

/// Which path a stream is carried on.
public enum MizarNetPathKind: String, Sendable, Codable, CaseIterable {
    /// A local network — the LAN case.
    case lan
    /// A punched direct path across NATs.
    case p2p
    /// A relay — the always-works fallback.
    case relay
}

/// What a connection intends to do with its engine.
///
/// The acceptor punch only runs for an accepting connection. Both sides
/// hear each other's hello over signaling, so "somebody announced
/// themselves" does not say which side dialled — without this, a dialer
/// would punch back at its own dial and the two would fight over the
/// engine's one active punch.
public enum MizarNetIntent: Sendable {
    /// We are dialling the far endpoint.
    case dial
    /// We are waiting to be dialled.
    case accept
}

/// What the engine makes of the path it is on.
public enum MizarNetHealth: Sendable, Equatable {
    /// The path is carrying traffic; the round trip is what it is.
    case healthy(rttMilliseconds: Int)
    /// The path is up but measurably bad.
    case degraded(rttMilliseconds: Int, lossPercent: Int)
    /// The engine cannot tell yet — a freshly dialled path, or one that has
    /// not carried anything worth measuring.
    case unknown

    /// Whether the engine considers this fit to keep using.
    ///
    /// `unknown` is *not* unhealthy: a path that has not been measured yet is
    /// not evidence of a problem, and treating it as such would downgrade
    /// every connection the moment it came up.
    public var isHealthy: Bool {
        if case .healthy = self { return true }
        return false
    }
}

/// A reliable, ordered, **message-preserving** bidirectional channel.
///
/// The Mizar protocol is text frames over a socket, so the kernel's job is
/// exactly this: a message in, the same message out, in order, or an honest
/// `nil` when the peer is gone. Message boundaries are preserved — the
/// transport above sends one frame per `send` and reads one frame per
/// `receive`, and a byte stream would force it to re-frame the protocol it
/// is carrying. A QUIC stream satisfies this with a length prefix; so does
/// a pipe.
public protocol MizarNetStream: Sendable {
    /// Which kind of path this stream is carried on.
    var pathKind: MizarNetPathKind { get async }
    /// Send bytes.
    func send(_ data: Data) async throws
    /// Await the next bytes.
    ///
    /// - Returns: the data, or `nil` when the peer closed the stream.
    /// - Throws: on a transport failure.
    func receive() async throws -> Data?
    /// Close the stream.
    func close() async
}

/// What the kernel needs from a connectivity engine.
public protocol MizarNetEngine: Sendable {
    /// This engine's identity. Fixed for the engine's lifetime.
    var identity: MizarNetIdentity { get async }

    /// Start the engine. Idempotent: a second call is a no-op.
    func start() async throws

    /// Stop the engine and release whatever it holds.
    func shutdown() async

    /// Dial the endpoint a ticket names.
    ///
    /// - Parameters:
    ///   - ticket: what to dial.
    ///   - timeout: the budget for the whole attempt, punch included. An
    ///     engine that respects it makes the connection's own timeout a
    ///     backstop rather than the only bound.
    /// - Returns: a connected stream.
    /// - Throws: ``MizarNetError`` — `dialTimeout` when the budget ran out,
    ///   `punchFailed` when the attempt was made and did not land.
    func dial(ticket: MizarNetTicket, timeout: Duration) async throws -> any MizarNetStream

    /// The streams peers dial *into* this engine on.
    ///
    /// Single-consumer, like signaling: one accept loop drains it.
    func incomingStreams() async -> AsyncStream<any MizarNetStream>

    /// The addresses this endpoint can be reached on right now.
    func localCandidates() async -> [MizarNetCandidate]

    /// Addresses the peer announced. The engine decides what to do with
    /// them; usually that means trying them, in priority order.
    func offerCandidates(_ candidates: [MizarNetCandidate]) async

    /// The network changed — Wi-Fi to cellular, a new LAN address, a VPN
    /// coming up. An engine with multipath migrates; one without re-gathers
    /// its candidates and lets the next dial start over.
    func networkChanged() async

    /// The engine's read on the paths it is holding.
    func health() async -> MizarNetHealth

    /// What the connection intends to do, before anything is sent.
    ///
    /// Called once, at the top of ``MizarNetConnection/connect()`` or
    /// ``MizarNetConnection/accept()``. An engine that has not been told
    /// assumes nothing: it will not punch back at a peer it merely heard
    /// about.
    func noteIntent(_ intent: MizarNetIntent) async
}

/// Everything the kernel can get wrong that is its own fault.
///
/// Each case maps to a Mizar protocol error code through ``mizarError``,
/// because these errors cross the ``WebSocketTransport`` boundary where the
/// app's diagnosis layer only speaks Mizar error codes.
public enum MizarNetError: Error, Sendable, Equatable {
    /// The engine was used before `start()`, or after `shutdown()`.
    case engineNotStarted
    /// A ticket could not be parsed or names something impossible.
    case ticketInvalid(reason: String)
    /// The dial budget ran out.
    case dialTimeout(path: MizarNetPathKind)
    /// The punch was attempted and failed.
    case punchFailed(reason: String)
    /// A stream the kernel was holding went away.
    case streamClosed
    /// Signaling could not be used.
    case signalingFailed(reason: String)
    /// The connection was closed underneath an await.
    case cancelled
    /// The connection is already up.
    case alreadyReady
    /// Another dial is already in flight on this engine.
    case dialInFlight
    /// The socket could not be opened, bound or written to.
    case socketFailed(reason: String)
    /// The handshake completed but could not be trusted: a signature did
    /// not verify, or a packet did not decrypt.
    case handshakeFailed(reason: String)

    /// The error as a Mizar protocol error.
    ///
    /// The `P2P_*` codes are new and unknown to older hosts, which is fine:
    /// the protocol tolerates unknown codes on the wire, and these are
    /// client-side failures that never reach a host at all.
    public var mizarError: MizarError {
        switch self {
        case .engineNotStarted:
            return MizarError(code: "P2P_NOT_STARTED", message: "the engine was not started", retryable: true)
        case .ticketInvalid:
            return MizarError(code: "P2P_TICKET_INVALID", message: "the ticket could not be used", retryable: false)
        case .dialTimeout:
            return MizarError(code: "P2P_TIMEOUT", message: "the dial budget ran out", retryable: true)
        case .punchFailed:
            return MizarError(code: "P2P_FAILED", message: "the direct attempt failed", retryable: true)
        case .streamClosed:
            return MizarError(code: "SOCKET_CLOSED", message: "the stream closed", retryable: true)
        case .signalingFailed:
            return MizarError(code: "P2P_SIGNALING", message: "signaling failed", retryable: true)
        case .cancelled:
            return MizarError(code: "SOCKET_CLOSED", message: "the connection was closed", retryable: true)
        case .alreadyReady:
            return MizarError(code: "SOCKET_CLOSED", message: "the connection is already up", retryable: false)
        case .dialInFlight:
            return MizarError(code: "P2P_BUSY", message: "another dial is in flight", retryable: true)
        case .socketFailed:
            return MizarError(code: "P2P_SOCKET", message: "the socket failed", retryable: true)
        case .handshakeFailed:
            return MizarError(code: "P2P_HANDSHAKE", message: "the handshake could not be trusted", retryable: true)
        }
    }
}
