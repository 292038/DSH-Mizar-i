//
//  MarkdownMessage.swift
//  DSH-Mizar
//
//  A model's answer, drawn block by block.
//
//  `Text` cannot draw the shape of a Markdown message. Given an
//  `AttributedString` parsed with `.full`, it renders characters and inline
//  attributes only: the paragraphs, list items, headings and tables live in
//  `presentationIntent`, and the characters themselves come back with no line
//  breaks -- measured, "第一行\n第二行" parses to "第一行 第二行". So a summary
//  arrived as one run-on paragraph, a list lost its bullets, and a table became
//  "列A列B12".
//
//  `MizarKit.MarkdownBlocks` cuts the message into blocks; this draws them.
//  Inline styling (bold, italic, code, links) is still the system's own
//  parser -- one line at a time, where it cannot swallow a line break.
//

import SwiftUI
import MizarKit

/// A message body drawn as the blocks it is made of.
struct MarkdownMessage: View {
    /// The raw text, kept for VoiceOver: what is read is what was said, not the
    /// rendering of it.
    private let source: String
    private let blocks: [MarkdownBlock]

    init(_ source: String) {
        self.source = source
        self.blocks = MarkdownBlocks.parse(source)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm + 2) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(source)
    }

    // MARK: - Blocks

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            inline(text)
                .fixedSize(horizontal: false, vertical: true)

        case .heading(let level, let text):
            inline(text)
                .font(headingFont(level))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, level <= 2 ? 4 : 2)

        case .list(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.marker)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 18, alignment: .trailing)
                        inline(item.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // Nested items keep their own indent; the marker column is
                    // shared so a numbered list lines up on the dot.
                    .padding(.leading, CGFloat(item.indent) * 6)
                }
            }

        case .quote(let text):
            // The bar is an overlay on the text rather than a sibling in an
            // HStack: a shape has no height of its own, so as a sibling it
            // stretches to whatever the row is offered -- measured, a quote
            // drew a full-screen vertical line.
            inline(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 13)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(Color.primary.opacity(0.18))
                        .frame(width: 3)
                }

        case .code(let language, let text):
            codeBlock(language: language, text: text)

        case .table(let table):
            tableView(table)

        case .divider:
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(height: 0.5)
                .padding(.vertical, 2)
        }
    }

    // MARK: - Parts

    /// One line (or paragraph) of inline Markdown.
    ///
    /// Inline-only, preserving whitespace: emphasis, code spans and links are
    /// styled, and every newline inside the run stays a newline. A string the
    /// system parser refuses is drawn verbatim rather than dropped.
    private func inline(_ string: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: string,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace),
        ) {
            return Text(attributed)
        }
        return Text(string)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1, 2: .title3.weight(.semibold)
        case 3, 4: .headline
        default: .subheadline.weight(.semibold)
        }
    }

    private func codeBlock(language: String?, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let language, !language.isEmpty {
                Text(language.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                // An empty fence still needs a line's height, or the block
                // collapses to a border with nothing inside it.
                Text(text.isEmpty ? " " : text)
                    .font(.system(.callout, design: .monospaced))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // A horizontal ScrollView is greedy in both directions unless told
            // otherwise; without this the block took the whole screen's height.
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(2)
        .background(
            Color.primary.opacity(0.05),
            in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous),
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5),
        )
    }

    /// A GFM table, as a grid that scrolls sideways when it is wider than the
    /// column of text it sits in.
    private func tableView(_ table: MarkdownTable) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(table.header.indices, id: \.self) { column in
                        tableCell(
                            table.header[column],
                            alignment: table.alignment(at: column),
                            isHeader: true,
                            fill: Color.primary.opacity(0.06),
                        )
                    }
                }
                ForEach(table.rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(table.header.indices, id: \.self) { column in
                            tableCell(
                                table.rows[row][column],
                                alignment: table.alignment(at: column),
                                isHeader: false,
                                fill: row.isMultiple(of: 2) ? .clear : Color.primary.opacity(0.03),
                            )
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5),
            )
        }
        // Same reason as the code block: a horizontal scroll view left to
        // itself takes the height it is offered, which in a conversation row is
        // the rest of the screen.
        .fixedSize(horizontal: false, vertical: true)
    }

    private func tableCell(
        _ text: String,
        alignment: MarkdownTableAlignment,
        isHeader: Bool,
        fill: Color,
    ) -> some View {
        inline(text)
            .font(isHeader ? .callout.weight(.semibold) : .callout)
            .multilineTextAlignment(textAlignment(alignment))
            .frame(minWidth: 84, maxWidth: 220, alignment: alignmentValue(alignment))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(fill)
            // Row and column lines, drawn inside the cell so the grid needs no
            // divider rows of its own.
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.primary.opacity(0.10))
                    .frame(height: 0.5)
            }
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 0.5)
            }
    }

    private func alignmentValue(_ alignment: MarkdownTableAlignment) -> Alignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private func textAlignment(_ alignment: MarkdownTableAlignment) -> TextAlignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}
