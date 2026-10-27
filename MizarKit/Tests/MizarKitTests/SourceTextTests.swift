//
//  SourceTextTests.swift
//  MizarKitTests
//
//  The encoding ladder behind the source preview.
//
//  These are the bytes the page will actually be handed: a UTF-8 file with a
//  BOM, a UTF-16 file from a Windows editor, a Windows-1252 file that is not
//  UTF-8 at all, a binary file with a source extension, and a prefix cut in the
//  middle of a multi-byte character. The host carries all of them; the page has
//  to draw the first four and refuse the fifth.
//

import Foundation
import Testing
@testable import MizarKit

@Suite("Source text")
struct SourceTextTests {
    @Test("decodes plain UTF-8 and counts its lines")
    func plainUTF8() throws {
        let preview = try SourceText.decode(Data("let a = 1\nlet b = 2\n".utf8))
        #expect(preview.text == "let a = 1\nlet b = 2\n")
        #expect(preview.encoding == .utf8)
        #expect(preview.lineCount == 2)
        #expect(!preview.truncated)
    }

    @Test("strips a UTF-8 BOM instead of drawing it on the first line")
    func utf8BOM() throws {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data("import Foundation".utf8))
        let preview = try SourceText.decode(data)
        #expect(preview.text == "import Foundation")
        #expect(preview.encoding == .utf8)
    }

    @Test("decodes UTF-16 with a little-endian BOM")
    func utf16LittleEndian() throws {
        var data = Data([0xFF, 0xFE])
        data.append("let value = 1".data(using: .utf16LittleEndian) ?? Data())
        let preview = try SourceText.decode(data)
        #expect(preview.text == "let value = 1")
        #expect(preview.encoding == .utf16LittleEndian)
    }

    @Test("decodes UTF-16 with a big-endian BOM")
    func utf16BigEndian() throws {
        var data = Data([0xFE, 0xFF])
        data.append("let value = 1".data(using: .utf16BigEndian) ?? Data())
        let preview = try SourceText.decode(data)
        #expect(preview.text == "let value = 1")
        #expect(preview.encoding == .utf16BigEndian)
    }

    @Test("falls back to Windows-1252 for a file that is not UTF-8")
    func windows1252() throws {
        // 0xE9 is "é" in Windows-1252; alone it is not valid UTF-8.
        let preview = try SourceText.decode(Data([0x63, 0x61, 0x66, 0xE9]))
        #expect(preview.text == "café")
        #expect(preview.encoding == .windows1252)
    }

    @Test("an empty file is empty, not one blank line")
    func emptyFile() throws {
        let preview = try SourceText.decode(Data())
        #expect(preview.text.isEmpty)
        #expect(preview.lineCount == 0)
        #expect(preview.encoding == .utf8)
    }

    @Test("refuses bytes with control characters or NULs")
    func binaryIsRefused() {
        #expect(throws: SourceText.Failure.binary) {
            try SourceText.decode(Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x0D]))
        }
        #expect(throws: SourceText.Failure.binary) {
            try SourceText.decode(Data(repeating: 0x01, count: 64))
        }
    }

    @Test("truncates at the limit and says so")
    func truncates() throws {
        let data = Data("0123456789".utf8)
        let preview = try SourceText.decode(data, limit: 4)
        #expect(preview.text == "0123")
        #expect(preview.truncated)
    }

    @Test("a cut inside a multi-byte character drops the partial character")
    func cutInsideScalar() throws {
        // "é" is C3 A9. Cutting after C3 must not leave a replacement char or
        // fail the decode: the prefix is "aé" without the partial byte.
        var data = Data("a".utf8)
        data.append(Data([0xC3, 0xA9]))
        data.append(Data("b".utf8))
        let preview = try SourceText.decode(data, limit: 2)
        #expect(preview.text == "a")
        #expect(preview.truncated)
    }

    @Test("reads a file from disk and stops at the byte budget")
    func readsFromDisk() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mizar-source-\(UUID().uuidString).swift")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("let a = 1\nlet b = 2\n".utf8).write(to: url)
        let preview = try SourceText.read(url, limit: 8)
        #expect(preview.truncated)
        #expect(preview.text == "let a = ")
    }

    @Test("a directory is not text")
    func directoryIsUnreadable() {
        #expect(throws: SourceText.Failure.unreadable) {
            try SourceText.read(FileManager.default.temporaryDirectory)
        }
    }
}

@Suite("Image preview policy")
struct ImagePreviewPolicyTests {
    @Test("a phone photo fits")
    func phonePhoto() {
        #expect(ImagePreviewPolicy.accepts(width: 4032, height: 3024))
    }

    @Test("the budget is 40 megapixels")
    func budget() {
        #expect(ImagePreviewPolicy.accepts(width: 8000, height: 5000))
        #expect(!ImagePreviewPolicy.accepts(width: 8001, height: 5000))
    }

    @Test("a giant square is refused before decoding")
    func giantSquare() {
        #expect(!ImagePreviewPolicy.accepts(width: 20_000, height: 20_000))
    }

    @Test("zero and negative dimensions are refused")
    func degenerate() {
        #expect(!ImagePreviewPolicy.accepts(width: 0, height: 10))
        #expect(!ImagePreviewPolicy.accepts(width: 10, height: 0))
        #expect(!ImagePreviewPolicy.accepts(width: -1, height: 10))
    }
}
