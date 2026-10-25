//
//  PreviewTarget.swift
//  MizarKit
//
//  What each session's preview page is showing.
//
//  The preview page belongs to the drawer, and the drawer outlives the session
//  whose conversation is in front of it: switching conversations, closing the
//  drawer, even relaunching the app all pass through the same page. The rule the
//  operator asked for is the simple one — come back to the page and it shows the
//  last file you opened *in this conversation* — so the answer has to be kept per
//  session rather than in the view's own state.
//
//  It is written to disk for the same reason the conversation cache is: a phone
//  that was killed in the background should not come back to an empty preview
//  page for a file it still has on disk.
//

import Foundation

/// One session's preview: which file, from which computer.
public struct PreviewTarget: Codable, Sendable, Equatable, Identifiable {
    /// The conversation it belongs to.
    public let sessionId: String
    /// The computer it was read from: the same path on another machine is
    /// another file, and the cache is keyed the same way.
    public let hostId: String
    /// The file itself.
    public let file: DeliveredFile

    public var path: String { file.path }
    public var name: String { file.name }
    public var detail: String? { file.detail }
    public var kind: PreviewKind { file.kind }

    public var id: String { "\(hostId)|\(sessionId)|\(path)" }

    public init(sessionId: String, hostId: String, file: DeliveredFile) {
        self.sessionId = sessionId
        self.hostId = hostId
        self.file = file
    }

    /// The cache key this target reads through.
    public var cacheKey: PreviewCacheKey {
        PreviewCacheKey(hostId: hostId, sessionId: sessionId, path: path)
    }
}

/// The last preview per session, kept across launches.
public actor PreviewHistoryStore {
    private let file: URL
    private var entries: [String: PreviewTarget]?

    /// - Parameter directory: where to keep the index. Defaults to Application
    ///   Support, beside the cache it describes.
    public init(directory: URL? = nil) {
        file = (directory ?? PreviewStore.directory).appendingPathComponent("index.json")
    }

    /// What a session was last showing.
    ///
    /// - Parameter sessionId: the conversation.
    /// - Returns: the target, or `nil` when nothing has been opened there.
    public func last(for sessionId: String) -> PreviewTarget? {
        load()[sessionId]
    }

    /// Record what a session is showing now.
    ///
    /// - Parameter target: the file that was opened.
    public func remember(_ target: PreviewTarget) {
        var all = load()
        all[target.sessionId] = target
        entries = all
        write(all)
    }

    /// Forget every session's preview.
    ///
    /// Called when the file cache is cleared: the index names files that no
    /// longer exist, and a page that remembered one would show a broken preview
    /// instead of its empty state.
    public func forgetAll() {
        entries = [:]
        try? FileManager.default.removeItem(at: file)
    }

    /// Forget one session's preview, for a conversation that no longer exists.
    ///
    /// - Parameter sessionId: the conversation.
    public func forget(sessionId: String) {
        var all = load()
        guard all.removeValue(forKey: sessionId) != nil else { return }
        entries = all
        write(all)
    }

    private func load() -> [String: PreviewTarget] {
        if let entries { return entries }
        guard let data = try? Data(contentsOf: file),
              let decoded = try? JSONDecoder().decode([String: PreviewTarget].self, from: data) else {
            entries = [:]
            return [:]
        }
        entries = decoded
        return decoded
    }

    private func write(_ all: [String: PreviewTarget]) {
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            let data = try JSONEncoder().encode(all)
            try data.write(to: file, options: .atomic)
        } catch {
            // An index that cannot be written is an index that does not exist,
            // not a failure the operator should see: the preview still works,
            // it just will not be remembered across launches.
        }
    }
}
