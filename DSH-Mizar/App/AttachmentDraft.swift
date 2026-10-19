//
//  AttachmentDraft.swift
//  DSH-Mizar
//
//  A file on its way from the photo library or the Files app to the host.
//
//  This is where the product rules live, not in the uploader: what is too large,
//  what an image is normalised to, how many of each kind can be attached. The
//  uploader in MizarKit is deliberately mechanical, because these are rules the
//  operator sees and can be told about, and they belong beside the screen that
//  says no.
//
//  Images are normalised before they are measured. A modern phone camera writes
//  a 12-megapixel HEIC that is 2–4 MB and 4032 px on its long edge; the host
//  hands it to a model that downsamples it again, and the socket carries every
//  byte three times (phone → relay → host). Re-encoding to a 2048-px JPEG costs
//  nothing the model can see and is what makes a photo attachment practical on a
//  mobile connection.
//

import Foundation
import MizarKit
import Observation
import UniformTypeIdentifiers
import UIKit

/// The limits the host enforces, mirrored so the phone can say no early.
///
/// They are the host's numbers, not the phone's invention: the host rejects a
/// prompt that exceeds them, and a screen that lets the operator build a
/// 70 MiB draft only to be refused after the upload is a screen that wastes
/// their time and data.
enum AttachmentLimits {
    /// A normalised image may be at most 10 MiB.
    static let maxImageBytes = 10 * 1024 * 1024
    /// Any other file may be at most 32 MiB.
    static let maxFileBytes = 32 * 1024 * 1024
    /// One prompt may carry at most 64 MiB of attachments.
    static let maxTotalBytes = 64 * 1024 * 1024
    /// At most eight attachments per prompt.
    static let maxAttachments = 8
    /// At most four of those may be images.
    static let maxImages = 4
    /// The longest edge an image is resized to.
    static let maxImageEdge: CGFloat = 2048
}

/// Why a file could not be attached.
enum AttachmentProblem: LocalizedError, Equatable {
    case imageTooLarge
    case fileTooLarge
    case totalTooLarge
    case tooManyAttachments
    case tooManyImages
    case unreadableImage
    case unreadableFile
    case emptyFile

    var errorDescription: String? {
        switch self {
        case .imageTooLarge:
            String(format: String(localized: "That photo is too large. The limit is %@ per image."), Self.megabytes(AttachmentLimits.maxImageBytes))
        case .fileTooLarge:
            String(format: String(localized: "That file is too large. The limit is %@ per file."), Self.megabytes(AttachmentLimits.maxFileBytes))
        case .totalTooLarge:
            String(format: String(localized: "Those attachments add up to more than %@."), Self.megabytes(AttachmentLimits.maxTotalBytes))
        case .tooManyAttachments:
            String(format: String(localized: "At most %lld attachments can be sent at once."), AttachmentLimits.maxAttachments)
        case .tooManyImages:
            String(format: String(localized: "At most %lld photos can be sent at once."), AttachmentLimits.maxImages)
        case .unreadableImage:
            String(localized: "That photo could not be read.")
        case .unreadableFile:
            String(localized: "That file could not be read.")
        case .emptyFile:
            String(localized: "That file is empty.")
        }
    }

