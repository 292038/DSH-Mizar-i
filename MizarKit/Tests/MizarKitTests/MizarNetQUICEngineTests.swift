//
//  MizarNetQUICEngineTests.swift
//  MizarKitTests
//
//  The engine, over real UDP.
//
//  Loopback is not a NAT, so these tests do not prove that a punch crosses
//  one — nothing but a carrier network proves that, and the NAT matrix in
//  the plan is where it gets proven. What loopback *does* prove is
//  everything around the punch: the socket holds its port, the hello is
//  answered from the address it arrived on, the signature is checked, the
//  agreement produces working keys, the session delivers messages whole
//  and in order across a chunk boundary, and the teardown is visible to
//  the peer. Those are the parts that break silently.
//
//  One socket per engine, one port held for the engine's life: the tests
//  lean on that by learning the peer's port from its candidates and
//  dialling exactly that, the way a real ticket would.
//

import Foundation
import Testing

@testable import MizarKit

struct MizarNetQUICEngineTests {
    /// Fast enough for a test, shaped like the real policy.
    private static let policy = MizarNetPathPolicy(
        punchBudget: .seconds(2),
        healthInterval: .seconds(10),
        keepaliveInterval: .seconds(22),
        downgradeAfter: 3,
        punchBackoff: [.seconds(1)],
        maxPunchRounds: 3,
        punchRounds: 6,
        punchInterval: .milliseconds(60),
        streamChunkBytes: 512,
        stunBudget: .milliseconds(500),
    )

    /// A started engine, plus the loopback address its peers can dial.
    private static func startedEngine() async throws -> (engine: MizarNetQUICEngine, identity: MizarNetIdentity, loopbackPort: UInt16) {
        let identity = MizarNetIdentity.generate()
        let engine = MizarNetQUICEngine(identity: identity, policy: policy, stunServers: [])
        try await engine.start()
        let candidates = await engine.localCandidates()
        guard let loopback = candidates.first(where: { $0.address == "127.0.0.1" }) else {
            throw MizarNetError.punchFailed(reason: "no loopback candidate on the test host")
        }
        return (engine, identity, loopback.port)
    }

    private static func ticket(to identity: MizarNetIdentity, port: UInt16) -> MizarNetTicket {
        MizarNetTicket(endpointId: identity.endpointId, direct: ["127.0.0.1:\(port)"])
    }

    // MARK: - The punch itself

    @Test("a dial punches through, and the session carries messages both ways")
    func punchAndCarry() async throws {
        let desktop = try await Self.startedEngine()
        let phone = try await Self.startedEngine()

        let stream = try await phone.engine.dial(
            ticket: Self.ticket(to: desktop.identity, port: desktop.loopbackPort),
            timeout: .seconds(2),
        )
        #expect(await stream.pathKind == .p2p)

        // The desktop sees the dial on its incoming stream.
        var incoming = await desktop.engine.incomingStreams().makeAsyncIterator()
        let accepted = try #require(await incoming.next())
        #expect(await accepted.pathKind == .p2p)

        // Both directions, whole messages.
        try await stream.send(Data("hello".utf8))
        #expect(try await accepted.receive() == Data("hello".utf8))
        try await accepted.send(Data("welcome".utf8))
        #expect(try await stream.receive() == Data("welcome".utf8))

        // A message bigger than one chunk is reassembled intact — the
        // message-preserving contract, across a 512-byte chunk boundary.
        let page = Data((0..<3000).map { UInt8($0 % 251) })
        try await stream.send(page)
        #expect(try await accepted.receive() == page)

        // The engine reports a measured path once packets have been acked.
        let health = await phone.engine.health()
        if case .healthy(let rtt) = health {
            #expect(rtt >= 0)
        } else {
            Issue.record("expected a healthy path after an exchange, got \(health)")
        }

        await stream.close()
        // The peer sees a close, not a hang.
        #expect(try await accepted.receive() == nil)

        await phone.engine.shutdown()
        await desktop.engine.shutdown()
    }

    @Test("a dial nobody answers times out at the budget")
    func unansweredDialTimesOut() async throws {
        let phone = try await Self.startedEngine()
        let listener = MizarNetIdentity.generate()
        // A port nothing is bound to: the punch goes out, nothing comes
        // back, and the budget decides.
        let ticket = MizarNetTicket(endpointId: listener.endpointId, direct: ["127.0.0.1:1"])
        do {
            _ = try await phone.engine.dial(ticket: ticket, timeout: .milliseconds(400))
            Issue.record("a dial with nobody home must not connect")
        } catch let error as MizarNetError {
            #expect(error == .dialTimeout(path: .p2p))
        }
        await phone.engine.shutdown()
    }

    @Test("a second dial while one is in flight is refused, not queued")
    func concurrentDialsAreRefused() async throws {
        let phone = try await Self.startedEngine()
        let listener = MizarNetIdentity.generate()
        // Nobody answers the first dial, so it stays in flight for its
        // whole budget — which is the state the second dial must notice.
        let ticket = MizarNetTicket(endpointId: listener.endpointId, direct: ["127.0.0.1:1"])

        async let first = phone.engine.dial(ticket: ticket, timeout: .seconds(2))
        // Give the first a moment to register as the active dial.
        try await Task.sleep(for: .milliseconds(100))
        do {
            _ = try await phone.engine.dial(ticket: ticket, timeout: .milliseconds(200))
            Issue.record("a second concurrent dial must be refused")
        } catch let error as MizarNetError {
            #expect(error == .dialInFlight)
        }
        do {
            _ = try await first
            Issue.record("the first dial must still time out")
        } catch let error as MizarNetError {
            #expect(error == .dialTimeout(path: .p2p))
        }
        await phone.engine.shutdown()
    }

