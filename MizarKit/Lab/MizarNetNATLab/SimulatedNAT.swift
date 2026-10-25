//
//  SimulatedNAT.swift
//  MizarNetNATLab
//
//  A NAT made of real sockets.
//
//  macOS has no network namespaces and the engine cannot run on Linux, so
//  the matrix is built in userspace instead: this actor sits between the
//  engine and the wire and behaves like the NAT it is told to be. What it
//  implements is the two properties a punch depends on, and nothing else:
//
//   - mapping: does the socket's public port stay the same for every
//     destination (endpoint-independent, the cone NATs) or change per
//     destination (endpoint-dependent, symmetric)? An EIM NAT has one
//     forwarder socket; a symmetric one allocates a forwarder per
//     destination, exactly as the real thing does.
//   - filtering: after we have sent to an address, who may send back?
//     Anybody (full cone), that IP (address-restricted), that IP and port
//     (port-restricted), or only the destination a given forwarder spoke
//     to (symmetric, which is endpoint-dependent by construction).
//
//  The engine sees none of this. It is given this actor as its socket —
//  the same four-method protocol a real socket satisfies — binds it, sends
//  to the addresses its candidates name, and reads what the filter lets
//  through. A STUN request is forwarded like any packet, and the responder
//  answers with the forwarder's real address, which is what a STUN server
//  on the public side of a NAT reports.
//
//  Chaining composes: pass another NAT as the upstream and this one's WAN
//  becomes that NAT's LAN — carrier-grade NAT, in two actors. The
//  outermost layer is the one the far side sees; the inner layers add
//  filters that are automatically satisfied because the engine's own
//  packets traverse them.
//
//  What is deliberately absent: mapping expiry. A real NAT forgets an idle
//  mapping in minutes; the matrix opens fresh sessions, so the timeout
//  paths are the session's to test, not the NAT's.
//

import Foundation
import MizarKit

/// The NAT behaviour to simulate.
public enum SimulatedNATBehavior: String, Sendable, CaseIterable {
    /// No NAT at all. The engine binds a real socket and talks directly.
    case publicNetwork
    /// Endpoint-independent mapping, any source may send back.
    case fullCone
    /// Endpoint-independent mapping, only IPs we have sent to may answer.
    case addressRestricted
    /// Endpoint-independent mapping, only IP:ports we have sent to may answer.
    case portRestricted
    /// A mapping per destination; each forwarder only accepts its own peer.
    case symmetric
    /// Every packet dropped — the UDP-blocked firewall.
    case blocked
}

