//
//  SourcePreview.swift
//  DSH-Mizar
//
//  A source file, in the drawer.
//
//  TextKit rather than a SwiftUI `Text`: a source file is a page of monospaced
//  lines that the operator selects from, scrolls through and reads at a
//  comfortable size, and a `UITextView` is the view built for exactly that. It
//  also keeps the preview honest at the one-megabyte budget -- a giant `Text`
//  would be laid out whole before the first frame.
//
//  What is drawn is a prefix, decoded by `SourceText`: UTF-8 in the ordinary
//  case, UTF-16 or Windows-1252 when the bytes say so, and nothing at all when
//  they are binary. The caption says when the file was cut short or decoded as
//  something other than UTF-8, because a preview that hides either is a preview
//  that lies about what the computer holds.
//

import MizarKit
import SwiftUI
import UIKit

struct SourcePreview: View {
    let url: URL

    @State private var preview: SourceText.Preview?
    @State private var failure: String?

    var body: some View {
        Group {
            if let failure {
                message(failure)
            } else if let preview {
                VStack(alignment: .leading, spacing: 0) {
                    caption(preview)
                    SourceTextView(text: preview.text)
                        .accessibilityIdentifier("preview.code")
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: url) { await load() }
        // The text view itself carries `preview.code`; an identifier on this
        // container would be propagated down and replace it.
    }

    // MARK: - The file

    private func load() async {
        preview = nil
        failure = nil
        do {
            // Reading and decoding a megabyte must not wait for the main actor;
            // `SourceText` is pure Foundation and its value is Sendable.
            let result = try await Task.detached(priority: .userInitiated) {
                try SourceText.read(url)
            }.value
            guard !Task.isCancelled else { return }
            preview = result
        } catch SourceText.Failure.binary {
            failure = String(localized: "This file is not text this app can read.")
        } catch {
            failure = String(localized: "The saved copy of this file could not be read.")
        }
    }

    // MARK: - Parts

    /// What kind of file, how long it is, and what was done to it to draw it.
    ///
    /// The extension stands in for a language label: it is the one word the
    /// file itself uses, and there is no highlighter whose name would be more
    /// accurate.
    private func caption(_ preview: SourceText.Preview) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: "\(url.pathExtension.uppercased()) · \(lineCount(preview.lineCount))")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            if preview.truncated {
                Text("Showing the first 1 MB.")
            }
            if preview.encoding != .utf8 {
                Text(String(format: String(localized: "Opened as %@"), preview.encoding.displayName))
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .accessibilityIdentifier("preview.source.caption")
    }

    private func lineCount(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 line")
            : String(format: String(localized: "%lld lines"), count)
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("preview.source.failed")
    }
}

/// The text itself: read-only, selectable, monospaced, and scrollable.
private struct SourceTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 10, left: 14, bottom: 24, right: 14)
        view.textContainer.lineFragmentPadding = 0
        // A monospaced face that follows the operator's text size: source is
        // read as characters, and a fixed 12 pt is unreadable at large sizes.
        let base = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.font = UIFontMetrics(forTextStyle: .callout).scaledFont(for: base)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label
        view.dataDetectorTypes = []
        view.text = text
        view.accessibilityIdentifier = "preview.code"
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        // Only a new file replaces the text: assigning on every update would
        // move the reader's selection and scroll position back to the top.
        if view.text != text { view.text = text }
    }
}
