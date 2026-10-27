//
//  DeliverablesTests.swift
//  MizarKitTests
//
//  The two shapes a delivered file arrives in, and how a name becomes a viewer.
//
//  Everything here is a rule that decides what the operator sees: a path the
//  parser trimmed wrong is a card that opens nothing, a kind decided wrong is a
//  PDF drawn as text, and a link recognised as a web page is a tap that goes to
//  Safari. So the cases are the awkward ones — angle brackets, `#L12` anchors,
//  upper-case extensions, a `file://` URL nobody produces but somebody might.
//

import Foundation
import Testing
@testable import MizarKit

@Suite("Deliverables")
struct DeliverablesTests {
    @Test
    func readsTheFilesATurnDeclared() {
        let data: JSONValue = .object([
            "mizarDeliverables": .array([
                .object(["path": .string("docs/report.md"), "description": .string("根因报告")]),
                .object(["path": .string("Build/shot.pdf")]),
            ]),
        ])
        let files = DeliverablePayload.parse(data)
        #expect(files.count == 2)
        #expect(files[0].path == "docs/report.md")
        #expect(files[0].detail == "根因报告")
        #expect(files[0].name == "report.md")
        #expect(files[0].kind == .markdown)
        #expect(files[1].detail == nil)
        #expect(files[1].kind == .pdf)
    }

    @Test
    func anAbsentKeyIsNoFiles() {
        #expect(DeliverablePayload.parse(.object([:])).isEmpty)
        #expect(DeliverablePayload.parse(nil).isEmpty)
        #expect(DeliverablePayload.parse(.object(["mizarDeliverables": .null])).isEmpty)
    }

    @Test
    func dropsAnEntryWithNoPathInsteadOfFailingTheTurn() {
        let data: JSONValue = .object([
            "mizarDeliverables": .array([
                .object(["description": .string("no path here")]),
                .object(["path": .string("   ")]),
                .object(["path": .string("kept.md")]),
            ]),
        ])
        let files = DeliverablePayload.parse(data)
        #expect(files.map(\.path) == ["kept.md"])
    }

    @Test
    func trimsTheNoiseAModelWritesAroundAPath() {
        let data: JSONValue = .object([
            "mizarDeliverables": .array([.object(["path": .string("  ./docs/a.md  ")])]),
        ])
        #expect(DeliverablePayload.parse(data).first?.path == "docs/a.md")
    }

    @Test
    func aBlankDescriptionIsNone() {
        let data: JSONValue = .object([
            "mizarDeliverables": .array([.object([
                "path": .string("a.md"),
                "description": .string("   "),
            ])]),
        ])
        #expect(DeliverablePayload.parse(data).first?.detail == nil)
    }

    @Test
    func decodesTheWireNameForTheDescription() throws {
        // The wire key is `description`; the Swift property is `detail`, because
        // a stored `description` shadows `CustomStringConvertible` on every type
        // that holds one.
        let json = #"{"path":"a.pdf","description":"A"}"#.data(using: .utf8) ?? Data()
        let file = try JSONDecoder().decode(DeliveredFile.self, from: json)
        #expect(file.path == "a.pdf")
        #expect(file.detail == "A")
    }
}

@Suite("Preview kinds")
struct PreviewKindTests {
    @Test(arguments: [
        ("report.md", PreviewKind.markdown),
        ("README.MARKDOWN", .markdown),
        ("a/b/notes.mdown", .markdown),
        ("manual.pdf", .pdf),
        ("MANUAL.PDF", .pdf),
        ("plan.docx", .word),
        ("photo.png", .image),
        ("photo.JPG", .image),
        ("camera.jpeg", .image),
        ("main.c", .source),
        ("main.cpp", .source),
        ("Widget.hpp", .source),
        ("Main.java", .source),
        ("tool.py", .source),
        ("MarkdownMessage.swift", .source),
        ("Main.kt", .source),
        ("index.html", .source),
        ("style.css", .source),
        ("app.js", .source),
        ("app.tsx", .source),
        ("data.json", .source),
        ("layout.xml", .source),
        ("sheet.xlsx", .other),
        ("no-extension", .other),
        (".hidden", .other),
        ("report.", .other),
    ])
    func kindFollowsTheExtension(name: String, expected: PreviewKind) {
        #expect(PreviewKind(fileName: name) == expected)
    }

    @Test
    func everyKindWithAViewerSaysSo() {
        // The list is the gate `PreviewCenter` reads before it reads a byte.
        // A kind added with a badge but left out here never opens.
        for kind in PreviewKind.allCases where kind != .other {
            #expect(kind.isPreviewable, "\(kind) has a badge but no viewer")
        }
        #expect(!PreviewKind.other.isPreviewable)
    }
}

@Suite("Local file links")
struct LocalFileLinkTests {
    @Test
    func readsARelativePathWithItsEditorAnchor() {
        #expect(LocalFileLink.path(inRawTarget: "<Sources/App/A.swift#L139-L159>") == "Sources/App/A.swift")
        #expect(LocalFileLink.path(inRawTarget: "docs/plan.md") == "docs/plan.md")
    }

    @Test
    func readsAnAbsolutePath() {
        #expect(
            LocalFileLink.path(inRawTarget: "/Users/x/project/docs/plan.md")
                == "/Users/x/project/docs/plan.md",
        )
    }

    @Test
    func readsAFileURL() {
        let url = URL(fileURLWithPath: "/tmp/report.pdf")
        #expect(LocalFileLink.path(in: url) == "/tmp/report.pdf")
    }

    @Test
    func leavesTheWebAlone() {
        #expect(LocalFileLink.path(inRawTarget: "https://example.com/a.md") == nil)
        #expect(LocalFileLink.path(inRawTarget: "mailto:someone@example.com") == nil)
        #expect(LocalFileLink.path(in: URL(string: "https://example.com")!) == nil)
    }

    @Test
    func aDriveLetterIsNotAScheme() {
        #expect(LocalFileLink.path(inRawTarget: "C:/notes/a.md") == "C:/notes/a.md")
    }

    @Test
    func decodesPercentEscapes() {
        #expect(LocalFileLink.path(inRawTarget: "docs/my%20report.md") == "docs/my report.md")
    }

    @Test
    func onlyPreviewableTargetsOpenThePreview() {
        #expect(LocalFileLink.isPreviewable(URL(fileURLWithPath: "/tmp/a.pdf")))
        #expect(LocalFileLink.isPreviewable(URL(fileURLWithPath: "/tmp/a.png")))
        #expect(LocalFileLink.isPreviewable(URL(fileURLWithPath: "/tmp/a.swift")))
        #expect(!LocalFileLink.isPreviewable(URL(fileURLWithPath: "/tmp/a.xlsx")))
        #expect(!LocalFileLink.isPreviewable(URL(string: "https://example.com")!))
    }
}
