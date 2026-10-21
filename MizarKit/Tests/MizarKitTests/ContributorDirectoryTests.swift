//
//  ContributorDirectoryTests.swift
//  MizarKitTests
//
//  The merge rules: who is a contributor, who is a tool, and what a 304 or a
//  bad day at GitHub does to the list on screen.
//

import Foundation
import Testing
@testable import MizarKit

/// A transport that answers from a closure, keyed by path.
private struct CreditsStub: ContributorTransport {
    let handler: @Sendable (URL) -> String?
    /// Every URL asked for, so staleness can be asserted.
    final class Log: @unchecked Sendable {
        var urls: [String] = []
    }
    let log = Log()

    func get(_ url: URL, etag: String?) async throws -> ContributorHTTPResponse {
        log.urls.append(url.absoluteString)
        guard let body = handler(url) else {
            throw ContributorError("no fixture for \(url.path)")
        }
        return ContributorHTTPResponse(status: 200, data: Data(body.utf8), etag: nil)
    }
}

/// A clock the test can move.
private final class Clock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

private let repos = [
    ContributorRepo(owner: "ShirazuNagisa", name: "DSH-Mizar"),
    ContributorRepo(owner: "ShirazuNagisa", name: "DSH-Mizar-Android"),
]

private func contributorJSON(_ login: String, _ commits: Int) -> String {
    """
    [{"login":"\(login)","type":"User","avatar_url":"https://avatars.example/\(login).png",
      "html_url":"https://github.com/\(login)","contributions":\(commits)}]
    """
}

private func commitJSON(author: String, email: String, message: String) -> String {
    let escaped = message
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
    return """
    [{"author":{"login":"\(author)"},"commit":{"message":"\(escaped)","author":{"email":"\(email)","name":"\(author)"}}}]
    """
}

@Test("merges the repositories, resolves a co-author by name, and drops the tools")
func mergesAndFilters() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("credits-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let transport = CreditsStub { url in
        if url.path.hasSuffix("/DSH-Mizar-Android/contributors") { return contributorJSON("Arowey", 147) }
        if url.path.hasSuffix("/DSH-Mizar/contributors") { return contributorJSON("ShirazuNagisa", 86) }
        if url.path.hasSuffix("/DSH-Mizar/commits") {
            return commitJSON(
                author: "ShirazuNagisa",
                email: "shirazu@example.com",
                message: "feat: something\n\nCo-authored-by: Arowey <2859290647@qq.com>\nCo-authored-by: Claude Opus 5.5 <noreply@anthropic.com>",
            )
        }
        if url.path.hasSuffix("/DSH-Mizar-Android/commits") { return "[]" }
        return nil
    }
    let clock = Clock(Date(timeIntervalSince1970: 1_790_000_000))
    let store = ContributorDirectory(
        cacheDirectory: directory,
        transport: transport,
        now: { clock.now },
        repositories: repos,
    )
    let snapshot = try #require(await store.refresh(force: true))
    #expect(snapshot.contributors.map(\.login).sorted() == ["Arowey", "ShirazuNagisa"])
    let arowey = try #require(snapshot.contributors.first { $0.login == "Arowey" })
    #expect(arowey.coAuthored == 1)
    #expect(!snapshot.contributors.contains { $0.login.lowercased().contains("claude") })

    // The cache is on disk and can be read again.
    let reopened = ContributorDirectory(cacheDirectory: directory, transport: transport, now: { clock.now }, repositories: repos)
    await reopened.load()
    #expect(await reopened.current()?.contributors.count == 2)
}

@Test("does not refresh inside the day")
func staleness() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("credits-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let transport = CreditsStub { url in
        if url.path.hasSuffix("/contributors") { return contributorJSON("ShirazuNagisa", 1) }
        if url.path.hasSuffix("/commits") { return "[]" }
        return nil
    }
    let clock = Clock(Date(timeIntervalSince1970: 1_790_000_000))
    let store = ContributorDirectory(cacheDirectory: directory, transport: transport, now: { clock.now }, repositories: repos)
    _ = await store.refreshIfStale()
    let requests = transport.log.urls.count
    _ = await store.refreshIfStale()
    #expect(transport.log.urls.count == requests, "a second call inside 24h hit GitHub again")

    clock.now = clock.now.addingTimeInterval(25 * 60 * 60)
    _ = await store.refreshIfStale()
    #expect(transport.log.urls.count > requests, "a day later did not refresh")
}

@Test("a failure keeps the cached list and reports it as stale")
func failureKeepsTheCache() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("credits-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let clock = Clock(Date(timeIntervalSince1970: 1_790_000_000))
    let good = CreditsStub { url in
        if url.path.hasSuffix("/contributors") { return contributorJSON("ShirazuNagisa", 3) }
        if url.path.hasSuffix("/commits") { return "[]" }
        return nil
    }
    let store = ContributorDirectory(cacheDirectory: directory, transport: good, now: { clock.now }, repositories: repos)
    #expect(await store.refreshIfStale() != nil)

    let broken = CreditsStub { _ in nil }
    let failing = ContributorDirectory(cacheDirectory: directory, transport: broken, now: { clock.now }, repositories: repos)
    let snapshot = await failing.refresh(force: true)
    #expect(snapshot?.contributors.count == 1, "the cached list was thrown away")
    let state = await failing.currentState()
    #expect(state != .ready)
}

@Test("sums one person's commits across every repository")
func sumsCommitsAcrossRepositories() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("credits-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    // The real numbers, in shape: one author on two repositories and another on
    // one. The two-repository author must sort first, and the count must be the
    // sum rather than the last repository's share.
    let transport = CreditsStub { url in
        if url.path.hasSuffix("/DSH-Mizar/contributors") { return contributorJSON("ShirazuNagisa", 86) }
        if url.path.hasSuffix("/DSH-Mizar-iOS/contributors") { return contributorJSON("ShirazuNagisa", 139) }
        if url.path.hasSuffix("/DSH-Mizar-Android/contributors") { return contributorJSON("Arowey", 147) }
        if url.path.hasSuffix("/commits") { return "[]" }
        return nil
    }
    let store = ContributorDirectory(
        cacheDirectory: directory,
        transport: transport,
        repositories: [
            ContributorRepo(owner: "ShirazuNagisa", name: "DSH-Mizar"),
            ContributorRepo(owner: "ShirazuNagisa", name: "DSH-Mizar-iOS"),
            ContributorRepo(owner: "ShirazuNagisa", name: "DSH-Mizar-Android"),
        ],
    )
    let snapshot = try #require(await store.refresh(force: true))
    let shirazu = try #require(snapshot.contributors.first { $0.login == "ShirazuNagisa" })
    #expect(shirazu.commits == 225, "a repository's share replaced the running total")
    #expect(snapshot.contributors.first?.login == "ShirazuNagisa", "the most commits did not sort first")
}

@Test("a first launch with no network still shows the project's two people")
func failureSeedsTheList() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("credits-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let broken = CreditsStub { _ in nil }
    let store = ContributorDirectory(cacheDirectory: directory, transport: broken, repositories: repos)
    let snapshot = try #require(await store.refresh(force: true))
    #expect(snapshot.contributors.map(\.login).sorted() == ["Arowey", "ShirazuNagisa"],
            "an unreachable GitHub left the credits empty")
    let state = await store.currentState()
    if case .stale = state {} else {
        Issue.record("a seeded list should be marked stale, not ready")
    }
}
