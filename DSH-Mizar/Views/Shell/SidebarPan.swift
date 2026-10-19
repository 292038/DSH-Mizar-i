//
//  SidebarPan.swift
//  DSH-Mizar
//
//  The drag gesture for the two drawers.
//
//  The implementation is a `UIPanGestureRecognizer` subclass rather than a raw
//  `UIGestureRecognizer`, because UIKit gives pan recognizers a stable place in
//  the gesture arena next to a `UIScrollView`. A raw recognizer attached above a
//  scroll view is cancelled by that scroll view before it ever receives a
//  `touchesMoved`; a pan is not. That was discovered the hard way: the first
//  version of this rewrite used a raw gesture recognizer and only ever saw
//  `touchesBegan`.
//
//  It is installed on each of the four surfaces that can be under the finger --
//  the card, the sidebar, the index and the dismiss surface -- because a single
//  recognizer on the shell root is also outside the scroll views' gesture
//  arena. The four copies share this one implementation and the same shell
//  state; each surface is disjoint, so there is no first-recognizer race.
//
//  The pan deliberately does not let UIKit decide when to begin. It receives
//  touches while it is still possible, watches the axis, and only forwards a
//  move to `super` once the drag is clearly horizontal. Until then:
//
//  - the scroll views under the finger are told to wait for this pan, so a
//    sideways drag is not stolen by the conversation's vertical scroll;
//  - a vertical drag never reaches `super`, so the scroll view gets it;
//  - a horizontally scrolling code block or table gets the drag while it still
//    has somewhere to go, and the drawer takes over at the edge;
//  - a tap never begins the pan, so buttons and links keep their clicks.
//
//  Once the axis is locked the shell follows the finger exactly and can be
//  grabbed again at any point in an animation. The old version attached four
//  recognizers with four different `enabled` conditions, so which one saw the
//  touch depended on where the finger started and whether a drawer was moving.
//

import SwiftUI
import UIKit

struct SidebarPan: UIGestureRecognizerRepresentable {
    let shell: ShellState
    /// Whether the shell is in its phone layout. On a regular width the drawers
    /// are columns, so there is nothing to drag.
    let compact: Bool

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(shell: shell)
    }

    func makeUIGestureRecognizer(context: Context) -> DrawerPanRecognizer {
        let recognizer = DrawerPanRecognizer(target: nil, action: nil)
        recognizer.coordinator = context.coordinator
        recognizer.delegate = context.coordinator
        recognizer.isEnabled = compact
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: DrawerPanRecognizer, context: Context) {
        recognizer.coordinator = context.coordinator
        recognizer.isEnabled = compact
    }

    func handleUIGestureRecognizerAction(_ recognizer: DrawerPanRecognizer, context: Context) {
        // The recognizer drives the shell from its own touch callbacks: it has
        // to inspect intermediate samples and decide when to become a drag,
        // which a target/action on state changes cannot express.
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let shell: ShellState

        init(shell: ShellState) {
            self.shell = shell
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer,
        ) -> Bool {
            false
        }
    }
}

/// A pan that waits for the finger to say which axis it means before it begins.
///
/// `UIPanGestureRecognizer` asks its delegate once, at the first touch slop,
/// whether it may begin; that one sample is noisy. This subclass keeps the pan
/// possible and forwards moves to UIKit only after the horizontal intent is
/// clear. Vertical moves are deliberately not forwarded: the scroll view below
/// gets them. Horizontal moves over a code block go to the code block until its
/// edge, then to the drawer.
@MainActor
final class DrawerPanRecognizer: UIPanGestureRecognizer {
    weak var coordinator: SidebarPan.Coordinator?

    private enum Axis {
        case horizontal
        case vertical
    }

    /// How far the finger must travel before a clearly horizontal drag begins.
    private static let horizontalThreshold: CGFloat = 8
    /// A vertical drag may keep the pan possible a little longer: this is the
    /// margin for a thumb that starts down and then turns sideways.
    private static let verticalThreshold: CGFloat = 16
    /// If the axis is still ambiguous by here, take the larger component.
    private static let ambiguityLimit: CGFloat = 26
    /// Horizontal must beat vertical by this much before the drawer claims the
    /// touch. Vertical uses a slightly larger ratio so a genuine scroll wins
    /// when the two are close.
    private static let horizontalDominance: CGFloat = 1.15
    private static let verticalDominance: CGFloat = 1.2
    /// A half point of comparison for scroll edge checks. Content sizes are
    /// fractional after layout; an offset within this of an edge is at the edge.
    private static let scrollEpsilon: CGFloat = 0.5

