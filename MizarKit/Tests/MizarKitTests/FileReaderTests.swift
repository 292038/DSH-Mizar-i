//
//  FileReaderTests.swift
//  MizarKitTests
//
//  The download half of a preview, without a socket.
//
//  `FileReader` takes its `call` as a closure for exactly this: the tests drive
//  the whole slice loop against a table of answers, including the two shapes that
//  would hang a naive implementation — a slice that never advances, and a file
//  whose size the first slice corrects.
//

import Foundation
import Testing
@testable import MizarKit

@Suite("File reader")
struct FileReaderTests {
    /// A body big enough to need three slices at the size the tests ask for.
    private static let body = Data((0..<700).map { UInt8($0 % 251) })

    /// A reader whose host answers from `body`, slicing at `sliceSize`.
    ///
    /// Stateless: every answer is a function of the payload, which is also how
    /// the real host behaves.
    private static func reader(sliceSize: Int, eofAt: Int? = nil) -> FileReader {
        let body = Self.body
        return FileReader { method, payload in
            switch method {
            case "file.stat":
                return .object([
                    "path": .string(payload["path"]?.stringValue ?? ""),
                    "name": .string("data.md"),
                    "byteSize": .number(Double(body.count)),
                    "modifiedAt": .number(1_700_000_000_000),
                    "mediaType": .string("text/markdown"),
                    "previewable": .bool(true),
                ])
            case "file.read":
                let offset = payload["offset"]?.intValue ?? 0
                let asked = payload["length"]?.intValue ?? 0
                let end = min(offset + min(asked, sliceSize), eofAt ?? body.count)
                let slice = offset >= end ? Data() : body.subdata(in: offset..<end)
                return .object([
                    "offset": .number(Double(offset)),
                    "length": .number(Double(slice.count)),
                    "byteSize": .number(Double(body.count)),
                    "data": .string(slice.base64EncodedString()),
                    "eof": .bool(end >= body.count),
                ])
            default:
                throw MizarError(code: "MALFORMED_FRAME", message: "unexpected \(method)")
            }
        }
    }

    @Test
    func readsAFileInSlices() async throws {
        let reader = Self.reader(sliceSize: 300)
        let facts = try await reader.stat(sessionId: "s1", path: "docs/data.md")
        #expect(facts.name == "data.md")
        #expect(facts.byteSize == Self.body.count)

        let data = try await reader.read(sessionId: "s1", path: "docs/data.md")
        #expect(data == Self.body)
    }

    @Test
    func reportsProgressThatEndsAtOne() async throws {
        final class Progress: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [Double] = []
            func record(_ value: Double) { lock.lock(); values.append(value); lock.unlock() }
            var all: [Double] { lock.lock(); defer { lock.unlock() }; return values }
        }
        let progress = Progress()
        let reader = Self.reader(sliceSize: 300)
        _ = try await reader.read(
            sessionId: "s1",
            path: "docs/data.md",
            expectedSize: Self.body.count,
        ) { progress.record($0) }

        let values = progress.all
        #expect(!values.isEmpty)
        #expect(values.last == 1)
        #expect(values == values.sorted(), "progress must not go backwards")
    }

    @Test
    func aSliceThatNeverAdvancesIsAFailureNotALoop() async {
        // A host that answers `eof: false` with nothing in it would have the
        // client ask for the same offset forever. One throw, not a spin.
        let reader = FileReader { _, _ in
            .object([
                "offset": .number(0),
                "length": .number(0),
                "byteSize": .number(10),
                "data": .string(""),
                "eof": .bool(false),
            ])
        }
        await #expect(throws: MizarError.self) {
            _ = try await reader.read(sessionId: "s1", path: "a.md")
        }
    }

    @Test
    func aHostThatAnswersNothingIsAClearFailure() async {
        let reader = FileReader { _, _ in nil }
        await #expect(throws: MizarError.self) {
            _ = try await reader.stat(sessionId: "s1", path: "a.md")
        }
    }

    @Test
    func aRefusalKeepsItsCode() async {
        // The app branches on these: `FILE_FORBIDDEN` and `NOT_IMPLEMENTED` get
        // different sentences, and both are different from being offline.
        let reader = FileReader { _, _ in
            throw MizarError(code: "FILE_FORBIDDEN", message: "outside the workspace")
        }
        do {
            _ = try await reader.stat(sessionId: "s1", path: "../secret")
            Issue.record("expected a refusal")
        } catch let error as MizarError {
            #expect(error.code == "FILE_FORBIDDEN")
        } catch {
            Issue.record("expected a MizarError, got \(error)")
        }
    }

    @Test
    func asksForSlicesNoLargerThanTheFrameBudget() async throws {
        // 256 KiB of bytes is 341 KiB of base64, under the listener's 512 KiB
        // frame. The constant is asserted because a "tidy" round number here
        // would silently start failing on every file over a few hundred KB.
        #expect(FileReader.chunkBytes == 262_144)

        final class Asked: @unchecked Sendable {
            private let lock = NSLock()
            private var lengths: [Int] = []
            func record(_ value: Int) { lock.lock(); lengths.append(value); lock.unlock() }
            var all: [Int] { lock.lock(); defer { lock.unlock() }; return lengths }
        }
        let asked = Asked()
        let reader = FileReader { method, payload in
            if method == "file.read" { asked.record(payload["length"]?.intValue ?? 0) }
            return .object([
                "offset": .number(0),
                "length": .number(1),
                "byteSize": .number(1),
                "data": .string(Data([0]).base64EncodedString()),
                "eof": .bool(true),
            ])
        }
        _ = try await reader.read(sessionId: "s1", path: "a.bin")
        #expect(asked.all == [FileReader.chunkBytes])
    }
}
