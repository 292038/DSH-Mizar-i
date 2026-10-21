//
//  WebSocketTransport.swift
//  MizarKit
//
//  The socket, behind a protocol.
//
//  `URLSessionWebSocketTask` cannot be used in a unit test — there is no host to
//  connect to — so the connection logic is written against this protocol and the
//  tests drive it with a scripted stub. That keeps reconnection, correlation and
//  frame routing under test without a network.
//

import Foundation

/// A minimal text WebSocket.
public protocol WebSocketTransport: Sendable {
    /// Open the socket.
    ///
    /// - Parameters:
    ///   - url: the endpoint to dial.
    ///   - headers: extra HTTP headers for the upgrade request. The relay reads
    ///     its traffic identity from two of these before forwarding; a direct
    ///     connection has nothing to read them and ignores them.
    /// - Throws: when the handshake fails.
    func connect(url: URL, headers: [String: String]) async throws

    /// Send one text frame.
    /// - Parameter text: the frame body.
    /// - Throws: when the socket is not open.
    func send(text: String) async throws

    /// Await the next text frame.
    /// - Returns: the frame body, or `nil` when the peer closed the socket.
    /// - Throws: on a transport failure.
    func receive() async throws -> String?

    /// Close the socket.
    func close() async
}

/// The real transport.
public actor URLSessionWebSocketTransport: WebSocketTransport {
    private let session: URLSession
    private var task: URLSessionWebSocketTask?

    /// The host owns the heartbeat: it pings on an interval and terminates a
    /// peer that misses one, and `URLSessionWebSocketTask` answers at the
    /// protocol layer without any code here. So there is nothing to send.
    ///
    /// - Parameter timeout: how long the handshake may take.
    public init(timeout: TimeInterval = 20) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        self.session = URLSession(configuration: configuration)
    }

    public func connect(url: URL, headers: [String: String]) async throws {
        // A `URLRequest` rather than the bare URL: the upgrade headers can only
        // be set on a task created from a request, and the relay's identity
        // headers are only meaningful on the upgrade.
        var request = URLRequest(url: url)
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
    }

    public func send(text: String) async throws {
        guard let task else {
            throw MizarError(code: "SOCKET_CLOSED", message: "the socket is not open", retryable: true)
        }
        try await task.send(.string(text))
    }

    public func receive() async throws -> String? {
        guard let task else { return nil }
        do {
            let message = try await task.receive()
            switch message {
            case .string(let text):
                return text
            case .data(let data):
                return String(data: data, encoding: .utf8)
            @unknown default:
                return nil
            }
        } catch {
            // A close inside the WebSocket protocol arrives as a generic
            // `receive()` failure, but the task still holds the code and reason
            // the peer sent. The relay uses that sentence to tell the app the
            // day's traffic is spent, which is the difference between "retry"
            // and "come back tomorrow".
            let reason = task.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            if reason.isEmpty { throw error }
            throw MizarError(code: "SOCKET_CLOSED", message: reason, retryable: true)
        }
    }

    public func close() async {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }
}
