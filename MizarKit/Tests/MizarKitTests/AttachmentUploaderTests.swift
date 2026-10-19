//
//  AttachmentUploaderTests.swift
//  MizarKitTests
//
//  The chunked-upload sequence, driven by a scripted bridge.
//
//  Three properties are worth a test each, because all three fail silently in
//  production:
//
//  - the slices are 128 KiB and indexed from zero, exactly as the host's
//    idempotency rule assumes;
//  - the host's chosen chunk size from `upload.begin` is honoured, because the
//    host's limit is the one that matters;
//  - every failure after `begin` sends `upload.abort`, so a cancelled upload does
//    not leave a half-received file on the host for its whole TTL.
//

import Foundation
import Testing
@testable import MizarKit

/// Where one upload's progress values land.
///
/// A lock rather than a plain array because the progress closure is `@Sendable`:
/// the uploader may call it from whatever executor it runs on, and the test must
/// not be the thing that races.
private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []

    func record(_ value: Double) {
        lock.lock()
        defer { lock.unlock() }
        values.append(value)
    }

    var recorded: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

@Suite("AttachmentUploader")
struct AttachmentUploaderTests {
    /// A scripted bridge that records calls and answers per method.
    actor ScriptedBridge {
        struct Recorded: Sendable {
            let method: String
            let payload: JSONValue
        }

        private(set) var calls: [Recorded] = []
        /// What `upload.begin` answers.
        var beginAnswer: JSONValue?
        /// What every `upload.chunk` answers; `nil` means "no acknowledgment".
        var chunkAnswer: JSONValue? = .object(["received": .number(1)])
        /// What `upload.finish` answers.
        var finishAnswer: JSONValue?
        /// Send a failure when the method matches.
        var failure: (method: String, error: MizarError)?
        /// The chunk index (0-based) whose acknowledgment is deliberately wrong.
        var badAckIndex: Int?

        func setBegin(_ value: JSONValue?) { beginAnswer = value }
        func setFinish(_ value: JSONValue?) { finishAnswer = value }
        func setFailure(method: String, error: MizarError) { failure = (method, error) }
        func setBadAck(index: Int) { badAckIndex = index }

        func call(_ method: String, _ payload: JSONValue) async throws -> JSONValue? {
            calls.append(Recorded(method: method, payload: payload))
            if let failure, failure.method == method { throw failure.error }
            switch method {
            case "upload.begin":
                return beginAnswer
            case "upload.chunk":
                if let badAckIndex, payload["index"]?.intValue == badAckIndex {
                    return .object(["received": .number(Double(badAckIndex + 99))])
                }
                // The real host answers the index it now holds; the scripted one
                // mirrors that whenever the test has not replaced it.
                if let index = payload["index"]?.intValue {
                    return .object(["received": .number(Double(index + 1))])
                }
                return chunkAnswer
            case "upload.finish":
                return finishAnswer
            case "upload.abort":
                return .object(["aborted": .bool(true)])
            default:
                return nil
            }
        }

        func recordedCalls() -> [Recorded] { calls }
    }

    private static func beginAnswer(chunkBytes: Int = 131_072) -> JSONValue {
        .object([
            "uploadId": .string("up-1"),
            "chunkBytes": .number(Double(chunkBytes)),
        ])
    }

    private static func finishedRef(name: String = "photo.jpg") -> JSONValue {
        .object([
            "attachmentId": .string("att-1"),
            "kind": .string("image"),
            "name": .string(name),
            "mediaType": .string("image/jpeg"),
            "byteSize": .number(300_000),
        ])
    }

    private func makeUploader(_ bridge: ScriptedBridge) -> AttachmentUploader {
        AttachmentUploader { method, payload in
            try await bridge.call(method, payload)
        }
    }

