//
//  ZipWriter.swift
//  MizarKit
//
//  A ZIP writer, because the log export needs one and iOS has none.
//
//  There is no public zipping API on iOS. `NSFileCoordinator`'s
//  `coordinate(readingItemAt:options:.forUploading:)` produces a zip through a
//  temporary directory and a private implementation, refuses to run without an
//  iCloud-style coordination context, and gives no control over what is inside
//  -- and `FileManager.zipItem` is not public on this platform at all. So the
//  format is written out here, deliberately, and tested: a log archive the
//  operator cannot open is the same as no log archive.
//
//  Deliberately small. What a log export needs is what this has: named entries,
//  CRC-32, DEFLATE when it helps, stored when it does not, and one central
//  directory. No ZIP64, no encryption, no multi-disk, no streaming writer. The
//  one hard limit that follows -- an entry must fit in four gigabytes -- is
//  checked rather than silently truncated, because a zip whose central directory
//  disagrees with its entries is a zip that opens as corruption.
//
//  DEFLATE comes from `Compression`, whose `COMPRESSION_ZLIB` is *raw* deflate:
//  no zlib header, no Adler-32 trailer. That is exactly what a ZIP entry with
//  compression method 8 holds, and it is the one detail of this file worth
//  stating out loud, because the name "zlib" suggests the opposite.
//

import Compression
import Foundation

/// One entry in an archive.
public struct ZipEntry: Sendable, Equatable {
    /// The name inside the archive. Slashes make directories.
    public let path: String
    /// The bytes.
    public let contents: Data

    /// - Parameters:
    ///   - path: the name inside the archive.
    ///   - contents: the bytes.
    public init(path: String, contents: Data) {
        self.path = path
        self.contents = contents
    }

    /// - Parameters:
    ///   - path: the name inside the archive.
    ///   - text: the text, as UTF-8.
    public init(path: String, text: String) {
        self.init(path: path, contents: Data(text.utf8))
    }
}

/// What can go wrong building an archive.
public enum ZipWriterError: Error, Equatable {
    /// One entry is too large for the format as implemented here.
    ///
    /// ZIP stores sizes as 32-bit fields; past that an archive needs ZIP64, and
    /// silently writing the low 32 bits produces a file that reports itself as
    /// corrupt in every reader there is.
    case entryTooLarge(path: String, bytes: Int)
}

/// Builds ZIP archives in memory.
public enum ZipWriter {
    /// The largest an entry may be.
    public static let maximumEntryBytes = 0xFFFF_FFFF

