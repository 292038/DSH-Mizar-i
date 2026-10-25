//
//  MizarNetSession.swift
//  MizarKit
//
//  One session: a reliable, ordered, message-preserving channel over the
//  shared UDP socket.
//
//  This is the QUIC-shaped part of the engine — connection ids, packet
//  numbers as nonces, per-packet AEAD, ack-based reliability, keepalives —
//  implemented at the subset this deployment needs. It is deliberately not
//  a full RFC 9000 stack: no version negotiation, no crypto frames, no
//  flow-control windows beyond a bounded reorder buffer. What it does have
//  is the property that matters for a remote-control link: a message sent
//  is a message delivered, exactly once, in order, or the session says it
//  is unhealthy and the layer above falls back to the relay.
//
//  Reliability in one paragraph: every chunk gets a packet number; the
//  sender keeps the sealed bytes until an ack arrives and retransmits on a
//  doubling timer; the receiver acks what it delivers, buffers what arrives
//  early, and reassembles messages from their chunks. Congestion control is
//  absent on purpose — the traffic is request/response JSON at human
//  speeds, and a cubic window would add failure modes without adding
//  throughput that matters.
//

import CryptoKit
import Foundation

/// Which side of the handshake a session was built from. Decides key
/// direction, nothing else.
enum MizarNetSessionRole: Sendable {
    case dialer
    case acceptor
}

