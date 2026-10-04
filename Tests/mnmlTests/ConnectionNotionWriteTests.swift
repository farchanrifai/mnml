import XCTest
@testable import mnml

final class ConnectionNotionWriteTests: XCTestCase {
    private let pageID = "123456781234123412341234567890ab"
    private let createdID = "abcdefabcdefabcdefabcdefabcdefab"

    private func account(writes: Bool = true) -> ConnectionAccount {
        ConnectionAccount(id: UUID(), provider: .notion, title: "Workspace", services: [.notion],
            label: "Work", writableServices: writes ? [.notion] : nil)
    }
    private func page(_ account: ConnectionAccount) -> ConnectionHit {
        ConnectionHit(id: pageID, service: .notion, accountID: account.id, title: "Meeting notes",
            url: URL(string: "https://www.notion.so/Meeting-notes-" + pageID)!, detail: "", snippet: "")
    }
    private func plan(_ operation: ConnectionWriteOperation, account: ConnectionAccount, page: ConnectionHit) -> ConnectionWritePlan {
        ConnectionWritePlan(operation: operation, account: account.id,
            source: operation == .appendNotion ? page.reference : nil,
            destination: operation == .createNotion ? page.reference : nil,
            title: operation == .createNotion ? "Daily note" : nil, text: "## Decisions\nApproved €42.")
    }

