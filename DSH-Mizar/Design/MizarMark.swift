//
//  MizarMark.swift
//  DSH-Mizar
//
//  The icon's mark -- a dot and three arcs of signal -- as something that can
//  move.
//
//  Drawn rather than imported, so each arc can be lit on its own: the pairing
//  screen sends a pulse up through them like a signal looking for a computer, the
//  first download fills them a third at a time, and the home screen lights them
//  dot-outward the moment it appears. The geometry is the icon's own (a 68×46
//  box, the arcs centred on the dot and spanning 124°).
//

import SwiftUI

/// One arc of the mark, in the mark's own 68×46 box.
private struct MarkArc: Shape {
    /// The arc's radius in mark units: 11.1, 22.1 or 33.
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / 68, rect.height / 46)
        let origin = CGPoint(
            x: rect.midX - 34 * scale,
            y: rect.midY - 23 * scale,
        )
        var path = Path()
        path.addRelativeArc(
            center: CGPoint(x: origin.x + 34 * scale, y: origin.y + 38 * scale),
            radius: radius * scale,
            startAngle: .degrees(208),
            delta: .degrees(124),
        )
        return path
    }
}

/// The dot.
private struct MarkDot: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / 68, rect.height / 46)
        let center = CGPoint(x: rect.midX, y: rect.midY - 23 * scale + 38 * scale)
        let r = 6.25 * scale
        return Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
    }
}

/// The mark, with as many arcs lit as asked.
struct MizarMark: View {
    /// How many arcs are lit, dot outward. Fractions light an arc partially,
    /// which is how the first download fills it smoothly.
    var lit: Double = 3
    /// The outermost arc's colour; the icon's is the accent.
    var accent: Color = .accentColor
    /// The colour of the dot and the inner arcs.
    var ink: Color = .primary

    private static let radii: [CGFloat] = [11.1, 22.1, 33]

    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / 68, geometry.size.height / 46)
            ZStack {
                MarkDot().fill(ink)
                ForEach(Array(Self.radii.enumerated()), id: \.offset) { index, radius in
                    let amount = min(1, max(0, lit - Double(index)))
                    MarkArc(radius: radius)
                        .stroke(index == 2 ? accent : ink, style: StrokeStyle(lineWidth: 7.4 * scale, lineCap: .butt))
                        .opacity(0.16 + 0.84 * amount)
                }
            }
        }
        .aspectRatio(68 / 46, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// The mark, lighting dot-outward once, then resting.
///
/// The home screen's greeting: the signal finding its computer.
struct MizarMarkConnecting: View {
    var accent: Color = .accentColor
    var ink: Color = .primary
    @State private var lit: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        MizarMark(lit: lit, accent: accent, ink: ink)
            .onAppear {
                guard lit == 0 else { return }
                if reduceMotion {
                    lit = 3
                } else {
                    withAnimation(.easeOut(duration: 0.9).delay(0.15)) { lit = 3 }
                }
            }
    }
}

/// The mark, sending a pulse up through its arcs for as long as it is on
/// screen: a signal looking for something to answer it.
struct MizarMarkSearching: View {
    var accent: Color = .accentColor
    var ink: Color = .primary
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            MizarMark(lit: 3, accent: accent, ink: ink)
        } else {
            // One beat: the arcs come up in turn, hold, and fall away
            // together, then rest before the next.
            MizarMark(lit: 0.6, accent: accent, ink: ink)
                .keyframeAnimator(initialValue: 0.6, repeating: true) { _, value in
                    MizarMark(lit: value, accent: accent, ink: ink)
                } keyframes: { _ in
                    KeyframeTrack {
                        CubicKeyframe(3, duration: 1.1)
                        LinearKeyframe(3, duration: 0.5)
                        CubicKeyframe(0.6, duration: 0.6)
                        LinearKeyframe(0.6, duration: 0.7)
                    }
                }
        }
    }
}
