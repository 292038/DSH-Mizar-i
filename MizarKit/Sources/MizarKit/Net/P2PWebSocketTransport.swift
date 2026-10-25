//
//  P2PWebSocketTransport.swift
//  MizarKit
//
//  A MizarNet connection as a `WebSocketTransport`.
//
//  This is the seam the whole kernel was shaped around. `MizarConnection`
//  needs four methods — connect, send, receive, close — and a socket that
//  behaves like the wire; the app's route policy, handshake, correlation and
//  event routing are all written against that protocol already. So a direct
//  connection is not a new connection layer: it is a new transport, chosen
//  the same way the local kernel is chosen, and the Mizar frames travel over
//  it unchanged.
//
//  The URL is `mizar-net://dial?t=<ticket>`. The scheme is deliberately not
//  `ws`/`wss`: nothing here speaks WebSocket, and a URL that looked like one
//  would invite a caller to dial it with the wrong transport. The headers
//  are accepted and ignored, exactly as ``LocalKernelTransport`` ignores
//  them — the relay's identity headers belong to the relay's transport, and
//  the direct path authenticates inside the protocol, with the device token
//  in the `hello` frame.
//

import Foundation

/// The `mizar-net://` URL forms.
public enum MizarNetDialURL {
    /// The scheme.
    public static let scheme = "mizar-net"
    /// The dial host.
    public static let host = "dial"

    /// Build the URL a ``P2PWebSocketTransport`` dials.
    ///
    /// - Parameter ticket: what to reach.
    /// - Returns: `mizar-net://dial?t=<base64url ticket>`.
    public static func make(ticket: MizarNetTicket) throws -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = [URLQueryItem(name: "t", value: try ticket.encode())]
        guard let url = components.url else {
            throw MizarNetError.ticketInvalid(reason: "the ticket does not form a URL")
        }
        return url
    }

    /// Read the ticket back out of a URL.
    ///
    /// - Parameter url: what ``P2PWebSocketTransport`` was asked to dial.
    /// - Returns: the ticket.
    /// - Throws: ``MizarNetError/ticketInvalid(reason:)`` for anything that is
    ///   not a dial URL with a `t` parameter.
    public static func ticket(from url: URL) throws -> MizarNetTicket {
        guard url.scheme == scheme else {
            throw MizarNetError.ticketInvalid(reason: "scheme is not \(scheme)")
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = url.path
        let isDial = components?.host == host || path == "/\(host)" || path == host
        guard isDial else {
            throw MizarNetError.ticketInvalid(reason: "host is not \(host)")
        }
        guard let encoded = components?.queryItems?.first(where: { $0.name == "t" })?.value else {
            throw MizarNetError.ticketInvalid(reason: "no t parameter")
        }
        return try MizarNetTicket.decode(encoded)
    }
}

/// A direct MizarNet connection, wearing the transport protocol.
public actor P2PWebSocketTransport: WebSocketTransport {
    private let makeEngine: @Sendable () -> any MizarNetEngine
    private let signaling: (any MizarNetSignalingTransport)?
    private var connection: MizarNetConnection?
    private var stream: (any MizarNetStream)?
    private var closed = false

    /// A transport.
    ///
    /// - Parameters:
    ///   - makeEngine: builds a fresh engine per `connect()`. A closure, not
    ///     an engine, for the same reason ``MizarConnection`` takes a
    ///     transport factory: a second dial must not inherit the first
    ///     attempt's sockets.
    ///   - signaling: the side channel, already open.
    public init(
        makeEngine: @escaping @Sendable () -> any MizarNetEngine,
        signaling: (any MizarNetSignalingTransport)? = nil,
    ) {
        self.makeEngine = makeEngine
        self.signaling = signaling
    }

    public func connect(url: URL, headers: [String: String]) async throws {
        guard !closed, stream == nil else {
            throw MizarError(code: "SOCKET_CLOSED", message: "the transport is already connected", retryable: true)
        }
        do {
            let ticket = try MizarNetDialURL.ticket(from: url)
            let connection = MizarNetConnection(
                engine: makeEngine(),
                ticket: ticket,
                signaling: signaling,
            )
            self.connection = connection
            let stream = try await connection.connect()
            self.stream = stream
        } catch let error as MizarNetError {
            // Everything the kernel can throw crosses this boundary as a
            // Mizar error: the diagnosis layer above only speaks that
            // vocabulary, and a raw kernel error would surface to the user
            // as a type name.
            await connection?.close()
            self.connection = nil
            throw error.mizarError
        }
    }

    public func send(text: String) async throws {
        guard !closed, let stream else {
            throw MizarError(code: "SOCKET_CLOSED", message: "the socket is not open", retryable: true)
        }
        do {
            try await stream.send(Data(text.utf8))
        } catch let error as MizarNetError {
            throw error.mizarError
        }
    }

    public func receive() async throws -> String? {
        guard !closed, let stream else { return nil }
        do {
            guard let data = try await stream.receive() else { return nil }
            return String(data: data, encoding: .utf8)
        } catch let error as MizarNetError {
            throw error.mizarError
        }
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        if let stream {
            await stream.close()
            self.stream = nil
        }
        await connection?.close()
        connection = nil
    }
}
