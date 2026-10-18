//
//  SidebarPan.swift
//  DSH-Mizar
//
//  The drag that opens and closes the sidebar.
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
    enum Direction {
        /// From the conversation, towards the sidebar: a rightward drag.
        case opening
        /// From the sidebar or the card, back again: a leftward drag.
        case closing
    }

    let shell: ShellState
    /// The sidebar's width, which a full open is measured against.
    let width: CGFloat
    let direction: Direction
    /// Whether it may begin at all -- off on a regular width, where the sidebar
    /// is pinned, and off while the card is already pushed aside.
    var enabled: Bool = true

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(direction: direction)
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
        let width = max(1, width)
        switch recognizer.state {
        case .began:
            shell.beginDrag()
        case .changed:
            shell.drag(by: recognizer.translation(in: space).x / width)
        case .ended:
            shell.endDrag(velocity: recognizer.velocity(in: space).x / width)
        case .cancelled, .failed:
            shell.endDrag(velocity: 0)
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var direction: Direction

        init(direction: Direction) {
            self.direction = direction
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
            case .opening: return dx > 0
            case .closing: return dx < 0
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            // Never from inside something that wants a sideways drag of its own:
            // a text field moving its cursor, or anything that scrolls
            // horizontally (a wide code block, a carousel).
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
