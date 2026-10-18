//
//  ShellState.swift
//  DSH-Mizar
//
//  Where the sidebar is, as one number.
//
//  `progress` runs from 0 (the conversation in front) to 1 (the sidebar open and
//  the conversation pushed aside as a card). Everything that moves -- the card's
//  offset, its scale, its corner, the shade over it, the toggle's glyph -- is a
//  function of this one value, so a finger dragging it and a spring settling it
//  move every piece together and nothing can get out of step.
//
//  The settle is velocity-matched: a flick carries its speed into the spring, so
//  the card leaves the finger at the speed it was thrown rather than stopping
//  and starting again.
//

import SwiftUI

@MainActor
@Observable
final class ShellState {
    /// 0 closed, 1 open. Values a little outside that range while dragging are
    /// the rubber band.
    private(set) var progress: CGFloat = 0
    /// Whether a finger is on it right now.
    private(set) var isDragging = false
    /// Whether the last settle left it open, for the haptic and for VoiceOver.
    private(set) var settledOpen = false
    /// On a regular width the sidebar sits beside the conversation rather than
    /// under it; this is whether it is showing there.
    var pinnedVisible = true
    /// Which workspaces are open, per computer, for the life of the process.
    ///
    /// Collapsed is the default -- the set starts empty -- because a list of
    /// five workspaces each holding a dozen sessions is not a list anybody can
    /// read. Kept here rather than in the sidebar so that a switch to another
    /// computer and back finds its groups as they were left.
    private var expandedByHost: [String: Set<String>] = [:]

    private var dragOrigin: CGFloat = 0

    var isOpen: Bool { progress > 0.5 }

    // MARK: Opening and closing

    func open() { settle(to: 1) }
    func close() { settle(to: 0) }

    func toggle(compact: Bool) {
        if compact {
            settle(to: settledOpen ? 0 : 1)
        } else {
            withMizarAnimation(.mizarSmooth) { pinnedVisible.toggle() }
        }
    }

    /// Put it somewhere without animating, for the first frame.
    func place(open: Bool) {
        progress = open ? 1 : 0
        settledOpen = open
    }

    // MARK: Dragging

    func beginDrag() {
        isDragging = true
        dragOrigin = progress
        resignKeyboard()
    }

    /// Follow the finger.
    ///
    /// - Parameter fraction: the horizontal translation as a fraction of the
    ///   sidebar's width.
    func drag(by fraction: CGFloat) {
        let raw = dragOrigin + fraction
        // Past either end the card still moves, at a third of the finger's
        // speed and less the further it goes: the edge is felt, not hit.
        let banded: CGFloat
        if raw > 1 {
            banded = 1 + rubberBand(raw - 1)
        } else if raw < 0 {
            banded = -rubberBand(-raw)
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
    /// - Parameter velocity: the finger's speed in sidebar widths per second.
    func endDrag(velocity: CGFloat) {
        isDragging = false
        // Where a flick would carry it, a tenth of a second on. Deciding on the
        // projection rather than the position is what lets a short quick flick
        // open it and a long slow drag that changes its mind close it.
        let projected = progress + velocity * 0.12
        settle(to: projected > 0.5 ? 1 : 0, velocity: velocity)
    }

    private func settle(to target: CGFloat, velocity: CGFloat = 0) {
        let distance = target - progress
        // `initialVelocity` is measured in "whole journeys per second".
        let relative = abs(distance) > 0.001 ? max(-30, min(30, velocity / distance)) : 0
        let animation: Animation = Motion.reduced
            ? .mizarFade
            : .interpolatingSpring(duration: 0.42, bounce: 0, initialVelocity: relative)
        if target > 0.5 { resignKeyboard() }
        withAnimation(animation) {
            progress = target
        }
        settledOpen = target > 0.5
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
