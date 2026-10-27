//
//  PendingPromptBar.swift
//  DSH-Mizar
//
//  The message waiting for the running turn to end.
//
//  Guided send off, a text sent into a running turn stays on the phone instead
//  of going straight into the host's queue -- a queued prompt cannot be called
//  back, and everything this bar offers is a call-back. It floats just above the
//  composer, slightly narrower than it, one line tall, so it reads as belonging
//  to the field rather than to the conversation.
//
//  Three keys, and their order is the order of the decisions:
//
//    send    hand it over now, as guidance into the running turn
//    return  put it back in the field and let the bar go
//    delete  throw it away
//
//  The bar itself is Liquid Glass, like every other thing that floats over the
//  conversation (see `Glass.swift`). The keys are solid and sit on top of it,
//  the same choice the composer already makes for its own round controls: glass
//  nested in glass is morphed by the material whenever the surface changes
//  shape, and a key that wanders under the finger is a bug in a control.
//

import SwiftUI

/// One held prompt, and the three ways out of it.
struct PendingPromptBar: View {
    /// What is being held.
    let prompt: PendingPrompt
    /// Send it now, as guidance.
    var onSend: () async -> Void = {}
    /// Put it back in the field.
    var onReturn: () -> Void = {}
    /// Throw it away.
    var onDelete: () -> Void = {}

    /// Bumped by every key, for the light tap the app plays on a commit.
    @State private var taps = 0

    private static let keySize: CGFloat = 30

    var body: some View {
        HStack(spacing: 8) {
            Text(prompt.summary)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("pending.text")

            HStack(spacing: 6) {
                sendKey
                returnKey
                deleteKey
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .frame(minHeight: 40)
        // Glass after the layout and the content, as the material wants it.
        .glassEffect(.regular, in: Capsule())
        .contentShape(.capsule)
        .mizarFeedback(.impact(weight: .light), trigger: taps)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pending.bar")
    }

    // MARK: - The keys

    private var sendKey: some View {
        Button {
            taps += 1
            // The bar leaves before the host answers: the model takes the prompt
            // out of the pending map, then sends it. A tap during that is a tap
            // on a bar that is already going, and the model refuses the second
            // hand-over rather than sending the text twice.
            Task { await onSend() }
        } label: {
            Image(systemName: "arrow.up")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.onAccent)
                .frame(width: Self.keySize, height: Self.keySize)
                .background {
                    Circle()
                        .fill(Color.accentColor)
                        .shadow(color: Color.accentColor.opacity(0.4), radius: 6, y: 2)
                }
                .contentShape(.circle)
        }
        .buttonStyle(.pressable(scale: 0.86))
        .accessibilityLabel(Text("Send now"))
        .accessibilityHint(Text("Hands the message to the running turn as guidance."))
        .accessibilityIdentifier("pending.send")
    }

    private var returnKey: some View {
        Button {
            taps += 1
            onReturn()
        } label: {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: Self.keySize, height: Self.keySize)
                .background {
                    Circle().fill(Color(.tertiarySystemFill))
                }
                .contentShape(.circle)
        }
        .buttonStyle(.pressable(scale: 0.86))
        .accessibilityLabel(Text("Put back in the field"))
        .accessibilityIdentifier("pending.return")
    }

    private var deleteKey: some View {
        Button {
            taps += 1
            onDelete()
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.failed)
                .frame(width: Self.keySize, height: Self.keySize)
                .background {
                    Circle().fill(Color(.tertiarySystemFill))
                }
                .contentShape(.circle)
        }
        .buttonStyle(.pressable(scale: 0.86))
        .accessibilityLabel(Text("Delete"))
        .accessibilityIdentifier("pending.delete")
    }
}

#Preview {
    VStack(spacing: 12) {
        PendingPromptBar(prompt: PendingPrompt(sessionId: "s", text: "Also update the changelog before you finish."))
        PendingPromptBar(prompt: PendingPrompt(sessionId: "s", text: "One more thing."))
    }
    .padding()
}
