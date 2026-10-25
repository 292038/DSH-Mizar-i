//
//  MizarNetNATMatrixTests.swift
//  MizarKitTests
//
//  The NAT matrix, as tests.
//
//  Gated behind MIZAR_NAT_MATRIX=1 because the whole matrix is a couple of
//  minutes of wall clock and the repo's rule is to keep the default test
// loop cheap:
//
//     MIZAR_NAT_MATRIX=1 scripts/swift.sh test --filter MizarNetNATMatrix
//
//  Every cell is a real connection between two real engines behind two
//  simulated NATs. The expected outcomes are not wishes — they are what
//  the NAT literature says should happen, written down before the run:
//  cone meets cone anywhere in the matrix, one symmetric side is fine
//  against anything but a port-restricted peer, two symmetric sides never
//  meet, and a blocked side is a wall. When reality disagrees, the
//  disagreement is the finding.
//
//  Serialized because each row is a dozen tasks over real timers: run in
//  parallel, rows starve each other's 20 ms dial poll and a punch that
//  lands in 70 ms on an idle machine lands after its budget on a busy one.
//  The matrix is a correctness harness, not a benchmark — wall clock is
//  the price of a trustworthy verdict.
//

import Foundation
import Testing
import MizarKit
import MizarNetNATLab

@Suite(
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["MIZAR_NAT_MATRIX"] != nil),
)
struct MizarNetNATMatrixTests {
    /// What the NAT literature predicts for a cell.
    ///
    /// - A blocked side drops everything, so nothing works.
    /// - A symmetric dialer's hello leaves from the mapping it opened
    ///   toward the acceptor, which is not the mapping STUN reported — a
    ///   port-restricted acceptor compares exactly that port and drops it.
    /// - A symmetric acceptor answers from its per-destination mapping,
    ///   which is not the address a port-restricted dialer sent to.
    /// - Two symmetric sides never agree on an address at all.
    /// - Everything else — cone meets cone, in any combination — punches.
    static func expected(_ dialer: SimulatedNATBehavior, _ acceptor: SimulatedNATBehavior) -> Bool {
        if dialer == .blocked || acceptor == .blocked { return false }
        if dialer == .symmetric && acceptor == .symmetric { return false }
        if dialer == .symmetric && acceptor == .portRestricted { return false }
        if dialer == .portRestricted && acceptor == .symmetric { return false }
        return true
    }

    /// Run one row of the matrix and check every cell against the literature.
    private func runRow(_ dialer: SimulatedNATBehavior) async throws {
        let cells = NATMatrixLab.allBehaviors.map { NATCell(dialer: dialer, acceptor: $0) }
        let results = await NATMatrixLab.run(cells)
        print(NATMatrixLab.table(results))
        for result in results {
            let want = Self.expected(result.cell.dialer, result.cell.acceptor)
            #expect(
                (result.outcome == .punched) == want,
                "\(result.cell.label): expected \(want ? "a punch" : "no punch"), got \(result.outcome)",
            )
        }
    }

    @Test("a dialer on the public internet reaches every acceptor")
    func publicNetworkRow() async throws {
        try await runRow(.publicNetwork)
    }

    @Test("a dialer behind a full-cone NAT reaches every acceptor")
    func fullConeRow() async throws {
        try await runRow(.fullCone)
    }

    @Test("a dialer behind an address-restricted NAT reaches every acceptor")
    func addressRestrictedRow() async throws {
        try await runRow(.addressRestricted)
    }

    @Test("a dialer behind a port-restricted NAT fails only against a symmetric acceptor")
    func portRestrictedRow() async throws {
        try await runRow(.portRestricted)
    }

    @Test("a dialer behind a symmetric NAT fails against port-restricted and symmetric acceptors")
    func symmetricRow() async throws {
        try await runRow(.symmetric)
    }

    @Test("a dialer with UDP blocked reaches nothing")
    func blockedRow() async throws {
        try await runRow(.blocked)
    }

    @Test("carrier-grade NAT behaves like its outermost layer")
    func carrierGradeNAT() async throws {
        // The far side only ever sees the outer NAT, so a symmetric inner
        // layer is masked behind a cone outer one — and a symmetric outer
        // layer fails against a port-restricted peer exactly as it would
        // unchained.
        let cells = [
            NATCell(dialer: .portRestricted, acceptor: .fullCone, dialerUpstream: .portRestricted),
            NATCell(dialer: .portRestricted, acceptor: .fullCone, dialerUpstream: .symmetric),
            NATCell(dialer: .portRestricted, acceptor: .portRestricted, dialerUpstream: .portRestricted),
            NATCell(dialer: .portRestricted, acceptor: .portRestricted, dialerUpstream: .symmetric),
        ]
        let expected = [true, true, true, false]
        let results = await NATMatrixLab.run(cells)
        print(NATMatrixLab.table(results))
        for (index, result) in results.enumerated() {
            #expect(
                (result.outcome == .punched) == expected[index],
                "\(result.cell.label): expected \(expected[index] ? "a punch" : "no punch"), got \(result.outcome)",
            )
        }
    }
}
