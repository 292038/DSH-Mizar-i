//
//  ImagePreview.swift
//  DSH-Mizar
//
//  A PNG or JPEG, in the drawer.
//
//  The image is never loaded with `UIImage(contentsOfFile:)`: that decodes the
//  full bitmap before anything is drawn, and a 30 MiB screenshot can be enough
//  pixels to be killed for. ImageIO reads the header first, the pixel budget is
//  checked, and only then is a downsampled bitmap produced -- with EXIF
//  orientation applied, so a phone photo is not shown on its side.
//
//  The budget itself lives in `MizarKit.ImagePreviewPolicy`, where the cheap
//  suite can test it. The CoreGraphics work stays here, in the app.
//

import ImageIO
import MizarKit
import SwiftUI
import UIKit

struct ImagePreview: View {
    let url: URL

    @State private var loaded: LoadedImage?
    @State private var failure: String?

    var body: some View {
        Group {
            if let loaded {
                ZStack(alignment: .bottom) {
                    Image(uiImage: loaded.image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(10)
                    Text(verbatim: "\(Int(loaded.pixelSize.width)) × \(Int(loaded.pixelSize.height))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .liquidCapsule(interactive: false)
                        .padding(.bottom, 10)
                        .allowsHitTesting(false)
                }
                .accessibilityIdentifier("preview.image")
                .accessibilityLabel(Text(url.lastPathComponent))
            } else if let failure {
                message(failure)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: url) { await load() }
    }

    // MARK: - The file

    private func load() async {
        loaded = nil
        failure = nil
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try decode(url)
            }.value
            guard !Task.isCancelled else { return }
            loaded = result
        } catch ImageProblem.tooLarge {
            failure = String(localized: "This image is too large to preview.")
        } catch {
            failure = String(localized: "This image could not be read.")
        }
        if failure != nil { loaded = nil }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("preview.image.failed")
    }
}

// MARK: - Decoding

// File scope on purpose: `Task.detached` below must be able to call the decoder
// off the main actor, and members of a `View` inherit its main-actor isolation.
private enum ImageProblem: Error {
    case unreadable
    case tooLarge
}

/// A decoded bitmap and the file's own dimensions.
///
/// `@unchecked Sendable` for the trip back from the decoding task only:
/// `UIImage` is immutable here and is not touched by another thread after
/// the `await` hands it to the main actor.
private struct LoadedImage: @unchecked Sendable {
    let image: UIImage
    let pixelSize: CGSize
}

private func decode(_ url: URL) throws -> LoadedImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
          let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
    else {
        throw ImageProblem.unreadable
    }
    guard ImagePreviewPolicy.accepts(width: width, height: height) else {
        throw ImageProblem.tooLarge
    }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: ImagePreviewPolicy.maxThumbnailPixels,
        // Applies the EXIF orientation while downsampling, which is the
        // difference between a portrait photo and one lying on its side.
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        throw ImageProblem.unreadable
    }
    return LoadedImage(
        image: UIImage(cgImage: cgImage),
        pixelSize: CGSize(width: width, height: height),
    )
}
