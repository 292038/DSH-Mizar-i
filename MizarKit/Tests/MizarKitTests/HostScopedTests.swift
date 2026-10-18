//
//  HostScopedTests.swift
//  MizarKitTests
//
//  What belongs to one computer is not drawn under another.
//
//  The app has had this bug three times: a value read for one subject drawn for
//  another. Each fix has been the same shape -- tag the value, refuse it for
//  anything but its own subject -- and this is that shape for the machine.
//

import Foundation
import Testing
@testable import MizarKit

@Suite("Host scoping")
struct HostScopedTests {
    private let first = HostTag(hostId: "mac-a", epoch: 1)
    private let second = HostTag(hostId: "mac-b", epoch: 2)

    @Test("a value is readable for the machine it was read for")
    func readsForItsOwnSubject() {
        var catalog = HostScoped<String>()
        catalog.publish("deepseek", for: first)
        #expect(catalog.value(for: first) == "deepseek")
    }

    @Test("a value read for one machine is not readable for the next")
    func refusesAnotherMachinesSubject() {
        var catalog = HostScoped<String>()
        catalog.publish("deepseek", for: first)
        // The defect, in one line: the second computer has no catalogue of its own
        // yet, and the first computer's is still here. It must read as absent rather
        // than as this machine's answer.
        #expect(catalog.value(for: second) == nil)
    }

    @Test("a value is not readable over a new connection to the same machine")
    func refusesAReconnectedSubject() {
        var catalog = HostScoped<String>()
        catalog.publish("deepseek", for: first)
        // A reconnect is the case a host id alone would let through: the same
        // machine, a different socket, and a value read over the old one.
        let reconnected = HostTag(hostId: first.hostId, epoch: first.epoch + 1)
        #expect(catalog.value(for: reconnected) == nil)
    }

    @Test("a read that lands after the machine changed is dropped")
    func dropsAReadThatLostItsSubject() {
        var sessions = HostScoped<[String]>()
        // A read started for the first computer. While it was in flight the operator
        // switched, so the subject it was started for is no longer current.
        let started = first
        let current = second
        let answer = ["session-a"]
        if current == started { sessions.publish(answer, for: started) }
        #expect(sessions.value(for: current) == nil)
        #expect(sessions.held == nil, "the dropped read is still held for somebody to read")
    }

    @Test("publishing for a new machine replaces the old value rather than joining it")
    func replacesRatherThanJoins() {
        var catalog = HostScoped<[String]>()
        catalog.publish(["deepseek", "openrouter"], for: first)
        catalog.publish(["moonshot"], for: second)
        #expect(catalog.value(for: second) == ["moonshot"])
        #expect(catalog.value(for: first) == nil)
    }

    @Test("clearing leaves nothing readable, for any subject")
    func clears() {
        var pending = HostScoped<String>()
        pending.publish("a question", for: first)
        pending.clear()
        #expect(pending.value(for: first) == nil)
        #expect(pending.held == nil)
    }

    @Test("with no machine connected, nothing scoped is readable")
    func refusesAnAbsentSubject() {
        var pending = HostScoped<String>()
        pending.publish("a question", for: first)
        // A disconnected screen has no subject, so what it holds cannot be an
        // answer about anything. This is the read the screens make between a
        // socket going down and another coming up.
        let none: HostTag? = nil
        #expect(pending.value(for: none) == nil)
    }

    @Test("what is held is readable for an archive after the connection is gone")
    func heldOutlivesItsSubject() {
        var pending = HostScoped<String>()
        pending.publish("a question", for: first)
        // The log export is built after the socket is closed and describes what
        // the phone holds; reading it through the subject would report an empty
        // archive for a phone that has one.
        #expect(pending.held == "a question")
    }
}
