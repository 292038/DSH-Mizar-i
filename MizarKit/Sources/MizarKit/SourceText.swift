//
//  SourceText.swift
//  MizarKit
//
//  Reading a source file as text, within what a phone can lay out.
//
//  The host will carry a 32 MiB file, and `file.read` is binary-safe. A text
//  view is not a transport: a megabyte is already around fifteen thousand
//  lines, and the rest of the file is still on the computer. So a source
//  preview reads a prefix, decodes it as honestly as it can, and says when it
//  showed only the start.
//
//  The encoding ladder is not decoration. Source is mostly UTF-8, but a
//  Windows-authored `.java` or `.css` can be Windows-1252, and a UTF-16 file
//  starts with a BOM that a plain UTF-8 decode turns into a leading U+FEFF. A
//  preview that refuses every non-UTF-8 file is a preview that cannot open the
//  file it was asked to open; a preview that decodes every binary file as
//  text is worse. Both are decided here, where a test can hold the bytes.
//
//  Pure Foundation: the image viewer's CoreGraphics work stays in the app, and
//  this stays testable in the cheap suite.
//

import Foundation

/// Reading the start of a text file for the preview page.
public enum SourceText {
    /// The most bytes a source preview reads.
    ///
    /// A megabyte is ~15k lines of ordinary source, and the host can carry
    /// 32 MiB. Past this, the page says it is showing the first part rather
    /// than handing a text view a document it cannot draw.
    public static let defaultLimit = 1_048_576

    /// The encoding the bytes were read as.
    public enum Encoding: String, Sendable, Equatable {
        case utf8
        case utf16LittleEndian
        case utf16BigEndian
        case windows1252
        case isoLatin1

        /// The name to show when the file was not UTF-8.
        public var displayName: String {
            switch self {
            case .utf8: "UTF-8"
            case .utf16LittleEndian: "UTF-16 LE"
            case .utf16BigEndian: "UTF-16 BE"
            case .windows1252: "Windows-1252"
            case .isoLatin1: "ISO Latin-1"
            }
        }
    }

    /// What the preview page can draw.
    public struct Preview: Sendable, Equatable {
        /// The decoded prefix.
        public let text: String
        /// The encoding it was decoded as.
        public let encoding: Encoding
        /// Whether the file had more bytes than ``defaultLimit`` (or the
        /// caller's limit).
        public let truncated: Bool
        /// How many lines the prefix holds. An empty file is zero, and a final
        /// newline does not make an empty last line.
        public let lineCount: Int

        public init(text: String, encoding: Encoding, truncated: Bool, lineCount: Int) {
            self.text = text
            self.encoding = encoding
            self.truncated = truncated
            self.lineCount = lineCount
        }
    }

    /// Why a file is not text this app can draw.
    public enum Failure: Error, Sendable, Equatable {
        /// NUL bytes or too many control bytes: a binary file with a text name.
        case binary
        /// The file could not be read at all -- missing, a directory, or a
        /// permission the container does not have.
        case unreadable
    }

