//
//  Glass.swift
//  DSH-Mizar
//
//  Liquid Glass, used where it belongs.
//
//  One rule: glass is for what floats above the content -- the bars, the
//  composer, the dock of pending requests, the sidebar's controls. Content stays
//  solid. A screen made of glass is a screen of reflections; the effect reads as
//  grand precisely because there is so little of it.
//

import SwiftUI

extension View {
    /// A capsule of glass.
    func liquidCapsule(interactive: Bool = false) -> some View {
        liquidSurface(in: Capsule(), interactive: interactive)
    }

    /// Glass in any shape, or nothing at all.
    ///
    /// - Parameters:
    ///   - shape: what to pour it into.
    ///   - tint: a colour the glass carries, for surfaces that mean something
    ///     (an approval, a question).
    ///   - interactive: whether the glass answers a touch -- it swells and
    ///     catches the light under the finger. For controls, not for panels.
    ///   - condition: when false the view is returned untouched, which is how a
    ///     control that fills itself with a solid colour avoids a layer of glass
    ///     underneath it.
    /// - Returns: the surfaced view.
    @ViewBuilder
    func liquidSurface<S: Shape>(
        in shape: S,
        tint: Color? = nil,
        interactive: Bool = false,
        when condition: Bool = true,
    ) -> some View {
        if condition {
            glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            self
        }
    }

    /// A continuous rounded rectangle of glass.
    func liquidCard(radius: CGFloat = Theme.Radius.card, tint: Color? = nil) -> some View {
        liquidSurface(in: RoundedRectangle(cornerRadius: radius, style: .continuous), tint: tint)
    }
}

/// Groups neighbouring glass so it blends instead of meeting in a seam, and so
/// pieces with a shared `glassEffectID` morph into one another.
struct GlassRow<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        GlassEffectContainer(spacing: spacing) {
            content
        }
    }
}

/// A round control on glass: the sidebar toggle, refresh, jump-to-latest.
struct GlassCircleLabel<Content: View>: View {
    var size: CGFloat = 40
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(width: size, height: size)
            .contentShape(.circle)
            .liquidSurface(in: Circle(), interactive: true)
    }
}
