//
//  TabBarTransition.swift
//  DSH-Mizar
//
//  The selection bar leaves and returns *with* the page.
//
//  Its visibility belongs to the layout -- a conversation is somewhere inside the
//  first screen, not a third one, so the bar is put away while one is open (see
//  `SessionDetailView`) -- but the layout change on its own is a bar that is
//  there in one frame and gone in the next. Measured on a recording of the app
//  at 15 fps, that is literally what it does: present at 60.600 s, absent by
//  60.667 s, while the conversation takes a further half second to slide in.
//  Reported as exactly that: the bar appears and disappears out of thin air.
//
//  Why this is not a navigation change. The honest fix is a real push, where the
//  bar travels with the transition for free -- and it was tried: putting the
//  conversation in a `NavigationStack` broke 21 of the 31 UI tests of the day in
//  one release, because the suite drives the app through accessibility
//  identifiers and a structural change moves the screens they name. That attempt
//  was reverted, and `WorkspaceListView.pushing` is what is left of it. So the
//  navigation is left exactly as it is, and the *bar* is given a transition
//  instead: the same state that hides it also drives an explicit one, which is
//  the second option and the smaller risk.
//
//  Why it is a separate view rather than an animation on the bar. SwiftUI's
//  `.toolbar(.hidden, for: .tabBar)` is the only mechanism that reaches the
//  accessibility tree -- the UI tests assert the bar has two buttons on the list
//  and none inside a conversation, and a `UITabBarController.setTabBarHidden`
//  call leaves those buttons in the tree, which was measured. It also applies in
//  one frame, and there is no animatable SwiftUI value behind it. So the state
//  that hides the bar stays exactly as it was, and the two directions take the
//  route the measurements allow:
//
//    - leaving, a still of the bar -- taken at that moment, when it is measured
//      still on screen -- slides down over the bottom edge with the page;
//    - returning, the real bar fades back in. The tab bar is chrome above the
//      navigation transition, so it can be seen while the page is still moving;
//      a picture of it at window level was covered by the pop's snapshot and did
//      not appear until the page had finished, which is the reported "after",
//      one direction over.
//
//  Nothing about which screen is reachable changes, so nothing the UI suite
//  queries changes.
//

import os
import SwiftUI
import UIKit

/// The transition's own record, in the simulator's unified log.
///
/// `debug`, so it costs nothing in a release build and is there when a report
/// about the bar turns out to be about the transition rather than the layout.
/// The look is not observable from a UI test; the order of these lines is.
private let tabBarLogger = Logger(subsystem: "me.shirazu.dshmizar", category: "tabbar")

