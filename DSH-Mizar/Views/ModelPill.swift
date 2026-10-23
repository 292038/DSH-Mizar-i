//
//  ModelPill.swift
//  DSH-Mizar
//
//  The model control, in both places a session can be aimed from.
//
//  It was written inline in `ComposerBar`, and the home screen -- the pane with
//  no conversation in it, which is where a session actually starts -- had no way
//  to choose a model at all. That is the one decision a new session needs before
//  it exists: the first prompt otherwise goes to whichever model the computer
//  defaults to, and by the time the conversation is on screen the choice costs a
//  second tap and a switch in the middle of a turn.
//
//  One control rather than two, because two would drift: the pill is small
//  enough that a copy looks identical until the day one of them gains a badge,
//  a truncation rule or a different hit area.
//

import SwiftUI
import MizarKit

/// `deepseek-v4 · High`, as a route is named on a pill.
///
/// The model id rather than the catalogue's display name: the pill has one line,
/// and the id is what the host's logs and the picker's rows are named with. The
/// effort is capitalised because it arrives as an id -- `high`, not `High`.
///
/// - Parameters:
///   - model: the model id.
///   - effort: the reasoning level, when the route has one.
/// - Returns: the label.
func modelPillLabel(model: String, effort: String?) -> String {
    guard let effort, !effort.isEmpty else { return model }
    return "\(model) · \(effort.capitalized)"
}

/// The route a session will actually use, as the app and the host agree on it.
///
/// Four sources, most specific first. The switch this phone made and the host
/// accepted is the newest: the host has no "what is this session using" read on
/// this side of the protocol, and its stats frame only catches up on the next
/// read -- on an idle session nothing asks it to. The host's own pending change
/// (`next`) is what the following turn will use, its `lastUsed` is the route the
/// previous turn took, and the catalogue default names a session that has never
/// run.
///
/// One function rather than the same precedence in the composer bar and in the
/// picker: the two copies drifted, and after a switch the bar went on naming the
/// model the session had been on before it.
///
/// - Parameters:
///   - chosen: the route this phone last had the host accept, when there is one.
///   - reported: the host's model pair from the session's stats frame.
///   - fallback: the route a new session would take.
/// - Returns: the selection to name, or `nil` when nothing can name it.
func agreedModelSelection(
    chosen: ModelSelection?,
    reported: ModelSelectionPair?,
    fallback: ModelSelection? = nil,
) -> ModelSelection? {
    chosen ?? reported?.next ?? reported?.lastUsed ?? fallback
}

/// A capsule naming the model in force, which opens the picker.
struct ModelPill: View {
    /// What to draw, already composed by ``modelPillLabel(model:effort:)``.
    let label: String
    /// Collapse to the glyph alone.
    ///
    /// The session composer does this while the keyboard is up: the field has
    /// the operator's attention and the row has to make room for what they are
    /// typing. The home screen has no such row to share, so its pill stays
    /// labelled.
    var compact: Bool = false
    /// Open the picker.
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "cpu")
                    .font(.system(size: 12, weight: .semibold))
                if !compact {
                    Text(label)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        // Tail, not middle: "deepseek-fl…" still names the family.
                        .truncationMode(.tail)
                        .transition(.blurReplace)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .transition(.blurReplace)
                }
            }
            .padding(.horizontal, compact ? 0 : 11)
            .frame(width: compact ? 32 : nil, height: 32)
            .background(.fill.tertiary, in: Capsule())
            .contentShape(.capsule)
        }
        .buttonStyle(.pressable)
        .animation(.mizarSmooth, value: compact)
    }
}
