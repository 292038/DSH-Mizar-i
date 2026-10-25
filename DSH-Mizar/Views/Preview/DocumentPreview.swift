//
//  DocumentPreview.swift
//  DSH-Mizar
//
//  A Word document, drawn by the system's own renderer.
//
//  There is no honest alternative on iOS. `NSAttributedString` can read HTML and
//  RTF but not OOXML — that document type exists on macOS and not here — and a
//  hand-written `word/document.xml` reader would render paragraphs, lose styles,
//  lose tables and lose images, which is a worse preview than none for exactly
//  the documents an operator asks a model to write. QuickLook is the renderer
//  the Files app and Mail use, and it reads `.docx` properly.
//
//  It is hosted as a child view controller rather than presented as a sheet,
//  because the file is supposed to appear *in the drawer* — a sheet would cover
//  the conversation the file belongs to. QuickLook brings its own small title bar
//  and share button; they are the system's, they work, and they sit under the
//  page's own header the way a document window sits under a title.
//

import QuickLook
import SwiftUI

struct DocumentPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        context.coordinator.url = url
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        controller.reloadData()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// QuickLook asks for its items through a data source, one at a time.
    @MainActor
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL?

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            url == nil ? 0 : 1
        }

        func previewController(
            _ controller: QLPreviewController,
            previewItemAt index: Int,
        ) -> any QLPreviewItem {
            (url ?? URL(fileURLWithPath: "/dev/null")) as NSURL
        }
    }
}
