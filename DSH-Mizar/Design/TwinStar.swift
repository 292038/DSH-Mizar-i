//
//  TwinStar.swift
//  DSH-Mizar
//
//  "Running", drawn as the app's namesake.
//
//  Mizar is a double star -- the bright one in the Big Dipper's handle with its
//  faint companion, Alcor, beside it. A session that is working shows exactly
//  that: a dot, and a smaller one going round it. It says "busy" the way a
//  spinner does, without looking like every other app's spinner, and it is
//  quiet enough to sit in a list of twenty rows without the list shimmering.
//
//  Under Reduce Motion the companion stops where it is. Two dots side by side
//  still say "running"; they just do not move. While a drawer is being dragged
//  or settles, the companion parks the same way, for the same reason in
//  miniature: the orbit redraws its layer on every frame it runs, and those
//  frames belong to the card.
//

import SwiftUI

struct TwinStar: View {
    /// The diameter of the whole figure.
    var size: CGFloat = 12
    var color: Color = .accentColor
    /// One full orbit, in seconds.
    var period: Double = 2.4

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Whether the companion may orbit. The shell holds this while a drawer
    /// is being dragged or settles; a held star parks where Reduce Motion
    /// parks it, and picks the orbit back up when the drawers stop.
    @Environment(\.drawersStill) private var drawersStill

    var body: some View {
        ZStack {
            Circle()
                .fill(color)
                .frame(width: size * 0.5, height: size * 0.5)
                .shadow(color: color.opacity(0.55), radius: size * 0.22)
            companion
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var companion: some View {
        let dot = Circle()
            .fill(color.opacity(0.85))
            .frame(width: size * 0.24, height: size * 0.24)
            .offset(x: size * 0.4)
        if reduceMotion || !drawersStill {
            dot.rotationEffect(.degrees(-35))
        } else {
            dot.keyframeAnimator(initialValue: 0.0, repeating: true) { content, angle in
                content.rotationEffect(.degrees(angle))
            } keyframes: { _ in
                LinearKeyframe(360, duration: period)
            }
        }
    }
}

#Preview {
    HStack(spacing: 20) {
        TwinStar()
        TwinStar(size: 20)
        TwinStar(size: 32, color: .green)
    }
    .padding()
}
