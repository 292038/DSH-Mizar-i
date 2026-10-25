//
//  MizarNetTestSupport.swift
//  MizarKitTests
//
//  A connectivity engine made of two pipes.
//
//  The kernel's contract with the engine is deliberately narrow — dial a
//  ticket, hand out streams, report health — so a test double is not a
//  compromise, it is the fastest way to drive the real state machine: real
//  budgets, real health streaks, real teardown, zero sockets. The production
//  engine (QUIC, UDP, the punch itself) is tested against the *same*
//  protocol when it exists; what is under test here is everything the engine
//  is not.
//
//  The registry is a static because the loopback models the one thing the
//  kernel cannot fake: two endpoints that know each other by key and are
//  connected by *something*. Keys are random per test, so parallel tests
//  never meet.
//

import Foundation
import Testing

@testable import MizarKit

/// Where loopback endpoints find each other.
actor LoopbackRegistry {
    static let shared = LoopbackRegistry()

    private var peers: [String: MizarNetLoopbackEngine] = [:]

    fileprivate func register(_ engine: MizarNetLoopbackEngine, for endpointId: String) {
        peers[endpointId] = engine
    }

    fileprivate func unregister(_ endpointId: String) {
        peers.removeValue(forKey: endpointId)
    }

    fileprivate func peer(for endpointId: String) -> MizarNetLoopbackEngine? {
        peers[endpointId]
    }
}

/// One side of a loopback stream's mailbox.
///
/// The StubTransport pattern, reused: an actor-held queue plus waiters, so
/// `next()` can suspend without the `AsyncStream` iterator's actor-isolation
/// problem, and a `finish()` that drains waiters to `nil` the way a closed
/// socket does.
actor LoopbackInbox {
    private var queued: [Data] = []
    private var closed = false
    private var waiters: [CheckedContinuation<Data?, Never>] = []

    fileprivate func push(_ data: Data) {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume(returning: data)
        } else {
            queued.append(data)
        }
    }

    fileprivate func finish() {
        closed = true
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
        waiters.removeAll()
    }

    func next() async -> Data? {
        if !queued.isEmpty { return queued.removeFirst() }
        if closed { return nil }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

/// A byte stream with another byte stream on the other end.
actor LoopbackStream: MizarNetStream {
    let pathKind: MizarNetPathKind

    private let inbox: LoopbackInbox
    private let outbox: LoopbackInbox
    private var closed = false

    fileprivate init(path: MizarNetPathKind, inbox: LoopbackInbox, outbox: LoopbackInbox) {
        self.pathKind = path
        self.inbox = inbox
        self.outbox = outbox
    }

    /// Two ends of one stream.
    static func pair(path: MizarNetPathKind = .p2p) -> (LoopbackStream, LoopbackStream) {
        let inboxA = LoopbackInbox()
        let inboxB = LoopbackInbox()
        // A writes into B's inbox and reads its own; B the mirror.
        let a = LoopbackStream(path: path, inbox: inboxA, outbox: inboxB)
        let b = LoopbackStream(path: path, inbox: inboxB, outbox: inboxA)
        return (a, b)
    }

    func send(_ data: Data) async throws {
        guard !closed else { throw MizarNetError.streamClosed }
        await outbox.push(data)
    }

    func receive() async throws -> Data? {
        await inbox.next()
    }

    func close() async {
        guard !closed else { return }
        closed = true
        // Finishing the outbox is what the peer's `receive()` sees as a
        // close: its inbox drains and then reads nil.
        await outbox.finish()
    }
}

/// An engine that "punches" by looking the peer up in a registry.
///
/// The failure scripts exist because the interesting behaviour of the state
/// machine is what it does when the engine misbehaves: a dial that hangs
/// must still respect the budget, and a path that reports itself degraded
/// must still be dropped after the streak runs out.
actor MizarNetLoopbackEngine: MizarNetEngine {
    let identity: MizarNetIdentity

    private let incoming: AsyncStream<any MizarNetStream>
    private let incomingContinuation: AsyncStream<any MizarNetStream>.Continuation
    private var started = false
    private var hangDial = false
    private var failNextDial = false
    private var healthSetting: MizarNetHealth = .healthy(rttMilliseconds: 20)
    private var offered: [MizarNetCandidate] = []
    private var networkChanges = 0
    private var shutdowns = 0
    private var recordedIntent: MizarNetIntent?

    init(identity: MizarNetIdentity) {
        self.identity = identity
        let made = AsyncStream<any MizarNetStream>.makeStream(of: (any MizarNetStream).self, bufferingPolicy: .unbounded)
        self.incoming = made.stream
        self.incomingContinuation = made.continuation
    }

    func start() async throws {
        guard !started else { return }
        started = true
        await LoopbackRegistry.shared.register(self, for: identity.endpointId)
    }

    func shutdown() async {
        started = false
        shutdowns += 1
        await LoopbackRegistry.shared.unregister(identity.endpointId)
        incomingContinuation.finish()
    }

    func dial(ticket: MizarNetTicket, timeout: Duration) async throws -> any MizarNetStream {
        if hangDial {
            // Long enough to outlive any budget a test will set, so the
            // connection's own timeout is what ends the attempt.
            try? await Task.sleep(for: .seconds(30))
            throw MizarNetError.dialTimeout(path: .p2p)
        }
        if failNextDial {
            failNextDial = false
            throw MizarNetError.punchFailed(reason: "scripted failure")
        }
        guard let peer = await LoopbackRegistry.shared.peer(for: ticket.endpointId) else {
            throw MizarNetError.punchFailed(reason: "no peer registered for the ticket")
        }
        let (mine, theirs) = LoopbackStream.pair(path: .p2p)
        await peer.deliver(theirs)
        return mine
    }

    func incomingStreams() async -> AsyncStream<any MizarNetStream> {
        incoming
    }

    func localCandidates() async -> [MizarNetCandidate] {
        [MizarNetCandidate(kind: .host, address: "127.0.0.1", port: 19390)]
    }

    func offerCandidates(_ candidates: [MizarNetCandidate]) async {
        offered.append(contentsOf: candidates)
    }

    func networkChanged() async {
        networkChanges += 1
    }

    func noteIntent(_ intent: MizarNetIntent) async {
        // The loopback engine has no NAT to punch through, so the intent is
        // recorded and otherwise ignored.
        recordedIntent = intent
    }

    func health() async -> MizarNetHealth {
        healthSetting
    }

    /// Deliver a stream the peer dialled in on.
    fileprivate func deliver(_ stream: any MizarNetStream) {
        incomingContinuation.yield(stream)
    }

    // MARK: - Test scripts and observations

    /// Make the next dial hang until cancelled.
    func scriptHang() {
        hangDial = true
    }

    /// Make the next dial fail with a scripted punch failure.
    func scriptFailure() {
        failNextDial = true
    }

    /// Override what `health()` reports.
    func setHealth(_ health: MizarNetHealth) {
        healthSetting = health
    }

    /// The candidates offered so far.
    func offeredCandidates() -> [MizarNetCandidate] {
        offered
    }

    /// How many network-change notifications arrived.
    func networkChangeCount() -> Int {
        networkChanges
    }

    /// How many times the engine was shut down.
    func shutdownCount() -> Int {
        shutdowns
    }
}
