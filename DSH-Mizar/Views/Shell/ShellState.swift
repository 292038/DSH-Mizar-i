//
//  ShellState.swift
//  DSH-Mizar
//
//  Where the two drawers are, as one number.
//
//  `progress` runs from -1 to 1. At 0 the conversation is in front. Towards 1
//  the workspace sidebar comes out on the left and the conversation is pushed
//  right as a card; towards -1 the turn index comes out on the right and the
//  card is pushed left -- the same gesture, mirrored. One signed number rather
//  than two, so the two drawers can never both be out, and a drag that starts
//  with one closed simply decides by its direction which one it is opening.
//
//  Everything that moves -- the card's offset, its scale, its corner, the shade
//  over it, the toggle's glyph -- is a function of this one value, so a finger
//  dragging it and a spring settling it move every piece together and nothing
//  can get out of step.
//
//  The settle is velocity-matched: a flick carries its speed into the spring, so
//  the card leaves the finger at the speed it was thrown rather than stopping
//  and starting again.
//

import SwiftUI

@MainActor
@Observable
final class ShellState {
    enum Side: Equatable {
        /// The workspace sidebar, on the left.
        case leading
        /// The turn index, on the right.
        case trailing
    }

    /// -1 the index out, 0 closed, 1 the sidebar out. Values a little beyond
    /// either end while dragging are the rubber band.
    private(set) var progress: CGFloat = 0
    /// Whether a finger is on it right now.
    private(set) var isDragging = false
    /// Whether a spring is still carrying a drawer to its destination.
    ///
    /// A window presented *out of* a control must not come out while that
    /// control is moving. The one-time naming prompt is anchored to either the
    /// computer's name or the sidebar button, and a launch presented it during
    /// the sidebar's close: it dismissed itself under the finger before it could
    /// be answered, and the test that taps it caught a window with no buttons.
    /// The spring's duration is the moment this becomes false again.
    private(set) var isSettling = false
    private var settleGeneration = 0
    /// Which drawer the last settle left out, for the haptic and VoiceOver.
    private(set) var settled: Side?
    /// On a regular width the sidebar sits beside the conversation rather than
    /// under it; this is whether it is showing there.
    var pinnedVisible = true
    /// The same for the turn index, which on a regular width is a column of its
    /// own on the right.
    var indexPinnedVisible = false
    /// Whether there is a turn index to open: there is none on the home screen.
    var trailingAvailable = false
    /// How wide each drawer is, so a drag is measured in drawers.
    var leadingWidth: CGFloat = 320
    var trailingWidth: CGFloat = 300
    /// The whole window's width, for deciding whether both columns fit.
    var containerWidth: CGFloat = 1000
    /// The narrowest the conversation may be squeezed to by the iPad's columns
    /// before one of them steps aside for the other.
    private static let narrowestConversation: CGFloat = 460

    /// Whether both iPad columns fit beside a readable conversation.
    private var bothColumnsFit: Bool {
        containerWidth - leadingWidth - trailingWidth >= Self.narrowestConversation
    }
    /// Which workspaces are open, per computer, for the life of the process.
    ///
    /// Collapsed is the default -- the set starts empty -- because a list of
    /// five workspaces each holding a dozen sessions is not a list anybody can
    /// read. Kept here rather than in the sidebar so that a switch to another
    /// computer and back finds its groups as they were left.
    private var expandedByHost: [String: Set<String>] = [:]

    private var dragOrigin: CGFloat = 0

    /// Whether the sidebar is the one out.
    var settledOpen: Bool { settled == .leading }
    /// Whether the turn index is the one out.
    var trailingOpen: Bool { settled == .trailing }

    // MARK: Opening and closing

    func open() { settle(to: 1) }
    func openTrailing() {
        guard trailingAvailable else { return }
        settle(to: -1)
    }
    func close() { settle(to: 0) }

    func toggle(compact: Bool) {
        if compact {
            settle(to: settledOpen ? 0 : 1)
        } else {
            withMizarAnimation(.mizarSmooth) {
                pinnedVisible.toggle()
                // On a window too narrow for both, the column coming in asks
                // the other to step aside -- the way Mail trades its sidebar
                // for the message list.
                if pinnedVisible, !bothColumnsFit { indexPinnedVisible = false }
            }
        }
    }

