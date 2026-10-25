//
//  PreviewCenter.swift
//  DSH-Mizar
//
//  What the preview page is showing, and how a file gets there.
//
//  The page itself is one screen with five states; the interesting part is the
//  trip a tap takes. A file the model delivered lives on the computer, so the
//  phone has to (1) learn whether it may read it and what it is, (2) use the copy
//  it already has when that copy is still current, (3) otherwise read it in
//  256 KiB slices and keep it, and (4) hand a *local* URL to a viewer — PDFKit
//  and QuickLook both take a file, not bytes.
//
//  Three decisions worth stating, because each one is a bug if reversed:
//
//    - **`file.stat` on every open, even a cached one.** One small frame buys the
//      guarantee that the page shows the report as it is now. A cache that
//      trusted itself would show yesterday's document under today's name.
//    - **The cache is the source of the URL, not a shortcut beside it.** Every
//      preview reads through the same file, so "cached" and "downloaded" differ
//      only in how many frames it took, not in what is drawn.
//    - **A failure is a sentence about *this* file.** "The plugin is too old",
//      "the file is gone", "it is outside the session's workspace" and "the
//      computer is not connected" are four different problems with four
//      different fixes, and the app has already learned (in the connection
//      diagnosis) how much a generic sentence costs.
//

import Foundation
import MizarKit
import SwiftUI

/// The preview page's state, and the file each session last opened.
@MainActor
@Observable
final class PreviewCenter {
    /// What the page draws.
    enum State: Equatable {
        /// Nothing has been opened in this session yet.
        case empty
        /// Reading it now. `nil` progress is "we do not know how big it is yet".
        case loading(progress: Double?)
        /// A local file to draw, and whether it is being shown without the
        /// computer confirming it is still current.
        ///
        /// `unconfirmed` is only true on the offline path: a cache hit that the
        /// host's `file.stat` agreed with is confirmed, and so is a file just
        /// read. The page says so only when it has something to admit.
        case ready(url: URL, unconfirmed: Bool)
        /// A file the app has no viewer for.
        case unsupported
        /// Something went wrong, said in a sentence the operator can act on.
        case failed(String)
    }

    private(set) var state: State = .empty
    /// The file the page is about, whether or not it is on screen yet.
    private(set) var current: PreviewTarget?
    /// Bytes the cache holds, for the settings screen.
    private(set) var cacheBytes = 0
    /// Files the cache holds.
    private(set) var cacheFiles = 0

    /// How to reach the computer. Set once the shell knows which computer it is.
    @ObservationIgnored private var reader: FileReader?
    @ObservationIgnored private var hostId = ""
    @ObservationIgnored private var cache = FilePreviewCache()
    @ObservationIgnored private var history = PreviewHistoryStore()
    /// Which load is current. A second tap cancels the first by bumping this,
    /// so a slow download cannot land on top of a file the operator opened after
    /// it.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loading: Task<Void, Never>?

    init() {
        #if DEBUG
        // A test that asserts on what a *first* look does has to say it wants a
        // first look. The cache is meant to survive relaunches and, in the
        // simulator, reinstalls of the same bundle — which makes a UI test lie
        // about exactly the thing it is measuring: one run's downloaded file
        // answered the next run's open, and "the page starts empty" found a
        // document from the previous test.
        //
        // Wiped here, synchronously and before any view can ask for a restore,
        // rather than from `attach`: that runs on the first frame, in parallel
        // with the preview page's own load, and a clear that lands after a
        // restore leaves the page showing what it was asked to forget.
        if ProcessInfo.processInfo.arguments.contains("-mizarFreshPreviews") {
            PreviewStore.wipe()
        }
        #endif
    }

    // MARK: - Wiring

    /// Point the centre at the computer the shell is talking to.
    ///
    /// Called when the shell is built and again after a reconnect: the closure
    /// captures the connection, and a stale one would answer `SOCKET_CLOSED` for
    /// every preview until the app restarted.
    ///
    /// - Parameters:
    ///   - hostId: the computer's id, which scopes the cache.
    ///   - call: how to dispatch one bridge method.
    func attach(hostId: String, call: @escaping FileReader.Call) {
        self.hostId = hostId
        reader = FileReader(call: call)
    }

    // MARK: - Opening

    /// Show a file, and remember it for its session.
    ///
    /// - Parameters:
    ///   - file: the file the operator tapped.
    ///   - sessionId: the conversation it was delivered in.
    func open(_ file: DeliveredFile, sessionId: String) {
        guard !sessionId.isEmpty else { return }
        let target = PreviewTarget(sessionId: sessionId, hostId: hostId, file: file)
        current = target
        let store = history
        Task { await store.remember(target) }
        load(target)
    }

    /// Put a session's last preview back on screen.
    ///
    /// Called when the drawer turns to the preview page and when the selected
    /// conversation changes: the page belongs to the drawer, the file belongs to
    /// the conversation, and this is where the two meet.
    ///
    /// - Parameter sessionId: the conversation in front, or `nil` for none.
    func restore(sessionId: String?) async {
        guard let sessionId, !sessionId.isEmpty else {
            current = nil
            state = .empty
            return
        }
        if current?.sessionId == sessionId { return }
        guard let target = await history.last(for: sessionId) else {
            current = nil
            state = .empty
            return
        }
        // A target remembered from another computer is not this one's file: the
        // path would be resolved against a different workspace, or not at all.
        guard target.hostId == hostId || hostId.isEmpty else {
            current = nil
            state = .empty
            return
        }
        current = target
        load(target)
    }