/// Drives the bar's transition when a conversation opens or closes.
///
/// Installed where it can always see the bar and always survive the change of
/// screen -- above the tab view, not inside the conversation -- and driven by the
/// one value that decides whether the bar belongs: the layout state `MainTabs`
/// keeps, not the selection alone, because an iPad keeps the bar beside a
/// conversation and a session opened from another tab was never pushed from this
/// one.
struct TabBarTransition: UIViewRepresentable {
    /// Whether the selection bar belongs on screen now.
    ///
    /// The caller decides, because it is not the same question as "is a session
    /// selected": on an iPad the split view shows the list beside the
    /// conversation and the bar stays, and a session opened from a notification
    /// while the Settings tab is on screen is a conversation that is not being
    /// pushed from this tab. `MainTabs` holds both facts and passes the answer.
    var barIsVisible: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        tabBarLogger.debug("update: bar \(barIsVisible ? "in" : "out", privacy: .public), in window \(view.window != nil)")
        context.coordinator.apply(barIsVisible: barIsVisible, from: view)
    }

    /// The two journeys: a picture leaving, and the real bar returning.
    ///
    /// Owns at most one surrogate at a time. A departure that is interrupted --
    /// the conversation closed again while the bar was still leaving -- removes
    /// the picture and starts the return, rather than leaving a picture of the
    /// same bar moving in the opposite direction over the real one.
    @MainActor
    final class Coordinator {
        /// A still of the bar's place in the window, and where that was.
        ///
        /// The window is rendered once and the bar's rectangle is cropped out of
        /// it. The bar's own snapshot is not enough on iOS 26: the floating pill
        /// is drawn across views, and `UITabBar.snapshotView` captured only the
        /// selected item's half of it -- a half pill with one label, which is
        /// worse than the bar it is standing in for. The crop carries the whole
        /// pill, and the page behind it is the app's own background, so the strip
        /// is invisible against the page that replaces it.
        private struct Still {
            let image: UIImage
            /// The bar's rectangle in the window, where the picture is laid.
            let frame: CGRect
        }

        /// What the last update said, so a redraw is not a journey.
        private var shown: Bool?
        /// The bar's picture while it is leaving.
        private var surrogate: UIView?

        /// Move the bar, when it has somewhere to move.
        ///
        /// - Parameters:
        ///   - barIsVisible: whether the bar belongs on screen now.
        ///   - view: the invisible view this coordinator belongs to, used only to
        ///     find the window to draw in.
        func apply(barIsVisible: Bool, from view: UIView) {
            let was = shown
            shown = barIsVisible
            tabBarLogger.debug("apply: bar \(barIsVisible ? "in" : "out", privacy: .public), was \(was.map { $0 ? "in" : "out" } ?? "unset", privacy: .public)")

            // The first update is the state the screen started in, not a change:
            // a phone that launches straight into a conversation must not play
            // the bar's exit for a bar nobody saw.
            guard let was, was != barIsVisible else { return }
            guard let window = view.window, window.windowScene != nil else { return }
            // Reduce Motion is a request for fewer transitions, not shorter
            // ones. The bar still goes and returns; it just does not travel.
            guard !UIAccessibility.isReduceMotionEnabled else {
                surrogate?.removeFromSuperview()
                surrogate = nil
                if barIsVisible { Self.setBarHidden(false, animated: false, on: view) }
                return
            }

            if barIsVisible {
                arrive(from: view)
            } else {
                depart(from: view, window: window)
            }
        }

        /// Bring the bar back with the page.
        ///
        /// The real bar, faded in, and not a picture of it. It is chrome above the
        /// navigation transition, so it is on screen while the page is still
        /// moving; a picture added to the window was behind the pop's snapshot and
        /// did not appear until the page had finished -- which is the reported
        /// "after", one direction over.
        ///
        /// - Parameter view: any view in the tab's hierarchy.
        private func arrive(from view: UIView) {
            surrogate?.removeFromSuperview()
            surrogate = nil
            Self.setBarHidden(false, animated: false, on: view)
            guard let bar = Self.tabBar(above: view) else { return }
            tabBarLogger.debug("journey: arriving, the real bar fades in")
            bar.alpha = 0
            UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
                bar.alpha = 1
            } completion: { _ in
                bar.alpha = 1
            }
        }

        /// Take the bar away with the page.
        ///
        /// The still is taken here, at the departure, because this is the last
        /// moment it can honestly be taken: measured, the real bar is still on
        /// screen at the update that hides it (`isHidden == false`,
        /// `alpha == 1`). Taken while the list was merely idle, it was whatever
        /// the screen looked like when the overlay last updated -- on a quiet
        /// list, the first layout, before the bar had drawn its contents.
        ///
        /// - Parameters:
        ///   - view: any view in the tab's hierarchy.
        ///   - window: the window the bar is in.
        private func depart(from view: UIView, window: UIView) {
            guard let bar = Self.tabBar(above: view),
                  let still = Self.still(of: bar, in: window)
            else {
                tabBarLogger.debug("journey: no still to travel with, asking UIKit to animate")
                Self.setBarHidden(true, animated: true, on: view)
                return
            }

            surrogate?.removeFromSuperview()
            surrogate = nil

            let picture = UIView(frame: still.frame)
            // Nothing that reaches the operator's finger or VoiceOver: this is a
            // picture of a bar, and the real one is still the control. Only the
            // real bar carries the buttons the UI suite counts.
            picture.isUserInteractionEnabled = false
            picture.isAccessibilityElement = false
            picture.accessibilityElementsHidden = true
            let image = UIImageView(image: still.image)
            image.frame = CGRect(origin: .zero, size: still.frame.size)
            image.isUserInteractionEnabled = false
            image.isAccessibilityElement = false
            picture.addSubview(image)
            window.addSubview(picture)
            surrogate = picture

            // The real bar is taken out here rather than left to SwiftUI, and
            // that is measured: on iOS 27 the system's own hide *animates* the
            // bar down over about a third of a second. Left alone, the operator
            // saw two bars -- the system's, moving, and this picture of the same
            // bar starting a few points behind it. Hiding it first makes the
            // moving thing the only one, and on an OS where the hide is one frame
            // it is a no-op.
            Self.setBarHidden(true, animated: false, on: view)
            tabBarLogger.debug("journey: leaving, the bar slides out")

            // The bar's own edge, so it travels out over the edge it lives on
            // rather than across the middle of the screen.
            let distance = still.frame.height + 24
            UIView.animate(withDuration: 0.32, delay: 0, options: [.curveEaseIn, .beginFromCurrentState]) {
                var end = CATransform3DMakeTranslation(0, distance, 0)
                end = CATransform3DScale(end, 0.92, 0.92, 1)
                picture.layer.transform = end
                picture.alpha = 0
            } completion: { _ in
                // This journey's picture, and only if it is still the current
                // one. A conversation reopened before it finished starts another
                // journey, whose picture must not be removed by this completion.
                self.finish(picture)
            }
        }

        /// Take the real bar out of the picture, or put it back.
        ///
        /// The bar is a `UITabBar`, and `UITabBarController.setTabBarHidden` is the
        /// only handle on its visibility from here. It is used for exactly the
        /// length of the journey and then let go, so the state SwiftUI keeps -- and
        /// the accessibility tree the UI tests read -- is what is in force before
        /// and after.
        ///
        /// - Parameters:
        ///   - hidden: whether the real bar should be off screen.
        ///   - animated: whether UIKit should move it rather than jump. The
        ///     journeys hide it instantly and restore it instantly; the animated
        ///     form is only for a departure with no still, where UIKit's own move
        ///     is the transition.
        ///   - view: any view in the tab's hierarchy, to find the controller.
        private static func setBarHidden(_ hidden: Bool, animated: Bool, on view: UIView) {
            guard let bar = tabBar(above: view) else {
                tabBarLogger.debug("bar: no tab bar to \(hidden ? "hide" : "show", privacy: .public)")
                return
            }
            tabBarLogger.debug("bar: \(hidden ? "hide" : "show", privacy: .public), animated \(animated)")
            var candidate: UIViewController? = bar.next as? UIViewController
            while let controller = candidate {
                if let tab = controller as? UITabBarController {
                    tab.setTabBarHidden(hidden, animated: animated)
                    return
                }
                candidate = controller.parent
            }
        }

        /// Take one departure's picture away.
        ///
        /// - Parameter picture: the picture this departure animated.
        private func finish(_ picture: UIView) {
            picture.removeFromSuperview()
            // A newer journey owns the screen now. Removing whichever picture is
            // current would take the newer one off mid-flight.
            guard surrogate === picture else { return }
            surrogate = nil
        }

        /// A still of the bar's place in the window, and where that was.
        ///
        /// The whole window is rendered once and the bar's place is cropped out
        /// of it, rather than the cropped rectangle being drawn *into* a
        /// bar-shaped context: the second is the whole screen squeezed into the
        /// bar's place, which is what the first attempt at this did and it read
        /// as a smear of the page sliding past.
        ///
        /// - Parameters:
        ///   - bar: the bar to photograph.
        ///   - window: the window to take the picture from.
        /// - Returns: the picture and the bar's frame, or `nil` when the bar is
        ///   not on screen to be taken.
        private static func still(of bar: UIView, in window: UIView) -> Still? {
            guard frame(of: bar, in: window) != nil else { return nil }
            // A departure that interrupts an arrival finds the bar mid-fade. The
            // picture is meant to be the bar at full strength, and the bar is
            // about to be hidden anyway; snap it home before rendering.
            bar.alpha = 1
            let frame = bar.convert(bar.bounds, to: window)
            let bounds = window.bounds
            let renderer = UIGraphicsImageRenderer(bounds: bounds)
            let screen = renderer.image { _ in
                window.drawHierarchy(in: bounds, afterScreenUpdates: false)
            }
            let scale = screen.scale
            let crop = CGRect(
                x: frame.minX * scale,
                y: frame.minY * scale,
                width: frame.width * scale,
                height: frame.height * scale,
            )
            guard let cropped = screen.cgImage?.cropping(to: crop) else { return nil }
            return Still(
                image: UIImage(cgImage: cropped, scale: scale, orientation: .up),
                frame: frame,
            )
        }

        /// The bar of the tab view this view is drawn under.
        ///
        /// Walked from the view rather than found through the key window: the app
        /// has exactly one bar, but sheets and previews have windows of their own,
        /// and a global search would find the bar under whichever came first.
        ///
        /// - Parameter view: any view inside the tab's hierarchy.
        /// - Returns: the bar, when there is one above this view.
        private static func tabBar(above view: UIView) -> UIView? {
            var next: UIResponder? = view
            while let responder = next {
                if let controller = responder as? UIViewController,
                   let tab = controller as? UITabBarController {
                    return tab.tabBar
                }
                next = responder.next
            }
            // The responder chain from a SwiftUI-hosted view does not always
            // reach the tab view's controller -- measured: it does not here --
            // so the window's own hierarchy is searched as well. There is one
            // tab bar in this app, and the window this view is in is the one it
            // is drawn in.
            var queue: [UIView] = view.window.map { [$0] } ?? []
            var index = 0
            while index < queue.count {
                let candidate = queue[index]
                index += 1
                if let bar = candidate as? UITabBar { return bar }
                queue.append(contentsOf: candidate.subviews)
            }
            return nil
        }

        /// The bar's place in the window, or nothing when it is not on screen.
        ///
        /// - Parameters:
        ///   - bar: the bar to place.
        ///   - window: the window to place it in.
        /// - Returns: the rectangle, in the window's coordinates.
        private static func frame(of bar: UIView, in window: UIView) -> CGRect? {
            guard bar.superview != nil, !bar.isHidden, bar.alpha > 0 else { return nil }
            let frame = bar.convert(bar.bounds, to: window)
            // A bar laid out to nothing -- a window that has not been sized yet --
            // has no picture to take, and a zero-sized one would animate nowhere.
            guard frame.width > 1, frame.height > 1 else { return nil }
            return frame
        }
    }
}