    func testCreatePreflightIsReadOnlyAndExecutionKeepsReviewedParentAndContent() async throws {
        let account = account(), page = page(account)
        let fixture = fixture()
        let client = ConnectionNotion(http: { try await fixture.send($0) })
        let plan = plan(.createNotion, account: account, page: page)
        let prepared = try await client.prepareWrite(plan, account: account, target: nil, destination: page, token: "fixture")
        var mutations = try await fixture.mutations()
        XCTAssertTrue(mutations.isEmpty)
        XCTAssertEqual(prepared.plan, plan)
        let result = try await client.executeWrite(prepared, token: "fixture")
        mutations = try await fixture.mutations()
        XCTAssertEqual(mutations.count, 1)
        let arguments = try XCTUnwrap(mutations.first?["arguments"] as? [String: Any])
        XCTAssertEqual((arguments["parent"] as? [String: Any])?["page_id"] as? String, pageID)
        XCTAssertEqual(arguments["allow_async"] as? Bool, false)
        let pages = try XCTUnwrap(arguments["pages"] as? [[String: Any]])
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages[0]["content"] as? String, plan.text)
        XCTAssertEqual((pages[0]["properties"] as? [String: Any])?["title"] as? String, plan.title)
        XCTAssertNil(arguments["creation_mode"])
        XCTAssertEqual(result.hit.id, createdID)
        XCTAssertEqual(result.hit.accountID, account.id)
        XCTAssertEqual(result.hit.accountTitle, "Work · Workspace")
    }

    func testAppendUsesOnlyExactEndAnchorAndNeverReplacesPage() async throws {
        let account = account(), page = page(account)
        let fixture = fixture()
        let client = ConnectionNotion(http: { try await fixture.send($0) })
        let plan = plan(.appendNotion, account: account, page: page)
        let prepared = try await client.prepareWrite(plan, account: account, target: page, destination: nil, token: "fixture")
        XCTAssertEqual(prepared.before, "# Meeting\n\nExisting decisions.")
        let result = try await client.executeWrite(prepared, token: "fixture")
        let mutations = try await fixture.mutations()
        XCTAssertEqual(mutations.count, 1)
        let arguments = try XCTUnwrap(mutations.first?["arguments"] as? [String: Any])
        XCTAssertEqual(arguments["command"] as? String, "update_content")
        let updates = try XCTUnwrap(arguments["content_updates"] as? [[String: Any]])
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates[0]["old_str"] as? String, prepared.before)
        XCTAssertEqual(updates[0]["new_str"] as? String, prepared.before + "\n\n" + plan.text!)
        XCTAssertNil(arguments["replace_all_matches"])
        XCTAssertNil(arguments["properties"])
        XCTAssertEqual(result.hit.url, page.url)
    }

    func testLegacyDataWrapperAllowsAppendOnlyCommand() async throws {
        let account = account(), page = page(account)
        let fixture = fixture(legacy: true)
        let client = ConnectionNotion(http: { try await fixture.send($0) })
        let plan = plan(.appendNotion, account: account, page: page)
        let prepared = try await client.prepareWrite(plan, account: account, target: page, destination: nil, token: "fixture")
        _ = try await client.executeWrite(prepared, token: "fixture")
        let mutations = try await fixture.mutations()
        let arguments = try XCTUnwrap(mutations.first?["arguments"] as? [String: Any])
        let data = try XCTUnwrap(arguments["data"] as? [String: Any])
        XCTAssertEqual(data["command"] as? String, "insert_content_after")
        XCTAssertEqual(data["selection_with_ellipsis"] as? String, prepared.before)
        XCTAssertEqual(data["new_str"] as? String, "\n\n" + plan.text!)
    }

    func testWriteGrantCrossAccountAndForeignURLRefusedBeforeHTTP() async throws {
        let fixture = fixture()
        let client = ConnectionNotion(http: { try await fixture.send($0) })
        let reader = account(writes: false), readerPage = page(reader)
        do { _ = try await client.prepareWrite(plan(.appendNotion, account: reader, page: readerPage), account: reader, target: readerPage, destination: nil, token: "fixture"); XCTFail("Expected write capability refusal") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Enable Notion writes")) }
        let writer = account(), foreign = page(account())
        do { _ = try await client.prepareWrite(plan(.appendNotion, account: writer, page: foreign), account: writer, target: foreign, destination: nil, token: "fixture"); XCTFail("Expected account refusal") }
        catch { XCTAssertTrue(error.localizedDescription.contains("this account")) }
        var malicious = page(writer); malicious.url = URL(string: "https://notion.so.evil.example/" + pageID)!
        do { _ = try await client.prepareWrite(plan(.appendNotion, account: writer, page: malicious), account: writer, target: malicious, destination: nil, token: "fixture"); XCTFail("Expected foreign URL refusal") }
        catch { XCTAssertTrue(error.localizedDescription.contains("this account")) }
        let requests = await fixture.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testChangedPageOrSchemaStopsBeforeMutation() async throws {
        for schema in [false, true] {
            let account = account(), page = page(account)
            let fixture = fixture(changedContent: !schema, changedSchema: schema)
            let client = ConnectionNotion(http: { try await fixture.send($0) })
            let prepared = try await client.prepareWrite(plan(.appendNotion, account: account, page: page), account: account, target: page, destination: nil, token: "fixture")
            do { _ = try await client.executeWrite(prepared, token: "fixture"); XCTFail("Expected stale preview refusal") }
            catch { XCTAssertTrue(error.localizedDescription.contains("changed after the preview")) }
            let mutations = try await fixture.mutations()
            XCTAssertTrue(mutations.isEmpty)
        }
    }

    func testUnsupportedWriteToolRequiredFieldsAndPartialPagesFailClosed() async throws {
        for fixture in [fixture(unsupported: true), fixture(requiredUnknown: true), fixture(truncated: true), fixture(denied: true)] {
            let account = account(), page = page(account)
            let client = ConnectionNotion(http: { try await fixture.send($0) })
            do { _ = try await client.prepareWrite(plan(.createNotion, account: account, page: page), account: account, target: nil, destination: page, token: "fixture"); XCTFail("Expected unsupported preflight") }
            catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
            let mutations = try await fixture.mutations()
            XCTAssertTrue(mutations.isEmpty)
        }
    }

    func testTamperedPreparedPayloadCannotChangeReviewedAppend() async throws {
        let account = account(), page = page(account), fixture = fixture()
        let client = ConnectionNotion(http: { try await fixture.send($0) })
        let prepared = try await client.prepareWrite(plan(.appendNotion, account: account, page: page), account: account, target: page, destination: nil, token: "fixture")
        var altered = prepared.plan; altered.text = "Unreviewed content"
        let tampered = ConnectionPreparedWrite(plan: altered, account: account, target: page, before: prepared.before, state: prepared.state)
        do { _ = try await client.executeWrite(tampered, token: "fixture"); XCTFail("Expected frozen payload refusal") }
        catch { XCTAssertTrue(error.localizedDescription.contains("reviewed payload")) }
        let mutations = try await fixture.mutations()
        XCTAssertTrue(mutations.isEmpty)
    }

    func testAmbiguousOrMaliciousWriteReplyNeverRetriesOrReportsSuccess() async throws {
        for mode in ["foreign", "empty", "async", "error"] {
            let account = account(), page = page(account), fixture = fixture(replyMode: mode)
            let client = ConnectionNotion(http: { try await fixture.send($0) })
            let prepared = try await client.prepareWrite(plan(.createNotion, account: account, page: page), account: account, target: nil, destination: page, token: "fixture")
            do { _ = try await client.executeWrite(prepared, token: "fixture"); XCTFail("Expected unconfirmed write") }
            catch { XCTAssertTrue(error.localizedDescription.contains("before trying again")) }
            let mutations = try await fixture.mutations()
            XCTAssertEqual(mutations.count, 1)
        }
    }

    private func fixture(legacy: Bool = false, changedContent: Bool = false, changedSchema: Bool = false,
                         unsupported: Bool = false, requiredUnknown: Bool = false, truncated: Bool = false,
                         denied: Bool = false, replyMode: String = "success") -> Fixture {
        let pageID = pageID, createdID = createdID
        let handler: @Sendable (URLRequest, Int) throws -> Reply = { request, index in
            XCTAssertEqual(request.url?.absoluteString, "https://mcp.notion.com/mcp")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            switch body["method"] as? String {
            case "initialize": return Self.rpc(body, result: ["protocolVersion": "2025-06-18"])
            case "notifications/initialized": return Reply(data: Data(), status: 202)
            case "tools/list":
                var create = Self.createSchema()
                if requiredUnknown { create["required"] = ["pages", "parent", "unsupported_option"] }
                var update = Self.updateSchema(legacy: legacy)
                if changedSchema && index > 5 { update["required"] = ["page_id", "command", "new_required_option"] }
                let fetchSchema: [String: Any] = ["properties": ["id": ["type": "string"]], "required": ["id"]]
                let accessSchema: [String: Any] = ["properties": [String: Any]()]
                let tools: [[String: Any]] = [
                    ["name": "notion-fetch", "inputSchema": fetchSchema],
                    ["name": "notion-get-tool-access", "inputSchema": accessSchema],
                    ["name": unsupported ? "notion-delete-page" : "notion-create-pages", "inputSchema": create],
                    ["name": "notion-update-page", "inputSchema": update]]
                return Self.rpc(body, result: ["tools": tools])
            default:
                let params = try XCTUnwrap(body["params"] as? [String: Any])
                switch params["name"] as? String {
                case "notion-fetch":
                    let content = changedContent && index > 5 ? "Changed by someone else." : "# Meeting\n\nExisting decisions."
                    let page: [String: Any] = ["markdown": content, "truncated": truncated,
                        "url": "https://www.notion.so/Meeting-notes-" + pageID]
                    return Self.rpc(body, result: ["structuredContent": page])
                case "notion-get-tool-access":
                    let access: [String: Any] = ["create_pages": ["status": denied ? "not_enabled" : "available"],
                        "update_page": ["status": "available"]]
                    let metadata: [String: Any] = ["current_tool_access": access]
                    return Self.rpc(body, result: ["structuredContent": metadata])
                case "notion-create-pages", "notion-update-page":
                    if replyMode == "error" {
                        let error: [String: Any] = ["isError": true, "content": [["type": "text", "text": "Remote failed"]]]
                        return Self.rpc(body, result: error)
                    }
                    if replyMode == "empty" { return Self.rpc(body, result: ["structuredContent": [String: Any]()]) }
                    if replyMode == "async" {
                        let task: [String: Any] = ["object": "async_task", "id": "task_unknown"]
                        return Self.rpc(body, result: ["structuredContent": task])
                    }
                    let create = params["name"] as? String == "notion-create-pages"
                    let id = create ? createdID : pageID
                    let url = replyMode == "foreign" ? "https://notion.so.evil.example/" + id : "https://www.notion.so/" + (create ? "Daily-note-" : "Meeting-notes-") + id
                    let row: [String: Any] = ["id": id, "url": url]
                    let content: [String: Any]
                    if create { content = ["pages": [row]] }
                    else { content = row }
                    return Self.rpc(body, result: ["structuredContent": content])
                default: XCTFail("Unexpected tool"); return Self.rpc(body, result: [:])
                }
            }
        }
        return Fixture(handler)
    }

    private static func createSchema() -> [String: Any] {
        ["type": "object", "properties": [
            "parent": ["type": "object", "properties": ["page_id": ["type": "string"]], "required": ["page_id"]],
            "pages": ["type": "array", "items": ["type": "object", "properties": [
                "properties": ["type": "object", "properties": ["title": ["type": "string"]], "required": ["title"]],
                "content": ["type": "string"]], "required": ["properties", "content"]]],
            "allow_async": ["type": "boolean"]], "required": ["parent", "pages"]]
    }
    private static func updateSchema(legacy: Bool) -> [String: Any] {
        let fields: [String: Any] = legacy ? [
            "page_id": ["type": "string"], "command": ["enum": ["insert_content_after", "replace_content"]],
            "selection_with_ellipsis": ["type": "string"], "new_str": ["type": "string"]
        ] : [
            "page_id": ["type": "string"], "command": ["enum": ["update_content", "replace_content"]],
            "content_updates": ["type": "array", "items": ["type": "object", "properties": [
                "old_str": ["type": "string"], "new_str": ["type": "string"]], "required": ["old_str", "new_str"]]]]
        let required = legacy ? ["page_id", "command", "selection_with_ellipsis", "new_str"] : ["page_id", "command", "content_updates"]
        if legacy { return ["type": "object", "properties": ["data": ["type": "object", "properties": fields, "required": required], "allow_async": ["type": "boolean"]], "required": ["data"]] }
        return ["type": "object", "properties": fields.merging(["allow_async": ["type": "boolean"]]) { first, _ in first }, "required": required]
    }
    private static func rpc(_ body: [String: Any], result: [String: Any]) -> Reply {
        Reply(data: try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": body["id"]!, "result": result]))
    }
    private struct Reply: @unchecked Sendable { var data: Data; var status = 200 }
    private actor Fixture {
        var requests: [URLRequest] = []
        let handler: @Sendable (URLRequest, Int) throws -> Reply
        init(_ handler: @escaping @Sendable (URLRequest, Int) throws -> Reply) { self.handler = handler }
        func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
            let index = requests.count; requests.append(request)
            let reply = try handler(request, index)
            return (reply.data, HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!)
        }
        func mutations() throws -> [[String: Any]] {
            try requests.compactMap { request in
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
                guard body["method"] as? String == "tools/call", let params = body["params"] as? [String: Any],
                      ["notion-create-pages", "notion-update-page"].contains(params["name"] as? String ?? "") else { return nil }
                return params
            }
        }
    }
}