    @Test("uploads in 128 KiB chunks and finishes")
    func chunking() async throws {
        let bridge = ScriptedBridge()
        await bridge.setBegin(Self.beginAnswer())
        await bridge.setFinish(Self.finishedRef())
        let uploader = makeUploader(bridge)
        let data = Data(repeating: 0xAB, count: 300_000)

        let progress = ProgressRecorder()
        let ref = try await uploader.upload(
            sessionId: "s-1",
            kind: .image,
            name: "photo.jpg",
            mediaType: "image/jpeg",
            data: data,
            progress: { value in progress.record(value) },
        )

        #expect(ref.attachmentId == "att-1")
        #expect(ref.kind == .image)
        #expect(ref.byteSize == 300_000)

        let calls = await bridge.recordedCalls()
        #expect(calls.map(\.method) == [
            "upload.begin", "upload.chunk", "upload.chunk", "upload.chunk", "upload.finish",
        ])
        #expect(calls[0].payload["sessionId"]?.stringValue == "s-1")
        #expect(calls[0].payload["kind"]?.stringValue == "image")
        #expect(calls[0].payload["byteSize"]?.intValue == 300_000)

        // 300000 = 131072 + 131072 + 37856.
        #expect(calls[1].payload["index"]?.intValue == 0)
        #expect(calls[2].payload["index"]?.intValue == 1)
        #expect(calls[3].payload["index"]?.intValue == 2)
        let firstChunk = try #require(calls[1].payload["data"]?.stringValue)
        #expect(Data(base64Encoded: firstChunk)?.count == 131_072)
        let lastChunk = try #require(calls[3].payload["data"]?.stringValue)
        #expect(Data(base64Encoded: lastChunk)?.count == 300_000 - 2 * 131_072)

        let values = progress.recorded
        #expect(values.count == 4)
        #expect(values == values.sorted())
        #expect(values.last == 1.0)
    }

    @Test("uses the chunk size the host asked for")
    func honoursHostChunkSize() async throws {
        let bridge = ScriptedBridge()
        await bridge.setBegin(Self.beginAnswer(chunkBytes: 100_000))
        await bridge.setFinish(Self.finishedRef())
        let uploader = makeUploader(bridge)

        _ = try await uploader.upload(
            sessionId: "s-1",
            kind: .file,
            name: "a.bin",
            mediaType: "application/octet-stream",
            data: Data(repeating: 7, count: 250_000),
        )
        let chunks = await bridge.recordedCalls().filter { $0.method == "upload.chunk" }
        // 250000 / 100000 = three chunks.
        #expect(chunks.count == 3)
        #expect(chunks.last?.payload["index"]?.intValue == 2)
    }

    @Test("an empty file begins and finishes without chunks")
    func emptyFile() async throws {
        let bridge = ScriptedBridge()
        await bridge.setBegin(Self.beginAnswer())
        await bridge.setFinish(Self.finishedRef())
        let uploader = makeUploader(bridge)

        _ = try await uploader.upload(
            sessionId: "s-1",
            kind: .file,
            name: "empty.txt",
            mediaType: "text/plain",
            data: Data(),
        )
        let methods = await bridge.recordedCalls().map(\.method)
        #expect(methods == ["upload.begin", "upload.finish"])
    }

    @Test("aborts when the host refuses a chunk, and keeps the first error")
    func abortOnChunkFailure() async throws {
        let bridge = ScriptedBridge()
        await bridge.setBegin(Self.beginAnswer())
        await bridge.setFinish(Self.finishedRef())
        await bridge.setFailure(
            method: "upload.chunk",
            error: MizarError(code: "UPLOAD_BAD_CHUNK", message: "nope", retryable: false),
        )
        let uploader = makeUploader(bridge)

        do {
            _ = try await uploader.upload(
                sessionId: "s-1",
                kind: .image,
                name: "photo.jpg",
                mediaType: "image/jpeg",
                data: Data(repeating: 1, count: 200_000),
            )
            Issue.record("expected a failure")
        } catch let error as MizarError {
            #expect(error.code == "UPLOAD_BAD_CHUNK")
        }
        let methods = await bridge.recordedCalls().map(\.method)
        #expect(methods.last == "upload.abort")
        #expect(methods.contains("upload.finish") == false)
    }

    @Test("aborts when the host acknowledges the wrong chunk")
    func abortOnBadAck() async throws {
        let bridge = ScriptedBridge()
        await bridge.setBegin(Self.beginAnswer())
        await bridge.setFinish(Self.finishedRef())
        await bridge.setBadAck(index: 0)
        let uploader = makeUploader(bridge)

        do {
            _ = try await uploader.upload(
                sessionId: "s-1",
                kind: .image,
                name: "photo.jpg",
                mediaType: "image/jpeg",
                data: Data(repeating: 1, count: 200_000),
            )
            Issue.record("expected a failure")
        } catch let error as MizarError {
            #expect(error.code == "UPLOAD_BAD_CHUNK")
        }
        let methods = await bridge.recordedCalls().map(\.method)
        #expect(methods.last == "upload.abort")
    }

    @Test("aborts when the finish is refused")
    func abortOnFinishFailure() async throws {
        let bridge = ScriptedBridge()
        await bridge.setBegin(Self.beginAnswer())
        await bridge.setFailure(
            method: "upload.finish",
            error: MizarError(code: "UPLOAD_INCOMPLETE", message: "missing", retryable: false),
        )
        let uploader = makeUploader(bridge)

        do {
            _ = try await uploader.upload(
                sessionId: "s-1",
                kind: .file,
                name: "a.bin",
                mediaType: "application/octet-stream",
                data: Data(repeating: 2, count: 10),
            )
            Issue.record("expected a failure")
        } catch let error as MizarError {
            #expect(error.code == "UPLOAD_INCOMPLETE")
        }
        #expect(await bridge.recordedCalls().last?.method == "upload.abort")
    }

    @Test("reports a refused begin without trying to abort")
    func beginFailure() async throws {
        let bridge = ScriptedBridge()
        await bridge.setFailure(
            method: "upload.begin",
            error: MizarError(code: "NOT_IMPLEMENTED", message: "method not implemented", retryable: false),
        )
        let uploader = makeUploader(bridge)

        do {
            _ = try await uploader.upload(
                sessionId: "s-1",
                kind: .file,
                name: "a.bin",
                mediaType: "application/octet-stream",
                data: Data(repeating: 2, count: 10),
            )
            Issue.record("expected a failure")
        } catch let error as MizarError {
            #expect(error.code == "NOT_IMPLEMENTED")
        }
        // There is no upload id to abort with; a call nobody can address would
        // be noise on the wire and an error in the log.
        let methods = await bridge.recordedCalls().map(\.method)
        #expect(methods == ["upload.begin"])
    }
}
