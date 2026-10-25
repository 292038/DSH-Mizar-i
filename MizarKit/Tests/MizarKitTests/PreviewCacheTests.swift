//
//  PreviewCacheTests.swift
//  MizarKitTests
//
//  The copy on disk: when it may be trusted, and how it stops growing.
//
//  Three properties matter and each is a bug if it fails. A cached copy must only
//  be used when the host agrees it is current (otherwise a preview shows
//  yesterday's report under today's name); a write must never leave a half file
//  that decodes as a corrupt document; and the cache must not fill the phone.
//

import Foundation
import Testing
@testable import MizarKit

@Suite("Preview cache")
struct PreviewCacheTests {
    private static func directory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mizar-preview-cache-\(UUID().uuidString)", isDirectory: true)
    }

    private static func facts(_ name: String, size: Int, modified: Double = 1_700_000_000_000) -> FileFacts {
        FileFacts(
            path: "docs/\(name)",
            name: name,
            byteSize: size,
            modifiedAt: modified,
            mediaType: "text/markdown",
            previewable: true,
        )
    }

    @Test
    func storesAndReturnsACurrentCopy() async {
        let cache = FilePreviewCache(directory: Self.directory())
        let key = PreviewCacheKey(hostId: "h1", sessionId: "s1", path: "docs/report.md")
        let data = Data("# Report".utf8)

        let url = await cache.store(data, for: key, facts: Self.facts("report.md", size: data.count))
        #expect(url != nil)
        #expect(url.flatMap { try? Data(contentsOf: $0) } == data)

        let hit = await cache.cached(key, matching: Self.facts("report.md", size: data.count))
        #expect(hit == url)
    }

    @Test
    func refusesACopyTheHostSaysChanged() async {
        let cache = FilePreviewCache(directory: Self.directory())
        let key = PreviewCacheKey(hostId: "h1", sessionId: "s1", path: "docs/report.md")
        let data = Data("one".utf8)
        await cache.store(data, for: key, facts: Self.facts("report.md", size: data.count))

        // Same size, later modification: the operator edited the file.
        #expect(await cache.cached(key, matching: Self.facts("report.md", size: 3, modified: 1_800_000_000_000)) == nil)
        // Different size, same modification time: a file replaced in place.
        #expect(await cache.cached(key, matching: Self.facts("report.md", size: 99)) == nil)
    }

    @Test
    func stillHandsBackTheCopyWhenNothingCanBeAsked() async {
        // The offline path: no `stat`, no opinion, but the operator already read
        // this file once and the page says so.
        let cache = FilePreviewCache(directory: Self.directory())
        let key = PreviewCacheKey(hostId: "h1", sessionId: "s1", path: "docs/report.md")
        await cache.store(Data("x".utf8), for: key, facts: Self.facts("report.md", size: 1))
        #expect(await cache.cached(key) != nil)
    }

    @Test
    func keepsTwoComputersAndTwoSessionsApart() async {
        // The path is relative to a session's working directory, so the same
        // string on another computer or in another session is another file.
        let cache = FilePreviewCache(directory: Self.directory())
        let base = PreviewCacheKey(hostId: "h1", sessionId: "s1", path: "docs/report.md")
        let otherHost = PreviewCacheKey(hostId: "h2", sessionId: "s1", path: "docs/report.md")
        let otherSession = PreviewCacheKey(hostId: "h1", sessionId: "s2", path: "docs/report.md")

        await cache.store(Data("one".utf8), for: base, facts: Self.facts("report.md", size: 3))
        #expect(await cache.cached(otherHost) == nil)
        #expect(await cache.cached(otherSession) == nil)
    }

    @Test
    func aPathThatLooksLikeTraversalCannotEscape() async {
        // The path comes from a model. A cache keyed on it must not become a
        // directory traversal, whatever it contains.
        let root = Self.directory()
        let cache = FilePreviewCache(directory: root)
        let key = PreviewCacheKey(hostId: "../../etc", sessionId: "..", path: "../../../etc/passwd")
        let url = await cache.store(Data("x".utf8), for: key, facts: Self.facts("passwd", size: 1))
        let path = url?.standardizedFileURL.path ?? ""
        #expect(path.hasPrefix(root.standardizedFileURL.path))
    }

    @Test
    func reportsItsSizeAndCount() async {
        let cache = FilePreviewCache(directory: Self.directory())
        #expect(await cache.totalSize() == 0)
        #expect(await cache.fileCount() == 0)

        for index in 0..<3 {
            let name = "f\(index).md"
            let data = Data(repeating: UInt8(index), count: 100)
            await cache.store(
                data,
                for: PreviewCacheKey(hostId: "h", sessionId: "s", path: name),
                facts: Self.facts(name, size: data.count),
            )
        }
        #expect(await cache.fileCount() == 3)
        #expect(await cache.totalSize() == 300)
    }

    @Test
    func clearingLeavesNothingBehind() async {
        let cache = FilePreviewCache(directory: Self.directory())
        let key = PreviewCacheKey(hostId: "h", sessionId: "s", path: "a.md")
        await cache.store(Data("x".utf8), for: key, facts: Self.facts("a.md", size: 1))
        await cache.clear()
        #expect(await cache.cached(key) == nil)
        #expect(await cache.totalSize() == 0)
    }

    @Test
    func evictsTheOldestWhenOverItsLimit() async {
        let cache = FilePreviewCache(directory: Self.directory(), limit: 250)
        for index in 0..<4 {
            let name = "f\(index).md"
            let data = Data(repeating: UInt8(index), count: 100)
            await cache.store(
                data,
                for: PreviewCacheKey(hostId: "h", sessionId: "s", path: name),
                facts: Self.facts(name, size: data.count),
            )
            // The eviction order is the stored order, and a store that lands in
            // the same millisecond as the last one would tie; a short wait keeps
            // the test about the rule rather than about clock resolution.
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(await cache.totalSize() <= 250)
        #expect(await cache.fileCount() == 2)
        #expect(await cache.cached(PreviewCacheKey(hostId: "h", sessionId: "s", path: "f0.md")) == nil)
        #expect(await cache.cached(PreviewCacheKey(hostId: "h", sessionId: "s", path: "f3.md")) != nil)
    }
}