    /// Try the same file again, after a failure the operator can fix.
    func retry() {
        guard let current else { return }
        load(current)
    }

    // MARK: - Loading

    /// Read a target, or show the copy already on disk.
    private func load(_ target: PreviewTarget) {
        generation &+= 1
        let token = generation
        loading?.cancel()
        guard target.kind.isPreviewable else {
            state = .unsupported
            return
        }
        state = .loading(progress: nil)
        loading = Task { [weak self] in
            await self?.run(target, token: token)
        }
    }

    /// The trip itself: ask, reuse, or read.
    private func run(_ target: PreviewTarget, token: Int) async {
        guard let reader else {
            state = .failed(String(localized: "The computer is not connected."))
            return
        }
        let key = target.cacheKey

        // 1. What is it now? One small frame, and the answer decides everything
        //    else: whether the cached copy is current, and whether the file may
        //    be read at all.
        let facts: FileFacts
        do {
            facts = try await reader.stat(sessionId: target.sessionId, path: target.path)
        } catch {
            guard token == generation else { return }
            // Offline, or the computer went away: a copy already on disk is
            // still the right thing to show, and the page says so.
            if let url = await cache.cached(key), !Self.isRefusal(error) {
                state = .ready(url: url, unconfirmed: true)
                return
            }
            state = .failed(Self.describe(error))
            return
        }

        guard token == generation else { return }
        if let url = await cache.cached(key, matching: facts) {
            // Confirmed by the host just now: this is the current file, however
            // it got here.
            state = .ready(url: url, unconfirmed: false)
            return
        }

        // 2. Read it, slice by slice, reporting as it goes.
        do {
            let data = try await reader.read(
                sessionId: target.sessionId,
                path: target.path,
                expectedSize: facts.byteSize,
            ) { fraction in
                Task { @MainActor [weak self] in
                    guard let self, token == self.generation else { return }
                    self.state = .loading(progress: fraction)
                }
            }
            guard token == generation else { return }
            guard let url = await materialize(data, for: key, facts: facts) else {
                state = .failed(String(localized: "The file could not be saved on this phone."))
                return
            }
            state = .ready(url: url, unconfirmed: false)
            await refreshCacheUsage()
        } catch {
            guard token == generation else { return }
            // A read that failed half way still has the copy from last time, if
            // there is one. A file the host refused is not the same thing: the
            // copy on disk may be exactly what was refused.
            if let url = await cache.cached(key), !Self.isRefusal(error) {
                state = .ready(url: url, unconfirmed: true)
                return
            }
            state = .failed(Self.describe(error))
        }
    }

    /// Put the bytes somewhere a viewer can open them.
    ///
    /// The cache is the usual home. When it cannot be written — a full disk, a
    /// protected container — the file still has to be drawable, so a temporary
    /// copy is made and the preview works for this visit only.
    private func materialize(_ data: Data, for key: PreviewCacheKey, facts: FileFacts) async -> URL? {
        if let url = await cache.store(data, for: key, facts: facts) { return url }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("mizar-preview", isDirectory: true)
        try? FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let url = temporary.appendingPathComponent(facts.name.isEmpty ? "file" : facts.name)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - Cache

    /// Read the cache's size for the settings screen.
    func refreshCacheUsage() async {
        cacheBytes = await cache.totalSize()
        cacheFiles = await cache.fileCount()
    }

    /// Delete every cached file, and put the page back to its empty state.
    ///
    /// The remembered targets go with them: the index names files that no
    /// longer exist, and a page that restored one would show a broken preview
    /// where the empty state belongs.
    func clearCache() async {
        await cache.clear()
        await history.forgetAll()
        await refreshCacheUsage()
        current = nil
        state = .empty
    }

    // MARK: - Sentences

    /// Whether a failure is the host refusing this file, rather than the link
    /// failing. A refusal must not fall back to a cached copy: the copy may be
    /// exactly what the host just declined to hand over.
    private static func isRefusal(_ error: any Error) -> Bool {
        guard let mizar = error as? MizarError else { return false }
        return mizar.code.hasPrefix("FILE_")
    }

    /// One failure, as the sentence the page shows.
    ///
    /// The codes come from `bridge/files.ts` on the computer; each one names a
    /// different fix, so each one gets its own sentence.
    ///
    /// - Parameter error: what the read threw.
    /// - Returns: the sentence.
    private static func describe(_ error: any Error) -> String {
        guard let mizar = error as? MizarError else {
            return String(localized: "The file could not be read.")
        }
        switch mizar.code {
        case "NOT_IMPLEMENTED":
            return String(localized: "This computer's Mizar plugin is too old to send files. Update it to preview delivered files.")
        case "FILE_UNKNOWN":
            return String(localized: "The file is no longer on the computer.")
        case "FILE_FORBIDDEN":
            return String(localized: "This file is outside the session's working folder, or is not a document the app may read.")
        case "FILE_TOO_LARGE":
            return String(localized: "The file is larger than 32 MB, so it is not previewed here.")
        case "MALFORMED_FRAME":
            return String(localized: "This computer's plugin answered a preview request in a way this app does not understand. Update both.")
        case "SOCKET_CLOSED", "NO_CONNECTION", "CONNECTION_CLOSED":
            return String(localized: "The computer is not connected.")
        default:
            return mizar.message.isEmpty
                ? String(localized: "The file could not be read.")
                : mizar.message
        }
    }
}
