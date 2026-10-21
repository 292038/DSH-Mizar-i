//
//  CreditsController.swift
//  DSH-Mizar
//
//  The credits row as the Settings screen reads it.
//
//  `ContributorDirectory` owns the fetching and the cache; this owns the object
//  SwiftUI observes, plus the decoded avatars. The split is the same one the
//  account uses: protocol work in MizarKit, presentation state in the app.
//

import Foundation
import MizarKit
import Observation
import UIKit

@MainActor
@Observable
final class CreditsController {
    /// The people to draw, newest fetch first.
    private(set) var contributors: [Contributor] = []
    /// Whether the list is loading, fresh, stale or failed.
    private(set) var state: ContributorState = .idle
    /// When the list on screen was fetched.
    private(set) var lastUpdated: Date?
    /// Decoded avatars, keyed by lowercased login.
    private(set) var avatars: [String: UIImage] = [:]

    private var directory: ContributorDirectory?
    private var started = false

    /// Load the cache and refresh when it is a day old.
    ///
    /// Safe to call from every screen that shows credits: the first call does
    /// the work, the rest are no-ops until the day is up.
    func start() async {
        guard !started else { return }
        started = true
        #if DEBUG
        // The UI suite cannot reach GitHub; this is the deterministic list its
        // credits assertions read. Never present in a release build.
        if ProcessInfo.processInfo.arguments.contains("-mizarCreditsFixture") {
            contributors = Self.fixture
            state = .ready
            lastUpdated = Date(timeIntervalSince1970: 1_790_000_000)
            return
        }
        #endif
        let directory = ContributorDirectory(cacheDirectory: ContributorDirectory.defaultCacheDirectory())
        self.directory = directory
        await directory.load()
        if let cached = await directory.current() { apply(cached) }
        if let refreshed = await directory.refreshIfStale() { apply(refreshed) }
        state = await directory.currentState()
    }

    /// Ask GitHub again. The directory throttles a manual refresh to once a minute.
    func refresh(force: Bool = true) async {
        if directory == nil { await start() }
        guard let directory else { return }
        state = .loading
        if let snapshot = await directory.refresh(force: force) { apply(snapshot) }
        state = await directory.currentState()
    }

    /// The avatar for one row, when it was saved locally.
    func avatar(for login: String) -> UIImage? {
        avatars[login.lowercased()]
    }

    private func apply(_ snapshot: ContributorSnapshot) {
        contributors = snapshot.contributors
        lastUpdated = snapshot.fetchedAt
        Task { await loadAvatars(snapshot.contributors) }
    }

    private func loadAvatars(_ list: [Contributor]) async {
        guard let directory else { return }
        var decoded: [String: UIImage] = [:]
        for contributor in list {
            guard let data = await directory.avatarData(for: contributor.login),
                  let image = UIImage(data: data)
            else { continue }
            decoded[contributor.login.lowercased()] = image
        }
        avatars = decoded
    }

    #if DEBUG
    /// Two rows for the UI suite, which has no network and no avatar cache.
    private static let fixture: [Contributor] = [
        Contributor(
            login: "ShirazuNagisa",
            profileURL: URL(string: "https://github.com/ShirazuNagisa")!,
            commits: 255,
            repositories: ["DSH-Mizar", "DSH-Mizar-iOS"],
        ),
        Contributor(
            login: "Arowey",
            profileURL: URL(string: "https://github.com/Arowey")!,
            commits: 147,
            repositories: ["DSH-Mizar-Android"],
        ),
    ]
    #endif
}
