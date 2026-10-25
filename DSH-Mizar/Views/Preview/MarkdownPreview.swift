//
//  MarkdownPreview.swift
//  DSH-Mizar
//
//  A Markdown document, drawn the way the conversation draws one.
//
//  The same `MarkdownBlocksView` the transcript uses, on purpose: a report the
//  model wrote is the same kind of text as a reply it wrote, and two renderers
//  would eventually disagree about a table. What differs is only the frame —
//  a page's margins instead of a bubble's — and that the whole file is read at
//  once rather than revealed as it streams.
//

import MizarKit
import SwiftUI

struct MarkdownPreview: View {
    let url: URL

    @State private var blocks: [MarkdownBlock] = []
    @State private var failure: String?

    var body: some View {
        Group {
            if let failure {
                Text(failure)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if blocks.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    MarkdownBlocksView(blocks: blocks)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 28)
                }
                // Selectable: a report is something an operator copies out of.
                .textSelection(.enabled)
                .accessibilityIdentifier("preview.markdown")
            }
        }
        .task(id: url) { load() }
    }

    /// Read and parse the file.
    ///
    /// Parsed once, here, rather than in `body`: a document is redrawn whenever
    /// the page scrolls or the drawer moves, and cutting Markdown into blocks on
    /// every one of those frames is work the reader never sees.
    private func load() {
        failure = nil
        do {
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) else {
                failure = String(localized: "This file is not text this app can read.")
                return
            }
            blocks = MarkdownBlocks.parse(text)
        } catch {
            failure = String(localized: "The saved copy of this file could not be read.")
        }
    }
}