    private var axis: Axis?
    private var startView: UIView?
    private var startPoint: CGPoint?
    private var lastPoint: CGPoint?
    private var lastTimestamp: TimeInterval = 0
    private var dragVelocity: CGPoint = .zero
    private var ownsTouch = false

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        maximumNumberOfTouches = 1
        cancelsTouchesInView = true
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func reset() {
        super.reset()
        axis = nil
        startView = nil
        startPoint = nil
        lastPoint = nil
        lastTimestamp = 0
        dragVelocity = .zero
        ownsTouch = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard !ownsTouch else { return }
        startView = touches.first?.view
        axis = nil
        ownsTouch = false
        guard let touch = touches.first, let window = view?.window ?? view else { return }
        let point = touch.location(in: window)
        startPoint = point
        lastPoint = point
        lastTimestamp = touch.timestamp
        dragVelocity = .zero

        // Every scroll view under the finger waits for this pan to decide.
        // Without this, the scroll view begins as soon as the touch moves and
        // cancels the pan before it can inspect the axis.
        var ancestor = startView
        while let current = ancestor {
            if let scroll = current as? UIScrollView {
                scroll.panGestureRecognizer.require(toFail: self)
            }
            ancestor = current.superview
        }

        // A touch that starts in the composer must remain a text-input touch.
        if isTextInput(startView) {
            fail()
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first,
              let window = view?.window ?? view,
              let start = startPoint,
              let last = lastPoint
        else { return }
        let point = touch.location(in: window)
        let dt = max(1.0 / 120.0, touch.timestamp - lastTimestamp)
        dragVelocity = CGPoint(x: (point.x - last.x) / dt, y: (point.y - last.y) / dt)
        lastPoint = point
        lastTimestamp = touch.timestamp

        let dx = point.x - start.x
        let dy = point.y - start.y

        guard let axis else {
            decideAxis(dx: dx, dy: dy, touches: touches, event: event)
            return
        }

        guard axis == .horizontal, ownsTouch else { return }
        super.touchesMoved(touches, with: event)
        coordinator?.shell.drag(by: dx)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if axis == .horizontal, ownsTouch {
            super.touchesEnded(touches, with: event)
            coordinator?.shell.endDrag(velocity: dragVelocity.x)
        } else {
            fail()
        }
        ownsTouch = false
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        if axis == .horizontal, ownsTouch {
            super.touchesCancelled(touches, with: event)
            coordinator?.shell.endDrag(velocity: 0)
        } else {
            fail()
        }
        ownsTouch = false
    }

    /// Decide the axis once, and either begin the drawer or fail the pan.
    ///
    /// - Parameters:
    ///   - dx: horizontal travel in window coordinates.
    ///   - dy: vertical travel in window coordinates.
    private func decideAxis(
        dx: CGFloat,
        dy: CGFloat,
        touches: Set<UITouch>,
        event: UIEvent,
    ) {
        let ax = abs(dx)
        let ay = abs(dy)

        if ax >= Self.horizontalThreshold, ax > ay * Self.horizontalDominance {
            beginHorizontalIfAvailable(dx: dx, touches: touches, event: event)
        } else if ay >= Self.verticalThreshold, ay > ax * Self.verticalDominance {
            fail()
        } else if max(ax, ay) >= Self.ambiguityLimit {
            if ax >= ay {
                beginHorizontalIfAvailable(dx: dx, touches: touches, event: event)
            } else {
                fail()
            }
        }
    }

    /// Commit to a horizontal drag if this touch is allowed to move a drawer.
    ///
    /// - Parameter dx: the horizontal travel since the touch began.
    private func beginHorizontalIfAvailable(
        dx: CGFloat,
        touches: Set<UITouch>,
        event: UIEvent,
    ) {
        guard let coordinator else {
            fail()
            return
        }
        guard coordinator.shell.canDrag(towards: dx) else {
            fail()
            return
        }
        // A horizontal code block or table gets the drag while it still has
        // somewhere to go. At its edge the drawer takes over, which is the
        // behaviour a reader expects: keep scrolling the code until it stops,
        // then the gesture means the screen.
        if let scroll = horizontalScroll(containing: startView),
           canScroll(scroll, towards: dx) {
            fail()
            return
        }
        axis = .horizontal
        ownsTouch = true
        coordinator.shell.beginDrag()
        coordinator.shell.drag(by: dx)
        // Forward the move only after the shell has been told where the drag
        // starts. This is what transitions UIKit's pan to `.began` and makes it
        // cancel the child control instead of letting a button also fire.
        super.touchesMoved(touches, with: event)
    }

    /// Fail the pan without forwarding the touch to the scroll view.
    ///
    /// A failed pan releases the scroll view's failure requirement; the scroll
    /// view then gets the remaining touches and handles the vertical drag or
    /// the horizontal code block.
    private func fail() {
        if state == .possible || state == .began || state == .changed {
            state = .failed
        }
    }

    /// The nearest ancestor that actually scrolls horizontally.
    ///
    /// - Parameter view: the view under the touch.
    /// - Returns: the scroll view, or `nil` for ordinary content.
    private func horizontalScroll(containing view: UIView?) -> UIScrollView? {
        var current = view
        while let candidate = current {
            if let scroll = candidate as? UIScrollView,
               scroll.contentSize.width > scroll.bounds.width + Self.scrollEpsilon,
               scroll.contentSize.height <= scroll.bounds.height + 1 {
                return scroll
            }
            current = candidate.superview
        }
        return nil
    }

    /// Whether a horizontal scroll view can still move in the drag's direction.
    ///
    /// - Parameters:
    ///   - scroll: the horizontal scroll view under the touch.
    ///   - dx: the horizontal travel; negative means the finger moved left.
    /// - Returns: `true` when the scroll view itself should receive the drag.
    private func canScroll(_ scroll: UIScrollView, towards dx: CGFloat) -> Bool {
        let maximum = max(0, scroll.contentSize.width - scroll.bounds.width)
        if dx < 0 {
            // Finger moved left: content moves left, offset grows.
            return scroll.contentOffset.x < maximum - Self.scrollEpsilon
        }
        if dx > 0 {
            // Finger moved right: content moves right, offset shrinks.
            return scroll.contentOffset.x > Self.scrollEpsilon
        }
        return false
    }

    /// Whether the finger started on something that owns its own text touch.
    ///
    /// - Parameter view: the view under the touch.
    /// - Returns: whether it is a text field or text view.
    private func isTextInput(_ view: UIView?) -> Bool {
        var current = view
        while let candidate = current {
            if candidate is UITextField { return true }
            // A read-only text view is the message body with selection enabled:
            // a horizontal drag there is the drawer, not a cursor. An editable
            // one is the composer and keeps the touch.
            if let text = candidate as? UITextView, text.isEditable { return true }
            current = candidate.superview
        }
        return false
    }
}
