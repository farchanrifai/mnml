import XCTest
@testable import mnml

final class ConnectionRetrievalTests: XCTestCase {
    private let google = ConnectionAccount(id: UUID(), provider: .google, title: "reader@example.com", services: [.gmail, .drive, .calendar])
    private let notion = ConnectionAccount(id: UUID(), provider: .notion, title: "Project workspace", services: [.notion])

    private func client(_ account: ConnectionAccount, fixture: Fixture, now: Date = Date(timeIntervalSince1970: 1_000)) -> ConnectionRetrieval {
        ConnectionRetrieval(accounts: { [account] }, token: { id in
            guard id == account.id else { throw ConnectionFailure("Wrong account") }; return "fixture-token"
        }, http: { try await fixture.send($0) }, now: { now })
    }

    func testGmailSearchKeepsQueryAndAccountAndBoundsResults() async throws {
        let fixture = Fixture { request, index in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
            if index == 0 {
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                XCTAssertEqual(query.first { $0.name == "q" }?.value, "from:ana@example.com subject:\"A&B\" after:100 before:200")
                XCTAssertEqual(query.first { $0.name == "maxResults" }?.value, "1")
                return .json(["messages": [["id": "a12"], ["id": "a13"]]])
            }
            XCTAssertTrue(request.url!.path.hasSuffix("/a12"))
            return .json(["threadId": "b22", "snippet": "Approved budget", "payload": ["headers": [
                ["name": "Subject", "value": "Budget"], ["name": "From", "value": "Ana"], ["name": "Date", "value": "Today"]]]])
        }
        let hits = try await client(google, fixture: fixture).search(ConnectionSearch(service: .gmail, query: "from:ana@example.com subject:\"A&B\"", limit: 1,
            start: Date(timeIntervalSince1970: 100), end: Date(timeIntervalSince1970: 200)))
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].accountID, google.id)
        XCTAssertEqual(hits[0].accountTitle, google.title)
        XCTAssertEqual(hits[0].url.fragment, "all/b22")
        XCTAssertEqual(URLComponents(url: hits[0].url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, google.title)
        let count = await fixture.requests.count
        XCTAssertEqual(count, 2)
    }

    func testGmailMultipartPrefersPlainTextAndIgnoresTextAttachment() async throws {
        let plain = "The approved amount is €42."
        let payload: [String: Any] = ["mimeType": "multipart/mixed", "headers": [["name": "Subject", "value": "Approval"]], "parts": [
            ["mimeType": "multipart/alternative", "parts": [
                ["mimeType": "text/plain", "body": ["data": Self.base64(plain)]],
                ["mimeType": "text/html", "body": ["data": Self.base64("<script>attack()</script><p>HTML duplicate</p>")]]]],
            ["mimeType": "text/plain", "filename": "secret.txt", "body": ["data": Self.base64("ATTACHMENT CONTENT")]]]]
        let fixture = Fixture { _, _ in .json(["payload": payload]) }
        let hit = source(.gmail, account: google)
        let document = try await client(google, fixture: fixture).fetch(hit)
        XCTAssertTrue(document.text.contains("Subject: Approval"))
        XCTAssertTrue(document.text.contains(plain))
        XCTAssertFalse(document.text.contains("HTML duplicate"))
        XCTAssertFalse(document.text.contains("ATTACHMENT CONTENT"))
        XCTAssertEqual(ConnectionRetrieval.plainHTML("<style>bad</style><p>Hello &amp; bye</p><script>bad</script>"), "Hello & bye")
    }

    func testFetchRejectsDisconnectedAccountAndInvalidSourceIDBeforeHTTP() async throws {
        let fixture = Fixture { _, _ in XCTFail("Must not send HTTP"); return .json([:]) }
        let retrieval = client(google, fixture: fixture)
        var hit = source(.gmail, account: google); hit.accountID = UUID()
        do { _ = try await retrieval.fetch(hit); XCTFail("Expected disconnected account") }
        catch { XCTAssertTrue(error.localizedDescription.contains("disconnected")) }
        hit.accountID = google.id; hit.id = "a/../../other"
        do { _ = try await retrieval.fetch(hit); XCTFail("Expected invalid ID") }
        catch { XCTAssertTrue(error.localizedDescription.contains("identifier")) }
        let count = await fixture.requests.count; XCTAssertEqual(count, 0)
    }

    func testSearchRejectsAccountOutsideCapturedSelectionBeforeTokenOrHTTP() async throws {
        let fixture = Fixture { _, _ in XCTFail("Must not send HTTP outside the turn's account selection"); return .json([:]) }
        let retrieval = ConnectionRetrieval(accounts: { [self.google] }, token: { _ in
            XCTFail("Must not read credentials outside the turn's account selection"); return "fixture-token"
        }, http: { try await fixture.send($0) })
        do {
            _ = try await retrieval.search(ConnectionSearch(service: .gmail, query: "budget"), allowedAccounts: [UUID()])
            XCTFail("Expected account refusal")
        } catch { XCTAssertTrue(error is ConnectionFailure) }
        let count = await fixture.requests.count; XCTAssertEqual(count, 0)
    }

    func testSearchChoosesCapturedAccountInsteadOfGloballyFirstAccount() async throws {
        let chosen = ConnectionAccount(id: UUID(), provider: .google, title: "selected@example.com", services: [.gmail])
        let fixture = Fixture { _, _ in .json(["messages": []]) }
        let first = google
        let retrieval = ConnectionRetrieval(accounts: { [first, chosen] }, token: { id in
            XCTAssertEqual(id, chosen.id); return "fixture-token"
        }, http: { try await fixture.send($0) })
        let hits = try await retrieval.search(ConnectionSearch(service: .gmail, query: "budget"), allowedAccounts: [chosen.id])
        XCTAssertTrue(hits.isEmpty)
        let count = await fixture.requests.count; XCTAssertEqual(count, 1)
    }

    func testAccountsLoadingFailureIsReportedBeforeHTTP() async throws {
        let fixture = Fixture { _, _ in XCTFail("Must not send HTTP when account loading failed"); return .json([:]) }
        let retrieval = ConnectionRetrieval(accounts: { throw ConnectionFailure("Keychain could not be loaded.") }, token: { _ in
            XCTFail("Must not read tokens before readiness"); return "fixture-token"
        }, http: { try await fixture.send($0) })
        do {
            _ = try await retrieval.search(ConnectionSearch(service: .gmail, query: "budget"))
            XCTFail("Expected readiness failure")
        } catch { XCTAssertEqual(error.localizedDescription, "Keychain could not be loaded.") }
        let count = await fixture.requests.count; XCTAssertEqual(count, 0)
    }

    func testCalendarUsesExplicitBoundsAndReadableDescription() async throws {
        let fixture = Fixture { request, _ in
            let params = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(params.first { $0.name == "timeMin" }?.value, "1970-01-01T00:16:40Z")
            XCTAssertEqual(params.first { $0.name == "timeMax" }?.value, "1970-01-01T00:33:20Z")
            XCTAssertTrue(request.url!.path.contains("/calendars/primary/events"))
            return .json(["items": [["id": "a123", "summary": "Review", "htmlLink": "https://calendar.google.com/calendar/event?eid=abc",
                "start": ["date": "2026-10-04"], "end": ["date": "2026-10-05"], "location": "Room 2", "description": "<p>Bring &amp; read notes</p>"]]])
        }
        let hits = try await client(google, fixture: fixture).search(ConnectionSearch(service: .calendar, query: "Review",
            start: Date(timeIntervalSince1970: 1_000), end: Date(timeIntervalSince1970: 2_000)))
        XCTAssertEqual(hits.first?.snippet, "Bring & read notes")
        XCTAssertTrue(hits.first!.detail.contains("Room 2"))
    }

    func testCalendarDefaultIsThirtyDaysAndInvalidRangeDoesNotRequest() async throws {
        let fixture = Fixture { request, _ in
            let params = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let dates = ISO8601DateFormatter()
            let start = dates.date(from: params.first { $0.name == "timeMin" }!.value!)!
            let end = dates.date(from: params.first { $0.name == "timeMax" }!.value!)!
            XCTAssertEqual(end.timeIntervalSince(start), 30 * 24 * 60 * 60)
            return .json(["items": []])
        }
        let retrieval = client(google, fixture: fixture)
        _ = try await retrieval.search(ConnectionSearch(service: .calendar, query: ""))
        do {
            _ = try await retrieval.search(ConnectionSearch(service: .calendar, query: "", start: Date(timeIntervalSince1970: 200), end: Date(timeIntervalSince1970: 100)))
            XCTFail("Expected invalid range")
        } catch { XCTAssertTrue(error.localizedDescription.contains("after")) }
        let count = await fixture.requests.count; XCTAssertEqual(count, 1)
    }

    func testDriveEscapesSearchLiteralAndOnlyFetchesSupportedText() async throws {
        let fixture = Fixture { request, index in
            let params = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
            if index == 0 {
                let q = params.first { $0.name == "q" }!.value!
                XCTAssertTrue(q.contains("fullText contains 'O\\'Reilly \\\\ FY'"))
                XCTAssertTrue(q.contains("trashed = false"))
                return .json(["files": [["id": "file123", "name": "Accounts", "mimeType": "application/vnd.google-apps.spreadsheet"]]])
            }
            if index == 1 { return .json(["mimeType": "application/vnd.google-apps.spreadsheet"]) }
            XCTAssertTrue(request.url!.path.hasSuffix("/file123/export"))
            XCTAssertEqual(params.first { $0.name == "mimeType" }?.value, "text/csv")
            return Reply(data: Data("Item,Amount\nA,42\n".utf8))
        }
        let retrieval = client(google, fixture: fixture)
        let hits = try await retrieval.search(ConnectionSearch(service: .drive, query: "O'Reilly \\ FY"))
        let document = try await retrieval.fetch(XCTUnwrap(hits.first))
        XCTAssertTrue(document.text.contains("first sheet only"))
        XCTAssertTrue(document.text.contains("A,42"))
    }

    func testDriveExportPermissionFailureAndUnsupportedTypeAreClear() async throws {
        let denied = Fixture { _, index in index == 0 ? .json(["mimeType": "application/vnd.google-apps.document"]) : Reply(data: Data(), status: 403) }
        do { _ = try await client(google, fixture: denied).fetch(source(.drive, account: google)); XCTFail("Expected permission failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("permission")) }
        let unsupported = Fixture { _, _ in .json(["mimeType": "application/vnd.google-apps.presentation"]) }
        do { _ = try await client(google, fixture: unsupported).fetch(source(.drive, account: google)); XCTFail("Expected unsupported type") }
        catch { XCTAssertTrue(error.localizedDescription.contains("file type")) }
        let count = await unsupported.requests.count; XCTAssertEqual(count, 1)
    }

    func testTransportRejectsRedirectLargeResponseAndReportsRateLimit() async throws {
        let request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files")!)
        for fixture in [Fixture { _, _ in Reply(data: Data(), status: 302, headers: ["Location": "https://evil.example/"]) },
                        Fixture { _, _ in Reply(data: Data(repeating: 0, count: ConnectionRetrievalTransport.maximumBytes + 1)) }] {
            do { _ = try await ConnectionRetrievalTransport.checked(request, http: { try await fixture.send($0) }); XCTFail("Expected refusal") }
            catch { XCTAssertTrue(error is ConnectionFailure) }
        }
        let limited = Fixture { _, _ in Reply(data: Data(), status: 429, headers: ["Retry-After": "15"]) }
        do { _ = try await ConnectionRetrievalTransport.checked(request, http: { try await limited.send($0) }); XCTFail("Expected rate limit") }
        catch { XCTAssertTrue(error.localizedDescription.contains("15 seconds")) }
    }

    func testNotionDiscoversSchemasAndUsesAIWithSessionHeaderAndSSE() async throws {
        let fixture = notionFixture(aiStatus: "available", sse: true)
        let hits = try await client(notion, fixture: fixture).search(ConnectionSearch(service: .notion, query: "budget approval", limit: 1))
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.title, "Budget")
        XCTAssertEqual(hits.first?.accountTitle, notion.title)
        let requests = await fixture.requests
        XCTAssertEqual(requests.count, 5)
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Mcp-Session-Id"), "fixture-session")
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "MCP-Protocol-Version"), "2025-06-18")
        let last = try Self.requestJSON(requests.last!)
        XCTAssertEqual((last["params"] as? [String: Any])?["name"] as? String, "notion-ai-search")
    }

    func testNotionPlanFallbackUsesKeywordToolAndMakesNoticeVisible() async throws {
        let fixture = notionFixture(aiStatus: "upgrade_required", sse: false)
        let hits = try await client(notion, fixture: fixture).search(ConnectionSearch(service: .notion, query: "budget"))
        XCTAssertTrue(hits.first!.detail.contains("keyword search only"))
        let requests = await fixture.requests
        let last = try Self.requestJSON(requests.last!)
        XCTAssertEqual((last["params"] as? [String: Any])?["name"] as? String, "notion-search")
    }

    func testNotionFetchUsesDiscoveredURLArgumentAndRejectsOutsideSource() async throws {
        let fixture = Fixture { request, _ in
            let body = try Self.requestJSON(request)
            switch body["method"] as? String {
            case "initialize": return Self.rpc(body, result: ["protocolVersion": "2025-06-18"])
            case "notifications/initialized": return Reply(data: Data(), status: 202)
            case "tools/list": return Self.rpc(body, result: ["tools": [["name": "notion-fetch", "inputSchema": ["properties": ["id": ["type": "string"]], "required": ["id"]]]]])
            default:
                let params = body["params"] as? [String: Any]
                XCTAssertEqual(params?["name"] as? String, "notion-fetch")
                XCTAssertEqual((params?["arguments"] as? [String: Any])?["id"] as? String, "https://www.notion.so/Budget-a123")
                return Self.rpc(body, result: ["structuredContent": ["markdown": "# Budget\nApproved: 42", "truncated": true]])
            }
        }
        let retrieval = client(notion, fixture: fixture)
        var hit = source(.notion, account: notion)
        let document = try await retrieval.fetch(hit)
        XCTAssertTrue(document.text.contains("Approved: 42"))
        XCTAssertTrue(document.text.contains("partial page"))
        hit.url = URL(string: "https://notion.so.evil.example/Budget")!
        do { _ = try await retrieval.fetch(hit); XCTFail("Expected external URL refusal") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Only Notion")) }
        let count = await fixture.requests.count; XCTAssertEqual(count, 4)
    }

    func testNotionSSEMatchesRequestedIDAndCombinesDataLines() throws {
        let data = Data("event: message\r\ndata: {\"jsonrpc\":\"2.0\",\"id\":\"unrelated\",\"result\":{}}\r\n\r\nevent: message\r\ndata: {\"jsonrpc\":\"2.0\",\"id\":\"wanted\",\r\ndata: \"result\":{\"value\":42}}\r\n\r\n".utf8)
        let envelope = try ConnectionNotion.envelope(data, contentType: "text/event-stream", id: "wanted")
        XCTAssertEqual((envelope["result"] as? [String: Any])?["value"] as? Int, 42)
        XCTAssertThrowsError(try ConnectionNotion.envelope(data, contentType: "text/event-stream", id: "absent"))
    }

    private func notionFixture(aiStatus: String, sse: Bool) -> Fixture {
        Fixture { request, _ in
            let body = try Self.requestJSON(request)
            switch body["method"] as? String {
            case "initialize": return Self.rpc(body, result: ["protocolVersion": "2025-06-18"], headers: ["Mcp-Session-Id": "fixture-session"])
            case "notifications/initialized": return Reply(data: Data(), status: 202)
            case "tools/list":
                let tools: [[String: Any]] = [
                    ["name": "notion-get-tool-access", "inputSchema": ["properties": [:]]],
                    ["name": "notion-search", "inputSchema": ["properties": ["query": ["type": "string"], "query_type": ["type": "string"], "limit": ["type": "integer"]], "required": ["query"]]],
                    ["name": "notion-ai-search", "inputSchema": ["properties": ["query": ["type": "string"]], "required": ["query"]]],
                    ["name": "notion-update-page", "inputSchema": ["properties": [:]]]]
                return Self.rpc(body, result: ["tools": tools])
            default:
                let params = body["params"] as? [String: Any]
                if params?["name"] as? String == "notion-get-tool-access" {
                    return Self.rpc(body, result: ["content": [["type": "text", "text": String(data: try JSONSerialization.data(withJSONObject: ["current_tool_access": ["ai_search": ["status": aiStatus]]]), encoding: .utf8)!]]])
                }
                let result: [String: Any] = ["structuredContent": ["results": [["id": "a123", "url": "https://www.notion.so/Budget-a123", "title": "Budget", "snippet": "Approved amount"]]]]
                let reply = Self.rpc(body, result: result)
                if sse {
                    return Reply(data: Data(("event: message\ndata: " + String(data: reply.data, encoding: .utf8)! + "\n\n").utf8), headers: ["Content-Type": "text/event-stream"])
                }
                return reply
            }
        }
    }

    private func source(_ service: ConnectionService, account: ConnectionAccount) -> ConnectionHit {
        ConnectionHit(id: "a123", service: service, accountID: account.id, title: "Source", url: URL(string: service == .notion ? "https://www.notion.so/Budget-a123" : "https://www.google.com/")!, detail: "", snippet: "")
    }

    private static func base64(_ text: String) -> String {
        Data(text.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func requestJSON(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    private static func rpc(_ request: [String: Any], result: [String: Any], headers: [String: String] = [:]) -> Reply {
        .json(["jsonrpc": "2.0", "id": request["id"]!, "result": result], headers: headers)
    }

    private struct Reply: @unchecked Sendable {
        var data: Data
        var status = 200
        var headers: [String: String] = ["Content-Type": "application/json"]
        static func json(_ object: [String: Any], headers: [String: String] = [:]) -> Reply {
            Reply(data: try! JSONSerialization.data(withJSONObject: object), headers: headers.merging(["Content-Type": "application/json"]) { first, _ in first })
        }
    }

    private actor Fixture {
        var requests: [URLRequest] = []
        let handler: @Sendable (URLRequest, Int) throws -> Reply
        init(_ handler: @escaping @Sendable (URLRequest, Int) throws -> Reply) { self.handler = handler }
        func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
            let index = requests.count; requests.append(request)
            let reply = try handler(request, index)
            return (reply.data, HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!)
        }
    }
}