    // MARK: - STUN

    @Test("STUN discovery records the mapped address as a candidate")
    func stunDiscovery() async throws {
        let server = try await FakeSTUNServer(mappedIP: "203.0.113.77", mappedPort: 54321)
        await server.start()
        defer { Task { await server.stop() } }

        let identity = MizarNetIdentity.generate()
        let engine = MizarNetQUICEngine(identity: identity, policy: Self.policy, stunServers: ["127.0.0.1:\(await server.port)"])
        try await engine.start()

        let candidates = await engine.localCandidates()
        let reflexive = candidates.first { $0.kind == .serverReflexive }
        #expect(reflexive?.address == "203.0.113.77")
        #expect(reflexive?.port == 54321)
        // Host candidates come first — the LAN path is preferred over the
        // punched one, exactly as ICE orders them.
        #expect(candidates.first?.kind == .host)
        await engine.shutdown()
    }

    // MARK: - Network change

    @Test("a network change re-gathers candidates and leaves the session alone")
    func networkChange() async throws {
        let desktop = try await Self.startedEngine()
        let phone = try await Self.startedEngine()
        let stream = try await phone.engine.dial(
            ticket: Self.ticket(to: desktop.identity, port: desktop.loopbackPort),
            timeout: .seconds(2),
        )

        await phone.engine.networkChanged()
        // Still connected: the kernel does not invent a reconnect, and the
        // session that survived the change still carries bytes.
        var incoming = await desktop.engine.incomingStreams().makeAsyncIterator()
        let accepted = try #require(await incoming.next())
        try await stream.send(Data("after the change".utf8))
        #expect(try await accepted.receive() == Data("after the change".utf8))
        // Candidates were re-gathered, not dropped.
        let candidates = await phone.engine.localCandidates()
        #expect(candidates.contains { $0.kind == .host })
        // A measured path is asynchronous by nature — the round trip only
        // exists once the ack for the packet above comes back — so this
        // waits rather than reads.
        let measured = await eventually(timeout: 2) {
            await phone.engine.health() != .unknown
        }
        #expect(measured)

        await stream.close()
        await phone.engine.shutdown()
        await desktop.engine.shutdown()
    }

    // MARK: - The transport seam, over real UDP

    @Test("the transport carries Mizar frames over a punched session")
    func transportOverUDP() async throws {
        let desktop = try await Self.startedEngine()
        let desktopIdentity = desktop.identity

        let phoneIdentity = MizarNetIdentity.generate()
        let transport = P2PWebSocketTransport(
            makeEngine: { MizarNetQUICEngine(identity: phoneIdentity, policy: Self.policy, stunServers: []) },
        )
        try await transport.connect(
            url: try MizarNetDialURL.make(ticket: Self.ticket(to: desktopIdentity, port: desktop.loopbackPort)),
            headers: ["x-mizar-client-id": "install-1"],
        )

        try await transport.send(text: "{\"v\":1,\"type\":\"ping\"}")
        var incoming = await desktop.engine.incomingStreams().makeAsyncIterator()
        let accepted = try #require(await incoming.next())
        #expect(try await accepted.receive() == Data("{\"v\":1,\"type\":\"ping\"}".utf8))

        try await accepted.send(Data("{\"v\":1,\"type\":\"pong\"}".utf8))
        #expect(try await transport.receive() == "{\"v\":1,\"type\":\"pong\"}")

        await transport.close()
        #expect(try await accepted.receive() == nil)
        await desktop.engine.shutdown()
    }

    @Test("signaling-delivered candidates are enough to punch without ticket hints")
    func punchFromSignaledCandidates() async throws {
        let desktop = try await Self.startedEngine()
        let phone = try await Self.startedEngine()

        // No direct hints on the ticket: the only way to the desktop is the
        // candidate its hello carried over the signaling channel.
        let (phoneSide, desktopSide) = await LoopbackSignalingTransport.pair()
        let acceptor = MizarNetConnection(
            engine: desktop.engine,
            ticket: MizarNetTicket(endpointId: desktop.identity.endpointId),
            signaling: desktopSide,
        )
        let dialer = MizarNetConnection(
            engine: phone.engine,
            ticket: MizarNetTicket(endpointId: desktop.identity.endpointId),
            signaling: phoneSide,
        )

        let acceptTask = Task { try await acceptor.accept() }
        // Let the acceptor's hello reach the dialer's engine before the
        // dial starts, so the punch has candidates to work with.
        try await Task.sleep(for: .milliseconds(150))

        let stream = try await dialer.connect()
        #expect(await dialer.state == .ready(path: .p2p))
        let accepted = try await acceptTask.value
        try await stream.send(Data("via signaling".utf8))
        #expect(try await accepted.receive() == Data("via signaling".utf8))

        await dialer.close()
        await phone.engine.shutdown()
        await desktop.engine.shutdown()
    }
}
