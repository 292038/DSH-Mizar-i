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

/// An upgrade the far end answered with a status instead of `101`.
///
/// The relay refuses a socket this way on purpose: a room with no computer
/// attached is a `404`, and a paid gate is a `402`/`403`, both written as a raw
/// HTTP response before any handshake. `URLSessionWebSocketTask` reports all of
/// them as one `URLError.badServerResponse`, whose only sentence is "there was a
/// bad response from the server" -- true of a computer that is switched off and
/// of a server that cannot be reached, and useless for telling them apart.
///
/// The status is on the task's response, so it is kept here and carried out of
/// the transport. What the app says about it is decided in ``ConnectionDiagnosis``;
/// this type only remembers the number.
public struct WebSocketUpgradeRefused: Error, Sendable, Equatable {
    /// The HTTP status the far end answered with.
    public let status: Int
    /// The socket that was being dialled, when known.
    public let url: URL?

    public init(status: Int, url: URL? = nil) {
        self.status = status
        self.url = url
    }

    /// Whether the answer means "this room has no computer behind it".
    ///
    /// `404` is the relay's answer for a room with no live tunnel -- and
    /// deliberately the same answer for a room that never existed, so it cannot
    /// be used to enumerate which computers are online. `410` is the same
    /// statement in the vocabulary other proxies use.
    public var meansComputerAbsent: Bool { status == 404 || status == 410 }
}

extension WebSocketUpgradeRefused: LocalizedError {
    /// What to say when there is no route to explain it with.
    ///
    /// The diagnosis above is the sentence the app shows; this is the fallback
    /// for the places that only have `localizedDescription`, and it exists so
    /// those places do not print the type's name and an ordinal.
    public var errorDescription: String? {
        "The connection was refused with HTTP \(status)."
    }
}

/// The real transport.
public actor URLSessionWebSocketTransport: WebSocketTransport {
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    /// What this transport was last asked to dial.
    ///
    /// Kept only so a refusal can name the address it was refused at; the task
    /// itself does not expose the URL it was created from.
    private var dialed: URL?

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
        self.dialed = url
        task.resume()
    }

    public func send(text: String) async throws {
        guard let task else {
            throw MizarError(code: "SOCKET_CLOSED", message: "the socket is not open", retryable: true)
        }
        do {
            try await task.send(.string(text))
        } catch {
            // The upgrade is refused before the first frame is written, so this
            // is where a 404 from the relay usually surfaces.
            throw refused(error)
        }
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
            if reason.isEmpty { throw refused(error) }
            throw MizarError(code: "SOCKET_CLOSED", message: reason, retryable: true)
        }
    }

    /// The failure, as a refusal when the far end answered with a status.
    ///
    /// Only a status of 400 or above is a refusal: a socket that completed its
    /// upgrade and later failed carries `101` in the same place, and reading
    /// that as a refusal would turn every dropped connection into "the server
    /// said no".
    ///
    /// - Parameter error: what the task threw.
    /// - Returns: the error to throw instead.
    private func refused(_ error: any Error) -> any Error {
        guard error is URLError else { return error }
        guard let http = task?.response as? HTTPURLResponse, http.statusCode >= 400 else {
            return error
        }
        return WebSocketUpgradeRefused(status: http.statusCode, url: dialed)
    }

    public func close() async {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }
}
