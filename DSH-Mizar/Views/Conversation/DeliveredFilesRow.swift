//
//  DeliveredFilesRow.swift
//  DSH-Mizar
//
//  The files a turn handed over, drawn between the answer and its toolbar.
//
//  This is the same place the computer puts them: after the model's summary,
//  before the row of actions. That order is the point — the prose says what was
//  done, the card is the thing that was produced, and the actions belong to the
//  message rather than to the file.
//
//  Two shapes reach the screen from one tap. A card here opens the drawer's
//  preview page; so does a link to a local file inside the prose (see
//  `MarkdownBlocksView`). Both end in ``PreviewCenter/open(_:sessionId:)``, which
//  is what makes them the same feature rather than two that resemble each other.
//

import MizarKit
import SwiftUI

struct DeliveredFilesRow: View {
    let turn: ConversationTurn
    let sessionId: String

    @Environment(PreviewCenter.self) private var preview
    @Environment(ShellState.self) private var shell
    @Environment(SidePlaneState.self) private var plane
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// Counts opens, so the tap has something to play the haptic *on*: the
    /// app's haptics are all `sensoryFeedback` attached to a value change.
    @State private var opens = 0

    /// How many cards fit under one answer before the list is the wrong shape.
    ///
    /// The tool allows four files per call and a turn may call it twice; past
    /// half a dozen, a list of names is a worse index than the sentence above it.
    private static let visible = 6

    private var files: [DeliveredFile] { turn.files }
    private var shown: [DeliveredFile] { Array(files.prefix(Self.visible)) }
    private var hidden: Int { max(0, files.count - Self.visible) }

    var body: some View {
        if !files.isEmpty {
            VStack(spacing: 6) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, file in
                    card(file, index: index)
                }
                if hidden > 0 {
                    Text(String(format: String(localized: "%lld more"), hidden))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 4)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("turn.\(turn.id).deliverables")
            .mizarFeedback(.selection, trigger: opens)
        }
    }

    /// One file, as a card.
    private func card(_ file: DeliveredFile, index: Int) -> some View {
        Button {
            open(file)
        } label: {
            HStack(spacing: 11) {
                DeliveredFileIcon(kind: file.kind, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let detail = file.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.primary.opacity(0.045),
                in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous),
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5),
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(accessibilityLabel(for: file))
        .accessibilityHint(Text("Opens the preview"))
        .accessibilityIdentifier("turn.\(turn.id).deliverable.\(index)")
    }

    /// What VoiceOver reads: the file, then what it is, because "report.md" alone
    /// is a file name rather than a thing.
    private func accessibilityLabel(for file: DeliveredFile) -> Text {
        if let detail = file.detail {
            return Text("\(file.name), \(detail)")
        }
        return Text(file.name)
    }

    /// Show a file, and put the drawer on its preview page.
    private func open(_ file: DeliveredFile) {
        reveal(
            file,
            in: sessionId,
            preview: preview,
            shell: shell,
            plane: plane,
            compact: sizeClass != .regular,
        )
        opens += 1
    }
}

/// The one gesture both entry points share.
///
/// A card and a link in the prose are two ways to name the same file, and they
/// have to end in exactly the same place: the file becomes the preview page's
/// subject, the plane turns to that page, and the drawer comes out. Written once
/// because the two callers would otherwise drift — one of them forgetting the
/// iPad's pinned column, or the plane, and leaving the operator with a file that
/// opened somewhere they cannot see.
///
/// - Parameters:
///   - file: the file to show.
///   - sessionId: the conversation it was delivered in.
///   - preview: what holds the page's state.
///   - shell: where the drawer is.
///   - plane: which of the drawer's pages is in front.
///   - compact: whether the drawer is the phone's (a spring) or the iPad's (a
///     pinned column).
@MainActor
func reveal(
    _ file: DeliveredFile,
    in sessionId: String,
    preview: PreviewCenter,
    shell: ShellState,
    plane: SidePlaneState,
    compact: Bool,
) {
    preview.open(file, sessionId: sessionId)
    plane.show(.preview)
    if compact {
        shell.openTrailing()
    } else {
        shell.indexPinnedVisible = true
    }
}
