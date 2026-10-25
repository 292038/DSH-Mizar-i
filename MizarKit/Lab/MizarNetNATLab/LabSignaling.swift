//
//  LabSignaling.swift
//  MizarNetNATLab
//
//  A signaling channel that is a wire between two actors.
//
//  This is the loopback signaling pair the kernel tests use, promoted into
//  the lab target so both the unit tests and the NAT matrix share one
// implementation. In the matrix it plays the relay: candidates travel over
// it while the packets themselves try to go direct — which is the same
// split the production flow has, where signaling rides the relay and the
// session tries not to.
//

import Foundation
import MizarKit

/// Two ends of one signaling channel.
public actor LabSignalingTransport: MizarNetSignalingTransport {
    private nonisolated let stream: AsyncStream<MizarNetSignal>
    private let continuation: AsyncStream<MizarNetSignal>.Continuation
    private var partner: LabSignalingTransport?
    private var closed = false

    private(set) public var sent: [MizarNetSignal] = []
    private(set) public var received: [MizarNetSignal] = []

    public init() {
        let made = AsyncStream<MizarNetSignal>.makeStream(of: MizarNetSignal.self, bufferingPolicy: .unbounded)
        self.stream = made.stream
        self.continuation = made.continuation
    }

    /// Two ends of one channel.
    public static func pair() async -> (LabSignalingTransport, LabSignalingTransport) {
        let a = LabSignalingTransport()
        let b = LabSignalingTransport()
        await a.setPartner(b)
        await b.setPartner(a)
        return (a, b)
    }

    private func setPartner(_ other: LabSignalingTransport) {
        partner = other
    }

    public func send(_ signal: MizarNetSignal) async throws {
        guard !closed else {
            throw MizarNetError.signalingFailed(reason: "the channel is closed")
        }
        sent.append(signal)
        await partner?.receive(signal)
    }

    private func receive(_ signal: MizarNetSignal) {
        received.append(signal)
        continuation.yield(signal)
    }

    public nonisolated func signals() -> AsyncStream<MizarNetSignal> {
        stream
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        continuation.finish()
    }
}
