//
//  MizarNetQUICEngine.swift
//  MizarKit
//
//  The real engine: UDP sockets, STUN discovery, synchronized punching.
//
//  What happens, end to end:
//
//  1. `start()` binds one UDP socket — one port for the engine's whole
//     life, because a NAT mapping is per socket and the punch depends on
//     the port holding still — and gathers candidates: every IPv4 address
//     on the machine as a host candidate, plus the server-reflexive
//     address a STUN server reports.
//  2. `dial(ticket:)` sends a ClientHello — the punch packet — to every
//     candidate pair: our addresses against the ones the ticket and
//     signaling offered. Rounds repeat on a short interval, which is what
//     absorbs the two peers' timing skew; libp2p's DCUtR does it with an
//     RTT/2 sync, this does it with repetition, and repetition needs no
//     shared clock.
//  3. The acceptor's engine sees a ClientHello, verifies the Ed25519
//     signature binding the claimed endpoint id, answers with a ServerHello
//     from the address the hello arrived on, and hands the session to
//     `incomingStreams()`.
//  4. Both sides run the ephemeral-ephemeral agreement, derive one key per
//     direction, and the session — reliable, ordered, message-preserving —
//     takes over. The Mizar protocol never knew any of this happened.
//
//  The socket is shared: the connection id in every packet demultiplexes,
//  so one engine carries every session it opens, and STUN responses are
//  told apart from ours by the RFC's magic cookie.
//
//  Two honest limitations, both documented rather than designed away:
//  simultaneous open (both sides dialling each other) is not a supported
//  topology — the phone dials, the desktop accepts; and an established
//  session does not migrate when the network changes, it degrades and the
//  layer above reconnects with fresh candidates.
//

import CryptoKit
import Foundation

/// A dial in progress.
private struct ActiveDial {
    let connectionId: UInt64
    /// The endpoint the ticket named — used to spot a duplicate session
    /// after a simultaneous open.
    let remoteEndpointId: String
    /// Our ephemeral key for this attempt. Held so the session can be built
    /// the moment the far hello arrives.
    let ephemeral: Curve25519.KeyAgreement.PrivateKey
    /// Every address to send the hello to, best pair first.
    let remote: [MizarNetSocketAddress]
    let deadline: ContinuousClock.Instant
    /// The hello, built once — every round sends the same bytes.
    let hello: Data
}

