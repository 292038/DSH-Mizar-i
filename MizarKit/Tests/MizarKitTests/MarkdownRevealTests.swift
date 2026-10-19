//
//  MarkdownRevealTests.swift
//  MizarKitTests
//
//  Cutting a parsed message down to the characters typed so far.
//
//  The typewriter works on the parsed blocks rather than on the raw Markdown,
//  which is what keeps `**` and fence markers out of the reveal. The cost is
//  that the character count has to agree exactly with what the reader sees:
//  markers, pipes and language labels are not characters, and a plan paced on a
//  different count would run ahead of or behind the text. These tests pin that
//  agreement block by block.
//

import Foundation
import Testing

@testable import MizarKit

struct MarkdownRevealTests {
    @Test("an untyped message draws nothing")
    func nothingAtZero() {
        let blocks = MarkdownBlocks.parse("# 标题\n\n正文内容")
        #expect(MarkdownReveal.blocks(blocks, visibleCharacters: 0).isEmpty)
        #expect(MarkdownReveal.blocks(blocks, visibleCharacters: -3).isEmpty)
    }

    @Test("a finished reveal is the message unchanged")
    func completeIsIdentity() {
        let blocks = MarkdownBlocks.parse("# 标题\n\n- 一\n- 二")
        let count = MarkdownReveal.characterCount(blocks)
        #expect(MarkdownReveal.blocks(blocks, visibleCharacters: count) == blocks)
        #expect(MarkdownReveal.blocks(blocks, visibleCharacters: count + 50) == blocks)
    }

    @Test("the pacing string is exactly the characters that appear")
    func plainTextMatchesTheCount() {
        let blocks = MarkdownBlocks.parse(
            """
            # 标题

            第一段**加粗**内容

            - 列表一
            - 列表二

            > 引用

            ```
            代码
            ```

            | 列一 | 列二 |
            | --- | --- |
            | 一 | 二 |

            ***
            """,
        )
        #expect(MarkdownReveal.plainText(blocks).count == MarkdownReveal.characterCount(blocks))
        // Block markers are not characters a reader watches being typed, so
        // none of them may be in the count: the heading has lost its `#`, the
        // table its pipes, the fence its backticks.
        let plain = MarkdownReveal.plainText(blocks)
        #expect(!plain.contains("|"))
        #expect(!plain.contains("```"))
        #expect(!plain.contains("# "))
        #expect(plain.contains("标题"))
        #expect(plain.contains("代码"))
        // Inline emphasis is left in the typed characters on purpose. It is
        // what a stream shows: `**加粗**` types as its own characters and
        // resolves into bold when the closing pair arrives, exactly as the
        // desktop does while a model writes. Stripping it here would make the
        // phone the only client that types differently from what was sent.
        #expect(plain.contains("**加粗**"))
    }

    @Test("a paragraph is cut at the budget")
    func cutsAParagraph() {
        let blocks: [MarkdownBlock] = [.paragraph("abcdef")]
        #expect(MarkdownReveal.blocks(blocks, visibleCharacters: 2) == [.paragraph("ab")])
        #expect(MarkdownReveal.blocks(blocks, visibleCharacters: 5) == [.paragraph("abcde")])
    }

    @Test("the budget carries across blocks, and later blocks wait their turn")
    func crossesBlocks() {
        let blocks: [MarkdownBlock] = [
            .paragraph("abc"),
            .heading(level: 2, text: "de"),
            .paragraph("fg"),
        ]
        #expect(MarkdownReveal.blocks(blocks, visibleCharacters: 3) == [.paragraph("abc")])
        #expect(
            MarkdownReveal.blocks(blocks, visibleCharacters: 4)
                == [.paragraph("abc"), .heading(level: 2, text: "d")],
        )
        #expect(
            MarkdownReveal.blocks(blocks, visibleCharacters: 6)
                == [.paragraph("abc"), .heading(level: 2, text: "de"), .paragraph("f")],
        )
    }

    @Test("a list keeps its markers and reveals its items in order")
    func revealsAList() {
        let blocks: [MarkdownBlock] = [
            .list([
                MarkdownListItem(marker: "•", indent: 0, text: "ab"),
                MarkdownListItem(marker: "•", indent: 0, text: "cd"),
            ]),
        ]
        #expect(
            MarkdownReveal.blocks(blocks, visibleCharacters: 3)
                == [.list([
                    MarkdownListItem(marker: "•", indent: 0, text: "ab"),
                    MarkdownListItem(marker: "•", indent: 0, text: "c"),
                ])],
        )
    }

    @Test("a code block types its body, not its fence")
    func revealsCode() {
        let blocks: [MarkdownBlock] = [.code(language: "swift", text: "let x = 1")]
        #expect(
            MarkdownReveal.blocks(blocks, visibleCharacters: 5)
                == [.code(language: "swift", text: "let x")],
        )
    }

    @Test("a table keeps its width while its cells fill in")
    func revealsATable() {
        let table = MarkdownTable(
            header: ["ab", "cd"],
            rows: [["ef", "gh"]],
            alignments: [.leading, .trailing],
        )
        let blocks: [MarkdownBlock] = [.table(table)]
        let partial = MarkdownReveal.blocks(blocks, visibleCharacters: 3)
        guard case .table(let revealed) = try! #require(partial.first) else {
            Issue.record("a table was revealed as something else")
            return
        }
        // Two characters in the first cell, one in the second, nothing below:
        // the header still has both columns, which is what keeps the grid from
        // jumping sideways.
        #expect(revealed.header == ["ab", "c"])
        // The budget ran out inside the header, so no body row has started.
        // The header keeps both columns, which is what holds the grid's width.
        #expect(revealed.rows.isEmpty)
        #expect(revealed.alignments == table.alignments)
    }

    @Test("a divider appears once the reveal reaches it")
    func revealsADivider() {
        let blocks: [MarkdownBlock] = [.paragraph("a"), .divider, .paragraph("b")]
        #expect(MarkdownReveal.characterCount(blocks) == 2)
        #expect(MarkdownReveal.blocks(blocks, visibleCharacters: 1) == [.paragraph("a")])
        // Both characters are typed by the second count, and the rule between
        // them has been reached, so it is drawn between them.
        #expect(
            MarkdownReveal.blocks(blocks, visibleCharacters: 2)
                == [.paragraph("a"), .divider, .paragraph("b")],
        )
    }
}
