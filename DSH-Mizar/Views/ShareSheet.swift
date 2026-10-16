//
//  ShareSheet.swift
//  DSH-Mizar
//
//  The system share sheet, for a file that does not exist until it is asked for.
//
//  `ShareLink` would be the shorter answer and it is the wrong one here: its item
//  has to be known when the view is built, and the log archive is produced by the
//  tap that asks for it. Building it eagerly would zip the log every time the
//  settings list redrew -- on scroll, on a notification, on a switch -- and a
//  screen that does work nobody asked for is a screen that stutters.
//
//  So: the button makes the file, and only then is a sheet presented over it.
//  This is Apple's own `UIActivityViewController` underneath, with the same
//  destinations the operator already knows -- AirDrop, Mail, Save to Files.
//

import SwiftUI
import UIKit

/// Presents `UIActivityViewController`.
struct ShareSheet: UIViewControllerRepresentable {
    /// What to share. A file URL, in this app's one use of it.
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {
        // Nothing to update. The sheet is built for one export and dismissed with
        // it; a second export gets a second sheet.
    }
}
