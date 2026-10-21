//
//  ContributorDirectory.swift
//  MizarKit
//
//  Who worked on the four DSH-Mizar repositories, fetched from GitHub.
//
//  Two sources, because GitHub has two: the contributors endpoint names the
//  people who authored commits, and commit trailers name the people who were
//  credited with them (`Co-authored-by:`). The second is where AI tools show up,
//  and it is also where a human who only ever co-authored appears. Both are read;
//  both are filtered.
//
//  The result is cached on disk for a day, with avatars beside it, because the
//  Settings screen must draw something when GitHub is unreachable -- which, from
//  a phone in China, is a normal Tuesday.
//

import Foundation

/// One GitHub repository the credits are collected from.
public struct ContributorRepo: Sendable, Hashable, Codable {
    /// The owner, `ShirazuNagisa`.
    public let owner: String
    /// The repository name, `DSH-Mizar-iOS`.
    public let name: String

    public init(owner: String, name: String) {
        self.owner = owner
        self.name = name
    }

    /// The four repositories the app is built from.
    public static let all: [ContributorRepo] = [
        ContributorRepo(owner: "ShirazuNagisa", name: "DSH-Mizar"),
        ContributorRepo(owner: "ShirazuNagisa", name: "DSH-Mizar-iOS"),
        ContributorRepo(owner: "ShirazuNagisa", name: "DSH-Mizar-Relay"),
        ContributorRepo(owner: "ShirazuNagisa", name: "DSH-Mizar-Android"),
    ]
}

/// One person on the credits screen.
public struct Contributor: Codable, Sendable, Equatable, Identifiable {
    /// The GitHub handle, which is also the identity of the row.
    public let login: String
    /// A display name, when GitHub gave one.
    public let name: String?
    /// `https://github.com/<login>`.
    public let profileURL: URL
    /// The avatar, when one was found.
    public let avatarURL: URL?
    /// Commits credited by the contributors endpoint.
    public let commits: Int
    /// Commits this person co-authored, counted from trailers.
    public let coAuthored: Int
    /// The repositories they appear in, by name.
    public let repositories: [String]

    public init(
        login: String,
        name: String? = nil,
        profileURL: URL,
        avatarURL: URL? = nil,
        commits: Int,
        coAuthored: Int = 0,
        repositories: [String] = [],
    ) {
        self.login = login
        self.name = name
        self.profileURL = profileURL
        self.avatarURL = avatarURL
        self.commits = commits
        self.coAuthored = coAuthored
        self.repositories = repositories
    }

    public var id: String { login }

    /// What the row says under the name.
    public var detail: String {
        var parts: [String] = []
        if commits > 0 {
            parts.append(commits == 1 ? "1 commit" : "\(commits) commits")
        }
        if coAuthored > 0 {
            parts.append(coAuthored == 1 ? "1 co-authored" : "\(coAuthored) co-authored")
        }
        return parts.isEmpty ? "Contributor" : parts.joined(separator: " · ")
    }
}

/// What a refresh produced.
public struct ContributorSnapshot: Codable, Sendable, Equatable {
    public let fetchedAt: Date
    public let contributors: [Contributor]

    public init(fetchedAt: Date, contributors: [Contributor]) {
        self.fetchedAt = fetchedAt
        self.contributors = contributors
    }
}

/// Where the directory is in its load.
public enum ContributorState: Sendable, Equatable {
    case idle
    case loading
    case ready
    case stale(String)
    case failed(String)
}

/// One HTTP answer, enough for ETag caching.
public struct ContributorHTTPResponse: Sendable {
    public let status: Int
    public let data: Data
    public let etag: String?

    public init(status: Int, data: Data, etag: String?) {
        self.status = status
        self.data = data
        self.etag = etag
    }
}

/// The network seam, injectable so the merge rules can be tested without GitHub.
public protocol ContributorTransport: Sendable {
    func get(_ url: URL, etag: String?) async throws -> ContributorHTTPResponse
}

/// A failure the directory reports rather than throws upward.
public struct ContributorError: Error, Sendable, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// `URLSession`, with the two headers GitHub asks for.
public struct URLSessionContributorTransport: ContributorTransport {
    private let session: URLSession

