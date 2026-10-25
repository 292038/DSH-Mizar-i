//
//  SidePlaneState.swift
//  DSH-Mizar
//
//  Which of the drawer's three pages is in front.
//
//  The plane used to own this as its own `@State`, and that was right while the
//  only way across was the segmented control: nothing outside the plane needed
//  to know. A delivered file changed that — tapping a card in the conversation
//  has to put the plane on its preview page, and the conversation is a different
//  layer of the shell, built by a different hosting controller. So the choice
//  moves up here, where both layers can read it.
//
//  The plane's *position* stays in the view: it is a number that a spring
//  carries frame by frame, and nothing outside the animation needs it.
//

import Foundation

/// The three pages, in the order the plane lays them out.
///
/// The raw value is the page's index in the plane, which is what the offset is
/// computed from — so the order here and the order in the `HStack` are the same
/// fact, and changing one without the other would slide the plane to the wrong
/// page.
enum SidePlanePage: Int, CaseIterable, Sendable {
    case turns
    case subagents
    case preview
}

/// Where the drawer's plane is looking.
@MainActor
@Observable
final class SidePlaneState {
    /// The page in front.
    var page: SidePlanePage = .turns

    /// Turn to a page, as a tap on the control would.
    ///
    /// - Parameter page: the page to show.
    func show(_ page: SidePlanePage) {
        self.page = page
    }
}