    /// Read the start of a file as text.
    ///
    /// - Parameters:
    ///   - url: a local file, already in the preview cache.
    ///   - limit: the most bytes to decode.
    /// - Returns: the decoded prefix and how it was decoded.
    /// - Throws: ``Failure`` when the bytes are not text, or the file cannot be
    ///   read.
    public static func read(_ url: URL, limit: Int = defaultLimit) throws -> Preview {
        let cap = max(limit, 1)
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw Failure.unreadable
        }
        defer { try? handle.close() }
        let data: Data
        do {
            // One byte past the cap is enough to know the file continues, and
            // four spare bytes let a truncated multi-byte scalar be dropped
            // rather than rendered as a replacement character.
            data = try handle.read(upToCount: cap + 4) ?? Data()
        } catch {
            throw Failure.unreadable
        }
        return try decode(data, limit: cap)
    }

    /// Decode bytes as text.
    ///
    /// - Parameters:
    ///   - data: the bytes, which may be more than `limit`.
    ///   - limit: the most bytes to decode.
    /// - Returns: the decoded prefix.
    /// - Throws: ``Failure`` when the bytes are binary.
    public static func decode(_ data: Data, limit: Int = defaultLimit) throws -> Preview {
        let cap = max(limit, 1)
        let truncated = data.count > cap
        let head = data.prefix(cap)

        // A BOM is the one unambiguous statement about encoding a file can
        // make. Strip it before anything else: a UTF-8 BOM left in place is a
        // U+FEFF at the start of the first line.
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            let body = head.dropFirst(min(3, head.count))
            return try preview(utf8Text(from: Data(body), truncated: truncated), encoding: .utf8, truncated: truncated)
        }
        if data.starts(with: [0xFF, 0xFE]) {
            let body = head.dropFirst(min(2, head.count))
            return try preview(utf16Text(from: Data(body), bigEndian: false), encoding: .utf16LittleEndian, truncated: truncated)
        }
        if data.starts(with: [0xFE, 0xFF]) {
            let body = head.dropFirst(min(2, head.count))
            return try preview(utf16Text(from: Data(body), bigEndian: true), encoding: .utf16BigEndian, truncated: truncated)
        }

        // No BOM. A NUL byte, or a run of control bytes past the whitespace a
        // text file is allowed to contain, is a binary file someone named .json.
        try refuseBinary(head)

        if let text = utf8Text(from: Data(head), truncated: truncated) {
            return preview(text, encoding: .utf8, truncated: truncated)
        }
        // Not UTF-8. Windows-1252 is the ordinary answer for source edited on
        // a Windows machine; ISO Latin-1 is the fallback that cannot fail.
        if let text = String(data: Data(head), encoding: .windowsCP1252) {
            return preview(text, encoding: .windows1252, truncated: truncated)
        }
        let text = String(data: Data(head), encoding: .isoLatin1) ?? String(decoding: head, as: UTF8.self)
        return preview(text, encoding: .isoLatin1, truncated: truncated)
    }

    // MARK: - Internals

    /// A decoded string, with the line count the page shows.
    private static func preview(_ text: String, encoding: Encoding, truncated: Bool) -> Preview {
        Preview(text: text, encoding: encoding, truncated: truncated, lineCount: lineCount(of: text))
    }

    /// The same, or a failure for an encoding the bytes did not honour.
    private static func preview(_ text: String?, encoding: Encoding, truncated: Bool) throws -> Preview {
        guard let text else { throw Failure.binary }
        return preview(text, encoding: encoding, truncated: truncated)
    }

    /// How many lines a string holds.
    ///
    /// Counted in UTF-8 bytes for large files: the answer is the same, and it
    /// avoids making an array of every line to count it.
    private static func lineCount(of text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var count = 1
        for byte in text.utf8 where byte == 0x0A { count += 1 }
        if text.hasSuffix("\n") { count -= 1 }
        return count
    }

    /// Decode UTF-8, dropping an incomplete scalar at a truncation boundary.
    private static func utf8Text(from data: Data, truncated: Bool) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        guard truncated else { return nil }
        // A cut can land inside a 1-3 byte scalar. Dropping up to three bytes
        // from the end is the most that can repair it; if it still does not
        // decode, the file is not UTF-8.
        var candidate = data
        for _ in 0..<3 {
            guard !candidate.isEmpty else { return nil }
            candidate = Data(candidate.dropLast())
            if let text = String(data: candidate, encoding: .utf8) { return text }
        }
        return nil
    }

    /// Decode UTF-16 without the BOM, dropping an odd trailing byte.
    private static func utf16Text(from data: Data, bigEndian: Bool) -> String? {
        var candidate = data
        if candidate.count % 2 == 1 { candidate = Data(candidate.dropLast()) }
        return String(data: candidate, encoding: bigEndian ? .utf16BigEndian : .utf16LittleEndian)
    }

    /// Refuse bytes that are not text.
    private static func refuseBinary(_ bytes: Data) throws {
        guard !bytes.isEmpty else { return }
        var controls = 0
        for byte in bytes {
            if byte == 0x00 { throw Failure.binary }
            // Tab, newline and carriage return are text; every other C0
            // control is not something a source file is made of.
            if byte < 0x09 || (byte > 0x0D && byte < 0x20) { controls += 1 }
        }
        // A handful of controls can be a stray escape sequence; a fifth of the
        // bytes being controls is a binary file.
        if controls * 20 > bytes.count { throw Failure.binary }
    }
}

/// What an image preview will agree to decode.
///
/// Kept apart from ImageIO so the budget can be tested without a simulator:
/// the check is arithmetic, and it is the check that stands between a 30 MiB
/// PNG of 20000 x 20000 pixels and a jetsam kill.
public enum ImagePreviewPolicy {
    /// The most pixels the preview page will decode.
    ///
    /// 40 MP is above every phone camera image and most screenshots, and far
    /// below the point where one bitmap would exhaust the app's memory.
    public static let maxPixels = 40_000_000

    /// The longest edge of the bitmap the viewer keeps.
    ///
    /// A drawer column is a few hundred points wide; 2048 px still has detail
    /// to spare at 3x. ImageIO downsamples while decoding, so this is the
    /// memory ceiling as well as the display ceiling.
    public static let maxThumbnailPixels = 2048

    /// Whether an image's reported dimensions fit the budget.
    ///
    /// - Parameters:
    ///   - width: the image's pixel width.
    ///   - height: the image's pixel height.
    /// - Returns: whether the viewer may decode it.
    public static func accepts(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0 else { return false }
        return width <= maxPixels / height
    }
}
