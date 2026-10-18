//
//  Theme.swift
//  DSH-Mizar
//
//  The few numbers the whole app is drawn with.
//
//  Restraint is the design: one accent, one radius scale, one spacing grid. The
//  accent is the asset catalogue's `AccentColor` -- a cyan that is deep enough to
//  carry white text in the light appearance and bright enough to glow in the dark
//  one -- and everything else is the system's own neutrals, so the accent is the
//  only colour on screen that means anything.
//
//  Every radius here is meant for `style: .continuous`. A circular-arc corner is
//  the one detail that makes a SwiftUI screen look like a web page.
//

import SwiftUI

enum Theme {
    /// Corner radii, smallest to largest. Nest them concentrically: a surface
    /// inset by `n` inside one of radius `r` takes `concentric(r, inset: n)`.
    enum Radius {
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 20
        static let xl: CGFloat = 26
        /// A sheet-sized card.
        static let card: CGFloat = 22
    }

    /// The radius of a surface nested inside another, so their curves stay
    /// parallel instead of pinching at the corners.
    ///
    /// - Parameters:
    ///   - outer: the containing surface's radius.
    ///   - inset: how far inside it the nested surface sits.
    /// - Returns: the nested radius, never negative.
    static func concentric(_ outer: CGFloat, inset: CGFloat) -> CGFloat {
        max(0, outer - inset)
    }

    /// The 4-pt grid the apps have always used.
    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        static let huge: CGFloat = 32
    }

    /// The icon's own navy, used where the brand rather than the system is
    /// speaking: the pairing screen and the Live Activity card.
    static let navy = Color(red: 19 / 255, green: 31 / 255, blue: 61 / 255)
    static let navyDeep = Color(red: 8 / 255, green: 13 / 255, blue: 27 / 255)

    /// Ink for text drawn on an accent fill.
    ///
    /// White in the light appearance, where the accent is a deep cyan; a near
    /// black in the dark one, where the accent is bright enough that white on it
    /// fails contrast.
    static let onAccent = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 3 / 255, green: 20 / 255, blue: 31 / 255, alpha: 1)
            : .white
    })

    /// The states the app has always coloured, kept to the system's hues so
    /// they follow the appearance and the accessibility contrast setting.
    static let running = Color.green
    static let waiting = Color.orange
    static let failed = Color.red
    static let question = Color.blue

    /// The sidebar's ground: one step off the conversation's, so the card the
    /// conversation becomes reads as lifted off it.
    static let sidebarBackground = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.075, green: 0.082, blue: 0.098, alpha: 1)
            : UIColor(red: 0.953, green: 0.957, blue: 0.969, alpha: 1)
    })

    /// The highlight under the selected row: a sheet of paper on the light
    /// sidebar, a faint lift on the dark one.
    static let selectionFill = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.085)
            : UIColor.white
    })

    /// The conversation's ground.
    static let paneBackground = Color(UIColor.systemBackground)
}
