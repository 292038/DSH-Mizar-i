//
//  NATMatrixLab.swift
//  MizarNetNATLab
//
//  The matrix: two engines, two NATs, one dial.
//
//  Each cell is a real MizarNet connection between two real engines, each
//  behind its own simulated NAT, with candidates exchanged over a
//  signaling pair and STUN answered by an observing responder. Nothing is
//  stubbed: the engine binds a socket, asks STUN what it looks like,
//  exchanges candidates, punches, and — if the punch lands — carries a
//  frame in each direction. A cell passes only if bytes moved both ways.
//
//  The runner is sequential on purpose. Parallel cells would share the
//  machine's timers, and a punch that lands in 200 milliseconds on an idle
//  machine is exactly the kind of thing a loaded machine turns into a
//  false failure.
//

import Foundation
import MizarKit

/// One cell of the matrix.
public struct NATCell: Sendable, Equatable {
    /// The NAT in front of the dialing engine.
    public let dialer: SimulatedNATBehavior
    /// The NAT in front of the accepting engine.
    public let acceptor: SimulatedNATBehavior
    /// An optional outer NAT in front of the dialer — carrier-grade NAT.
    public let dialerUpstream: SimulatedNATBehavior?
    /// An optional outer NAT in front of the acceptor.
    public let acceptorUpstream: SimulatedNATBehavior?

    public init(
        dialer: SimulatedNATBehavior,
        acceptor: SimulatedNATBehavior,
        dialerUpstream: SimulatedNATBehavior? = nil,
        acceptorUpstream: SimulatedNATBehavior? = nil,
    ) {
        self.dialer = dialer
        self.acceptor = acceptor
        self.dialerUpstream = dialerUpstream
        self.acceptorUpstream = acceptorUpstream
    }

    public var label: String {
        var dialerLabel = dialer.rawValue
        if let dialerUpstream { dialerLabel += " over \(dialerUpstream.rawValue)" }
        var acceptorLabel = acceptor.rawValue
        if let acceptorUpstream { acceptorLabel += " over \(acceptorUpstream.rawValue)" }
        return "\(dialerLabel) → \(acceptorLabel)"
    }
}

/// How a cell ended.
public enum NATCellOutcome: Sendable, Equatable {
    /// A session formed and carried a frame in each direction.
    case punched
    /// The dial budget ran out.
    case timeout
    /// Something else went wrong; the reason is carried for the report.
    case failed(String)
}

/// One cell's result.
public struct NATCellResult: Sendable, Equatable {
    public let cell: NATCell
    public let outcome: NATCellOutcome
    public let milliseconds: Int
}

/// Runs the matrix.
public struct NATMatrixLab {
    /// Fast enough to keep a 36-cell matrix inside a couple of minutes,
    /// shaped like the real policy everywhere it matters: rounds, intervals,
    /// windows and budgets all come from the same knobs.
    public static let labPolicy = MizarNetPathPolicy(
        punchBudget: .seconds(2),
        healthInterval: .seconds(10),
        keepaliveInterval: .seconds(22),
        downgradeAfter: 3,
        punchBackoff: [.seconds(1)],
        maxPunchRounds: 3,
        punchRounds: 10,
        punchInterval: .milliseconds(60),
        streamChunkBytes: 512,
        stunBudget: .milliseconds(400),
        acceptorPunchWindow: .seconds(3),
        punchAnswerGrace: .milliseconds(250),
    )

    /// Every behaviour, in report order.
    public static let allBehaviors: [SimulatedNATBehavior] = [
        .publicNetwork, .fullCone, .addressRestricted, .portRestricted, .symmetric, .blocked,
    ]

    private init() {}

    /// Run the given cells, sequentially, and report each one.
    public static func run(_ cells: [NATCell]) async -> [NATCellResult] {
        let stun = try? await ObservingSTUNServer()
        await stun?.start()
        // The lab is loopback by construction, and a bound socket reports
        // its wildcard address (0.0.0.0) — which is a bind, not a
        // destination. The responder is reached on loopback.
        let stunServer = (await stun?.address).map { "127.0.0.1:\($0.port)" } ?? ""
        var results: [NATCellResult] = []
        for cell in cells {
            results.append(await runCell(cell, stunServer: stunServer))
        }
        await stun?.stop()
        return results
    }

    /// The full 6×6 matrix: every dialer behaviour against every acceptor.
    public static func fullMatrix() async -> [NATCellResult] {
        var cells: [NATCell] = []
        for dialer in allBehaviors {
            for acceptor in allBehaviors {
                cells.append(NATCell(dialer: dialer, acceptor: acceptor))
            }
        }
        return await run(cells)
    }

