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
    /// Which kind of punch this is.
    enum Kind: Sendable {
        /// We are dialling, and somebody is waiting on the result.
        case dialer
        /// Somebody is dialling us; we learned their candidates from
        /// signaling and are punching back so their first hello has a
        /// filter entry to land in.
        case acceptorPunch
    }

    let kind: Kind
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
    private let injectedSocket: (any MizarNetDatagramSocket)?
    /// What to ask the router for, if anything.
    private let portMappingOptions: MizarNetPortMappingService.Options?
    /// A mapper supplied by the caller — how a test stands in for a router.
    private let injectedMapper: (any MizarNetPortMapper)?

    private let incoming: AsyncStream<any MizarNetStream>
    private let incomingContinuation: AsyncStream<any MizarNetStream>.Continuation

    private var socket: (any MizarNetDatagramSocket)?
    private var started = false
    private var hostCandidates: [MizarNetCandidate] = []
    private var reflexiveCandidates: [MizarNetCandidate] = []
    private var offeredCandidates: [MizarNetCandidate] = []
    private var sessions: [UInt64: MizarNetSession] = [:]
    private var sessionOrder: [UInt64] = []
    private var activeDial: ActiveDial?
    private var dialOutcomes: [UInt64: Result<any MizarNetStream, MizarNetError>] = [:]
    private var punchTasks: [UInt64: Task<Void, Never>] = [:]
    /// One commit per endpoint at a time, keyed by the endpoint being
    /// committed to.
    private var commitTasks: [String: Task<Void, Never>] = [:]
    /// Endpoints whose surviving session has already been offered to the
    /// incoming channel. One stream per endpoint.
    private var yieldedEndpoints: Set<String> = []
    private var pendingSTUN: [Data: String] = [:]
    private var stunResults: [String: MizarNetSocketAddress] = [:]
    private var receiveTask: Task<Void, Never>?
    /// The router mapping in force, if one was granted.
    private var mapper: (any MizarNetPortMapper)?
    /// The address a mapping was paired with — the STUN-observed one.
    private var mappedAddress: String?
    private var mappedCandidate: MizarNetCandidate?
    private var mappingTask: Task<Void, Never>?
    /// Whether the one-shot acceptor punch has been started. One shot is
    /// enough: it runs until a session exists or its window closes, and a
    /// second one would only duplicate the first.
    private var acceptorPunchStarted = false
    /// What the connection intends. `nil` until told — and an engine that
    /// has not been told does not punch back.
    private var intent: MizarNetIntent?

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
    ///   - socket: a socket to use instead of binding a fresh one. The NAT
    ///     matrix lab injects a simulated NAT here; production passes
    ///     nothing and gets a bound UDP socket.
    public init(
        identity: MizarNetIdentity,
        policy: MizarNetPathPolicy = .standard,
        stunServers: [String] = MizarNetQUICEngine.defaultSTUNServers,
        socket: (any MizarNetDatagramSocket)? = nil,
        portMapping: MizarNetPortMappingService.Options? = nil,
        portMapper: (any MizarNetPortMapper)? = nil,
    ) {
        self.identity = identity
        self.policy = policy
        self.stunServers = stunServers
        self.injectedSocket = socket
        self.portMappingOptions = portMapping
        self.injectedMapper = portMapper
        let made = AsyncStream<any MizarNetStream>.makeStream(of: (any MizarNetStream).self, bufferingPolicy: .unbounded)
        self.incoming = made.stream
        self.incomingContinuation = made.continuation
    }

    // MARK: - Lifecycle

    public func start() async throws {
        guard !started else { return }
        // An injected socket arrives already bound — a NAT front owns the
        // real sockets — and `bind` is a no-op there. A fresh socket binds
        // here, on an ephemeral port, and holds it for the engine's life.
        let socket = injectedSocket ?? MizarNetUDPSocket()
        try await socket.bind(port: nil)
        self.socket = socket
        started = true
        startReceiveLoop()
        hostCandidates = await gatherHostCandidates()
        // Bounded: the punch budget is for punching, not for waiting on a
        // server this network may not reach.
        await gatherReflexiveCandidates()
        await adoptPortMappingIfConfigured()
    }

    public func shutdown() async {
        started = false
        mappingTask?.cancel()
        mappingTask = nil
        if let mapper {
            // Delete the mapping rather than leaving it to expire: a forwarded
            // port nobody uses is a door left open on the router.
            await mapper.remove()
            await mapper.close()
            self.mapper = nil
        }
        receiveTask?.cancel()
        receiveTask = nil
        for task in punchTasks.values { task.cancel() }
        punchTasks.removeAll()
        for task in commitTasks.values { task.cancel() }
        commitTasks.removeAll()
        activeDial = nil
        dialOutcomes.removeAll()
        yieldedEndpoints.removeAll()
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

        let deadline = ContinuousClock.now.advanced(by: timeout)

        // The far side's punch can arrive before this dial starts — it is
        // sent the moment signaling hands it our candidates, which may be
        // while this side is still binding its socket. A session to the
        // ticket's endpoint is therefore already the connection, and
        // dialling again would only build a second one and a race over
        // which of the two the caller gets.
        if let already = adoptExistingSession(ticket.endpointId) { return already }

        // Candidates travel over signaling, so the list can legitimately be
        // empty for the few milliseconds between deciding to dial and the
        // peer's hello being consumed. Waiting briefly is the difference
        // between a connection and a "no candidates" failure the peer never
        // had a chance to prevent.
        var remote = Self.remoteCandidates(offered: offeredCandidates, hints: ticket.direct)
        if remote.isEmpty {
            let graceDeadline = min(deadline, ContinuousClock.now.advanced(by: policy.candidateGrace))
            while remote.isEmpty, ContinuousClock.now < graceDeadline {
                try? await Task.sleep(for: .milliseconds(20))
                if Task.isCancelled { break }
                remote = Self.remoteCandidates(offered: offeredCandidates, hints: ticket.direct)
            }
        }
        guard !remote.isEmpty else {
            throw MizarNetError.punchFailed(reason: "no candidate addresses to dial")
        }

        let connectionId = Self.randomConnectionId()
        let ephemeral = MizarNetCrypto.ephemeralKeyPair()
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
            kind: .dialer,
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
            // A session to the far endpoint beats any outcome the punch
            // bookkeeping may still be writing: it exists, it is one half of
            // the pair, and the caller asked for exactly that.
            if let already = adoptExistingSession(ticket.endpointId) { return already }
            if let outcome = dialOutcomes.removeValue(forKey: connectionId) {
                return try outcome.get()
            }
            try? await Task.sleep(for: .milliseconds(20))
            if Task.isCancelled { break }
        }
        // The budget is spent, but the far side's hello may have built a
        // session on its own — the symmetric-acceptor path, where our punch
        // could never land but theirs did. That session is the connection.
        if let already = adoptExistingSession(ticket.endpointId) { return already }
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
        // Somebody announced themselves over signaling. If we are the side
        // being dialled, this is the moment to punch back: their first hello
        // is already on its way, and a restricted or port-restricted filter
        // on our side will only let it in if we have sent to their address
        // first. libp2p's DCUtR synchronises both sides for exactly this
        // reason; ours does it by answering the signaling hello with a
        // punch rather than waiting to be reached.
        await startAcceptorPunchIfNeeded()
    }

    /// The one-shot punch from the side being dialled.
    private func startAcceptorPunchIfNeeded() async {
        guard intent != .dial,
              !acceptorPunchStarted,
              activeDial == nil,
              sessions.isEmpty,
              !offeredCandidates.isEmpty else { return }
        acceptorPunchStarted = true

        let connectionId = Self.randomConnectionId()
        let ephemeral = MizarNetCrypto.ephemeralKeyPair()
        let remote = Self.remoteCandidates(offered: offeredCandidates, hints: [])
        guard !remote.isEmpty else { return }
        let deadline = ContinuousClock.now.advanced(by: policy.acceptorPunchWindow)
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
            return
        }
        activeDial = ActiveDial(
            kind: .acceptorPunch,
            connectionId: connectionId,
            remoteEndpointId: "",
            ephemeral: ephemeral,
            remote: remote,
            deadline: deadline,
            hello: hello,
        )
        punchTasks[connectionId] = Task.detached { [engine = self] in
            await engine.runPunchRounds(connectionId)
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

    public func noteIntent(_ intent: MizarNetIntent) async {
        self.intent = intent
    }

    // MARK: - Punching

    private func runPunchRounds(_ connectionId: UInt64) async {
        guard let dial = activeDial, dial.connectionId == connectionId, let socket else { return }
        var round = 0
        while round < policy.punchRounds, ContinuousClock.now < dial.deadline {
            // A session already exists — the far side reached us, or our own
            // hello landed. Either way the punch's job is done.
            if dial.kind == .acceptorPunch {
                if !sessions.isEmpty { break }
            } else if sessions.values.contains(where: { $0.remoteEndpointId == dial.remoteEndpointId }) {
                break
            }
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
        // its outcome overwritten. And a commit still pending for this
        // endpoint means a session is on its way to the caller — the
        // symmetric-acceptor path, where our own punch never landed but the
        // far side's did — so this loop stays quiet and lets the commit
        // speak.
        guard activeDial?.connectionId == connectionId,
              dialOutcomes[connectionId] == nil,
              commitTasks[dial.remoteEndpointId] == nil else { return }
        if dial.kind == .acceptorPunch {
            // Nobody dialled in through our punch. The flag stays set: a
            // later hello over signaling may still start a fresh attempt.
            acceptorPunchStarted = false
            return
        }
        // A session to the far endpoint exists — or a commit is still
        // choosing between two — so this punch has nothing left to fail.
        // Writing a timeout here would beat the commit to the dial and turn
        // a connection that is already up into a reported failure.
        if sessions.values.contains(where: { $0.remoteEndpointId == dial.remoteEndpointId }) {
            return
        }
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
    ///
    /// Sessions form from exactly two events: a ClientHello we received, and
    /// a ServerHello answering a punch of ours. When both sides punch — the
    /// normal case once signaling has told each about the other — both
    /// events happen on both sides, and the pair would hold two sessions.
    /// ``reconcile(endpointId:)`` keeps that to one with the only rule both
    /// sides can compute identically: the smaller connection id wins. The
    /// dialer knows its own punch's id and the id of the hello it received;
    /// the acceptor knows the same two numbers from its side. No id lottery,
    /// no mirrored preference that can disagree.
    ///
    /// A session is not routed to its caller the moment it exists — it is
    /// committed after ``scheduleCommit(endpointId:)``, which waits until
    /// both kinds exist (the common case: both arrive within a round trip,
    /// so the wait is a few milliseconds) or the grace expires. The
    /// symmetric-acceptor case arrives through the same door: the dialer's
    /// punch can never reach a symmetric mapping, so only the punch-back
    /// session exists, the grace expires, and it becomes the connection —
    /// which is exactly the session the dialer fell back to.
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

        // A session with this connection id already exists — a retransmitted
        // or late hello — so re-answer it and create nothing.
        if let existing = sessions[header.connectionId] {
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
                fromOwnPunch: false,
                onClose: { [weak self] id in await self?.removeSession(id) },
            )
        } catch {
            return
        }
        sessions[header.connectionId] = session
        sessionOrder.append(header.connectionId)
        // Registered before the first await: a commit is a promise that this
        // session is on its way to a caller, and the punch loop reads that
        // promise to know it must not declare a timeout. Leaving a window
        // here is what turns a formed connection into a reported failure.
        scheduleCommit(endpointId: handshake.endpointId)
        await session.activate()
        await answerHello(connectionId: header.connectionId, to: datagram.from, ephemeralPublicKey: session.localEphemeralPublicKey)
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
            completeDial(header.connectionId, .failure(.handshakeFailed(reason: "the far signature did not verify")))
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
                fromOwnPunch: true,
                onClose: { [weak self] id in await self?.removeSession(id) },
            )
            sessions[header.connectionId] = session
            sessionOrder.append(header.connectionId)
            scheduleCommit(endpointId: handshake.endpointId)
            await session.activate()
        } catch {
            completeDial(header.connectionId, .failure(.handshakeFailed(reason: "the agreement failed")))
        }
    }

    // MARK: - Commit

    /// Route an endpoint's surviving session to whoever is waiting for it.
    ///
    /// One commit per endpoint at a time, and the wait ends the moment both
    /// kinds of session exist — so the common case costs milliseconds and
    /// only the genuinely one-sided cases wait out the grace.
    private func scheduleCommit(endpointId: String) {
        guard commitTasks[endpointId] == nil else { return }
        commitTasks[endpointId] = Task.detached { [engine = self] in
            let deadline = ContinuousClock.now.advanced(by: engine.policy.punchAnswerGrace)
            while !(await engine.hasBothKinds(endpointId)), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            await engine.commit(endpointId)
        }
    }

    private func hasBothKinds(_ endpointId: String) -> Bool {
        let toThisEndpoint = sessions.values.filter { $0.remoteEndpointId == endpointId }
        return toThisEndpoint.contains(where: { $0.fromOwnPunch })
            && toThisEndpoint.contains(where: { !$0.fromOwnPunch })
    }

    private func commit(_ endpointId: String) async {
        commitTasks.removeValue(forKey: endpointId)
        guard let keeper = reconcile(endpointId) else { return }
        if let dial = activeDial, dial.kind == .dialer, dial.remoteEndpointId == endpointId {
            completeDial(dial.connectionId, .success(keeper))
        } else if intent != .dial, !yieldedEndpoints.contains(endpointId) {
            // One stream per endpoint into the incoming channel: the
            // acceptor's accept() takes exactly one.
            yieldedEndpoints.insert(endpointId)
            incomingContinuation.yield(keeper)
        }
        // A side that is dialling — or has not decided yet — keeps the
        // session where it is. `dial` adopts it; handing it to the incoming
        // channel would put it in a queue nobody on a dialler reads.
    }

    /// The session a dial should adopt, when the far endpoint already has
    /// one.
    ///
    /// A dial that finds a session does not punch: the session came from the
    /// far side's hello (or from its answer to a previous punch), the keys
    /// are already agreed, and punching again would only race the session
    /// the caller is about to be handed. Reconciled first, because a
    /// simultaneous open leaves two and only one survives — adopting the
    /// loser would hand the caller a stream that is being closed.
    private func adoptExistingSession(_ endpointId: String) -> MizarNetSession? {
        guard sessions.values.contains(where: { $0.remoteEndpointId == endpointId }) else { return nil }
        return reconcile(endpointId)
    }

    /// One session per endpoint: the smaller connection id wins.
    ///
    /// Returns the keeper. Both sides of a simultaneous open hold the same
    /// two connection ids — each side's own punch and the hello it received
    /// — so both close the same loser without a word between them.
    @discardableResult
    private func reconcile(_ endpointId: String) -> MizarNetSession? {
        let toThisEndpoint = sessions.values.filter { $0.remoteEndpointId == endpointId }
        guard let keeper = toThisEndpoint.min(by: { $0.connectionId < $1.connectionId }) else { return nil }
        for session in toThisEndpoint where session.connectionId != keeper.connectionId {
            let connectionId = session.connectionId
            Task.detached { [engine = self] in
                await engine.sessions[connectionId]?.close()
            }
        }
        return keeper
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

    /// The dial's outcome. An acceptor punch never lands here — its session
    /// is offered to whoever is accepting after the grace, by
    /// ``offerPunchAnswer(_:)``.
    private func completeDial(_ connectionId: UInt64, _ outcome: Result<any MizarNetStream, MizarNetError>) {
        dialOutcomes[connectionId] = outcome
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
            do {
                try await socket.send(MizarNetSTUN.bindingRequest(transactionId: transactionId), to: resolved)
            } catch {
                // A request that cannot even be sent — an unreachable
                // address, a dead interface — is answered now, not after
                // the budget: waiting would only delay the punch.
                pendingSTUN.removeValue(forKey: transactionId)
                continue
            }
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

    // MARK: - Port mapping

    /// Ask the router for a forwarded port, if anybody configured one.
    private func adoptPortMappingIfConfigured() async {
        let candidate: (any MizarNetPortMapper)?
        if let injectedMapper {
            candidate = injectedMapper
        } else {
            candidate = await openConfiguredMapper()
        }
        guard let candidate else { return }
        await adopt(candidate)
    }

    private func openConfiguredMapper() async -> (any MizarNetPortMapper)? {
        guard let options = portMappingOptions, let socket else { return nil }
        let port = await socket.localAddress?.port ?? 0
        guard port != 0 else { return nil }
        return await MizarNetPortMappingService.open(port: port, options: options)
    }

    /// Adopt a granted mapping as a candidate.
    ///
    /// A mapping is only half an address: the port is what the router forwards,
    /// the address is what STUN saw. Pairing them is the point — the pair is
    /// reachable even when the NAT is symmetric, because the router is now
    /// forwarding instead of filtering.
    private func adopt(_ mapper: any MizarNetPortMapper) async {
        guard let external = reflexiveCandidates.first else {
            // No external address to pair the port with. The mapping would be a
            // door with no address on it, so hand it back rather than leak it.
            await mapper.remove()
            await mapper.close()
            return
        }
        var mapping = await mapper.current()
        if mapping == nil {
            guard let socketPort = await socket?.localAddress?.port else { return }
            mapping = try? await mapper.map(port: socketPort, lifetimeSeconds: portMappingOptions?.lifetimeSeconds ?? 0)
        }
        guard let mapping else {
            await mapper.close()
            return
        }
        self.mapper = mapper
        self.mappedAddress = external.address
        installMappedCandidate(address: external.address, port: mapping.externalPort)
        guard mapping.lifetimeSeconds > 0 else { return }
        // Renew at half the lease: a router that expires a mapping while a
        // session is using it looks exactly like a dead network.
        let interval = max(1, Int(mapping.lifetimeSeconds / 2))
        mappingTask = Task.detached { [engine = self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { break }
                await engine.renewMapping()
            }
        }
    }

    private func installMappedCandidate(address: String, port: UInt16) {
        if let previous = mappedCandidate {
            reflexiveCandidates.removeAll { $0 == previous }
        }
        // Local preference 1 puts it above the raw reflexive candidate it shares
        // a kind with: this one is forwarded, so it works from places that one
        // does not.
        let entry = MizarNetCandidate(kind: .serverReflexive, address: address, port: port, localPreference: 1)
        mappedCandidate = entry
        if !reflexiveCandidates.contains(entry) {
            reflexiveCandidates.append(entry)
        }
    }

    private func renewMapping() async {
        guard let mapper, let address = mappedAddress else { return }
        guard let renewed = try? await mapper.renew() else {
            // The router forgot us. Stop advertising a door that is no longer
            // there, and stop the timer: a router that refused once will refuse
            // again.
            mappingTask?.cancel()
            mappingTask = nil
            if let current = mappedCandidate {
                reflexiveCandidates.removeAll { $0 == current }
                mappedCandidate = nil
            }
            return
        }
        installMappedCandidate(address: address, port: renewed.externalPort)
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
