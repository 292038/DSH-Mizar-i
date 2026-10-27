//
//  HeldPrompt.swift
//  DSH-Mizar
//
//  A message the phone keeps back until the turn it was sent into ends.
//
//  Not the host's queue. The host already has one, and it was what a send into
//  a running turn did before this file existed -- but a queued prompt cannot be
//  called back, and calling it back is the point: the bar above the field lets
//  the operator send it as guidance instead, put it back in the field, or throw
//  it away.
//
//  A value rather than screen state, and kept in ``AppModel``, because the
//  screen that typed the message is not the thing that delivers it. The turn
//  may end while the operator is in another conversation, and the message has
//  to go all the same.
//

import Foundation

/// One message waiting for the end of a turn.
struct PendingPrompt: Identifiable, Equatable, Sendable {
    /// Identity of the bar, and of the send that consumed it.
    ///
    /// Stable across merges on purpose: a second message sent while the first
    /// is still held lands in the same bar, and a bar that was replaced under
    /// the finger would read as a losing animation rather than one more line
    /// waiting.
    let id: UUID
    /// The session it belongs to.
    let sessionId: String
    /// What will be sent. One prompt, newline-separated, because one bar means
    /// one hand-over.
    private(set) var text: String

    /// Whether the automatic hand-over has given up on this prompt.
    ///
    /// Set when its own attempts fail, and when a hand-over the operator asked
    /// for fails. A refused prompt must not be re-attempted on every
    /// session-list read for the life of the app -- a plugin that never learned
    /// `steer` would be asked again every three seconds -- so the bar keeps the
    /// text and the send key is the only way to try again. The operator is then
    /// the only one who can decide a retry is worth it.
    private(set) var automaticDeliveryStalled = false

    /// - Parameters:
    ///   - id: the identity, fresh for a new prompt.
    ///   - sessionId: the session it belongs to.
    ///   - text: the first line of it.
    init(id: UUID = UUID(), sessionId: String, text: String) {
        self.id = id
        self.sessionId = sessionId
        self.text = text
    }

    /// The one line the bar draws, without its line breaks.
    ///
    /// A `Text` with `lineLimit(1)` would stop at the first newline rather than
    /// truncating, so a merged prompt would look shorter than it is; the breaks
    /// become spaces here, and the ellipsis is the layout's.
    var summary: String {
        text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    /// Add a later message to this one.
    /// - Parameter more: the text that was sent after this prompt was held.
    mutating func append(_ more: String) {
        guard !more.isEmpty else { return }
        text = text.isEmpty ? more : text + "\n" + more
    }

    /// Stop trying to hand this prompt over without being asked.
    mutating func stallAutomaticDelivery() {
        automaticDeliveryStalled = true
    }

    /// Put an earlier, unsent prompt in front of this one.
    ///
    /// The failure path: the phone took the text out of the bar to send it, the
    /// host refused it, and anything that was typed while the request was in
    /// flight came after it. Order is the operator's, not the retry's.
    /// - Parameter earlier: the text that failed.
    mutating func prepend(_ earlier: String) {
        guard !earlier.isEmpty else { return }
        text = text.isEmpty ? earlier : earlier + "\n" + text
    }
}

/// A held prompt the host has accepted.
///
/// The screen's cue to draw the sent bubble and follow it into the conversation.
/// Its own value rather than a bool on ``PendingPrompt`` because the send is what
/// the screen reacts to, not the bar: the bar has already gone by the time this
/// exists.
struct DeliveredPrompt: Identifiable, Equatable, Sendable {
    let id: UUID
    let sessionId: String
    let text: String

    init(id: UUID = UUID(), sessionId: String, text: String) {
        self.id = id
        self.sessionId = sessionId
        self.text = text
    }
}
