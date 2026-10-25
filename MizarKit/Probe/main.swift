//
//  main.swift
//  mizar-net-probe
//
//  A command-line endpoint for cross-language tests.
//
//  The TypeScript engine and this one implement the same protocol; the only
//  way to know they agree is to make them talk. This binary is the Swift half
//  of that conversation: it binds a socket, prints where it is, and either
//  waits for a dial or makes one. The Node suite (`dsh/test/p2p-interop.test.ts`)
//  starts it and speaks to it over loopback.
//
//  Deliberately built only on MizarKit's public API: if this needed internals,
//  the engine would not be usable from another module, which is the property
//  the app is supposed to rely on.
//
//  Usage:
//
//      mizar-net-probe accept --secret <hex32> [--purpose host|device]
//      mizar-net-probe dial --secret <hex32> --peer <endpointId> --address <ip:port>
//
//  Output, one fact per line, flushed immediately so a parent process can
//  parse it without guessing:
//
//      ID <endpointId>          both modes, once the identity is known
//      PORT <n>                 accept mode, once the socket is bound
//      RECEIVED <text>          accept mode, the message it was sent
//      REPLY <text>             dial mode, what came back
//
//  Exit codes: 0 success, 2 failure, 3 timeout, 64 bad arguments.
//

import Foundation
import MizarKit

/// Write a line and flush: a parent process is reading this.
func emit(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

/// Write a line to stderr and stop with a code.
func die(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

/// Parse `--key value` pairs and one positional mode.
func parseArguments() -> (mode: String, options: [String: String]) {
    var mode = ""
    var options: [String: String] = [:]
    var index = 1
    let arguments = CommandLine.arguments
    while index < arguments.count {
        let argument = arguments[index]
        if argument.hasPrefix("--") {
            guard index + 1 < arguments.count else { die("missing value for \(argument)", code: 64) }
            options[String(argument.dropFirst(2))] = arguments[index + 1]
            index += 2
        } else {
            mode = argument
            index += 1
        }
    }
    guard !mode.isEmpty else { die("expected accept or dial", code: 64) }
    return (mode, options)
}

/// The bytes a hex string names.
func decodeHex(_ text: String) -> Data? {
    guard text.count % 2 == 0 else { return nil }
    var data = Data(capacity: text.count / 2)
    var index = text.startIndex
    while index < text.endIndex {
        let next = text.index(index, offsetBy: 2)
        guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
        data.append(byte)
        index = next
    }
    return data
}

/// Race a long-running operation against a deadline.
///
/// `receive()` has no timeout of its own — the app's reconnect policy is what
/// bounds it — so a probe that needs to fail rather than hang has to supply
/// one.
func withDeadline<T: Sendable>(_ seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw ProbeError.timedOut
        }
        guard let first = try await group.next() else { throw ProbeError.timedOut }
        group.cancelAll()
        return first
    }
}

/// What can go wrong that is the probe's own business.
enum ProbeError: Error {
    case timedOut
    case missingOption(String)
    case badSecret
}

let (mode, options) = parseArguments()

guard let secretHex = options["secret"], let secret = decodeHex(secretHex), secret.count == 32 else {
    die("--secret must be 32 hex-encoded bytes", code: 64)
}

/// The role a probe plays decides which purpose its key is derived under, so a
/// test can exercise both derivations without a second binary.
let purpose: MizarNetIdentity.Purpose = options["purpose"] == "device" ? .device : .host
let identity = MizarNetIdentity.derived(from: secret, purpose: purpose)

/// The probe's own numbers. Short on purpose: a test that hangs is a test
/// nobody runs.
let policy = MizarNetPathPolicy.standard

/// No STUN: the test hands over a loopback address, and a STUN query would
/// only add an external dependency to a hermetic test.
let engine = MizarNetQUICEngine(identity: identity, policy: policy, stunServers: [])

do {
    switch mode {
    case "accept":
        let connection = MizarNetConnection(
            engine: engine,
            ticket: MizarNetTicket(endpointId: identity.endpointId),
            policy: policy,
        )
        try await engine.start()
        emit("ID \(identity.endpointId)")
        // The socket is bound now; the port is what a caller dials. Taken from
        // the candidates rather than the engine so it is the same address the
        // wire would carry.
        let port = await engine.localCandidates().first?.port ?? 0
        emit("PORT \(port)")

        let stream = try await withDeadline(20) { try await connection.accept() }
        let message = try await withDeadline(20) { try await stream.receive() } ?? Data()
        emit("RECEIVED \(String(decoding: message, as: UTF8.self))")
        try await stream.send(Data(("echo:" + String(decoding: message, as: UTF8.self)).utf8))
        // Give the write a moment to leave the socket before the process ends:
        // a closed descriptor can drop a datagram that was already queued.
        try await Task.sleep(for: .milliseconds(200))
        await connection.close()
        exit(0)

    case "dial":
        guard let peer = options["peer"] else { die("--peer is required", code: 64) }
        guard let address = options["address"] else { die("--address is required", code: 64) }
        let connection = MizarNetConnection(
            engine: engine,
            ticket: MizarNetTicket(endpointId: peer, direct: [address]),
            policy: policy,
        )
        emit("ID \(identity.endpointId)")
        let stream = try await withDeadline(20) { try await connection.connect() }
        try await stream.send(Data("ping".utf8))
        let reply = try await withDeadline(20) { try await stream.receive() } ?? Data()
        emit("REPLY \(String(decoding: reply, as: UTF8.self))")
        try await Task.sleep(for: .milliseconds(200))
        await connection.close()
        exit(0)

    default:
        die("expected accept or dial", code: 64)
    }
} catch ProbeError.timedOut {
    die("timed out", code: 3)
} catch {
    die("failed: \(error)", code: 2)
}