    /// A human-readable table of the results.
    public static func table(_ results: [NATCellResult]) -> String {
        var lines: [String] = ["cell | outcome | ms"]
        for result in results {
            let outcome: String
            switch result.outcome {
            case .punched: outcome = "PUNCHED"
            case .timeout: outcome = "timeout"
            case .failed(let reason): outcome = "failed: \(reason)"
            }
            lines.append("\(result.cell.label) | \(outcome) | \(result.milliseconds)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - One cell

    private static func runCell(_ cell: NATCell, stunServer: String) async -> NATCellResult {
        let dialerIdentity = MizarNetIdentity.generate()
        let acceptorIdentity = MizarNetIdentity.generate()
        let stunServers = stunServer.isEmpty ? [] : [stunServer]

        // The NATs, outermost first when chained.
        let dialerOuter = cell.dialerUpstream.map { SimulatedNAT(behavior: $0) }
        let acceptorOuter = cell.acceptorUpstream.map { SimulatedNAT(behavior: $0) }
        if let dialerOuter { try? await dialerOuter.bind(port: nil) }
        if let acceptorOuter { try? await acceptorOuter.bind(port: nil) }
        let dialerNAT = cell.dialer == .publicNetwork ? nil : SimulatedNAT(behavior: cell.dialer, upstream: dialerOuter)
        let acceptorNAT = cell.acceptor == .publicNetwork ? nil : SimulatedNAT(behavior: cell.acceptor, upstream: acceptorOuter)

        let dialerEngine = MizarNetQUICEngine(
            identity: dialerIdentity,
            policy: labPolicy,
            stunServers: stunServers,
            socket: dialerNAT,
        )
        let acceptorEngine = MizarNetQUICEngine(
            identity: acceptorIdentity,
            policy: labPolicy,
            stunServers: stunServers,
            socket: acceptorNAT,
        )

        let (dialerSide, acceptorSide) = await LabSignalingTransport.pair()
        // No ticket hints: the only route either side knows is what the
        // other's hello carried over signaling — the production shape.
        let dialer = MizarNetConnection(
            engine: dialerEngine,
            ticket: MizarNetTicket(endpointId: acceptorIdentity.endpointId),
            signaling: dialerSide,
            policy: labPolicy,
        )
        let acceptor = MizarNetConnection(
            engine: acceptorEngine,
            ticket: MizarNetTicket(endpointId: acceptorIdentity.endpointId),
            signaling: acceptorSide,
            policy: labPolicy,
        )

        let clock = ContinuousClock()
        let start = clock.now
        let acceptTask = Task { try await acceptor.accept() }
        let outcome = await runAttempt(
            dialer: dialer,
            acceptor: acceptor,
            acceptTask: acceptTask,
            acceptorSide: acceptorSide,
        )
        // A cell that timed out leaves the accept suspended on the incoming
        // stream; cancelling it is the teardown, not an interruption.
        acceptTask.cancel()

        await dialer.close()
        await acceptor.close()
        await dialerEngine.shutdown()
        await acceptorEngine.shutdown()
        await dialerNAT?.close()
        await acceptorNAT?.close()
        await dialerOuter?.close()
        await acceptorOuter?.close()

        let elapsed = start.duration(to: clock.now)
        let milliseconds = Int(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
        return NATCellResult(cell: cell, outcome: outcome, milliseconds: milliseconds)
    }

    /// The attempt itself: wait for the hellos to cross, dial, and prove the
    /// session carries a frame in each direction.
    private static func runAttempt(
        dialer: MizarNetConnection,
        acceptor: MizarNetConnection,
        acceptTask: Task<any MizarNetStream, any Error>,
        acceptorSide: LabSignalingTransport,
    ) async -> NATCellOutcome {
        // The dialer's only route to the acceptor is the candidate the
        // acceptor's hello carried, so the dial waits for that hello rather
        // than for a fixed sleep: a NAT whose STUN is slow must not turn
        // into a false "no candidates" failure.
        let helloDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await acceptorSide.sent.contains(where: { if case .hello = $0 { return true }; return false })),
              ContinuousClock.now < helloDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        do {
            let stream = try await dialer.connect()
            let accepted = try await acceptTask.value
            try await stream.send(Data("ping".utf8))
            guard try await accepted.receive() == Data("ping".utf8) else {
                return .failed("the acceptor never saw the frame")
            }
            try await accepted.send(Data("pong".utf8))
            guard try await stream.receive() == Data("pong".utf8) else {
                return .failed("the dialer never saw the reply")
            }
            return .punched
        } catch let error as MizarNetError where error == .dialTimeout(path: .p2p) {
            return .timeout
        } catch let error as MizarNetError {
            return .failed(error.mizarError.code)
        } catch {
            return .failed("\(error)")
        }
    }
}