/// The production engine.
public actor MizarNetQUICEngine: MizarNetEngine {
    public nonisolated let identity: MizarNetIdentity

    private let policy: MizarNetPathPolicy
    private let stunServers: [String]

    private let incoming: AsyncStream<any MizarNetStream>
    private let incomingContinuation: AsyncStream<any MizarNetStream>.Continuation

    private var socket: MizarNetUDPSocket?
    private var started = false
    private var hostCandidates: [MizarNetCandidate] = []
    private var reflexiveCandidates: [MizarNetCandidate] = []
    private var offeredCandidates: [MizarNetCandidate] = []
    private var sessions: [UInt64: MizarNetSession] = [:]
    private var sessionOrder: [UInt64] = []
    private var activeDial: ActiveDial?
    private var dialOutcomes: [UInt64: Result<any MizarNetStream, MizarNetError>] = [:]
    private var punchTasks: [UInt64: Task<Void, Never>] = [:]
    private var pendingSTUN: [Data: String] = [:]
    private var stunResults: [String: MizarNetSocketAddress] = [:]
    private var receiveTask: Task<Void, Never>?

    /// The public STUN servers tried when none are configured.
    ///
    /// Google's are the usual default and the right *default* — but this
    /// project deploys its own relay, and a self-hosted coturn STUN endpoint
    /// is the intended steady state: no third party learns when a phone
    /// opens a session. Pass your own list and these are never contacted.
    public static let defaultSTUNServers = [
        "stun.l.google.com:19302",
        "stun1.l.google.com:19302",
    ]

    /// An engine.
    ///
    /// - Parameters:
    ///   - identity: this endpoint's identity.
    ///   - policy: the numbers.
    ///   - stunServers: `host:port` of the STUN servers to ask, in order.
    ///     Empty means host candidates only — a LAN-only configuration.
    public init(
        identity: MizarNetIdentity,
        policy: MizarNetPathPolicy = .standard,
        stunServers: [String] = MizarNetQUICEngine.defaultSTUNServers,
    ) {
        self.identity = identity
        self.policy = policy
        self.stunServers = stunServers
        let made = AsyncStream<any MizarNetStream>.makeStream(of: (any MizarNetStream).self, bufferingPolicy: .unbounded)
        self.incoming = made.stream
        self.incomingContinuation = made.continuation
    }

    // MARK: - Lifecycle

    public func start() async throws {
        guard !started else { return }
        let socket = MizarNetUDPSocket()
        try await socket.bind(port: nil)
        self.socket = socket
        started = true
        startReceiveLoop()
        hostCandidates = await gatherHostCandidates()
        // Bounded: the punch budget is for punching, not for waiting on a
        // server this network may not reach.
        await gatherReflexiveCandidates()
    }

    public func shutdown() async {
        started = false
        receiveTask?.cancel()
        receiveTask = nil
        for task in punchTasks.values { task.cancel() }
        punchTasks.removeAll()
        activeDial = nil
        dialOutcomes.removeAll()
        for connectionId in Array(sessions.keys) {
            await sessions[connectionId]?.close()
        }
        sessions.removeAll()
        sessionOrder.removeAll()
        await socket?.close()
        socket = nil
    }

    // MARK: - MizarNetEngine

    public func dial(ticket: MizarNetTicket, timeout: Duration) async throws -> any MizarNetStream {
        guard started, socket != nil else { throw MizarNetError.engineNotStarted }
        if activeDial != nil { throw MizarNetError.dialInFlight }

        let remote = Self.remoteCandidates(offered: offeredCandidates, hints: ticket.direct)
        guard !remote.isEmpty else {
            throw MizarNetError.punchFailed(reason: "no candidate addresses to dial")
        }

        let connectionId = Self.randomConnectionId()
        let ephemeral = MizarNetCrypto.ephemeralKeyPair()
        let deadline = ContinuousClock.now.advanced(by: timeout)
        let hello: Data
        do {
            let message = MizarNetPunchPacket.handshakeMessage(
                type: .clientHello,
                connectionId: connectionId,
                ephemeralPublicKey: ephemeral.publicKey.rawRepresentation,
                endpointId: identity.endpointId,
            )
            hello = MizarNetPunchPacket.clientHello(
                connectionId: connectionId,
                endpointId: identity.endpointId,
                ephemeralPublicKey: ephemeral.publicKey.rawRepresentation,
                signature: try identity.sign(message),
            )
        } catch {
            throw MizarNetError.handshakeFailed(reason: "the hello could not be signed")
        }

        activeDial = ActiveDial(
            connectionId: connectionId,
            remoteEndpointId: ticket.endpointId,
            ephemeral: ephemeral,
            remote: remote,
            deadline: deadline,
            hello: hello,
        )
        punchTasks[connectionId] = Task.detached { [engine = self] in
            await engine.runPunchRounds(connectionId)
        }
        defer { cleanupDial(connectionId) }

        while ContinuousClock.now < deadline {
            if let outcome = dialOutcomes.removeValue(forKey: connectionId) {
                return try outcome.get()
            }
            try? await Task.sleep(for: .milliseconds(20))
            if Task.isCancelled { break }
        }
        if let outcome = dialOutcomes.removeValue(forKey: connectionId) {
            return try outcome.get()
        }
        // The engine's contract is that `dial` throws MizarNetError and
        // nothing else, so a cancelled wait — the connection's budget
        // expiring around us — reports as the timeout it is.
        throw MizarNetError.dialTimeout(path: .p2p)
    }

    public func incomingStreams() async -> AsyncStream<any MizarNetStream> {
        incoming
    }

    public func localCandidates() async -> [MizarNetCandidate] {
        MizarNetCandidate.sortedByPriority(hostCandidates + reflexiveCandidates)
    }

    public func offerCandidates(_ candidates: [MizarNetCandidate]) async {
        for candidate in candidates where offeredCandidates.count < 32 {
            if !offeredCandidates.contains(candidate) {
                offeredCandidates.append(candidate)
            }
        }
    }

    public func networkChanged() async {
        // Candidates are re-gathered so the *next* dial starts from what is
        // true now. Live sessions are left alone: migrating a session's
        // remote address is multipath work, and a session that dies with
        // the old network degrades honestly instead of being silently
        // re-homed.
        hostCandidates = await gatherHostCandidates()
        reflexiveCandidates.removeAll()
        await gatherReflexiveCandidates()
    }

    public func health() async -> MizarNetHealth {
        guard let connectionId = sessionOrder.last, let session = sessions[connectionId] else {
            return .unknown
        }
        return await session.health()
    }

    // MARK: - Punching

    private func runPunchRounds(_ connectionId: UInt64) async {
        guard let dial = activeDial, dial.connectionId == connectionId, let socket else { return }
        var round = 0
        while round < policy.punchRounds, ContinuousClock.now < dial.deadline {
            for address in dial.remote {
                try? await socket.send(dial.hello, to: address)
            }
            round += 1
            let remaining = dial.deadline - ContinuousClock.now
            let pause = min(policy.punchInterval, remaining)
            if pause > .zero {
                try? await Task.sleep(for: pause)
            }
        }
        // Only the loop that still owns the dial may fail it: a dial that
        // already completed, or one the caller gave up on, must not have
        // its outcome overwritten.
        guard activeDial?.connectionId == connectionId, dialOutcomes[connectionId] == nil else { return }
        dialOutcomes[connectionId] = .failure(.dialTimeout(path: .p2p))
    }

    // MARK: - Receive loop

    private func startReceiveLoop() {
        receiveTask?.cancel()
        guard let socket else { return }
        receiveTask = Task.detached { [engine = self] in
            // Sequential by construction: packet order into the sessions is
            // exactly the order the datagrams arrived in.
            for await datagram in socket.events {
                await engine.handleDatagram(datagram)
            }
        }
    }

    private func handleDatagram(_ datagram: MizarNetDatagram) async {
        if MizarNetSTUN.looksLikeSTUN(datagram.data) {
            handleSTUNResponse(datagram.data)
            return
        }
        guard let header = MizarNetPunchPacket.parseHeader(datagram.data) else { return }
        switch header.type {
        case .clientHello:
            await handleClientHello(datagram, header)
        case .serverHello:
            await handleServerHello(datagram, header)
        case .data, .ack, .keepalive, .close:
            await sessions[header.connectionId]?.receiveDatagram(datagram.data)
        }
    }

    /// A peer dialled us.
    ///
    /// The signature is the whole admission check: it proves the sender
    /// holds the private half of the endpoint id it claims, which is the
    /// trust the pairing established. There is no allow-list — any paired
    /// phone may dial any paired desktop — because the session key the
    /// hello leads to is bound to *these two* endpoint ids, and the Mizar
    /// protocol's own device-token check runs on top of it anyway.
    private func handleClientHello(_ datagram: MizarNetDatagram, _ header: MizarNetPacketHeader) async {
        guard let parsed = MizarNetPunchPacket.parseHello(datagram.data),
              parsed.header.type == .clientHello,
              let socket else { return }
        let handshake = parsed.handshake
        let message = MizarNetPunchPacket.handshakeMessage(
            type: .clientHello,
            connectionId: header.connectionId,
            ephemeralPublicKey: handshake.ephemeralPublicKey,
            endpointId: handshake.endpointId,
        )
        guard MizarNetIdentity.verify(signature: handshake.signature, message: message, endpointId: handshake.endpointId) else {
            return
        }

        if let existing = sessions[header.connectionId] {
            // A retransmitted hello for a session we already have: answer
            // again so the dialer completes even though the first answer
            // was lost.
            await answerHello(connectionId: header.connectionId, to: datagram.from, ephemeralPublicKey: existing.localEphemeralPublicKey)
            return
        }

        let session: MizarNetSession
        do {
            session = try MizarNetSession(
                role: .acceptor,
                connectionId: header.connectionId,
                remote: datagram.from,
                remoteEndpointId: handshake.endpointId,
                localEphemeral: MizarNetCrypto.ephemeralKeyPair(),
                remoteEphemeralPublicKey: handshake.ephemeralPublicKey,
                localEndpointId: identity.endpointId,
                socket: socket,
                policy: policy,
                onClose: { [weak self] id in await self?.removeSession(id) },
            )
        } catch {
            return
        }
        sessions[header.connectionId] = session
        sessionOrder.append(header.connectionId)
        await session.activate()
        await answerHello(connectionId: header.connectionId, to: datagram.from, ephemeralPublicKey: session.localEphemeralPublicKey)
        incomingContinuation.yield(session)
    }

    /// The far end answered our hello.
    private func handleServerHello(_ datagram: MizarNetDatagram, _ header: MizarNetPacketHeader) async {
        guard let dial = activeDial, dial.connectionId == header.connectionId else { return }
        guard let parsed = MizarNetPunchPacket.parseHello(datagram.data),
              parsed.header.type == .serverHello,
              let socket else { return }
        let handshake = parsed.handshake
        let message = MizarNetPunchPacket.handshakeMessage(
            type: .serverHello,
            connectionId: header.connectionId,
            ephemeralPublicKey: handshake.ephemeralPublicKey,
            endpointId: handshake.endpointId,
        )
        guard MizarNetIdentity.verify(signature: handshake.signature, message: message, endpointId: handshake.endpointId) else {
            completeDial(header.connectionId, .failure(.handshakeFailed(reason: "the acceptor's signature did not verify")))
            return
        }

        do {
            let session = try MizarNetSession(
                role: .dialer,
                connectionId: header.connectionId,
                remote: datagram.from,
                remoteEndpointId: handshake.endpointId,
                localEphemeral: dial.ephemeral,
                remoteEphemeralPublicKey: handshake.ephemeralPublicKey,
                localEndpointId: identity.endpointId,
                socket: socket,
                policy: policy,
                onClose: { [weak self] id in await self?.removeSession(id) },
            )
            sessions[header.connectionId] = session
            sessionOrder.append(header.connectionId)
            await session.activate()
            completeDial(header.connectionId, .success(session))
        } catch {
            completeDial(header.connectionId, .failure(.handshakeFailed(reason: "the agreement failed")))
        }
    }

    private func answerHello(connectionId: UInt64, to address: MizarNetSocketAddress, ephemeralPublicKey: Data) async {
        guard let socket else { return }
        guard let signature = try? identity.sign(MizarNetPunchPacket.handshakeMessage(
            type: .serverHello,
            connectionId: connectionId,
            ephemeralPublicKey: ephemeralPublicKey,
            endpointId: identity.endpointId,
        )) else { return }
        let packet = MizarNetPunchPacket.serverHello(
            connectionId: connectionId,
            endpointId: identity.endpointId,
            ephemeralPublicKey: ephemeralPublicKey,
            signature: signature,
        )
        try? await socket.send(packet, to: address)
    }

    private func completeDial(_ connectionId: UInt64, _ outcome: Result<any MizarNetStream, MizarNetError>) {
        dialOutcomes[connectionId] = outcome
        // A simultaneous open — both sides dialled — leaves one session per
        // side. The dial result is the one the connection will use; the
        // accepted duplicate to the same endpoint is closed here so it
        // cannot sit retransmitting into a socket nobody reads.
        guard case .success(let stream) = outcome,
              let session = stream as? MizarNetSession else { return }
        let duplicate = session.remoteEndpointId
        Task.detached { [engine = self] in
            for id in await engine.sessionOrder where id != connectionId {
                guard let candidate = await engine.sessions[id], candidate.remoteEndpointId == duplicate else { continue }
                await candidate.close()
            }
        }
    }

    private func cleanupDial(_ connectionId: UInt64) {
        if activeDial?.connectionId == connectionId {
            activeDial = nil
        }
        punchTasks[connectionId]?.cancel()
        punchTasks.removeValue(forKey: connectionId)
        dialOutcomes.removeValue(forKey: connectionId)
    }

    // MARK: - STUN

    private func gatherReflexiveCandidates() async {
        let deadline = ContinuousClock.now.advanced(by: policy.stunBudget)
        for server in stunServers {
            guard ContinuousClock.now < deadline, let socket else { continue }
            // A stale answer from an earlier gather must not short-circuit
            // the wait for this one.
            stunResults.removeValue(forKey: server)
            guard let resolved = await MizarNetUDPSocket.resolve(server) else { continue }
            let transactionId = MizarNetSTUN.randomTransactionId()
            pendingSTUN[transactionId] = server
            try? await socket.send(MizarNetSTUN.bindingRequest(transactionId: transactionId), to: resolved)
            while stunResults[server] == nil, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard let mapped = stunResults.removeValue(forKey: server) else { continue }
            let candidate = MizarNetCandidate(kind: .serverReflexive, address: mapped.ip, port: mapped.port)
            if !reflexiveCandidates.contains(candidate) {
                reflexiveCandidates.append(candidate)
            }
        }
    }

    private func handleSTUNResponse(_ data: Data) {
        guard let transactionId = MizarNetSTUN.transactionId(of: data),
              let server = pendingSTUN.removeValue(forKey: transactionId),
              let mapped = MizarNetSTUN.parseBindingResponse(data, expectedTransactionId: transactionId) else {
            return
        }
        stunResults[server] = MizarNetSocketAddress(ip: mapped.ip, port: mapped.port)
    }

    private func gatherHostCandidates() async -> [MizarNetCandidate] {
        guard let port = await socket?.localAddress?.port else { return [] }
        return MizarNetUDPSocket.hostAddresses().map {
            MizarNetCandidate(kind: .host, address: $0, port: port)
        }
    }

    // MARK: - Sessions

    private func removeSession(_ connectionId: UInt64) {
        sessions.removeValue(forKey: connectionId)
        sessionOrder.removeAll { $0 == connectionId }
    }

    // MARK: - Helpers

    /// The addresses to punch: what signaling offered, plus the ticket's
    /// own hints, best pair first, capped.
    private static func remoteCandidates(offered: [MizarNetCandidate], hints: [String]) -> [MizarNetSocketAddress] {
        var candidates: [MizarNetCandidate] = offered
        for hint in hints {
            let parts = hint.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let port = UInt16(parts[1]) else { continue }
            candidates.append(MizarNetCandidate(kind: .host, address: String(parts[0]), port: port))
        }
        var seen: Set<String> = []
        var addresses: [MizarNetSocketAddress] = []
        for candidate in MizarNetCandidate.sortedByPriority(candidates) {
            let key = "\(candidate.kind.wireName)|\(candidate.address)|\(candidate.port)"
            guard seen.insert(key).inserted else { continue }
            addresses.append(MizarNetSocketAddress(ip: candidate.address, port: candidate.port))
            if addresses.count >= 16 { break }
        }
        return addresses
    }

    private static func randomConnectionId() -> UInt64 {
        var bytes = Data(count: 8)
        _ = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, 8, buffer.baseAddress!)
        }
        return bytes.withUnsafeBytes { buffer in
            buffer.loadUnaligned(as: UInt64.self).bigEndian
        }
    }
}
