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
//  that hides the bar stays exactly as it was, and what travels is a picture of
//  the bar: a still of it, cached while it was on screen, laid in the bar's own
//  place and then slid down over the bottom edge as the page arrives -- or slid
//  back up as the page leaves, with the real bar handed back where it lands.
//  Nothing about which screen is reachable changes, so nothing the UI suite
//  queries changes.
//

import SwiftUI
import UIKit

/// Drives the bar's transition when a conversation opens or closes.
///
/// Installed where it can always see the bar and always survive the change of
/// screen -- above the tab view, not inside the conversation -- and driven by the
/// one value that decides whether the bar belongs: the selected session.
struct TabBarTransition: UIViewRepresentable {
    /// The session on screen, or nothing when the list is.
    ///
    /// The bar belongs while this is `nil`; anything else means a conversation is
    /// open and the bar is on its way out. The value itself is not used beyond
    /// that decision -- it is read so a change is an update, whichever session it
    /// was.
    var sessionId: String?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.apply(barIsVisible: sessionId == nil, from: view)
    }

    /// The picture of the bar, and the timing of its one journey.
    ///
    /// Owns at most one surrogate at a time. A journey that is interrupted -- the
    /// conversation closed again while the bar was still leaving -- removes what
    /// is on screen and starts the other one, rather than leaving two pictures of
    /// the same bar moving in opposite directions.
    @MainActor
    final class Coordinator {
        /// What the last update said, so a redraw is not a journey.
        private var shown: Bool?
        /// The bar's picture while it is in flight.
        private var surrogate: UIView?
        /// The bar as it last looked, and where it was.
        ///
        /// Kept rather than taken at the moment of the change, because that
        /// moment is too late: measured, the bar is gone from the hierarchy
        /// before this coordinator is told the selection moved, so a still taken
        /// then is a still of the screen without a bar on it. Taken on every
        /// update while the bar *is* on screen, which costs one render of one
        /// window per change of screen -- not per frame.
        ///
        /// Shared rather than owned, and measured: SwiftUI builds a fresh
        /// coordinator when the tab view's own state moves, which happens in the
        /// same update as the selection change -- so a cache owned by the
        /// coordinator was taken away exactly when it was needed. The app has one
        /// tab bar, so one cache is enough.
        private static var cache: (image: UIImage, frame: CGRect)?

        /// Move the bar, when it has somewhere to move.
        ///
        /// - Parameters:
        ///   - barIsVisible: whether the bar belongs on screen now.
        ///   - view: the invisible view this coordinator belongs to, used only to
        ///     find the window to draw in.
        func apply(barIsVisible: Bool, from view: UIView) {
            let was = shown
            shown = barIsVisible

            // Every update, not only the ones that change something: the bar is
            // on screen while the list is, and the update that would catch it
            // leaving is one the bar has already gone by. The cache is what the
            // journey is made of, so it is filled whenever there is something to
            // fill it with, which is whenever the list is the screen.
            let window = view.window
            if barIsVisible,
               let window, window.windowScene != nil,
               let bar = Self.tabBar(above: view),
               let barFrame = Self.frame(of: bar, in: window) {
                Self.cache = (still(of: window, at: barFrame), barFrame)
            }

            // The first update is the state the screen started in, not a change:
            // a phone that launches straight into a conversation must not play
            // the bar's exit for a bar nobody saw.
            guard let was, was != barIsVisible else { return }
            guard let window, window.windowScene != nil else { return }
            // Reduce Motion is a request for fewer transitions, not shorter
            // ones. The bar still goes and returns; it just does not travel.
            guard !UIAccessibility.isReduceMotionEnabled else {
                surrogate?.removeFromSuperview()
                surrogate = nil
                return
            }
            // A bar with no still behind it -- the first launch of a process that
            // came back on a conversation, say -- still moves: UIKit is asked to
            // animate it rather than being told to jump, which is the same
            // transition with the system's own picture of the bar.
            guard let cached = Self.cache else {
                Self.setBarHidden(!barIsVisible, animated: true, on: view)
                return
            }
            let barFrame = cached.frame

            surrogate?.removeFromSuperview()
            surrogate = nil

            let picture = UIView(frame: barFrame)
            let image = UIImageView(image: cached.image)
            image.frame = CGRect(origin: .zero, size: barFrame.size)
            image.isUserInteractionEnabled = false
            image.isAccessibilityElement = false
            picture.addSubview(image)
            window.addSubview(picture)
            surrogate = picture

            // The bar's own edge, so it travels in and out over the edge it lives
            // on rather than across the middle of the screen.
            let distance = barFrame.height + 24
            if barIsVisible {
                // The bar is coming back, from below the edge it lives on, while
                // the list arrives behind it.
                //
                // The real bar is taken away first and given back at the end, and
                // that is what makes this a transition rather than a picture
                // drawn next to the thing it is a picture of: measured, SwiftUI
                // puts the real bar back in one frame as soon as the conversation
                // closes, so left alone the bar pops in on frame one and the
                // picture arrives underneath it -- two bars, one of them already
                // home. Handing over means the bar the operator sees coming back
                // is the one that moves, and the real one appears where it lands.
                Self.setBarHidden(true, animated: false, on: view)
                var start = CATransform3DMakeTranslation(0, distance, 0)
                start = CATransform3DScale(start, 0.92, 0.92, 1)
                picture.layer.transform = start
                picture.alpha = 0
                UIView.animate(withDuration: 0.42, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
                    picture.layer.transform = CATransform3DIdentity
                    picture.alpha = 1
                } completion: { _ in
                    self.finish()
                    Self.setBarHidden(false, animated: false, on: view)
                }
            } else {
                // The bar is leaving with the conversation: down and away over the
                // bottom edge, fading as it goes, while the page slides in above
                // it. The real bar is already on its way out -- SwiftUI has
                // hidden it by the time this runs, which is why the picture was
                // cached while it was still there -- so nothing has to be handed
                // over on this side.
                UIView.animate(withDuration: 0.32, delay: 0, options: [.curveEaseIn, .beginFromCurrentState]) {
                    var end = CATransform3DMakeTranslation(0, distance, 0)
                    end = CATransform3DScale(end, 0.92, 0.92, 1)
                    picture.layer.transform = end
                    picture.alpha = 0
                } completion: { _ in
                    self.finish()
                }
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
        ///   - animated: whether UIKit should move it rather than jump. Used only
        ///     when there is no still to travel with.
        ///   - view: any view in the tab's hierarchy, to find the controller.
        private static func setBarHidden(_ hidden: Bool, animated: Bool, on view: UIView) {
            guard let bar = tabBar(above: view) else { return }
            var candidate: UIViewController? = bar.next as? UIViewController
            while let controller = candidate {
                if let tab = controller as? UITabBarController {
                    tab.setTabBarHidden(hidden, animated: animated)
                    return
                }
                candidate = controller.parent
            }
        }

        /// Take the picture away, once it has arrived.
        private func finish() {
            surrogate?.removeFromSuperview()
            surrogate = nil
        }

        /// A still of one rectangle of the window.
        ///
        /// The whole window is rendered once and the bar's place is cropped out
        /// of it, rather than the cropped rectangle being drawn *into* a
        /// bar-shaped context: the second is the whole screen squeezed into the
        /// bar's place, which is what the first attempt at this did and it read
        /// as a smear of the page sliding past.
        ///
        /// - Parameters:
        ///   - window: the window to take the picture from.
        ///   - rect: the rectangle to keep, in the window's coordinates.
        /// - Returns: that rectangle, at the window's scale.
        private func still(of window: UIView, at rect: CGRect) -> UIImage {
            let bounds = window.bounds
            let renderer = UIGraphicsImageRenderer(bounds: bounds)
            let screen = renderer.image { _ in
                window.drawHierarchy(in: bounds, afterScreenUpdates: false)
            }
            let scale = screen.scale
            let crop = CGRect(
                x: rect.minX * scale,
                y: rect.minY * scale,
                width: rect.width * scale,
                height: rect.height * scale,
            )
            guard let cropped = screen.cgImage?.cropping(to: crop) else { return screen }
            return UIImage(cgImage: cropped, scale: scale, orientation: .up)
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
