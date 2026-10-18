//
//  PressableStyle.swift
//  DSH-Mizar
//
//  The press every hand-drawn control shares.
//
//  Down is immediate and up is a spring. A press that eases in waits for the
//  finger to be sure before it answers, and a release that snaps back looks
//  like a reset rather than a let-go; the asymmetry is the whole effect.
//

import SwiftUI

struct PressableStyle: ButtonStyle {
    /// How far a press sinks the control.
    var scale: CGFloat = 0.96
    /// Whether a press also dims it, for controls with no fill to darken.
    var dims = false

    func makeBody(configuration: Configuration) -> some View {
        PressableBody(configuration: configuration, scale: scale, dims: dims)
    }
}

private struct PressableBody: View {
    let configuration: ButtonStyleConfiguration
    let scale: CGFloat
    let dims: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(dims && configuration.isPressed ? 0.7 : (isEnabled ? 1 : 0.45))
            .animation(
                configuration.isPressed ? .easeOut(duration: 0.08) : .mizarBouncy,
                value: configuration.isPressed,
            )
    }
}

extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { PressableStyle() }
    static func pressable(scale: CGFloat, dims: Bool = false) -> PressableStyle {
        PressableStyle(scale: scale, dims: dims)
    }
}