    func toggleTrailing(compact: Bool) {
        if compact {
            if trailingOpen { close() } else { openTrailing() }
        } else {
            withMizarAnimation(.mizarSmooth) {
                indexPinnedVisible.toggle()
                if indexPinnedVisible, !bothColumnsFit { pinnedVisible = false }
            }
        }
    }

    /// Put it somewhere without animating, for the first frame.
    func place(open: Bool) {
        progress = open ? 1 : 0
        settled = open ? .leading : nil
        settleGeneration &+= 1
        isSettling = false
    }

    // MARK: Dragging

    func beginDrag() {
        isDragging = true
        dragOrigin = progress
        // The finger takes the card over from the spring.
        settleGeneration &+= 1
        isSettling = false
        resignKeyboard()
    }

    /// Follow the finger.
    ///
    /// - Parameter points: the horizontal translation since the drag began.
    func drag(by points: CGFloat) {
        let raw = dragOrigin + fraction(points)
        // A drag that started with a drawer out may close it but not carry on
        // through into the other one; a drag that started closed may open
        // either, the index only where there is one.
        let low: CGFloat = dragOrigin > 0.01 || !trailingAvailable ? 0 : -1
        let high: CGFloat = dragOrigin < -0.01 ? 0 : 1
        // Past either end the card still moves, less the further it goes: the
        // edge is felt, not hit.
        let banded: CGFloat
        if raw > high {
            banded = high + rubberBand(raw - high)
        } else if raw < low {
            banded = low - rubberBand(low - raw)
        } else {
            banded = raw
        }
        // A very short spring rather than an assignment: grabbing the card
        // while it is still settling blends from where it is drawn instead of
        // jumping to where the model says it is.
        withAnimation(.interactiveSpring(response: 0.14, dampingFraction: 0.86)) {
            progress = banded
        }
    }

    /// Let go.
    ///
    /// - Parameter velocity: the finger's speed in points per second.
    func endDrag(velocity: CGFloat) {
        isDragging = false
        let speed = fraction(velocity)
        // Where a flick would carry it, a tenth of a second on. Deciding on the
        // projection rather than the position is what lets a short quick flick
        // open a drawer and a long slow drag that changes its mind close it.
        let projected = progress + speed * 0.12
        let target: CGFloat
        // A flick that closes one drawer never throws the card on into the
        // other: only a drag that began closed, or on that side, may end there.
        if projected > 0.5, dragOrigin > -0.01 {
            target = 1
        } else if projected < -0.5, trailingAvailable, dragOrigin < 0.01 {
            target = -1
        } else {
            target = 0
        }
        settle(to: target, velocity: speed)
    }

    /// Points as a fraction of the drawer they move.
    private func fraction(_ points: CGFloat) -> CGFloat {
        // The side is the one the card is already towards, or the one the
        // finger is heading for when it is closed.
        let towardsTrailing = progress < -0.001 || (abs(progress) <= 0.001 && points < 0)
        return points / max(1, towardsTrailing ? trailingWidth : leadingWidth)
    }

    private func settle(to target: CGFloat, velocity: CGFloat = 0) {
        let distance = target - progress
        // `initialVelocity` is measured in "whole journeys per second".
        let relative = abs(distance) > 0.001 ? max(-30, min(30, velocity / distance)) : 0
        let animation: Animation = Motion.reduced
            ? .mizarFade
            : .interpolatingSpring(duration: 0.42, bounce: 0, initialVelocity: relative)
        if target != 0 { resignKeyboard() }
        withAnimation(animation) {
            progress = target
        }
        settled = target > 0.5 ? .leading : (target < -0.5 ? .trailing : nil)
        // The spring is "still moving" until it has arrived. A newer settle, a
        // drag, or the first frame placing the card invalidates this one's
        // countdown, so only the last spring decides when the drawers are still.
        settleGeneration &+= 1
        let generation = settleGeneration
        isSettling = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(520))
            guard settleGeneration == generation, !isDragging else { return }
            isSettling = false
        }
    }

    private func rubberBand(_ overshoot: CGFloat) -> CGFloat {
        let limit: CGFloat = 0.08
        return limit * (1 - 1 / (overshoot * 3 / limit + 1))
    }

    private func resignKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    // MARK: Workspaces

    func expanded(for hostId: String?) -> Set<String> {
        expandedByHost[hostId ?? ""] ?? []
    }

    func setExpanded(_ expanded: Set<String>, for hostId: String?) {
        expandedByHost[hostId ?? ""] = expanded
    }
}
