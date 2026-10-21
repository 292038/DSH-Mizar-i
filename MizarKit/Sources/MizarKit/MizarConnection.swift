//
//  MizarConnection.swift
//  MizarKit
//
//  The authenticated client.
//
//  One socket carries everything: unary calls are correlated by the `id` echo,
//  and the host pushes interactions (approvals, questions) as unsolicited
//  `event` frames on the same connection. There is no second channel to keep in
//  sync, which is what makes a phone recovering from the background a matter of
//  one reconnect rather than a set of independent recoveries.
//
//  Two properties are deliberate:
//
//  - **A request always settles.** Every call is bounded; a host that stops
//    answering produces a timeout error rather than a task that hangs forever,
//    and the pending continuation is resumed exactly once on every path.
//  - **Unknown frames do not break the socket.** A host newer than the app may
//    send a frame type this build has never heard of; it is delivered as
//    `.unknown` and ignored rather than failing to decode and tearing down the
//    connection.
//

import Foundation

/// The authenticated Mizar client.
public actor MizarConnection {
    /// How to reach the host.
    public struct Configuration: Sendable {
        /// `host:port`, or `nil` when the host is only reachable through a relay.
        public var authority: String?
        /// Base URL of a reverse tunnel, when the host is behind one.
        public var baseURL: String?
        /// The device token from pairing.
        public var token: String
        /// Whether to use `wss`.
        public var secure: Bool
        /// Reported to the host at `hello`, for the device roster.
        public var appVersion: String?
        /// Reported to the host at `hello`.
        public var deviceModel: String?
        /// How long a unary call may take before it is failed.
        public var requestTimeout: Duration
        /// How long the handshake may take before it is failed.
        ///
        /// A socket that completes its upgrade and then says nothing leaves the
        /// app on "Connecting…" with nothing that can change it, so the wait for
        /// the welcome is bounded the same way a call is.
        public var handshakeTimeout: Duration
        /// Extra headers for the socket upgrade, when the route is a relay.
        ///
        /// The relay reads its traffic identity from two of these
        /// (``RelayIdentity/clientIdHeader`` and ``RelayIdentity/accountHeader``)
        /// and strips them before forwarding. They are empty for a direct
        /// connection, where nobody meters anything.
        public var relayHeaders: [String: String]

        public init(
            authority: String?,
            token: String,
            secure: Bool = false,
            appVersion: String? = nil,
            deviceModel: String? = nil,
            requestTimeout: Duration = .seconds(60),
            baseURL: String? = nil,
            handshakeTimeout: Duration = .seconds(20),
            relayHeaders: [String: String] = [:],
        ) {
            self.authority = authority
            self.token = token
            self.secure = secure
            self.appVersion = appVersion
            self.deviceModel = deviceModel
            self.requestTimeout = requestTimeout
            self.baseURL = baseURL
            self.handshakeTimeout = handshakeTimeout
            self.relayHeaders = relayHeaders
        }

        /// Which of the two routes this configuration names.
        ///
        /// A direct authority wins when there is one: it is the same network or
        /// the same tailnet, so it is faster and involves nobody else.
        public var endpoint: PairedHost.Endpoint? {
            if let authority, !authority.isEmpty { return .direct(authority: authority) }
            if let baseURL, !baseURL.isEmpty, PairingURI.isUsableBaseURL(baseURL) {
                return .relay(baseURL: baseURL)
            }
            return nil
        }
    }

    /// Where the connection is in its lifecycle.
    public enum State: Sendable, Equatable {
        case idle
        case connecting
        /// Handshaken; the host's welcome is available.
        case ready(WelcomeFrame)
        case failed(String)

        /// The welcome, when connected.
        public var welcome: WelcomeFrame? {
            if case .ready(let welcome) = self { return welcome }
            return nil
        }
    }

    private let configuration: Configuration
    private let makeTransport: @Sendable () -> WebSocketTransport

    private var transport: WebSocketTransport?
    private var receiveTask: Task<Void, Never>?
    private var state: State = .idle
    /// The sentence the peer closed with, when it sent one.
    ///
    /// The relay uses it for one thing the app must act on: `traffic allowance
    /// spent` means the day's bytes are gone, which is a different screen from
    /// "the network dropped".
    private var lastCloseReason: String?

    /// Unary calls awaiting their answer, keyed by correlation id.
    private var pending: [String: CheckedContinuation<JSONValue?, any Error>] = [:]
    /// Whoever is awaiting the handshake.
    private var handshake: CheckedContinuation<WelcomeFrame, any Error>?
    /// Live event subscribers.
    private var subscribers: [UUID: AsyncStream<ServerFrame>.Continuation] = [:]

    /// - Parameters:
    ///   - configuration: how to reach the host, and how patient to be.
    ///   - makeTransport: produces a fresh socket per connection attempt.
    ///     Injecting this is what makes the client testable without a network.
    public init(
        configuration: Configuration,
        makeTransport: @escaping @Sendable () -> WebSocketTransport = { URLSessionWebSocketTransport() },
    ) {
        self.configuration = configuration
        self.makeTransport = makeTransport
    }

    /// The current lifecycle state.
    public var currentState: State { state }

    // MARK: - Events

    /// A stream of unsolicited frames from the host.
    ///
    /// Each call gets its own stream. The stream finishes when the connection
    /// closes, so a consumer loop ends rather than waiting forever on a socket
    /// that is gone.
    ///
    /// A connection that is **already** closed finishes the stream at once, for
    /// the same reason: nothing will ever be delivered and nothing will ever
    /// close it again, so a subscriber that arrived a moment too late would
    /// otherwise wait for the life of the process. That is not a hypothetical
    /// race: the app subscribes from a `Task` started after `connect()` returns,
    /// and a socket that closes in between used to leave the listener alive
    /// forever.
    ///
    /// The sentence the peer closed with, or `nil` when it closed without one.
    ///
    /// The app reads this after the event stream ends: the relay closes a phone
    /// that has spent its daily traffic with `traffic allowance spent`, and that
    /// is a notice, not a network failure.
    ///
    /// - Returns: the close reason.
    public func closeReason() -> String? {
        lastCloseReason
    }

    /// - Returns: the stream.
    public func events() -> AsyncStream<ServerFrame> {        let id = UUID()
        return AsyncStream { continuation in
            if case .failed = state {
                continuation.finish()
                return
            }
            subscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(id) }
            }
        }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    // MARK: - Lifecycle

    /// Open the socket and complete the handshake.
    ///
    /// - Returns: the host's welcome frame.
    /// - Throws: when the socket, the handshake or the version check fails.
    @discardableResult
    public func connect() async throws -> WelcomeFrame {
        if let welcome = state.welcome { return welcome }
        state = .connecting

        guard let endpoint = configuration.endpoint else {
            let error = MizarError(code: "BAD_AUTHORITY", message: "no address to dial")
            state = .failed(error.message)
            throw error
        }
        let url: URL
        switch endpoint {
        case .direct(let authority):
            guard let direct = PairingURI.webSocketURL(authority: authority, secure: configuration.secure) else {
                let error = MizarError(code: "BAD_AUTHORITY", message: "cannot dial \(authority)")
                state = .failed(error.message)
                throw error
            }
            url = direct
        case .relay(let baseURL):
            guard let relayed = PairingURI.relayWebSocketURL(baseURL: baseURL) else {
                let error = MizarError(code: "BAD_AUTHORITY", message: "cannot dial \(baseURL)")
                state = .failed(error.message)
                throw error
            }
            url = relayed
        }

        let socket = makeTransport()
        transport = socket

        do {
            try await socket.connect(url: url, headers: configuration.relayHeaders)
        } catch {
            state = .failed(String(describing: error))
            throw error
        }

        // Start reading before sending `hello`: the welcome can arrive before
        // the send call returns, and a socket with no reader loses it.
        receiveTask = Task { [weak self] in
            await self?.receiveLoop(socket)
        }

        let hello = ClientFrame.hello(
            id: nil,
            token: configuration.token,
            appVersion: configuration.appVersion,
            deviceModel: configuration.deviceModel,
        )
        do {
            try await socket.send(text: try Self.encode(hello))
        } catch {
            state = .failed(String(describing: error))
            await closeSocket()
            throw error
        }

        do {
            return try await awaitHandshake()
        } catch {
            // This route is finished, so the socket goes with it. A half-open
            // socket left behind is one nobody reads and nobody closes, and the
            // caller is already dialling the next route.
            await closeSocket()
            state = .failed(Self.reason(error))
            throw error
        }
    }

    /// Wait for the welcome, tolerating one that already arrived.
    ///
    /// This is a race, not a formality. The read loop starts before `hello` is
    /// sent, so a fast host can deliver the welcome before `connect()` reaches
    /// its suspension point — and resuming a continuation that has not been
    /// stored yet is a silent no-op that hangs the caller forever. Equally, the
    /// socket can close in that window, which would leave the caller suspended
    /// on a connection that is already gone.
    ///
    /// The check-and-store inside the continuation body is atomic because the
    /// body runs synchronously on this actor, with no suspension point between
    /// reading the state and storing the continuation.
    ///
    /// Bounded, like every other wait in this file. A socket that completes its
    /// upgrade and then says nothing at all — a wedged host, or a relay that
    /// accepts the connection and forwards nothing — answers no read, so there
    /// is nothing else to time out: without a deadline here the caller waits for
    /// the life of the process and the screen behind it says "Connecting…" with
    /// no way out.
    ///
    /// - Returns: the host's welcome.
    private func awaitHandshake() async throws -> WelcomeFrame {
        if let outcome = settledHandshake() { return try outcome.get() }

        return try await withThrowingTaskGroup(of: WelcomeFrame.self) { group in
            group.addTask { try await self.suspendForHandshake() }
            group.addTask {
                try await Task.sleep(for: self.configuration.handshakeTimeout)
                throw MizarError(
                    code: "REQUEST_TIMEOUT",
                    message: "the host did not say hello in time",
                    retryable: true,
                )
            }

            do {
                guard let welcome = try await group.next() else {
                    throw MizarError(
                        code: "CONNECTION_CLOSED",
                        message: "the connection closed during the handshake",
                        retryable: true,
                    )
                }
                group.cancelAll()
                return welcome
            } catch {
                group.cancelAll()
                // Whoever is suspended on the handshake has to be resumed here
                // rather than after the group drains: a task group waits for
                // every child, and a continuation nothing will ever resume is a
                // child that never finishes.
                failHandshake(with: error)
                throw error
            }
        }
    }

    /// The outcome of the handshake, when it is already decided.
    /// - Returns: the welcome, the failure, or `nil` while it is still open.
    private func settledHandshake() -> Result<WelcomeFrame, any Error>? {
        if let welcome = state.welcome { return .success(welcome) }
        if case .failed(let reason) = state {
            return .failure(
                MizarError(code: "CONNECTION_CLOSED", message: reason, retryable: true),
            )
        }
        return nil
    }

    /// Store the continuation the welcome will resume, or settle it at once when
    /// the state moved while the task was being set up.
    /// - Returns: the host's welcome.
    private func suspendForHandshake() async throws -> WelcomeFrame {
        try await withCheckedThrowingContinuation { continuation in
            if let outcome = settledHandshake() {
                continuation.resume(with: outcome)
            } else {
                handshake = continuation
            }
        }
    }

    /// Resume a waiting handshake with a failure, once.
    /// - Parameter error: what to fail it with.
    private func failHandshake(with error: any Error) {
        guard let continuation = handshake else { return }
        handshake = nil
        continuation.resume(throwing: error)
    }

    /// Close the socket and fail anything still in flight.
    public func disconnect() async {
        await closeSocket()
    }

    /// Retry a failed connection until it succeeds or the task is cancelled.
    ///
    /// - Parameter backoff: the schedule to follow. Reset after each success.
    /// - Throws: `CancellationError` when the surrounding task is cancelled.
    public func connectWithRetry(backoff: Backoff = .standard) async throws {
        var schedule = backoff
        while !Task.isCancelled {
            do {
                try await connect()
                return
            } catch {
                let delay = schedule.nextDelay()
                try await Task.sleep(for: .seconds(delay))
            }
        }
        throw CancellationError()
    }

    // MARK: - Calls

    /// Send one request and await its answer.
    ///
    /// - Parameters:
    ///   - type: the wire method name.
    ///   - payload: the method's arguments, when it takes any.
    /// - Returns: the `result` of the `ok` frame, or `nil` when it carried none.
    /// - Throws: ``MizarError`` for a host-reported failure, or a timeout.
    public func request(_ type: String, payload: JSONValue? = nil) async throws -> JSONValue? {
        let id = UUID().uuidString
        let text = try Self.encode(ClientFrame.request(id: id, type: type, payload: payload))

        return try await withThrowingTaskGroup(of: JSONValue?.self) { group in
            group.addTask { try await self.sendAndAwait(id: id, text: text) }
            group.addTask {
                try await Task.sleep(for: self.configuration.requestTimeout)
                throw MizarError(
                    code: "REQUEST_TIMEOUT",
                    message: "\(type) did not answer in time",
                    retryable: true,
                )
            }

            do {
                let first = try await group.next() ?? nil
                group.cancelAll()
                self.abandon(id, reason: "call settled")
                return first
            } catch {
                group.cancelAll()
                // The waiting branch may still be suspended; resuming it here is
                // what keeps a timed-out call from leaking a task.
                self.abandon(id, reason: String(describing: error))
                throw error
            }
        }
    }

    /// A typed convenience over ``request(_:payload:)``.
    ///
    /// - Parameters:
    ///   - method: the wire method name.
    ///   - payload: the method's arguments.
    ///   - as: the model to decode the result into.
    /// - Returns: the decoded result.
    /// - Throws: ``MizarError`` when the host reported a failure, or a
    ///   `DecodingError` when the shape does not match.
    public func call<Result: Decodable & Sendable>(
        _ method: String,
        payload: JSONValue? = nil,
        as type: Result.Type,
    ) async throws -> Result {
        let value = try await request(method, payload: payload)
        guard let value, value != .null else {
            throw MizarError(
                code: "EMPTY_RESULT",
                message: "\(method) answered without a result",
            )
        }
        return try value.decoded(as: Result.self)
    }

    // MARK: - Internals

    private func sendAndAwait(id: String, text: String) async throws -> JSONValue? {
        try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task { [weak self] in
                guard let self else { return }
                do {
                    guard let socket = await self.transport else {
                        throw MizarError(code: "SOCKET_CLOSED", message: "the socket is not open", retryable: true)
                    }
                    try await socket.send(text: text)
                } catch {
                    await self.failPending(id: id, error: error)
                }
            }
        }
    }

    /// Resume a waiting call with a failure, once.
    private func failPending(id: String, error: any Error) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(throwing: error)
    }

    /// Resume a waiting call with an abandonment error, once.
    private func abandon(_ id: String, reason: String) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(
            throwing: MizarError(code: "REQUEST_ABANDONED", message: reason, retryable: true),
        )
    }

    /// Read frames until the socket closes, then tear down.
    private func receiveLoop(_ socket: WebSocketTransport) async {
        var failure: String?
        while !Task.isCancelled {
            do {
                guard let text = try await socket.receive() else { break }
                guard await route(text) else { return }
            } catch {
                if !Task.isCancelled { failure = String(describing: error) }
                break
            }
        }
        guard !Task.isCancelled else { return }
        await handleClosed(reason: failure)
    }

    /// Dispatch one decoded frame.
    ///
    /// - Parameter text: the raw frame body.
    /// - Returns: whether the read loop should continue.
    private func route(_ text: String) async -> Bool {
        let frame: ServerFrame
        do {
            frame = try JSONDecoder().decode(ServerFrame.self, from: Data(text.utf8))
        } catch let error as MizarError {
            // A version mismatch is fatal for this socket: continuing would mean
            // reading fields this build misinterprets. Returning false stops the
            // read loop rather than leaving it reading an abandoned socket.
            await handleClosed(reason: error.message)
            return false
        } catch {
            // A frame that will not decode is not fatal. Dropping one is better
            // than tearing down a working connection over it.
            return true
        }

        switch frame {
        case .welcome(let welcome):
            state = .ready(welcome)
            handshake?.resume(returning: welcome)
            handshake = nil

        case .ok(let id, let result):
            // An answer nobody is waiting for is dropped, not fatal.
            pending.removeValue(forKey: id)?.resume(returning: result)

        case .failure(let error, let id):
            if let id, let continuation = pending.removeValue(forKey: id) {
                continuation.resume(throwing: error)
            } else {
                // An uncorrelated failure — the host refused something the
                // client did not ask for, or a socket-level complaint. Telling
                // subscribers is the only way an operator ever sees it.
                for continuation in subscribers.values {
                    continuation.yield(frame)
                }
            }

        case .event, .unknown:
            for continuation in subscribers.values {
                continuation.yield(frame)
            }
        }
        return true
    }

    /// Fail everything in flight and tell subscribers the stream ended.
    private func handleClosed(reason: String?) async {
        let message = reason ?? "the host closed the connection"
        lastCloseReason = message
        state = .failed(message)

        if let continuation = handshake {
            handshake = nil
            continuation.resume(
                throwing: MizarError(code: "CONNECTION_CLOSED", message: message, retryable: true),
            )
        }

        for (id, continuation) in pending {
            pending.removeValue(forKey: id)
            continuation.resume(
                throwing: MizarError(code: "CONNECTION_CLOSED", message: message, retryable: true),
            )
        }

        for continuation in subscribers.values {
            continuation.finish()
        }
        subscribers.removeAll()

        transport = nil
    }

    /// Close the socket and fail anything in flight.
    private func closeSocket() async {
        receiveTask?.cancel()
        receiveTask = nil
        let socket = transport
        transport = nil
        await socket?.close()
        await handleClosed(reason: "disconnected")
    }

    private static func encode(_ frame: ClientFrame) throws -> String {
        let data = try JSONEncoder().encode(frame)
        guard let text = String(data: data, encoding: .utf8) else {
            throw MizarError(code: "ENCODE_FAILED", message: "frame was not valid UTF-8")
        }
        return text
    }

    /// An error as the state carries it.
    ///
    /// The host's own words when it is a ``MizarError``, because that is what the
    /// failure screen shows; the full description otherwise, which is all a
    /// transport failure has.
    ///
    /// - Parameter error: what went wrong.
    /// - Returns: text for the state.
    private static func reason(_ error: any Error) -> String {
        (error as? MizarError)?.message ?? String(describing: error)
    }
}
