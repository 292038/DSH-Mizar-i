//
//  PDFPreview.swift
//  DSH-Mizar
//
//  A PDF, page by page, in the drawer.
//
//  PDFKit rather than QuickLook, and the difference is the frame: a PDF is the
//  one format where a reader wants continuous scrolling, pinch-zoom and a page
//  count, and QuickLook's chrome (a Done button, a share sheet, a title bar for a
//  document that already has a header above it) is designed for a full-screen
//  presentation. `PDFView` in continuous mode is what a preview column wants.
//
//  The document is loaded from the cached file, so this view never touches the
//  network: by the time it is built, `PreviewCenter` has already put the bytes on
//  disk.
//

import PDFKit
import SwiftUI

struct PDFPreview: View {
    let url: URL

    /// The page count, read once, for the caption under the page.
    @State private var pages = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            PDFDocumentView(url: url)
            if pages > 1 {
                Text(String(format: String(localized: "%lld pages"), pages))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .liquidCapsule(interactive: false)
                    .padding(.bottom, 10)
                    .allowsHitTesting(false)
            }
        }
        .task(id: url) {
            pages = PDFDocument(url: url)?.pageCount ?? 0
        }
        .accessibilityIdentifier("preview.pdf")
    }
}

/// `PDFView`, wrapped.
///
/// The document is loaded in `makeUIView` and reloaded only when the URL changes
/// — not on every update, which would reset the reader's scroll position each
/// time the drawer animates.
private struct PDFDocumentView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .clear
        view.document = PDFDocument(url: url)
        context.coordinator.url = url
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        view.document = PDFDocument(url: url)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// Which file the view is already showing.
    @MainActor
    final class Coordinator {
        var url: URL?
    }
}