@Suite("Preview history")
struct PreviewHistoryTests {
    @Test
    func remembersTheLastFilePerSession() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mizar-preview-history-\(UUID().uuidString)", isDirectory: true)
        let store = PreviewHistoryStore(directory: directory)

        await store.remember(PreviewTarget(
            sessionId: "s1",
            hostId: "h",
            file: DeliveredFile(path: "a.md", detail: "A"),
        ))
        await store.remember(PreviewTarget(
            sessionId: "s1",
            hostId: "h",
            file: DeliveredFile(path: "b.pdf"),
        ))
        await store.remember(PreviewTarget(
            sessionId: "s2",
            hostId: "h",
            file: DeliveredFile(path: "c.docx"),
        ))

        #expect(await store.last(for: "s1")?.path == "b.pdf")
        #expect(await store.last(for: "s2")?.path == "c.docx")
        #expect(await store.last(for: "s3") == nil)
    }

    @Test
    func survivesARelaunch() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mizar-preview-history-\(UUID().uuidString)", isDirectory: true)
        let first = PreviewHistoryStore(directory: directory)
        await first.remember(PreviewTarget(
            sessionId: "s1",
            hostId: "h",
            file: DeliveredFile(path: "docs/report.md", detail: "报告"),
        ))

        // A second store is what the next launch builds.
        let second = PreviewHistoryStore(directory: directory)
        let restored = await second.last(for: "s1")
        #expect(restored?.path == "docs/report.md")
        #expect(restored?.detail == "报告")
        #expect(restored?.kind == .markdown)
    }

    @Test
    func forgettingEverythingEmptiesIt() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mizar-preview-history-\(UUID().uuidString)", isDirectory: true)
        let store = PreviewHistoryStore(directory: directory)
        await store.remember(PreviewTarget(sessionId: "s1", hostId: "h", file: DeliveredFile(path: "a.md")))
        await store.forgetAll()
        #expect(await store.last(for: "s1") == nil)
    }
}