    /// A byte count as whole megabytes, for a limit sentence.
    private static func megabytes(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// Where upload progress is written from the socket's executor.
///
/// A shared object rather than a `@State` dictionary because the uploader calls
/// its progress closure on whatever executor the connection runs on: the closure
/// has to be `@Sendable`, and mutating view state from it directly is exactly
/// what the compiler refuses. This is the one small hop, and it is main-actor
/// isolated so the view reads it without a lock.
@MainActor
@Observable
final class AttachmentProgress: @unchecked Sendable {
    /// Fraction sent per draft, 0...1. Absent until an upload starts.
    private(set) var values: [UUID: Double] = [:]

    /// Record one draft's progress.
    /// - Parameters:
    ///   - value: the fraction sent.
    ///   - id: the draft.
    func set(_ value: Double, for id: UUID) {
        values[id] = value
    }

    /// The fraction sent for one draft, or `nil` when it has not started.
    /// - Parameter id: the draft.
    /// - Returns: the fraction, 0...1.
    func value(for id: UUID) -> Double? { values[id] }

    /// Forget every upload.
    func clear() { values = [:] }
}

/// One file waiting to be sent.
///
/// Holds the bytes, not a URL: the Files app's security-scoped URL is only valid
/// inside the importer's callback and the PhotosPicker item only yields data
/// once, so a draft that kept a reference would fail at send time after the
/// picker had gone.
struct AttachmentDraft: Identifiable, Equatable {
    /// Stable identity for the strip and for progress.
    let id = UUID()
    /// Image or file.
    let kind: AttachmentKind
    /// The file name the host will store.
    let name: String
    /// The IANA media type.
    let mediaType: String
    /// The bytes to upload, already normalised.
    let data: Data
    /// A small preview, for images.
    let thumbnail: UIImage?

    /// The byte size the limits are checked against.
    var byteSize: Int { data.count }

    /// Whether this is an image.
    var isImage: Bool { kind == .image }

    /// The label the strip shows for a file.
    var shortLabel: String {
        isImage ? String(localized: "Photo") : name
    }

    // MARK: - Building

    /// Normalise a photo into a draft.
    ///
    /// Downscales to at most 2048 px on the long edge, re-encodes as JPEG, and
    /// steps the quality down if the result is still over the image limit.
    ///
    /// - Parameter data: the photo bytes from `PhotosPickerItem`.
    /// - Returns: the draft.
    /// - Throws: ``AttachmentProblem`` when the data is not an image or cannot
    ///   be brought under the limit.
    static func image(from data: Data) throws -> AttachmentDraft {
        guard let source = UIImage(data: data) else { throw AttachmentProblem.unreadableImage }
        var candidate = downscaled(source, maxEdge: AttachmentLimits.maxImageEdge)
        var encoded = candidate.jpegData(compressionQuality: 0.85)
        var quality = 0.85
        while let bytes = encoded, bytes.count > AttachmentLimits.maxImageBytes, quality > 0.45 {
            quality -= 0.15
            encoded = candidate.jpegData(compressionQuality: quality)
        }
        if let bytes = encoded, bytes.count > AttachmentLimits.maxImageBytes {
            // Still over: the photo is unusually detailed at 2048 px. Half the
            // edge is the last thing worth trying before refusing, because a
            // 1024-px photo is usually still useful and a refusal is not.
            candidate = downscaled(source, maxEdge: AttachmentLimits.maxImageEdge / 2)
            encoded = candidate.jpegData(compressionQuality: 0.7)
        }
        guard let bytes = encoded, bytes.count <= AttachmentLimits.maxImageBytes else {
            throw AttachmentProblem.imageTooLarge
        }
        return AttachmentDraft(
            kind: .image,
            name: "photo.jpg",
            mediaType: "image/jpeg",
            data: bytes,
            thumbnail: UIImage(data: bytes)?.preparingThumbnail(of: CGSize(width: 140, height: 140)),
        )
    }

    /// Read a file from the Files app into a draft.
    ///
    /// - Parameter url: the file URL from `fileImporter`.
    /// - Returns: the draft.
    /// - Throws: ``AttachmentProblem`` when the file is too large or unreadable.
    static func file(from url: URL) throws -> AttachmentDraft {
        // The URL is security-scoped: without this the read fails for anything
        // outside the app's container, which is every real file.
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        let name = url.lastPathComponent.isEmpty ? String(localized: "file") : url.lastPathComponent
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > AttachmentLimits.maxFileBytes {
            throw AttachmentProblem.fileTooLarge
        }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw AttachmentProblem.unreadableFile
        }
        guard !data.isEmpty else { throw AttachmentProblem.emptyFile }
        guard data.count <= AttachmentLimits.maxFileBytes else { throw AttachmentProblem.fileTooLarge }
        let mediaType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        return AttachmentDraft(
            kind: .file,
            name: name,
            mediaType: mediaType,
            data: data,
            thumbnail: nil,
        )
    }

    // MARK: - Rules

    /// Check a set of drafts against the limits.
    ///
    /// - Parameter drafts: the drafts that would be attached.
    /// - Throws: ``AttachmentProblem`` naming the first rule broken.
    static func validate(_ drafts: [AttachmentDraft]) throws {
        guard drafts.count <= AttachmentLimits.maxAttachments else {
            throw AttachmentProblem.tooManyAttachments
        }
        guard drafts.count(where: \.isImage) <= AttachmentLimits.maxImages else {
            throw AttachmentProblem.tooManyImages
        }
        let total = drafts.reduce(0) { $0 + $1.byteSize }
        guard total <= AttachmentLimits.maxTotalBytes else {
            throw AttachmentProblem.totalTooLarge
        }
    }

    /// The text an attachment-only prompt should be shown as.
    ///
    /// Mirrors the host's own summary text for an attachment-only message:
    /// `[Photo]` for images, `[File: name]` for a file. The optimistic bubble
    /// then matches the record the host writes, which is what makes the
    /// stand-in disappear the moment the real message arrives instead of
    /// lingering for a refresh interval.
    ///
    /// - Parameters:
    ///   - text: what the operator typed, possibly empty.
    ///   - drafts: what is attached.
    /// - Returns: the text to send; unchanged when there is text.
    static func promptText(_ text: String, drafts: [AttachmentDraft]) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty else { return text }
        guard let first = drafts.first else { return "" }
        if first.isImage { return "[Photo]" }
        return "[File: \(first.name)]"
    }

    /// Whether a photo can be added without breaking the image count.
    /// - Parameter drafts: what is attached.
    /// - Returns: whether there is room for one more image.
    static func canAddImage(to drafts: [AttachmentDraft]) -> Bool {
        drafts.count < AttachmentLimits.maxAttachments
            && drafts.count(where: \.isImage) < AttachmentLimits.maxImages
    }

    /// Whether a file can be added without breaking the count.
    /// - Parameter drafts: what is attached.
    /// - Returns: whether there is room for one more file.
    static func canAddFile(to drafts: [AttachmentDraft]) -> Bool {
        drafts.count < AttachmentLimits.maxAttachments
    }

    // MARK: - Internals

    /// Scale an image so neither edge exceeds `maxEdge`.
    ///
    /// Drawn rather than resized through `CGImageSource`: `UIImage.draw` applies
    /// the EXIF orientation, and a portrait photo resized without it becomes a
    /// landscape one. The renderer is non-opaque so a PNG with transparency does
    /// not get a black background.
    private static func downscaled(_ image: UIImage, maxEdge: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxEdge, longest > 0 else { return image }
        let scale = maxEdge / longest
        let target = CGSize(width: floor(size.width * scale), height: floor(size.height * scale))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
