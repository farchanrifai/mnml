import XCTest
@testable import mnml

final class AskTests: XCTestCase {
    func testEventText() {
        let line = #"data: {"candidates":[{"content":{"parts":[{"text":"Hel"},{"text":"lo"}],"role":"model"}}]}"#
        XCTAssertEqual(Gemini.text(ofEvent: line), "Hello")
        XCTAssertNil(Gemini.text(ofEvent: ""))
        XCTAssertNil(Gemini.text(ofEvent: #"data: {"usageMetadata":{}}"#))
    }

    func testMarkdownBlocks() {
        let text = """
            ## Total
            The **total** is 60,339,188.

            - one
            1. first

            | Item | Qty |
            |---|---:|
            | Batch 2 | 1 |

            ```
            code
            ```
            """
        XCTAssertEqual(Markdown.blocks(text), [
            .heading("Total"),
            .paragraph("The **total** is 60,339,188."),
            .item("one", marker: "•"),
            .item("first", marker: "1."),
            .table([["Item", "Qty"], ["Batch 2", "1"]]),
            .code("code"),
        ])
        XCTAssertEqual(Markdown.blocks("Fixed:\n```text\nHi Ana,\nThanks.\n```"), [.paragraph("Fixed:"), .draft("Hi Ana,\nThanks.")])
    }

    func testFinishedText() {
        XCTAssertEqual(Chat.finished("Fixed:\n```text\nHi Ana,\nThanks.\n```\nNote: tone."), "Hi Ana,\nThanks.")
        XCTAssertEqual(Chat.finished("  Just this. "), "Just this.")
    }
}
