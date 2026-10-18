//
//  ComposerView.swift
//  DSH-Mizar
//
//  Sending a prompt, and stopping one.
//
//  One slab of glass: the field on top, growing with the text, and along its
//  bottom edge the controls -- commands, the model, the context dial -- with the
//  one round button at the end. The button carries both actions, and which one
//  it carries is the whole state machine:
//
//    the session is running, and nothing has been typed   -> stop
//    anything else                                        -> send
//
//  That is DSH's own rule, and it is right for the same reason it is right
//  there: mid-turn the thing an operator most often wants is to interrupt, and
//  the second most common is to queue something up. One button that changes
//  meaning keeps both one tap away; it changes shape as it changes meaning, so
//  the meaning is never a surprise.
//

import SwiftUI
import MizarKit

struct ComposerView: View {
    let sessionId: String
    let stats: SessionStatsFrame?
    /// What has been typed. Owned by the screen, because the command list puts
    /// text in here -- a command is something the operator finishes typing.
    @Binding var text: String
    /// Whether the field holds the keyboard. Owned by the screen so a tap on the
    /// conversation can put it away.
    @FocusState.Binding var focused: Bool
    @Binding var showingModel: Bool
    @Binding var showingContext: Bool
    @Binding var showingCommands: Bool
    /// Called the moment a send is tapped, with what is being sent: the screen
    /// puts it in flight towards the conversation before the host has answered.
    var onWillSend: (String) -> Void = { _ in }
    /// Called with the text the host accepted, so the conversation can pick it up.
    let onSent: (String) async -> Void
    /// Called when the host refused it; the text is back in the field.
    var onSendFailed: (String) -> Void = { _ in }

    @Environment(AppModel.self) private var model
    @State private var sending = false
    @State private var stopping = false
    /// Bumped on every send, to bounce the arrow.
    @State private var sends = 0

    private static let buttonSize: CGFloat = 34
    private static let corner: CGFloat = Theme.Radius.xl

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The key, not the Chinese: this string is already in the catalogue.
            TextField("Ask your agent…", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .focused($focused)
                .padding(.horizontal, 16)
                .padding(.top, 13)
                .padding(.bottom, 6)
                .accessibilityIdentifier("composer.field")
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(SessionDetailView.space)) } action: { frame in
                    ComposerGeometry.shared.field = frame
                }

            HStack(spacing: 6) {
                ComposerBar(
                    sessionId: sessionId,
                    stats: stats,
                    draft: $text,
                    focused: $focused,
                    showingModel: $showingModel,
                    showingContext: $showingContext,
                    showingCommands: $showingCommands,
                )
                Spacer(minLength: 4)
                primaryButton
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .contentShape(.rect)
        .onTapGesture { focused = true }
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        .animation(.mizarSmooth, value: text.isEmpty)
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .mizarFeedback(.impact(weight: .light), trigger: sends)
    }

    private enum Mode: Equatable { case idle, send, stop }

    private var mode: Mode {
        if showsStop { return .stop }
        return sendEnabled ? .send : .idle
    }

    private var primaryButton: some View {
        Button {
            Task { await primary() }
        } label: {
            Image(systemName: mode == .stop ? "stop.fill" : "arrow.up")
                .font(.system(size: mode == .stop ? 13 : 15, weight: .bold))
                .foregroundStyle(foreground)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce.up, value: sends)
                .frame(width: Self.buttonSize, height: Self.buttonSize)
                .background {
                    Circle()
                        .fill(fill)
                        .shadow(color: mode == .idle ? .clear : fill.opacity(0.4), radius: 8, y: 3)
                }
                .scaleEffect(mode == .idle ? 0.92 : 1)
                .contentShape(.circle)
        }
        .buttonStyle(.pressable(scale: 0.88))
        .disabled(mode == .idle)
        .animation(.mizarBouncy, value: mode)
        .accessibilityLabel(showsStop ? "Stop" : "Send")
        .accessibilityIdentifier(showsStop ? "composer.stop" : "composer.send")
    }

    private var fill: Color {
        switch mode {
        case .stop: Theme.failed
        case .send: .accentColor
        case .idle: Color(.tertiarySystemFill)
        }
    }

    private var foreground: Color {
        switch mode {
        case .stop: .white
        case .send: Theme.onAccent
        case .idle: .secondary
        }
    }

    /// Whether the session this composer belongs to has a turn in flight.
    private var running: Bool {
        model.sessions.first { $0.sessionId == sessionId }?.running ?? false
    }

    /// Whether the one button is a stop button right now.
    private var showsStop: Bool {
        running && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !stopping
    }

    private var sendEnabled: Bool {
        !sending && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Do whichever job the button is currently carrying.
    private func primary() async {
        if showsStop {
            stopping = true
            await model.cancelTurn(sessionId: sessionId)
            stopping = false
        } else {
            await send()
        }
    }

    private func send() async {
        let outgoing = text
        sending = true
        sends += 1
        onWillSend(outgoing)
        // Clear optimistically so the field is ready for the next thought; put
        // the text back if the host refused it, so nothing is silently lost.
        withMizarAnimation(.mizarSmooth) { text = "" }
        let accepted = await model.sendPrompt(outgoing, to: sessionId)
        if accepted {
            await onSent(outgoing)
        } else {
            text = outgoing
            onSendFailed(outgoing)
        }
        sending = false
        focused = true
    }
}

/// Where the field is, for the send's flight to start from.
///
/// A plain object rather than state: the frame changes on every keystroke that
/// wraps a line, and nothing needs to redraw when it does -- it is read once, at
/// the moment of a send.
@MainActor
final class ComposerGeometry {
    static let shared = ComposerGeometry()
    var field: CGRect = .zero
}