/// One session on the engine's socket.
public actor MizarNetSession: MizarNetStream {
    public nonisolated let pathKind: MizarNetPathKind = .p2p

    /// The connection id this session multiplexes under.
    public nonisolated let connectionId: UInt64
    /// The far endpoint's identity.
    public nonisolated let remoteEndpointId: String
    /// This side's ephemeral public key — what a ServerHello answers with,
    /// and what the far side agreed against.
    public nonisolated let localEphemeralPublicKey: Data

    private let role: MizarNetSessionRole
    private let socket: MizarNetUDPSocket
    private let remote: MizarNetSocketAddress
    private let sealKey: SymmetricKey
    private let openKey: SymmetricKey
    private let policy: MizarNetPathPolicy
    private let onClose: @Sendable (UInt64) async -> Void

    // Outgoing.
    private var outgoingPacketNumber: UInt32 = 0
    private var unacked: [UInt32: PendingPacket] = [:]

    // Incoming.
    private var expectedPacketNumber: UInt32 = 0
    private var reorderBuffer: [UInt32: BufferedChunk] = [:]
    private var incomingMessage: Data = Data()
    private var incomingMessageLength: Int?

    // Acks.
    private var recentReceived: [UInt32] = []
    private var receivedSet: Set<UInt32> = []
    private var ackDirty = false

    // Health.
    private var smoothedRTT: Double = 0
    private var lastReceivedAt = ContinuousClock.now
    private var idle = false
    private var stalled = false

    // Delivery.
    private var queued: [Data] = []
    private var waiters: [CheckedContinuation<Data?, Never>] = []

    private var closed = false
    private var timers: [Task<Void, Never>] = []

    /// A chunk waiting for its ack.
    private struct PendingPacket {
        let packet: Data
        let sentAt: ContinuousClock.Instant
        var attempts: Int
    }

    /// A chunk that arrived before its turn.
    private struct BufferedChunk {
        let messageLength: Int
        let chunk: Data
    }

    /// Build a session from a completed handshake.
    ///
    /// - Throws: ``MizarNetError/handshakeFailed(reason:)`` when the far
    ///   ephemeral key cannot be parsed — the caller has already verified
    ///   the signature by this point, so this is a malformed-key failure,
    ///   not a trust failure.
    init(
        role: MizarNetSessionRole,
        connectionId: UInt64,
        remote: MizarNetSocketAddress,
        remoteEndpointId: String,
        localEphemeral: Curve25519.KeyAgreement.PrivateKey,
        remoteEphemeralPublicKey: Data,
        localEndpointId: String,
        socket: MizarNetUDPSocket,
        policy: MizarNetPathPolicy,
        onClose: @escaping @Sendable (UInt64) async -> Void,
    ) throws {
        self.role = role
        self.connectionId = connectionId
        self.remote = remote
        self.remoteEndpointId = remoteEndpointId
        self.localEphemeralPublicKey = localEphemeral.publicKey.rawRepresentation
        self.socket = socket
        self.policy = policy
        self.onClose = onClose

        let remoteKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remoteEphemeralPublicKey)
        let sharedSecret = try localEphemeral.sharedSecretFromKeyAgreement(with: remoteKey)
        let keys = MizarNetCrypto.sessionKeys(
            sharedSecret: sharedSecret,
            salt: MizarNetCrypto.sessionSalt(localEndpointId: localEndpointId, remoteEndpointId: remoteEndpointId),
            localIsDialer: role == .dialer,
        )
        self.sealKey = keys.seal
        self.openKey = keys.open
    }

    /// Start the session's timers.
    ///
    /// Separate from `init` because an actor initialiser is a nonisolated
    /// context: the engine calls this the moment the session exists, before
    /// anything can send or receive on it, which is early enough that no
    /// packet can arrive at a session whose ack timer is not running yet.
    func activate() {
        startTimers()
    }

    // MARK: - Sending

    /// Send one message.
    ///
    /// The message is chunked to fit a datagram; the chunks are sealed,
    /// numbered and tracked until acked. Message boundaries survive: the
    /// receiver reassembles exactly this `Data` and nothing else.
    public func send(_ data: Data) async throws {
        guard !closed else { throw MizarNetError.streamClosed }
        if data.isEmpty {
            try await sendChunk(messageLength: 0, chunk: Data())
            return
        }
        var offset = 0
        while offset < data.count {
            let end = min(offset + policy.streamChunkBytes, data.count)
            try await sendChunk(messageLength: data.count, chunk: data[offset..<end])
            offset = end
        }
    }

    private func sendChunk(messageLength: Int, chunk: Data) async throws {
        let packetNumber = outgoingPacketNumber
        outgoingPacketNumber = outgoingPacketNumber &+ 1

        let acks = piggybackedAcks()
        // The header's length field is part of the authenticated data, and
        // the authenticated data is part of the sealed bytes — so the
        // layout is computed first, deterministically, and the seal happens
        // against exactly the header the wire will carry.
        let payloadLength = 4 + 1 + min(acks.count, MizarNetPunchPacket.maxAcksPerPacket) * 4 + 4 + chunk.count + 16
        let header = MizarNetPunchPacket.header(type: .data, connectionId: connectionId, payloadLength: payloadLength)
        var authenticated = header
        authenticated.appendUInt32(packetNumber)
        authenticated.appendUInt32(UInt32(messageLength))

        let sealed = try MizarNetCrypto.seal(chunk, key: sealKey, packetNumber: packetNumber, authenticatedData: authenticated)
        let packet = MizarNetPunchPacket.data(
            connectionId: connectionId,
            packetNumber: packetNumber,
            acks: acks,
            messageLength: messageLength,
            sealed: sealed,
        )
        try await socket.send(packet, to: remote)
        unacked[packetNumber] = PendingPacket(packet: packet, sentAt: .now, attempts: 0)
    }

    // MARK: - Receiving

    /// Await the next message.
    ///
    /// - Returns: the message, or `nil` when the peer closed the session.
    public func receive() async throws -> Data? {
        if !queued.isEmpty { return queued.removeFirst() }
        if closed { return nil }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    /// One datagram from the engine's receive loop. The loop is sequential,
    /// which is what keeps packet order intact.
    func receiveDatagram(_ data: Data) async {
        guard !closed else { return }
        lastReceivedAt = .now
        idle = false
        guard let header = MizarNetPunchPacket.parseHeader(data) else { return }
        switch header.type {
        case .data:
            await handleData(data)
        case .ack:
            if let parsed = MizarNetPunchPacket.parseAcks(data) {
                processAcks(parsed.acks)
            }
        case .keepalive:
            break
        case .close:
            let reason = MizarNetPunchPacket.parseClose(data)?.reason ?? ""
            await closeInternal(reason: "the peer closed the session: \(reason)")
        case .clientHello, .serverHello:
            // Handshakes belong to the engine; a session that sees one is
            // hearing a conversation it is not part of.
            break
        }
    }

    private func handleData(_ data: Data) async {
        guard let packet = MizarNetPunchPacket.parseData(data) else { return }
        processAcks(packet.acks)
        guard let chunk = try? MizarNetCrypto.open(
            packet.sealed,
            key: openKey,
            packetNumber: packet.packetNumber,
            authenticatedData: packet.authenticatedData,
        ) else { return }

        recordReceived(packet.packetNumber)
        if packet.packetNumber == expectedPacketNumber {
            acceptChunk(messageLength: packet.messageLength, chunk: chunk)
            expectedPacketNumber = expectedPacketNumber &+ 1
            while let buffered = reorderBuffer.removeValue(forKey: expectedPacketNumber) {
                acceptChunk(messageLength: buffered.messageLength, chunk: buffered.chunk)
                expectedPacketNumber = expectedPacketNumber &+ 1
            }
        } else if packet.packetNumber > expectedPacketNumber, reorderBuffer.count < 64 {
            reorderBuffer[packet.packetNumber] = BufferedChunk(messageLength: packet.messageLength, chunk: chunk)
        }
        // Below the expected number: already delivered, the sender has not
        // seen our ack yet. Recorded, so the ack goes out again.
    }

    private func acceptChunk(messageLength: Int, chunk: Data) {
        if incomingMessageLength == nil {
            incomingMessageLength = messageLength
        }
        incomingMessage.append(chunk)
        guard let total = incomingMessageLength, incomingMessage.count >= total else { return }
        deliver(Data(incomingMessage.prefix(total)))
        incomingMessage.removeFirst(total)
        incomingMessageLength = nil
    }

    private func deliver(_ message: Data) {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume(returning: message)
        } else {
            queued.append(message)
        }
    }

    private func recordReceived(_ packetNumber: UInt32) {
        guard !receivedSet.contains(packetNumber) else { return }
        receivedSet.insert(packetNumber)
        recentReceived.append(packetNumber)
        if recentReceived.count > 64 {
            let dropped = recentReceived.removeFirst()
            receivedSet.remove(dropped)
        }
        ackDirty = true
    }

    /// The acks to ride along on a data packet.
    ///
    /// Deliberately does *not* clear the dirty flag: if the packet carrying
    /// them is lost, the standalone ack timer still owes the peer those
    /// numbers, and a sender that never hears them retransmits until the
    /// session stalls. Piggybacked acks are a free optimisation on top of
    /// the timer, not a replacement for it.
    private func piggybackedAcks() -> [UInt32] {
        guard ackDirty else { return [] }
        return Array(recentReceived.suffix(MizarNetPunchPacket.maxAcksPerPacket))
    }

    private func processAcks(_ acks: [UInt32]) {
        let now = ContinuousClock.now
        for packetNumber in acks {
            guard let pending = unacked.removeValue(forKey: packetNumber) else { continue }
            let sample = seconds(from: pending.sentAt, to: now)
            smoothedRTT = smoothedRTT == 0 ? sample : 0.875 * smoothedRTT + 0.125 * sample
        }
    }

    // MARK: - Timers

    private func startTimers() {
        timers.append(Task.detached { [self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(25))
                if Task.isCancelled { break }
                await flushAcksIfNeeded()
            }
        })
        timers.append(Task.detached { [self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                if Task.isCancelled { break }
                await retransmitAndCheckIdle()
            }
        })
        timers.append(Task.detached { [self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: policy.keepaliveInterval)
                if Task.isCancelled { break }
                await sendKeepalive()
            }
        })
    }

    private func flushAcksIfNeeded() async {
        guard !closed, ackDirty else { return }
        ackDirty = false
        let acks = Array(recentReceived.suffix(MizarNetPunchPacket.maxAcksPerPacket))
        try? await socket.send(MizarNetPunchPacket.ack(connectionId: connectionId, acks: acks), to: remote)
    }

    private func retransmitAndCheckIdle() async {
        guard !closed else { return }
        let now = ContinuousClock.now
        if seconds(from: lastReceivedAt, to: now) > idleTimeoutSeconds {
            idle = true
        }
        // A sender that cannot get anything acked is not a session any
        // more, whatever the timers say.
        if unacked.count > unackedCapacity {
            stalled = true
        }
        let expired = unacked
            .filter { seconds(from: $0.value.sentAt, to: now) > seconds(of: rto(forAttempts: $0.value.attempts)) }
            .sorted { $0.key < $1.key }
        for (packetNumber, pending) in expired {
            if pending.attempts >= maxAttempts {
                stalled = true
                continue
            }
            try? await socket.send(pending.packet, to: remote)
            unacked[packetNumber] = PendingPacket(packet: pending.packet, sentAt: now, attempts: pending.attempts + 1)
        }
    }

    private func sendKeepalive() async {
        guard !closed else { return }
        try? await socket.send(MizarNetPunchPacket.keepalive(connectionId: connectionId), to: remote)
    }

    /// The retransmit timeout for the nth attempt: 300ms, doubling, capped
    /// at 2s. The floor is above a Wi-Fi RTT so a single loss never causes
    /// a retransmit.
    private func rto(forAttempts attempts: Int) -> Duration {
        guard attempts > 0 else { return .milliseconds(300) }
        let doubled = Duration.milliseconds(300 << min(attempts, 4))
        return min(doubled, .seconds(2))
    }

    // MARK: - Health and close

    /// The session's read on itself.
    func health() -> MizarNetHealth {
        let rtt = Int((smoothedRTT * 1000).rounded())
        if closed || stalled || idle {
            return .degraded(rttMilliseconds: rtt, lossPercent: 100)
        }
        if unacked.count > 8 {
            return .degraded(rttMilliseconds: rtt, lossPercent: 50)
        }
        if smoothedRTT <= 0 {
            return .unknown
        }
        return .healthy(rttMilliseconds: rtt)
    }

    /// Close the session: say so on the wire, stop the timers, and let the
    /// engine drop its reference.
    public func close() async {
        await closeInternal(reason: "closed locally")
    }

    private func closeInternal(reason: String) async {
        guard !closed else { return }
        closed = true
        try? await socket.send(MizarNetPunchPacket.close(connectionId: connectionId, reason: reason), to: remote)
        for timer in timers { timer.cancel() }
        timers.removeAll()
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
        waiters.removeAll()
        queued.removeAll()
        await onClose(connectionId)
    }

    // MARK: - Constants

    /// How long a session may hear nothing before it calls itself degraded.
    ///
    /// Three keepalive intervals: a NAT that has forgotten the mapping
    /// shows up as exactly this — our keepalives go out, nothing comes
    /// back — and reporting it is what lets the connection layer fall back
    /// to the relay instead of writing into a black hole.
    private let idleTimeoutSeconds: Double = 66

    private let maxAttempts = 8

    /// How many unacked chunks a session carries before calling itself
    /// stalled. A session.messages page is a few hundred kilobytes — a few
    /// hundred chunks — so this is far above the working set and only ever
    /// reached when the peer has stopped acking entirely.
    private let unackedCapacity = 512

    private func seconds(of duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private func seconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
        seconds(of: start.duration(to: end))
    }
}

private extension Data {
    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(value >> 24))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }
}
