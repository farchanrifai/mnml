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

    func testShares() {
        // Under budget: untouched.
        XCTAssertEqual(Chat.shares([10, 20, 30], budget: 100), [10, 20, 30])
        // The others share alike, the small one whole; own tab keeps half.
        XCTAssertEqual(Chat.shares([80, 10, 60, 90], budget: 100), [50, 10, 20, 20])
        // Own tab small: the others get the rest.
        XCTAssertEqual(Chat.shares([10, 200, 200], budget: 100), [10, 45, 45])
        // Own tab alone and too long.
        XCTAssertEqual(Chat.shares([500], budget: 100), [100])
    }

    func testSavedChatRoundTrip() throws {
        let saved = Chat.Saved(id: UUID(), title: "Total qty?", site: "go.xero.com", updated: Date(timeIntervalSince1970: 0),
                               turns: [Chat.Turn(mine: true, text: "Total qty?", about: ["Bill"])],
                               mentions: [.all, .site("go.xero.com"), .group(UUID())])
        let back = try JSONDecoder().decode(Chat.Saved.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(back.turns, saved.turns)
        XCTAssertEqual(back.mentions, saved.mentions)
    }
}
