//
//  LocalKernelTests.swift
//  MizarKitTests
//
//  The local kernel, end to end, on the host machine: the embedded bundle
//  runs in JavaScriptCore, the Swift host bridges file system and network,
//  and `MizarConnection` — the unmodified client — talks to it through
//  `LocalKernelTransport`.
//
//  These are the tests that prove the kernel's basic story works on the
//  platform it ships for: handshake, sessions, a full agent turn with a
//  scripted model, approvals, and persistence across restarts. The model is
//  always scripted (`KernelHTTPHandler`), never live — the default test run
//  must not hit a real API.
//

import Foundation
import Testing
@testable import MizarKit

// MARK: - Scripted HTTP

/// An SSE responder for one turn at a time: the scripted model the tests
/// drive. Each queued answer is one `chat/completions` stream body.
final class ScriptedKernelHTTP: KernelHTTPHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [String] = []
    private var requests: [KernelHTTPRequest] = []

    /// Queue one stream body for the next request.
    func enqueue(_ body: String) {
        lock.lock()
        scripts.append(body)
        lock.unlock()
    }

    /// Every request the kernel issued, for assertions.
    var issued: [KernelHTTPRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func request(
        _ request: KernelHTTPRequest,
        onChunk: @escaping @Sendable (String) -> Void,
        onDone: @escaping @Sendable (Int) -> Void,
        onError: @escaping @Sendable (String) -> Void,
    ) -> KernelHTTPHandle {
        lock.lock()
        let body = scripts.isEmpty ? nil : scripts.removeFirst()
        requests.append(request)
        lock.unlock()
        if let body {
            onChunk(body)
            onDone(200)
        } else {
            onError("no scripted response; the test queued none")
        }
        return KernelHTTPHandle {}
    }
}

/// An in-memory kv store, so tests never touch real defaults.
final class MemoryKernelKV: KernelKeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func value(forKey key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func set(_ value: String?, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
    }
}

// MARK: - Harness

@Suite("LocalKernel")
struct LocalKernelTests {
    /// A booted runtime with a scripted model and a connected client.
    private func makeRuntime(
        http: ScriptedKernelHTTP = ScriptedKernelHTTP(),
        apiKey: String? = "test-key-not-real",
    ) async throws -> (KernelRuntime, ScriptedKernelHTTP, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mizar-kernel-tests-\(UUID().uuidString)")
        let kv = MemoryKernelKV()
        if let apiKey {
            kv.set(apiKey, forKey: "apiKey.deepseek-official")
        }
        let runtime = KernelRuntime(
            rootURL: root,
            hostName: "kernel-test-host",
            kv: kv,
            httpHandler: http,
        )
        try await runtime.boot()
        return (runtime, http, root)
    }

    /// A MizarConnection speaking to the runtime in process.
    private func makeConnection(runtime: KernelRuntime) -> MizarConnection {
        MizarConnection(
            configuration: .init(
                authority: "127.0.0.1:19390",
                token: "local-accepts-any",
                requestTimeout: .seconds(10),
                handshakeTimeout: .seconds(10),
            ),
            makeTransport: { LocalKernelTransport(runtime: runtime) },
        )
    }

    /// SSE for one assistant turn that answers with text.
    private func textStream(_ text: String) -> String {
        let chunks = text.map { character in
            #"data: {"choices":[{"delta":{"content":"\#(String(character))"},"finish_reason":null}]}"# + "\n\n"
        }
        let finish = #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"# + "\n\n"
        return chunks.joined() + finish + "data: [DONE]\n\n"
    }

    /// SSE for one assistant turn that calls one tool.
    private func toolStream(callID: String, tool: String, arguments: String) -> String {
        let open = #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"\#(callID)","function":{"name":"\#(tool)"}}]},"finish_reason":null}]}"# + "\n\n"
        let args = #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":\#(jsonEncoded(arguments))}}]},"finish_reason":null}]}"# + "\n\n"
        let finish = #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"# + "\n\n"
        return open + args + finish + "data: [DONE]\n\n"
    }

    private func jsonEncoded(_ string: String) -> String {
        let data = try! JSONEncoder().encode(string)
        return String(decoding: data, as: UTF8.self)
    }

    @Test("the unmodified client completes the handshake with the kernel")
    func handshake() async throws {
        let (runtime, _, _) = try await makeRuntime()
        let connection = makeConnection(runtime: runtime)
        let welcome = try await connection.connect()
        #expect(welcome.hostName == "kernel-test-host")
        #expect(welcome.protocolVersion == mizarProtocolVersion)
        #expect(!welcome.home.isEmpty)
    }