    /// Build an archive.
    ///
    /// - Parameters:
    ///   - entries: what to put in it, in the order they should appear.
    ///   - modifiedAt: the timestamp every entry carries. One timestamp rather
    ///     than one per entry: these are generated files, and "when the archive
    ///     was made" is the only honest time to record.
    /// - Returns: the archive's bytes.
    /// - Throws: ``ZipWriterError/entryTooLarge(path:bytes:)`` when an entry
    ///   cannot be represented.
    public static func archive(_ entries: [ZipEntry], modifiedAt: Date = Date()) throws -> Data {
        let stamp = dosStamp(modifiedAt)
        var body = Data()
        var directory = Data()

        /// What one entry became, decided once.
        ///
        /// Decided once and then written twice -- into the local header and into
        /// the central directory -- rather than recompressing for the second
        /// copy. They must agree byte for byte about the method and the
        /// compressed size, and the way to guarantee that is to have one answer,
        /// not two computations that are supposed to match.
        struct Prepared {
            let name: Data
            let payload: Data
            let method: UInt16
            let crc: UInt32
            let uncompressed: Int
            let offset: Int
        }

        var prepared: [Prepared] = []
        for entry in entries {
            guard entry.contents.count <= maximumEntryBytes else {
                throw ZipWriterError.entryTooLarge(path: entry.path, bytes: entry.contents.count)
            }
            let name = Data(entry.path.utf8)
            guard name.count <= Int(UInt16.max) else {
                throw ZipWriterError.entryTooLarge(path: entry.path, bytes: name.count)
            }
            // Compression is attempted and kept only when it wins. A log line of
            // forty bytes is not compressible, and a stored entry is both
            // smaller on disk and cheaper to write than a deflated one that grew.
            let squeezed = deflate(entry.contents)
            let useDeflate = squeezed.map { $0.count < entry.contents.count } ?? false
            let item = Prepared(
                name: name,
                payload: useDeflate ? squeezed! : entry.contents,
                method: useDeflate ? 8 : 0,
                crc: crc32(entry.contents),
                uncompressed: entry.contents.count,
                offset: body.count,
            )
            prepared.append(item)
            append(UInt32(0x0403_4B50), to: &body)
            append(UInt16(20), to: &body)                 // version needed: 2.0
            append(UInt16(0x0800), to: &body)             // UTF-8 names
            append(item.method, to: &body)
            append(stamp.time, to: &body)
            append(stamp.date, to: &body)
            append(item.crc, to: &body)
            append(UInt32(item.payload.count), to: &body)
            append(UInt32(item.uncompressed), to: &body)
            append(UInt16(item.name.count), to: &body)
            append(UInt16(0), to: &body)                  // no extra field
            body.append(item.name)
            body.append(item.payload)
        }

        for item in prepared {
            append(UInt32(0x0201_4B50), to: &directory)
            append(UInt16(20), to: &directory)            // version made by
            append(UInt16(20), to: &directory)            // version needed
            append(UInt16(0x0800), to: &directory)        // UTF-8 names
            append(item.method, to: &directory)
            append(stamp.time, to: &directory)
            append(stamp.date, to: &directory)
            append(item.crc, to: &directory)
            append(UInt32(item.payload.count), to: &directory)
            append(UInt32(item.uncompressed), to: &directory)
            append(UInt16(item.name.count), to: &directory)
            append(UInt16(0), to: &directory)             // no extra field
            append(UInt16(0), to: &directory)             // no comment
            append(UInt16(0), to: &directory)             // first disk
            append(UInt16(0), to: &directory)             // internal attributes
            append(UInt32(0), to: &directory)             // external attributes
            append(UInt32(item.offset), to: &directory)
            directory.append(item.name)
        }

        var out = body
        let directoryOffset = out.count
        out.append(directory)
        append(UInt32(0x0605_4B50), to: &out)
        append(UInt16(0), to: &out)                       // this disk
        append(UInt16(0), to: &out)                       // disk with the directory
        append(UInt16(entries.count), to: &out)
        append(UInt16(entries.count), to: &out)
        append(UInt32(directory.count), to: &out)
        append(UInt32(directoryOffset), to: &out)
        append(UInt16(0), to: &out)                       // no archive comment
        return out
    }

    // MARK: - Primitives

    /// A ZIP timestamp, in the DOS format the format has used since 1989.
    ///
    /// Local time, not UTC, because that is what the format stores and what
    /// every reader displays back. The seconds field holds half-seconds, so the
    /// resolution is two seconds and an odd second is rounded down -- harmless
    /// for "when was this archive made", and the alternative is a zip whose
    /// entries look an hour out to whoever opens it.
    ///
    /// - Parameter date: the moment to record.
    /// - Returns: the DOS time and date fields.
    static func dosStamp(_ date: Date) -> (time: UInt16, date: UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        // 1980 is the format's epoch: anything earlier cannot be represented, and
        // dates before it are clamped rather than wrapped into the future.
        let year = max(1980, min(2107, parts.year ?? 1980))
        let month = max(1, min(12, parts.month ?? 1))
        let day = max(1, min(31, parts.day ?? 1))
        let time = UInt16((parts.hour ?? 0) << 11 | (parts.minute ?? 0) << 5 | (parts.second ?? 0) / 2)
        let stamp = UInt16((year - 1980) << 9 | month << 5 | day)
        return (time, stamp)
    }

    /// Write a 16-bit little-endian value.
    private static func append(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    /// Write a 32-bit little-endian value.
    private static func append(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }

    /// The CRC-32 every ZIP entry carries, as PKZIP defines it.
    public static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    /// Compress with raw DEFLATE, or `nil` when it cannot be done.
    ///
    /// Failure is not an error: an entry that will not compress is stored
    /// instead, which is a larger archive rather than a missing one.
    static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        // Apple's encoder writes a complete stream only when the destination is
        // big enough; it answers 0 otherwise, with no way to ask how much room
        // it wanted. Growing until it fits is the documented workaround, and it
        // is bounded: incompressible input stops being worth trying long before
        // the limit, and the caller stores the entry instead.
        var capacity = max(256, data.count + (data.count / 2))
        let limit = data.count * 4 + 4096
        while capacity <= limit {
            var destination = [UInt8](repeating: 0, count: capacity)
            let written = destination.withUnsafeMutableBufferPointer { out -> Int in
                data.withUnsafeBytes { raw -> Int in
                    guard let source = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_encode_buffer(
                        out.baseAddress!, out.count,
                        source, data.count,
                        nil, COMPRESSION_ZLIB,
                    )
                }
            }
            if written > 0 { return Data(destination[0..<written]) }
            capacity *= 2
        }
        return nil
    }
}
