//
//  LiveActivityAttributesTests.swift
//  MizarKitTests
//
//  What actually crosses the boundary between the app and the widget.
//
//  The two are separate processes with no shared memory and no shared call
//  stack: everything the island draws was encoded by one and decoded by the
//  other. That makes the encoding a wire format between two halves of one
//  feature, which is exactly the kind of thing a test should pin -- a rename or
//  a change of date strategy here is an activity that draws nothing, or draws a
//  clock counting from 2001, on somebody's phone.
//

import Foundation
import Testing
@testable import MizarKit

/// A fixed instant, so nothing here depends on the machine's clock.
private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

@Suite("The activity's attributes")
struct LiveActivityAttributesTests {
    @Test("are empty, so nothing but the state crosses the boundary")
    func attributesCarryNothing() throws {
        // Static attributes are for what varies between activities. This app
        // posts one kind of activity, so there is nothing to put in them -- and
        // the widget draws the title row itself rather than being handed a
        // string that can only go stale.
        let data = try JSONEncoder().encode(DSHMizarActivityAttributes())
        #expect(String(decoding: data, as: UTF8.self) == "{}")
        #expect(try JSONDecoder().decode(DSHMizarActivityAttributes.self, from: data) == DSHMizarActivityAttributes())
    }

    @Test("carry the rows and their clocks as the content state")
    func stateRoundTripsAsTheContentState() throws {
        let phase = LiveActivityPhase.running(rows: [
            LiveActivityRow(
                id: "s-1",
                prompt: "把登录页那个多余的转圈去掉…",
                elapsed: 134,
                countingSince: epoch.addingTimeInterval(-134),
            ),
            LiveActivityRow(id: "s-2", prompt: "run the tests", elapsed: 60, countingSince: epoch.addingTimeInterval(-60)),
        ])
        let data = try JSONEncoder().encode(phase)

        #expect(try JSONDecoder().decode(LiveActivityPhase.self, from: data) == phase)
        // A finished activity is the same trip with no rows: the check the
        // island draws is the *case*, not a row that says so.
        let finished = try JSONEncoder().encode(LiveActivityPhase.finished)
        #expect(try JSONDecoder().decode(LiveActivityPhase.self, from: finished) == .finished)
    }

    @Test("give each row's clock as a reference-date number")
    func clocksAreReferenceDateNumbers() throws {
        // The single most load-bearing field in the payload. The widget draws
        // `Text(row.countingSince, style: .timer)` and never asks the app for
        // the time again, so a date that arrived as an ISO string, or as
        // seconds since 1970 where the reader expected seconds since 2001, is a
        // clock on the island that is wrong by 31 years or absent entirely.
        let phase = LiveActivityPhase.running(rows: [
            LiveActivityRow(id: "s-1", prompt: "run", elapsed: 134, countingSince: epoch.addingTimeInterval(-134)),
        ])

        let json = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(phase)) as? [String: Any],
        )
        // The case name is the outer key and its payload is nested under it --
        // the shape the synthesised conformance writes for an enum with
        // associated values, and therefore the shape the widget reads.
        let payload = try #require(json["running"] as? [String: Any])
        let rows = try #require(payload["rows"] as? [[String: Any]])
        let first = try #require(rows.first)
        let since = try #require(first["countingSince"] as? NSNumber)
        // 134 seconds before the instant, as a plain number: the reference-date
        // double the encoder writes by default and the decoder reads by default.
        #expect(since.doubleValue == epoch.addingTimeInterval(-134).timeIntervalSinceReferenceDate)
        #expect((first["elapsed"] as? NSNumber)?.doubleValue == 134)
    }

    @Test("can be hashed, which is what the protocol asks of a content state")
    func stateHashes() {
        // `ActivityAttributes.ContentState` is `Hashable`. Nothing in the app
        // hashes a phase today; the conformance is a requirement of the type
        // system, and this is the smallest thing that fails if it is ever lost.
        let row = LiveActivityRow(id: "s-1", prompt: "run", elapsed: 1, countingSince: epoch)
        let states: Set<LiveActivityPhase> = [.running(rows: [row]), .finished, .running(rows: [row])]

        #expect(states.count == 2)
    }
}
