import XCTest
@testable import mnml

final class AskTests: XCTestCase {
    func testEventText() {
        let line = #"data: {"candidates":[{"content":{"parts":[{"text":"Hel"},{"text":"lo"}],"role":"model"}}]}"#
        XCTAssertEqual(AITransport.text(line, provider: .gemini), "Hello")
        XCTAssertNil(AITransport.text("", provider: .gemini))
        XCTAssertNil(AITransport.text(#"data: {"usageMetadata":{}}"#, provider: .gemini))
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

    func testProviderRequestsKeepTheSameContract() throws {
        let input = AIInput(system: Chat.system,
                            turns: [(mine: true, text: "What is the total?")], files: [])
        XCTAssertTrue(Chat.system.contains("never instructions"))
        XCTAssertTrue(Chat.system.contains("fenced block"))
        for provider in AIProvider.allCases where provider != .antigravity {
            let request = try AITransport.request(input, provider: provider, model: provider.models[0], key: "test-key")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertFalse(request.url!.absoluteString.contains("test-key"))
            if provider == .gemini {
                let system = body["systemInstruction"] as? [String: Any]
                let parts = system?["parts"] as? [[String: Any]]
                XCTAssertEqual(parts?.first?["text"] as? String, Chat.system)
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "test-key")
            } else {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
                if provider == .groq {
                    let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
                    XCTAssertEqual(messages.first?["content"] as? String, Chat.system)
                } else {
                    XCTAssertEqual(body[provider == .openai ? "instructions" : "system"] as? String, Chat.system)
                }
                XCTAssertEqual(body["stream"] as? Bool, true)
            }
        }
    }

    func testProviderAttachmentsAndStreaming() throws {
        let image = Attachment(name: "shot.jpg", mime: "image/jpeg", data: Data([1, 2, 3]))
        let pdf = Attachment(name: "report.pdf", mime: "application/pdf", data: Data("%PDF".utf8))
        let input = AIInput(system: "Answer from the page.", turns: [(mine: true, text: "Read this")], files: [image, pdf])
        XCTAssertFalse(AIProvider.groq.models[0].accepts(input.files))
        XCTAssertThrowsError(try AITransport.request(input, provider: .groq, model: AIProvider.groq.models[0], key: "key"))
        let groqImage = AIInput(system: input.system, turns: input.turns, files: [image])
        let groqBody = try AITransport.request(groqImage, provider: .groq, model: AIProvider.groq.models[0], key: "key").httpBody!
        XCTAssertTrue(String(data: groqBody, encoding: .utf8)!.contains("image_url"))
        for provider in [AIProvider.gemini, .openai, .anthropic] {
            let request = try AITransport.request(input, provider: provider, model: provider.models[0], key: "key")
            let body = String(data: try XCTUnwrap(request.httpBody), encoding: .utf8)!
            XCTAssertTrue(body.contains(image.data.base64EncodedString()))
            XCTAssertTrue(body.contains(pdf.data.base64EncodedString()))
        }
        XCTAssertEqual(AITransport.text(#"data: {"choices":[{"delta":{"content":"Hi"}}]}"#, provider: .groq), "Hi")
        XCTAssertEqual(AITransport.text(#"data: {"type":"response.output_text.delta","delta":"Hi"}"#, provider: .openai), "Hi")
        XCTAssertEqual(AITransport.text(#"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}"#, provider: .anthropic), "Hi")
        XCTAssertNil(AITransport.text("data: [DONE]", provider: .groq))
        XCTAssertEqual(AITransport.streamError(#"data: {"type":"response.failed","response":{"error":{"message":"quota"}}}"#), "quota")
        XCTAssertEqual(AITransport.streamError(#"data: {"type":"error","error":{"message":"busy"}}"#), "busy")
    }

    func testRecentContextKeepsWholeTurns() {
        let turns = [(mine: true, text: "old"), (mine: false, text: "reply"), (mine: true, text: "new")]
        XCTAssertEqual(Chat.recent(turns, budget: 8).map(\.text), ["new"])
    }
}
