//
//  MizarNetPathPolicy.swift
//  MizarKit
//
//  The numbers, in one place.
//
//  Every duration and threshold the connection state machine uses lives here
//  as a value, the same way ``ReconnectPlan`` keeps the route order as a pure
//  function: the interesting decisions about a P2P connection — how long a
//  punch may take, when a bad path is worth dropping, how long to wait
//  between attempts — should be readable in one screen and testable without
//  a socket.
//
//  The defaults are chosen against measured behaviour of the networks this
//  app runs on, not against taste:
//
//    - the punch budget is 3s. The app already gives a direct LAN dial 6s
//      (AppModel's per-route timeout); a punch that has not landed in 3s
//      usually will not, and the relay fallback is one reconnect away.
//    - keepalive is 22s. Cellular NAT mappings expire somewhere between 5
//      and 30 minutes of idleness, and 20–25s is the interval the WebRTC
//      world settled on for the same reason.
//    - three consecutive bad health checks before a downgrade. One bad
//      measurement is a burst of loss; three in a row is a path.
//

import Foundation

/// The tunable numbers of a MizarNet connection.
public struct MizarNetPathPolicy: Sendable, Equatable {
    /// How long a dial — punch included — may take.
    public var punchBudget: Duration
    /// How often the engine is asked about path health.
    public var healthInterval: Duration
    /// How often an idle path should be kept alive, in seconds.
    ///
    /// Engines own their keepalive packets; this value is the contract for
    /// how often they should send them.
    public var keepaliveInterval: Duration
    /// How many consecutive non-healthy checks justify dropping the path.
    public var downgradeAfter: Int
    /// The wait after the 1st, 2nd, … failed punch. The last entry repeats.
    public var punchBackoff: [Duration]
    /// How many punch rounds one connection may spend before it stops
    /// trying and stays on whatever path it has.
    public var maxPunchRounds: Int
    /// How many times the dial resends its hello across all candidate
    /// addresses. One "round" is one hello to every pair; rounds are what
    /// absorb the timing skew between two peers that started dialling a few
    /// milliseconds apart, the way libp2p's DCUtR absorbs it with an RTT/2
    /// sync — without needing a shared clock.
    public var punchRounds: Int = 8
    /// The pause between punch rounds.
    public var punchInterval: Duration = .milliseconds(120)
    /// The largest plaintext chunk the session puts in one datagram.
    ///
    /// 1024 keeps a datagram — header, packet number, piggybacked acks,
    /// AEAD tag — under 1200 bytes, so no IP fragmentation on any path
    /// worth using.
    public var streamChunkBytes: Int = 1024
    /// How long a freshly started engine waits for a STUN answer before
    /// punching with host candidates alone.
    ///
    /// Bounded because the punch budget should be spent punching, not
    /// waiting for a server that may be unreachable from this network.
    public var stunBudget: Duration = .milliseconds(700)
    /// How long the side being dialled keeps punching back after learning
    /// the dialer's candidates from signaling.
    ///
    /// Wider than the dial budget on purpose: the dialer may have started
    /// before its hello reached us, and the punch that opens the filter has
    /// to outlast the dial that depends on it.
    public var acceptorPunchWindow: Duration = .seconds(4)
    /// How long an answered punch-back waits before its session is offered
    /// to whoever is accepting.
    ///
    /// The grace exists for the simultaneous open: both sides punch, and
    /// the session the *dialer's* punch started is the one that survives.
    /// If the dialer's hello is still in flight when our punch is answered,
    /// this wait lets it land and take precedence; if it never lands — the
    /// symmetric-acceptor case, where the dialer's hello cannot reach our
    /// mapping — our own session is the one the dialer fell back to.
    public var punchAnswerGrace: Duration = .milliseconds(150)
    /// How long a dial waits for the peer's candidates before giving up on
    /// a punch entirely.
    ///
    /// Candidates arrive over signaling, a few milliseconds after the app
    /// decided to dial — but "a few" is not a guarantee on a busy phone or
    /// a relayed signal path. Failing the moment the list is empty spends
    /// the whole dial on a race the dial itself created; waiting costs a
    /// second in the one case where the peer never answers, and saves the
    /// connection in the common one.
    public var candidateGrace: Duration = .seconds(1)

    /// The defaults.
    public static let standard = MizarNetPathPolicy(
        punchBudget: .seconds(3),
        healthInterval: .seconds(10),
        keepaliveInterval: .seconds(22),
        downgradeAfter: 3,
        punchBackoff: [.seconds(1), .seconds(2), .seconds(4), .seconds(8)],
        maxPunchRounds: 3,
        punchRounds: 8,
        punchInterval: .milliseconds(120),
        streamChunkBytes: 1024,
        stunBudget: .milliseconds(700),
        acceptorPunchWindow: .seconds(4),
        punchAnswerGrace: .milliseconds(150),
        candidateGrace: .seconds(1),
    )

    /// A policy. Every field defaults to the standard value, so a caller
    /// overrides only what it means to change — the NAT matrix lab ships
    /// its own, tuned for a two-second budget.
    public init(
        punchBudget: Duration = .seconds(3),
        healthInterval: Duration = .seconds(10),
        keepaliveInterval: Duration = .seconds(22),
        downgradeAfter: Int = 3,
        punchBackoff: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8)],
        maxPunchRounds: Int = 3,
        punchRounds: Int = 8,
        punchInterval: Duration = .milliseconds(120),
        streamChunkBytes: Int = 1024,
        stunBudget: Duration = .milliseconds(700),
        acceptorPunchWindow: Duration = .seconds(4),
        punchAnswerGrace: Duration = .milliseconds(150),
        candidateGrace: Duration = .seconds(1),
    ) {
        self.punchBudget = punchBudget
        self.healthInterval = healthInterval
        self.keepaliveInterval = keepaliveInterval
        self.downgradeAfter = downgradeAfter
        self.punchBackoff = punchBackoff
        self.maxPunchRounds = maxPunchRounds
        self.punchRounds = punchRounds
        self.punchInterval = punchInterval
        self.streamChunkBytes = streamChunkBytes
        self.stunBudget = stunBudget
        self.acceptorPunchWindow = acceptorPunchWindow
        self.punchAnswerGrace = punchAnswerGrace
        self.candidateGrace = candidateGrace
    }

    /// How long to wait after `afterFailures` failed punch rounds.
    ///
    /// - Parameter afterFailures: how many have failed so far. Zero means
    ///   "the first attempt", which waits for nothing.
    /// - Returns: the delay before the next attempt.
    public func punchDelay(afterFailures: Int) -> Duration {
        guard afterFailures > 0, !punchBackoff.isEmpty else { return .zero }
        let index = min(afterFailures - 1, punchBackoff.count - 1)
        return punchBackoff[index]
    }

    /// Whether another punch round is allowed.
    ///
    /// - Parameter completedRounds: how many have completed, failed or not.
    /// - Returns: whether to try again.
    public func allowsAnotherRound(completedRounds: Int) -> Bool {
        completedRounds < maxPunchRounds
    }
}