/// A NAT between the engine and the wire.
public actor SimulatedNAT: MizarNetDatagramSocket {
    public nonisolated let events: AsyncStream<MizarNetDatagram>
    private let continuation: AsyncStream<MizarNetDatagram>.Continuation

    private let behavior: SimulatedNATBehavior
    private let upstream: (any MizarNetDatagramSocket)?
    private var bound = false
    private var closed = false

    /// The one forwarder an EIM behaviour uses for every destination.
    private var sharedForwarder: MizarNetUDPSocket?
    private var sharedTask: Task<Void, Never>?
    /// The port the engine believes it is bound to.
    ///
    /// A real NAT separates a private address from a public one, and the
    /// private one is unroutable from outside: a peer that dials a host
    /// candidate across the internet gets silence, not a shortcut. Loopback
    /// has no such separation, so this is what restores it — bound and
    /// never read, which makes every packet to it vanish exactly like a
    /// packet to a private address would. Without it the matrix would
    /// "punch" by walking round the NAT and prove nothing.
    private var internalSocket: MizarNetUDPSocket?
    /// One forwarder per destination, for symmetric behaviour.
    private var perDestination: [MizarNetSocketAddress: MizarNetUDPSocket] = [:]
    private var destinationTasks: [MizarNetSocketAddress: Task<Void, Never>] = [:]
    /// For a chained NAT: the drain of everything the upstream delivers.
    private var upstreamTask: Task<Void, Never>?
    /// Every destination this NAT has sent to. The filter state.
    private var sentTo: Set<MizarNetSocketAddress> = []

    public init(behavior: SimulatedNATBehavior, upstream: (any MizarNetDatagramSocket)? = nil) {
        self.behavior = behavior
        self.upstream = upstream
        let made = AsyncStream<MizarNetDatagram>.makeStream(of: MizarNetDatagram.self, bufferingPolicy: .unbounded)
        self.events = made.stream
        self.continuation = made.continuation
    }

    // MARK: - MizarNetDatagramSocket

    public var localAddress: MizarNetSocketAddress? {
        get async {
            switch behavior {
            case .blocked:
                return nil
            case .symmetric where upstream == nil:
                // No stable mapped address exists to advertise, and a
                // symmetric NAT's host candidates are unreachable from
                // outside anyway.
                return nil
            default:
                if let upstream { return await upstream.localAddress }
                // The private side: a port nothing listens on, which is
                // what a host candidate is worth across a NAT.
                guard let port = await internalSocket?.localAddress?.port else { return nil }
                return MizarNetSocketAddress(ip: "127.0.0.1", port: port)
            }
        }
    }

    public func bind(port: UInt16?) async throws {
        guard !bound else { return }
        bound = true
        guard behavior != .blocked else { return }

        if let upstream {
            // Chained: our WAN is the upstream's front. Everything it
            // delivers comes through our filter.
            let continuation = self.continuation
            upstreamTask = Task.detached {
                for await datagram in upstream.events {
                    guard await self.permits(source: datagram.from) else { continue }
                    continuation.yield(datagram)
                }
            }
            return
        }

        // The private port first: it is what the engine advertises and what
        // the world cannot reach. A symmetric NAT has no single mapping to
        // advertise, so it has no private port either.
        if behavior != .symmetric {
            let internalSocket = MizarNetUDPSocket()
            try await internalSocket.bind(port: nil)
            self.internalSocket = internalSocket
        }

        if behavior != .symmetric {
            let forwarder = MizarNetUDPSocket()
            try await forwarder.bind(port: nil)
            sharedForwarder = forwarder
            let continuation = self.continuation
            sharedTask = Task.detached {
                for await datagram in forwarder.events {
                    guard await self.permits(source: datagram.from) else { continue }
                    continuation.yield(datagram)
                }
            }
        }
    }

    public func send(_ data: Data, to address: MizarNetSocketAddress) async throws {
        guard !closed, behavior != .blocked else { return }

        if let upstream {
            // Chained: hand the packet to the outer NAT and let it map us.
            sentTo.insert(address)
            try? await upstream.send(data, to: address)
            return
        }

        switch behavior {
        case .blocked:
            return
        case .symmetric:
            if perDestination[address] == nil {
                let forwarder = MizarNetUDPSocket()
                try await forwarder.bind(port: nil)
                perDestination[address] = forwarder
                let continuation = self.continuation
                destinationTasks[address] = Task.detached {
                    for await datagram in forwarder.events {
                        // Endpoint-dependent filtering by construction: this
                        // socket only ever spoke to `address`, so nobody else
                        // may speak back on it.
                        guard datagram.from == address else { continue }
                        continuation.yield(datagram)
                    }
                }
            }
            try? await perDestination[address]?.send(data, to: address)
        default:
            sentTo.insert(address)
            try? await sharedForwarder?.send(data, to: address)
        }
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        sharedTask?.cancel()
        sharedTask = nil
        for task in destinationTasks.values { task.cancel() }
        destinationTasks.removeAll()
        upstreamTask?.cancel()
        upstreamTask = nil
        await sharedForwarder?.close()
        await internalSocket?.close()
        internalSocket = nil
        for forwarder in perDestination.values { await forwarder.close() }
        perDestination.removeAll()
        continuation.finish()
    }

    // MARK: - Filtering

    /// Whether a packet from `source` may reach the engine.
    private func permits(source: MizarNetSocketAddress) -> Bool {
        switch behavior {
        case .fullCone, .publicNetwork, .blocked:
            return true
        case .addressRestricted:
            return sentTo.contains { $0.ip == source.ip }
        case .portRestricted:
            return sentTo.contains(source)
        case .symmetric:
            // Chained symmetric: we sent to this source, so it may answer.
            return sentTo.contains(source)
        }
    }
}