    public init(timeout: TimeInterval = 20) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        self.session = URLSession(configuration: configuration)
    }

    public func get(_ url: URL, etag: String?) async throws -> ContributorHTTPResponse {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("DSH-Mizar/0.9.5", forHTTPHeaderField: "User-Agent")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ContributorError("GitHub did not answer with HTTP")
        }
        if http.statusCode == 304 {
            return ContributorHTTPResponse(status: 304, data: Data(), etag: etag)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ContributorError("GitHub answered \(http.statusCode)")
        }
        return ContributorHTTPResponse(
            status: 200,
            data: data,
            etag: http.value(forHTTPHeaderField: "ETag"),
        )
    }
}

/// The cached, refreshed directory.
public actor ContributorDirectory {
    /// How long a snapshot is trusted.
    public static let refreshInterval: TimeInterval = 24 * 60 * 60
    /// The shortest gap between two manual refreshes.
    public static let manualInterval: TimeInterval = 60

    private let cacheDirectory: URL
    private let transport: any ContributorTransport
    private let now: @Sendable () -> Date
    private let repositories: [ContributorRepo]
    private var snapshot: ContributorSnapshot?
    private var etags: [String: String] = [:]
    private var loaded = false
    private var refreshing = false
    private var state: ContributorState = .idle
    private var lastAttempt = Date.distantPast

    /// - Parameters:
    ///   - cacheDirectory: where `contributors.json` and `avatars/` live.
    ///   - transport: the network; a stub in tests.
    ///   - now: the clock, so staleness is testable.
    ///   - repositories: the four repositories by default.
    public init(
        cacheDirectory: URL,
        transport: any ContributorTransport = URLSessionContributorTransport(),
        now: @escaping @Sendable () -> Date = Date.init,
        repositories: [ContributorRepo] = ContributorRepo.all,
    ) {
        self.cacheDirectory = cacheDirectory
        self.transport = transport
        self.now = now
        self.repositories = repositories
    }

    /// The directory's cache directory, created on demand.
    public static func defaultCacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Mizar/Credits", isDirectory: true)
    }

    /// Read the cache once.
    public func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: cacheFile) else { return }
        guard let file = try? JSONDecoder().decode(CacheFile.self, from: data) else { return }
        guard file.version >= Self.cacheVersion else {
            // An older build's cache: the counts it holds were added up wrong,
            // so it is not worth showing. The next refresh writes a new one.
            return
        }
        snapshot = file.snapshot
        etags = file.etags
        state = .ready
    }

    /// What is on disk, or `nil` before the first successful fetch.
    public func current() -> ContributorSnapshot? {
        snapshot
    }

    /// The latest state, for the screen.
    public func currentState() -> ContributorState {
        state
    }

    /// Whether the cached snapshot is older than a day.
    public var isStale: Bool {
        guard let snapshot else { return true }
        return now().timeIntervalSince(snapshot.fetchedAt) >= Self.refreshInterval
    }

    /// Refresh only when the cache is missing or a day old.
    @discardableResult
    public func refreshIfStale() async -> ContributorSnapshot? {
        load()
        guard isStale else { return snapshot }
        return await refresh(force: false)
    }

    /// Fetch from GitHub and replace the cache.
    ///
    /// - Parameter force: bypass the 60-second manual throttle.
    /// - Returns: the snapshot, or the previous one when the fetch failed.
    @discardableResult
    public func refresh(force: Bool) async -> ContributorSnapshot? {
        load()
        if refreshing { return snapshot }
        let attemptAt = now()
        if !force, attemptAt.timeIntervalSince(lastAttempt) < Self.manualInterval {
            return snapshot
        }
        refreshing = true
        lastAttempt = attemptAt
        state = .loading
        defer { refreshing = false }
        do {
            var merged = try await fetchAll()
            // Seed the two people the project cannot be built without, when a
            // fetch returns nobody (an empty GitHub answer is not a credits
            // screen).
            if merged.isEmpty { merged = Self.seed }
            let made = ContributorSnapshot(fetchedAt: now(), contributors: merged)
            snapshot = made
            try persist(made)
            await downloadAvatars(for: merged)
            state = .ready
            return made
        } catch {
            let message = (error as? ContributorError)?.message ?? error.localizedDescription
            if let existing = snapshot {
                state = .stale(message)
                return existing
            }
            // Never leave the section empty: an unreachable GitHub on a first
            // launch reads as "the credits were never implemented". The two
            // people the project cannot be built without are shown instead,
            // with the failure beside them.
            let seeded = ContributorSnapshot(fetchedAt: .distantPast, contributors: Self.seed)
            snapshot = seeded
            state = .stale(message)
            return seeded
        }
    }

    /// The avatar bytes for one login, if they were saved.
    public func avatarData(for login: String) -> Data? {
        try? Data(contentsOf: avatarFile(login))
    }

    // MARK: - Fetching

    private func fetchAll() async throws -> [Contributor] {
        var byLogin: [String: MutableContributor] = [:]
        var emailToLogin: [String: String] = [:]
        var loginsByName: [String: String] = [:]
        var coAuthors: [String: (name: String?, count: Int, repos: Set<String>)] = [:]
        var commitsByRepo: [(repo: String, commits: [GitHubCommit])] = []

        // Pass one: names, avatars, and the email→login table that a co-author
        // trailer is resolved against.
        for repo in repositories {
            let contributors = try await fetchContributors(repo)
            for entry in contributors {
                guard !Self.isExcluded(login: entry.login, name: nil, email: nil) else { continue }
                var record = byLogin[entry.login] ?? MutableContributor(entry: entry)
                // Summed, not assigned: the same person authored on several
                // repositories, and the last one seen used to overwrite the
                // others -- which put a 255-commit author under a 147-commit one.
                record.commits += entry.contributions
                record.repos.insert(repo.name)
                if record.avatarURL == nil { record.avatarURL = entry.avatarURL }
                byLogin[entry.login] = record
                loginsByName[entry.login.lowercased()] = entry.login
            }

            let commits = try await fetchCommits(repo)
            commitsByRepo.append((repo: repo.name, commits: commits))
            for commit in commits {
                if let login = commit.author?.login, !login.isEmpty,
                   let email = commit.commit.author?.email, !email.isEmpty {
                    emailToLogin[email.lowercased()] = login
                    if byLogin[login] == nil, !Self.isExcluded(login: login, name: nil, email: nil) {
                        byLogin[login] = MutableContributor(login: login, avatarURL: nil, commits: 0)
                        loginsByName[login.lowercased()] = login
                    }
                    if var record = byLogin[login] {
                        record.repos.insert(repo.name)
                        byLogin[login] = record
                    }
                }
            }
        }

        // Pass two: resolve trailers now that every repository has contributed
        // to the name and email tables. Resolving inside pass one lost a
        // co-author whose GitHub login only appeared in a *later* repository.
        for (repoName, commits) in commitsByRepo {
            for commit in commits {
                for trailer in Self.coAuthors(in: commit.commit.message) {
                    guard !Self.isExcluded(login: "", name: trailer.name, email: trailer.email) else { continue }
                    guard let login = resolve(trailer, emailToLogin: emailToLogin, loginsByName: loginsByName) else {
                        continue
                    }
                    var record = coAuthors[login] ?? (name: trailer.name, count: 0, repos: [])
                    record.count += 1
                    record.repos.insert(repoName)
                    coAuthors[login] = record
                }
            }
        }

        for (login, record) in coAuthors {
            if var existing = byLogin[login] {
                existing.coAuthored += record.count
                existing.repos.formUnion(record.repos)
                if existing.name == nil { existing.name = record.name }
                byLogin[login] = existing
            } else {
                guard !Self.isExcluded(login: login, name: record.name, email: nil) else { continue }
                guard let profile = URL(string: "https://github.com/\(login)") else { continue }
                let avatar = try? await fetchUserAvatar(login)
                byLogin[login] = MutableContributor(
                    login: login,
                    name: record.name,
                    profileURL: profile,
                    avatarURL: avatar,
                    commits: 0,
                    coAuthored: record.count,
                    repos: record.repos,
                )
            }
        }

        return byLogin.values
            .map(\.value)
            .sorted {
                if $0.commits + $0.coAuthored != $1.commits + $1.coAuthored {
                    return $0.commits + $0.coAuthored > $1.commits + $1.coAuthored
                }
                return $0.login.lowercased() < $1.login.lowercased()
            }
    }

    private func fetchContributors(_ repo: ContributorRepo) async throws -> [GitHubContributor] {
        let urlString = "https://api.github.com/repos/\(repo.owner)/\(repo.name)/contributors?per_page=100"
        guard let url = URL(string: urlString) else { throw ContributorError("bad URL") }
        let response = try await cachedGet(url)
        guard response.status != 304 else { return [] }
        return (try? JSONDecoder().decode([GitHubContributor].self, from: response.data)) ?? []
    }

    private func fetchCommits(_ repo: ContributorRepo) async throws -> [GitHubCommit] {
        var out: [GitHubCommit] = []
        for page in 1...20 {
            let urlString =
                "https://api.github.com/repos/\(repo.owner)/\(repo.name)/commits?per_page=100&page=\(page)"
            guard let url = URL(string: urlString) else { break }
            let response = try await cachedGet(url)
            guard response.status != 304 else { break }
            let batch = (try? JSONDecoder().decode([GitHubCommit].self, from: response.data)) ?? []
            out.append(contentsOf: batch)
            if batch.count < 100 { break }
        }
        return out
    }

    private func fetchUserAvatar(_ login: String) async throws -> URL? {
        guard let url = URL(string: "https://api.github.com/users/\(login)") else { return nil }
        let response = try await cachedGet(url)
        guard response.status != 304 else { return nil }
        let user = try? JSONDecoder().decode(GitHubUser.self, from: response.data)
        return user?.avatarURL
    }

    /// GET one URL.
    ///
    /// No conditional requests: a 304 would mean "the body you already have is
    /// still right", and this directory keeps only the merged result, not the
    /// per-URL bodies it came from. A dozen requests a day is well inside
    /// GitHub's anonymous budget.
    private func cachedGet(_ url: URL) async throws -> ContributorHTTPResponse {
        try await transport.get(url, etag: nil)
    }

    /// Resolve one trailer to a GitHub login.
    private func resolve(
        _ trailer: (name: String, email: String),
        emailToLogin: [String: String],
        loginsByName: [String: String],
    ) -> String? {
        let email = trailer.email.lowercased()
        if email.hasSuffix("@users.noreply.github.com") {
            if let plus = email.firstIndex(of: "+"), let at = email.firstIndex(of: "@") {
                let numeric = email[email.startIndex..<plus]
                let login = String(email[email.index(after: plus)..<at])
                if numeric.allSatisfy(\.isNumber), !login.isEmpty { return login }
            }
        }
        if let mapped = emailToLogin[email] { return mapped }
        if let byName = loginsByName[trailer.name.lowercased()] { return byName }
        return nil
    }

    // MARK: - Filtering

    /// Handles and mail domains that are tools rather than people.
    private static let deniedLogins: Set<String> = [
        "claude", "claude-code", "anthropic", "anthropic-ai", "openai", "chatgpt",
        "zwork", "copilot", "github-actions", "dependabot", "cursor", "codex",
        "aider", "devin", "gemini", "windsurf", "sourcegraph",
    ]

    private static let deniedDomains: [String] = [
        "anthropic.com", "openai.com", "cursor.com", "zwork.dev", "zwork.ai",
        "copilot.github.com", "noreply.anthropic.com",
    ]

    private static func isExcluded(login: String, name: String?, email: String?) -> Bool {
        let handle = login.lowercased()
        if handle.hasSuffix("[bot]") || deniedLogins.contains(handle) { return true }
        if let email, let domain = email.lowercased().split(separator: "@").last.map(String.init) {
            if deniedDomains.contains(domain) { return true }
        }
        if let name {
            let lowered = name.lowercased()
            for tool in ["claude", "chatgpt", "zwork", "copilot", "codex", "anthropic", "openai"] {
                if lowered == tool || lowered.hasPrefix("\(tool) ") || lowered.hasPrefix("\(tool)-") {
                    return true
                }
            }
        }
        return false
    }

    /// The `Co-authored-by:` trailers in one message.
    private static func coAuthors(in message: String) -> [(name: String, email: String)] {
        var out: [(name: String, email: String)] = []
        for line in message.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("co-authored-by:") else { continue }
            let rest = trimmed.dropFirst("co-authored-by:".count).trimmingCharacters(in: .whitespaces)
            guard let open = rest.lastIndex(of: "<"), rest.hasSuffix(">") else { continue }
            let name = String(rest[..<open]).trimmingCharacters(in: .whitespaces)
            let email = String(rest[rest.index(after: open)..<rest.index(before: rest.endIndex)])
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            if !email.isEmpty { out.append((name: name, email: email)) }
        }
        return out
    }

    // MARK: - Storage

    private struct CacheFile: Codable {
        let version: Int
        let snapshot: ContributorSnapshot
        let etags: [String: String]
    }

    /// Bumped when the merge rules change: a cache written by an older build
    /// holds counts those rules produced, and keeping it for a day would show
    /// the wrong order for a day.
    private static let cacheVersion = 2

    private var cacheFile: URL { cacheDirectory.appendingPathComponent("contributors.json") }

    private func avatarFile(_ login: String) -> URL {
        cacheDirectory
            .appendingPathComponent("avatars", isDirectory: true)
            .appendingPathComponent("\(login.lowercased()).png")
    }

    private func persist(_ snapshot: ContributorSnapshot) throws {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(
            CacheFile(version: Self.cacheVersion, snapshot: snapshot, etags: etags),
        )
        try data.write(to: cacheFile, options: .atomic)
    }

    private func downloadAvatars(for contributors: [Contributor]) async {
        let avatars = cacheDirectory.appendingPathComponent("avatars", isDirectory: true)
        try? FileManager.default.createDirectory(at: avatars, withIntermediateDirectories: true)
        var saved: Set<String> = []
        for contributor in contributors.prefix(40) {
            let file = avatarFile(contributor.login)
            if FileManager.default.fileExists(atPath: file.path) {
                saved.insert(contributor.login.lowercased())
                continue
            }
            guard let url = contributor.avatarURL else { continue }
            guard let response = try? await transport.get(url, etag: nil),
                  response.status == 200, !response.data.isEmpty
            else { continue }
            try? response.data.write(to: file, options: .atomic)
            saved.insert(contributor.login.lowercased())
        }
        // Drop avatars for people no longer in the list.
        if let files = try? FileManager.default.contentsOfDirectory(at: avatars, includingPropertiesForKeys: nil) {
            for file in files where !saved.contains(file.deletingPathExtension().lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private static let seed: [Contributor] = [
        Contributor(
            login: "ShirazuNagisa",
            name: nil,
            profileURL: URL(string: "https://github.com/ShirazuNagisa")!,
            avatarURL: nil,
            commits: 0,
            coAuthored: 0,
            repositories: [],
        ),
        Contributor(
            login: "Arowey",
            name: nil,
            profileURL: URL(string: "https://github.com/Arowey")!,
            avatarURL: nil,
            commits: 0,
            coAuthored: 0,
            repositories: [],
        ),
    ]
}

// MARK: - Mutable accumulator

private struct MutableContributor {
    let login: String
    var name: String?
    let profileURL: URL
    var avatarURL: URL?
    var commits: Int
    var coAuthored: Int
    var repos: Set<String>

    init(entry: GitHubContributor) {
        self.login = entry.login
        self.name = nil
        self.profileURL = entry.htmlURL
        self.avatarURL = entry.avatarURL
        // Zero, not `entry.contributions`: the caller adds each repository's
        // share, and a starting value would count the first one twice.
        self.commits = 0
        self.coAuthored = 0
        self.repos = []
    }

    init(
        login: String,
        name: String? = nil,
        profileURL: URL? = nil,
        avatarURL: URL?,
        commits: Int,
        coAuthored: Int = 0,
        repos: Set<String> = [],
    ) {
        self.login = login
        self.name = name
        self.profileURL = profileURL ?? URL(string: "https://github.com/\(login)")!
        self.avatarURL = avatarURL
        self.commits = commits
        self.coAuthored = coAuthored
        self.repos = repos
    }

    var value: Contributor {
        Contributor(
            login: login,
            name: name,
            profileURL: profileURL,
            avatarURL: avatarURL,
            commits: commits,
            coAuthored: coAuthored,
            repositories: repos.sorted(),
        )
    }
}

// MARK: - GitHub's wire shapes

struct GitHubContributor: Decodable, Sendable {
    let login: String
    let type: String?
    let avatarURL: URL?
    let htmlURL: URL
    let contributions: Int

    private enum CodingKeys: String, CodingKey {
        case login, type, contributions
        case avatarURL = "avatar_url"
        case htmlURL = "html_url"
    }
}

struct GitHubCommit: Decodable, Sendable {
    struct Author: Decodable, Sendable {
        let login: String?
    }

    struct CommitAuthor: Decodable, Sendable {
        let email: String?
        let name: String?
    }

    struct CommitInfo: Decodable, Sendable {
        let message: String
        let author: CommitAuthor?
    }

    let author: Author?
    let commit: CommitInfo
}

struct GitHubUser: Decodable, Sendable {
    let avatarURL: URL?

    private enum CodingKeys: String, CodingKey {
        case avatarURL = "avatar_url"
    }
}
