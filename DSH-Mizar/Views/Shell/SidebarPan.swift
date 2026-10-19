//
//  SidebarPan.swift
//  DSH-Mizar
//
//  The drag that brings the drawers out and puts them away.
//
//  A UIKit pan rather than a SwiftUI `DragGesture`, and the reason is the
//  conversation's own scroll view. A simultaneous SwiftUI drag cannot cancel a
//  scroll, so a diagonal swipe both scrolled and slid; a high-priority one stops
//  scrolling altogether. A `UIPanGestureRecognizer` can decide in its very first
//  movement whether the swipe is sideways -- and when it is not, it fails at once
//  and the scroll view, which was told to wait for exactly that, takes over with
//  no delay anybody can feel.
//
//  Sideways means sideways: the horizontal travel has to beat the vertical by
//  half again. A perfectly vertical swipe -- which is what every UI test's
//  `swipeUp` is -- never opens anything.
//

import SwiftUI
import UIKit

struct SidebarPan: UIGestureRecognizerRepresentable {
    /// Which way a drag may begin.
    enum Direction {
        /// A drag to the right: opening the sidebar, or putting the index away.
        case rightward
        /// A drag to the left: opening the index, or putting the sidebar away.
        case leftward
        /// Either, from a conversation with both drawers closed.
        case either
    }

    let shell: ShellState
    let direction: Direction
    /// Whether it may begin at all -- off on a regular width, where the
    /// drawers are columns.
    var enabled: Bool = true

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(direction: direction, shell: shell)
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.maximumNumberOfTouches = 1
        recognizer.delegate = context.coordinator
        recognizer.isEnabled = enabled
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.direction = direction
        recognizer.isEnabled = enabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        // Measured in the window, which does not move. The view this is attached
        // to is the card, and the card is what the drag moves -- in its own
        // coordinates the finger would appear to stand still.
        let space = recognizer.view?.window
        switch recognizer.state {
        case .began:
            shell.beginDrag()
        case .changed:
            shell.drag(by: recognizer.translation(in: space).x)
        case .ended:
            shell.endDrag(velocity: recognizer.velocity(in: space).x)
        case .cancelled, .failed:
            shell.endDrag(velocity: 0)
        default:
            break
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var direction: Direction
        let shell: ShellState

        init(direction: Direction, shell: ShellState) {
            self.direction = direction
            self.shell = shell
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let travel = pan.translation(in: pan.view)
            let speed = pan.velocity(in: pan.view)
            // Where the finger is going, not only where it has been: the travel
            // so far plus a twentieth of a second of its current speed. The
            // first few points of a drag wander -- a thumb rolls, a synthetic
            // drag starts with a hop -- and judging on them alone refused a
            // plainly sideways swipe whose first 8 points went down.
            let dx = travel.x + speed.x * 0.05
            let dy = travel.y + speed.y * 0.05
            guard abs(dx) > abs(dy) * 1.5 else { return false }
            switch direction {
            case .rightward: return dx > 0
            case .leftward: return dx < 0
            case .either: return dx > 0 || shell.trailingAvailable
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            // Never from inside something that wants a sideways drag of its own:
            // a text field moving its cursor, or anything that scrolls
            // horizontally (a wide code block, a table, a carousel).
            var view = touch.view
            while let current = view {
                if current is UITextField || current is UITextView { return false }
                if let scroll = current as? UIScrollView,
                   scroll.contentSize.width > scroll.bounds.width + 1 {
                    return false
                }
                view = current.superview
            }
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer,
        ) -> Bool {
            false
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy other: UIGestureRecognizer,
        ) -> Bool {
            // A vertical scroll waits for this pan to decide. It decides on the
            // first movement, so the wait is the length of a touch slop -- and
            // without it a sideways swipe started the scroll as well.
            if let scroll = other.view as? UIScrollView, other === scroll.panGestureRecognizer {
                return scroll.contentSize.width <= scroll.bounds.width + 1
            }
            return false
        }
    }
}