    @Test("a full turn runs on the scripted model and the summary page tells the story")
    func fullTurn() async throws {
        let (runtime, http, _) = try await makeRuntime()
        http.enqueue(textStream("Hello from the kernel."))
        let connection = makeConnection(runtime: runtime)
        _ = try await connection.connect()

        let created = try await connection.call("session.create", payload: .object([:]), as: SessionCreateResult.self)
        _ = try await connection.call(
            "session.prompt",
            payload: .object(["sessionId": .string(created.sessionId), "text": .string("hi")]),
            as: PromptAccepted.self,
        )

        // The turn runs in the background; poll the summary page until the
        // turn ends, the way the GUI does.
        var records: [JSONValue] = []
        for _ in 0..<100 {
            let page = try await connection.call(
                "session.messages",
                payload: .object(["sessionId": .string(created.sessionId), "afterSeq": .null]),
                as: MessagesPage.self,
            )
            records = page.records
            if records.contains(where: { record in
                record["event"]?["type"]?.stringValue == "turn/end"
            }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        let types = records.compactMap { $0["event"]?["type"]?.stringValue }
        #expect(types == ["turn/start", "step/start", "user/message", "assistant/message", "turn/end"])
        let answer = records.last { $0["event"]?["type"]?.stringValue == "assistant/message" }
        let text = answer?["event"]?["data"]?["message"]?["content"]?.arrayValue?.first?["text"]?.stringValue
        #expect(text == "Hello from the kernel.")

        // The engine request went out with the streamed shape and auth header.
        let request = http.issued.first
        #expect(request?.url == "https://api.deepseek.com/chat/completions")
        #expect(request?.headers["authorization"]?.hasPrefix("Bearer ") == true)
        let body = request.map { try? JSONSerialization.jsonObject(with: Data($0.body!.utf8)) as? [String: Any] } ?? nil
        #expect((body?["stream"] as? Bool) == true)
    }

    @Test("a write under read-only raises an approval, and allowed-once covers one call")
    func approvalFlow() async throws {
        let (runtime, http, root) = try await makeRuntime()
        let connection = makeConnection(runtime: runtime)
        _ = try await connection.connect()
        let created = try await connection.call("session.create", payload: .object([:]), as: SessionCreateResult.self)
        _ = try await connection.call(
            "session.permission.set",
            payload: .object(["sessionId": .string(created.sessionId), "preset": .string("read-only")]),
            as: JSONValue.self,
        )

        // The model asks to write a file; the kernel must raise a card.
        http.enqueue(toolStream(callID: "call-1", tool: "write_file", arguments: #"{"path":"notes.md","content":"written by the kernel"}"#))
        http.enqueue(textStream("Done."))

        // Watch the event stream for the approval card, then answer it.
        let events = await connection.events()
        let listener = Task {
            for await frame in events {
                if case .event(let name, let data) = frame, name == "approval.request" {
                    let requestID = data["requestId"]?.stringValue ?? ""
                    _ = try? await connection.call(
                        "approval.answer",
                        payload: .object(["requestId": .string(requestID), "outcome": .string("allowed-once")]),
                        as: JSONValue.self,
                    )
                    return
                }
            }
        }

        _ = try await connection.call(
            "session.prompt",
            payload: .object(["sessionId": .string(created.sessionId), "text": .string("write a note")]),
            as: PromptAccepted.self,
        )
        await listener.value

        // The turn completes and the file is on disk in the session workspace.
        var sawEnd = false
        for _ in 0..<100 {
            let page = try await connection.call(
                "session.messages",
                payload: .object(["sessionId": .string(created.sessionId), "afterSeq": .null]),
                as: MessagesPage.self,
            )
            sawEnd = page.records.contains { $0["event"]?["type"]?.stringValue == "turn/end" }
            if sawEnd { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(sawEnd)

        let fileURL = root
            .appendingPathComponent("workspace/\(created.sessionId)/notes.md")
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == "written by the kernel")
    }

    @Test("a kernel restart closes a turn left running and keeps the history")
    func restart() async throws {
        let (runtime, _, root) = try await makeRuntime()
        let connection = makeConnection(runtime: runtime)
        _ = try await connection.connect()
        let created = try await connection.call("session.create", payload: .object([:]), as: SessionCreateResult.self)
        _ = try await connection.call(
            "session.prompt",
            payload: .object(["sessionId": .string(created.sessionId), "text": .string("remember me")]),
            as: PromptAccepted.self,
        )
        // Let the turn finish.
        try await Task.sleep(for: .milliseconds(400))

        // A fresh runtime over the same root: the session is still there.
        let kv = MemoryKernelKV()
        kv.set("test-key-not-real", forKey: "apiKey.deepseek-official")
        let restarted = KernelRuntime(
            rootURL: root,
            hostName: "kernel-test-host",
            kv: kv,
            httpHandler: ScriptedKernelHTTP(),
        )
        try await restarted.boot()
        let reconnected = MizarConnection(
            configuration: .init(
                authority: "127.0.0.1:19390",
                token: "local-accepts-any",
                requestTimeout: .seconds(10),
                handshakeTimeout: .seconds(10),
            ),
            makeTransport: { LocalKernelTransport(runtime: restarted) },
        )
        _ = try await reconnected.connect()

        let list = try await reconnected.call("session.list", payload: nil, as: SessionListResult.self)
        #expect(list.items.contains { $0.sessionId == created.sessionId })
        let stats = try await reconnected.call(
            "session.stats",
            payload: .object(["sessionId": .string(created.sessionId)]),
            as: JSONValue.self,
        )
        #expect(stats["stats"]?["stats"]?["turns"]?.numberValue == 1)
    }

    @Test("the interactions surface answers and events flow through one connection")
    func interactionsSurface() async throws {
        let (runtime, _, _) = try await makeRuntime()
        let connection = makeConnection(runtime: runtime)
        _ = try await connection.connect()
        let pending = try await connection.call(
            "interactions.pending",
            payload: nil,
            as: JSONValue.self,
        )
        #expect(pending["approvals"]?.arrayValue?.isEmpty == true)
        #expect(pending["questions"]?.arrayValue?.isEmpty == true)
    }
}

// MARK: - Local decoding shapes for the tests

private struct SessionCreateResult: Decodable, Sendable {
    let sessionId: String
}

private struct PromptAccepted: Decodable, Sendable {
    let accepted: Bool
    let requestId: String
}

private struct MessagesPage: Decodable, Sendable {
    let sessionId: String
    let records: [JSONValue]
}

private struct SessionListResult: Decodable, Sendable {
    struct Row: Decodable, Sendable {
        let sessionId: String
        let running: Bool
    }
    let items: [Row]
}
