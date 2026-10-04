import XCTest
@testable import mnml

final class ConnectionGoogleWriteTests: XCTestCase {
    private func account(writable: Bool = true) -> ConnectionAccount {
        ConnectionAccount(id: UUID(), provider: .google, title: "work@example.com", services: [.drive],
            label: "Work account", writableServices: writable ? [.drive] : [])
    }
    private func source(_ id: String, account: ConnectionAccount) -> ConnectionHit {
        ConnectionHit(id: id, service: .drive, accountID: account.id, title: "Cached title",
            url: URL(string: "https://drive.google.com/file/d/\(id)/view")!, detail: "", snippet: "")
    }
    private func client(_ fixture: Fixture) -> ConnectionGoogleWrites { ConnectionGoogleWrites(http: { try await fixture.send($0) }) }

    func testCreatesSheetWithTypedLiteralCellsInOneMutation() async throws {
        let account = account(), fixture = Fixture { request, index in
            XCTAssertEqual(index, 0); XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.host, "sheets.googleapis.com"); XCTAssertEqual(request.url?.path, "/v4/spreadsheets")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
            let body = try Self.body(request), sheets = try XCTUnwrap(body["sheets"] as? [[String: Any]])
            XCTAssertEqual((body["properties"] as? [String: Any])?["title"] as? String, "Budget")
            let grid = try XCTUnwrap(sheets[0]["data"] as? [[String: Any]])
            let rows = try XCTUnwrap(grid[0]["rowData"] as? [[String: Any]])
            let cells = try XCTUnwrap(rows[0]["values"] as? [[String: Any]])
            XCTAssertEqual((cells[0]["userEnteredValue"] as? [String: Any])?["stringValue"] as? String, "=SUM(A1:A2)")
            XCTAssertNil((cells[0]["userEnteredValue"] as? [String: Any])?["formulaValue"])
            XCTAssertEqual((cells[1]["userEnteredValue"] as? [String: Any])?["numberValue"] as? Double, 42)
            XCTAssertEqual((cells[2]["userEnteredValue"] as? [String: Any])?["boolValue"] as? Bool, true)
            XCTAssertEqual((cells[3]["userEnteredValue"] as? [String: Any])?["stringValue"] as? String, "")
            return .json(["spreadsheetId": "new-sheet"])
        }
        let plan = ConnectionWritePlan(operation: .createSheet, account: account.id, title: "Budget",
            values: [[.string("=SUM(A1:A2)"), .number(42), .bool(true), .empty]])
        let prepared = try await client(fixture).prepare(plan, account: account, target: nil, destination: nil, token: "fixture-token")
        let before = await fixture.requests.count; XCTAssertEqual(before, 0, "Preflight cannot mutate")
        let result = try await client(fixture).execute(prepared, token: "fixture-token")
        XCTAssertEqual(result.hit.accountTitle, "Work account · work@example.com")
        XCTAssertEqual(result.hit.url.absoluteString, "https://docs.google.com/spreadsheets/d/new-sheet/edit")
        let count = await fixture.requests.count; XCTAssertEqual(count, 1)
    }

    func testCreatesDocAndWritesExactTextUsingRevisionAndFirstTab() async throws {
        let account = account(), fixture = Fixture { request, index in
            switch index {
            case 0:
                XCTAssertEqual(request.httpMethod, "POST"); XCTAssertEqual(request.url?.host, "docs.googleapis.com")
                XCTAssertEqual(request.url?.path, "/v1/documents")
                XCTAssertEqual(try Self.body(request)["title"] as? String, "Daily note")
                return .json(["documentId": "new-doc"])
            case 1:
                XCTAssertEqual(request.httpMethod, "GET"); XCTAssertEqual(Self.query(request, "includeTabsContent"), "true")
                return .json(Self.document())
            default:
                XCTAssertEqual(index, 2); XCTAssertEqual(request.url?.path, "/v1/documents/new-doc:batchUpdate")
                let body = try Self.body(request)
                XCTAssertEqual((body["writeControl"] as? [String: Any])?["requiredRevisionId"] as? String, "revision-1")
                let requests = try XCTUnwrap(body["requests"] as? [[String: Any]])
                let insert = try XCTUnwrap(requests[0]["insertText"] as? [String: Any])
                XCTAssertEqual(insert["text"] as? String, "Line 1\nLine 2")
                XCTAssertEqual((insert["endOfSegmentLocation"] as? [String: Any])?["tabId"] as? String, "t.0")
                XCTAssertEqual(requests.count, 1); return .json(["documentId": "new-doc"])
            }
        }
        let plan = ConnectionWritePlan(operation: .createDoc, account: account.id, title: "Daily note", text: "Line 1\nLine 2")
        let prepared = try await client(fixture).prepare(plan, account: account, target: nil, destination: nil, token: "fixture-token")
        let result = try await client(fixture).execute(prepared, token: "fixture-token")
        XCTAssertEqual(result.hit.id, "new-doc")
        let count = await fixture.requests.count; XCTAssertEqual(count, 3)
    }

    func testUpdateSheetReviewsFormulaValuesAndUsesRAWExactRectangle() async throws {
        let account = account(), target = source("sheet-1", account: account)
        let fixture = Fixture { request, index in
            if request.url?.host == "www.googleapis.com" { return .json(Self.metadata("sheet-1", mime: Self.sheet)) }
            if request.httpMethod == "GET" {
                XCTAssertEqual(Self.query(request, "valueRenderOption"), "FORMULA")
                return .json(["values": [["=SUM(A3:A5)", 8], [false, "old"]]])
            }
            XCTAssertEqual(index, 4); XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(Self.query(request, "valueInputOption"), "RAW")
            XCTAssertTrue(request.url!.absoluteString.contains("%27Budget%27%21A1%3AB2"))
            let body = try Self.body(request)
            XCTAssertEqual(body["range"] as? String, "'Budget'!A1:B2")
            let values = try XCTUnwrap(body["values"] as? [[Any]])
            XCTAssertEqual(values[0][0] as? Double, 42)
            XCTAssertEqual(values[0][1] as? Bool, true)
            XCTAssertEqual(values[1][0] as? String, "=1+2")
            XCTAssertEqual(values[1][1] as? String, "")
            return .json(["updatedCells": 4])
        }
        let plan = ConnectionWritePlan(operation: .updateSheet, account: account.id, source: target.reference,
            range: "'Budget'!A1:B2", values: [[.number(42), .bool(true)], [.string("=1+2"), .empty]])
        let prepared = try await client(fixture).prepare(plan, account: account, target: target, destination: nil, token: "fixture-token")
        XCTAssertTrue(prepared.before.contains("=SUM(A3:A5)")); XCTAssertEqual(prepared.target?.title, "Fresh file")
        let result = try await client(fixture).execute(prepared, token: "fixture-token")
        XCTAssertTrue(result.summary.contains("'Budget'!A1:B2"))
        let count = await fixture.requests.count; XCTAssertEqual(count, 5)
    }

    func testSheetRefusesChangedValuesAndVersionWithoutMutation() async throws {
        for changedVersion in [false, true] {
            let account = account(), target = source("sheet-1", account: account)
            let fixture = Fixture { request, index in
                XCTAssertEqual(request.httpMethod, "GET", "Changed data must never be written")
                if request.url?.host == "www.googleapis.com" {
                    return .json(Self.metadata("sheet-1", mime: Self.sheet, version: changedVersion && index >= 2 ? "2" : "1"))
                }
                return .json(["values": [[!changedVersion && index >= 2 ? "changed" : "old"]]])
            }
            let plan = ConnectionWritePlan(operation: .updateSheet, account: account.id, source: target.reference,
                range: "Sheet1!A1", values: [[.string("new")]])
            let prepared = try await client(fixture).prepare(plan, account: account, target: target, destination: nil, token: "fixture-token")
            do { _ = try await client(fixture).execute(prepared, token: "fixture-token"); XCTFail("Expected changed-target refusal") }
            catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
            let requests = await fixture.requests; XCTAssertEqual(requests.count, 4); XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
        }
    }

    func testAppendDocUsesExactApprovedTextAndFirstTabWithRequiredRevision() async throws {
        let account = account(), target = source("doc-1", account: account)
        let fixture = Fixture { request, index in
            if request.url?.host == "www.googleapis.com" { return .json(Self.metadata("doc-1", mime: Self.doc)) }
            if request.httpMethod == "GET" { return .json(Self.document()) }
            XCTAssertEqual(index, 4); XCTAssertEqual(request.httpMethod, "POST")
            let body = try Self.body(request), requests = try XCTUnwrap(body["requests"] as? [[String: Any]])
            let insert = try XCTUnwrap(requests[0]["insertText"] as? [String: Any])
            XCTAssertEqual(insert["text"] as? String, "\nApproved append")
            XCTAssertEqual((insert["endOfSegmentLocation"] as? [String: Any])?["tabId"] as? String, "t.0")
            XCTAssertEqual((body["writeControl"] as? [String: Any])?["requiredRevisionId"] as? String, "revision-1")
            return .json([:])
        }
        let plan = ConnectionWritePlan(operation: .appendDoc, account: account.id, source: target.reference, text: "\nApproved append")
        let prepared = try await client(fixture).prepare(plan, account: account, target: target, destination: nil, token: "fixture-token")
        XCTAssertTrue(prepared.before.contains("Existing text"))
        _ = try await client(fixture).execute(prepared, token: "fixture-token")
    }

    func testDocRevisionChangeRefusesBeforeBatchUpdate() async throws {
        let account = account(), target = source("doc-1", account: account)
        let fixture = Fixture { request, index in
            XCTAssertEqual(request.httpMethod, "GET")
            if request.url?.host == "www.googleapis.com" { return .json(Self.metadata("doc-1", mime: Self.doc)) }
            return .json(Self.document(revision: index >= 2 ? "revision-2" : "revision-1"))
        }
        let plan = ConnectionWritePlan(operation: .appendDoc, account: account.id, source: target.reference, text: "Append")
        let prepared = try await client(fixture).prepare(plan, account: account, target: target, destination: nil, token: "fixture-token")
        do { _ = try await client(fixture).execute(prepared, token: "fixture-token"); XCTFail("Expected revision refusal") }
        catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
        let count = await fixture.requests.count; XCTAssertEqual(count, 4)
    }

    func testMoveFileChangesOnlyParentsWithinSameSharedDrive() async throws {
        let account = account(), target = source("file-1", account: account), destination = source("folder-2", account: account)
        let fixture = Fixture { request, index in
            XCTAssertEqual(Self.query(request, "supportsAllDrives"), "true")
            if request.httpMethod == "GET" {
                return .json(Self.metadata(request.url!.path.hasSuffix("folder-2") ? "folder-2" : "file-1",
                    mime: request.url!.path.hasSuffix("folder-2") ? Self.folder : "application/pdf", drive: "team-drive"))
            }
            XCTAssertEqual(index, 4); XCTAssertEqual(request.httpMethod, "PATCH")
            XCTAssertEqual(Self.query(request, "addParents"), "folder-2")
            XCTAssertEqual(Self.query(request, "removeParents"), "old-parent")
            XCTAssertTrue(try Self.body(request).isEmpty, "Move must not rename, delete or share")
            return .json(["id": "file-1"])
        }
        let plan = ConnectionWritePlan(operation: .moveDrive, account: account.id, source: target.reference, destination: destination.reference)
        let prepared = try await client(fixture).prepare(plan, account: account, target: target, destination: destination, token: "fixture-token")
        _ = try await client(fixture).execute(prepared, token: "fixture-token")
        let count = await fixture.requests.count; XCTAssertEqual(count, 5)
    }

    func testMovesRefuseCrossDriveAndFolderMoves() async throws {
        for folderMove in [false, true] {
            let account = account(), target = source("file-1", account: account), destination = source("folder-2", account: account)
            let fixture = Fixture { request, _ in
                XCTAssertEqual(request.httpMethod, "GET")
                let isDestination = request.url!.path.hasSuffix("folder-2")
                return .json(Self.metadata(isDestination ? "folder-2" : "file-1",
                    mime: isDestination || folderMove ? Self.folder : Self.doc, drive: !folderMove && isDestination ? "team" : nil))
            }
            let plan = ConnectionWritePlan(operation: .moveDrive, account: account.id, source: target.reference, destination: destination.reference)
            do { _ = try await client(fixture).prepare(plan, account: account, target: target, destination: destination, token: "fixture-token"); XCTFail("Expected move refusal") }
            catch { XCTAssertTrue(error is ConnectionFailure) }
            let requests = await fixture.requests; XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
        }
    }

    func testRejectsReadOnlyAndCrossAccountSourcesBeforeHTTP() async throws {
        let fixture = Fixture { _, _ in XCTFail("Invalid scope cannot send HTTP"); return .json([:]) }
        let readonly = account(writable: false)
        let create = ConnectionWritePlan(operation: .createDoc, account: readonly.id, title: "Note", text: "Text")
        do { _ = try await client(fixture).prepare(create, account: readonly, target: nil, destination: nil, token: "fixture-token"); XCTFail("Expected write scope refusal") }
        catch { XCTAssertTrue(error.localizedDescription.contains("write access")) }
        let account = account(), wrong = source("doc-1", account: self.account())
        let plan = ConnectionWritePlan(operation: .appendDoc, account: account.id, source: wrong.reference, text: "Text")
        do { _ = try await client(fixture).prepare(plan, account: account, target: wrong, destination: nil, token: "fixture-token"); XCTFail("Expected account refusal") }
        catch { XCTAssertTrue(error.localizedDescription.contains("another account")) }
        let count = await fixture.requests.count; XCTAssertEqual(count, 0)
    }

    func testRejectsAmbiguousOrOversizedRangeBeforeHTTP() async throws {
        let account = account(), target = source("sheet-1", account: account)
        let fixture = Fixture { _, _ in XCTFail("Invalid range must not send HTTP"); return .json([:]) }
        for range in ["A1", "Sheet1!A:A", "namedRange", "Sheet1!A1:B1", "Sheet1!A1:ZZZ9999999", "Sheet1!A0"] {
            let plan = ConnectionWritePlan(operation: .updateSheet, account: account.id, source: target.reference, range: range, values: [[.string("new")]])
            do { _ = try await client(fixture).prepare(plan, account: account, target: target, destination: nil, token: "fixture-token"); XCTFail("Expected range refusal: \(range)") }
            catch { XCTAssertTrue(error is ConnectionFailure) }
        }
        let count = await fixture.requests.count; XCTAssertEqual(count, 0)
    }

    func testDocPartialCreateFailurePreservesCreatedURLAndNeverRetriesOrDeletes() async throws {
        let account = account(), fixture = Fixture { request, index in
            switch index {
            case 0: return .json(["documentId": "created-doc"])
            case 1: return .json(Self.document())
            default:
                XCTAssertEqual(index, 2); XCTAssertEqual(request.httpMethod, "POST")
                return Reply(data: Data("{}".utf8), status: 503)
            }
        }
        let plan = ConnectionWritePlan(operation: .createDoc, account: account.id, title: "Note", text: "Text")
        let prepared = try await client(fixture).prepare(plan, account: account, target: nil, destination: nil, token: "fixture-token")
        do { _ = try await client(fixture).execute(prepared, token: "fixture-token"); XCTFail("Expected partial failure") }
        catch let failure as ConnectionWritePartialFailure {
            XCTAssertEqual(failure.hit.id, "created-doc")
            XCTAssertTrue(failure.localizedDescription.contains("https://docs.google.com/document/d/created-doc/edit"))
            XCTAssertTrue(failure.localizedDescription.contains("may already have been applied"))
        }
        let requests = await fixture.requests; XCTAssertEqual(requests.count, 3); XCTAssertFalse(requests.contains { $0.httpMethod == "DELETE" })
    }

    func testSheetPartialFolderFailureDoesNotCreateAgain() async throws {
        let account = account(), destination = source("folder-2", account: account)
        let fixture = Fixture { request, index in
            if request.httpMethod == "POST" { XCTAssertEqual(index, 2); return .json(["spreadsheetId": "created-sheet"]) }
            XCTAssertEqual(request.httpMethod, "GET")
            return .json(Self.metadata("folder-2", mime: Self.folder, version: index >= 3 ? "2" : "1"))
        }
        let plan = ConnectionWritePlan(operation: .createSheet, account: account.id, destination: destination.reference, title: "Note", values: [[.string("Text")]])
        let prepared = try await client(fixture).prepare(plan, account: account, target: nil, destination: destination, token: "fixture-token")
        do { _ = try await client(fixture).execute(prepared, token: "fixture-token"); XCTFail("Expected partial placement failure") }
        catch let failure as ConnectionWritePartialFailure {
            XCTAssertEqual(failure.hit.id, "created-sheet"); XCTAssertTrue(failure.localizedDescription.contains("folder placement failed"))
        }
        let requests = await fixture.requests; XCTAssertEqual(requests.filter { $0.httpMethod == "POST" }.count, 1)
        XCTAssertFalse(requests.contains { ["PATCH", "DELETE"].contains($0.httpMethod ?? "") })
    }

    func testTimedOutExistingMutationIsReportedAsUnknownAndNotRetried() async throws {
        let account = account(), target = source("sheet-1", account: account)
        let fixture = Fixture { request, _ in
            if request.httpMethod == "PUT" { throw URLError(.timedOut) }
            if request.url?.host == "www.googleapis.com" { return .json(Self.metadata("sheet-1", mime: Self.sheet)) }
            return .json(["values": [["old"]]])
        }
        let plan = ConnectionWritePlan(operation: .updateSheet, account: account.id, source: target.reference, range: "Sheet1!A1", values: [[.string("new")]])
        let prepared = try await client(fixture).prepare(plan, account: account, target: target, destination: nil, token: "fixture-token")
        do { _ = try await client(fixture).execute(prepared, token: "fixture-token"); XCTFail("Expected unknown outcome") }
        catch { XCTAssertTrue(error.localizedDescription.contains("may already have been applied")); XCTAssertTrue(error.localizedDescription.contains(prepared.target!.url.absoluteString)) }
        let requests = await fixture.requests; XCTAssertEqual(requests.filter { $0.httpMethod == "PUT" }.count, 1)
    }

    func testMetadataPermissionsAndSharedCreateDestinationRefuseBeforeMutation() async throws {
        let account = account(), target = source("doc-1", account: account), destination = source("folder-2", account: account)
        let locked = Fixture { _, _ in .json(Self.metadata("doc-1", mime: Self.doc, editable: false)) }
        let append = ConnectionWritePlan(operation: .appendDoc, account: account.id, source: target.reference, text: "Text")
        do { _ = try await client(locked).prepare(append, account: account, target: target, destination: nil, token: "fixture-token"); XCTFail("Expected edit refusal") }
        catch { XCTAssertTrue(error.localizedDescription.contains("cannot edit")) }
        let shared = Fixture { request, _ in XCTAssertEqual(request.httpMethod, "GET"); return .json(Self.metadata("folder-2", mime: Self.folder, drive: "team")) }
        let create = ConnectionWritePlan(operation: .createDoc, account: account.id, destination: destination.reference, title: "Note", text: "Text")
        do { _ = try await client(shared).prepare(create, account: account, target: nil, destination: destination, token: "fixture-token"); XCTFail("Expected shared create refusal") }
        catch { XCTAssertTrue(error.localizedDescription.contains("shared drive")) }
    }

    private static let sheet = "application/vnd.google-apps.spreadsheet", doc = "application/vnd.google-apps.document", folder = "application/vnd.google-apps.folder"
    private static func metadata(_ id: String, mime: String, version: String = "1", drive: String? = nil, editable: Bool = true) -> [String: Any] {
        var value: [String: Any] = ["id": id, "name": "Fresh file", "mimeType": mime, "version": version, "trashed": false,
            "parents": ["old-parent"], "capabilities": ["canEdit": editable, "canModifyContent": editable,
                "canAddChildren": true, "canMoveItemWithinDrive": true]]
        if let drive { value["driveId"] = drive }; return value
    }
    private static func document(revision: String = "revision-1") -> [String: Any] {
        let paragraph: [String: Any] = ["paragraph": ["elements": [["textRun": ["content": "Existing text\n"]]]]]
        let tab: [String: Any] = ["tabProperties": ["tabId": "t.0", "title": "First tab"],
            "documentTab": ["body": ["content": [paragraph]]]]
        return ["revisionId": revision, "title": "Document", "tabs": [tab]]
    }
    private static func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }
    private static func query(_ request: URLRequest, _ name: String) -> String? {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }
    private struct Reply: @unchecked Sendable {
        var data: Data
        var status = 200
        static func json(_ object: [String: Any]) -> Reply { Reply(data: try! JSONSerialization.data(withJSONObject: object)) }
    }
    private actor Fixture {
        var requests: [URLRequest] = []
        let handler: @Sendable (URLRequest, Int) throws -> Reply
        init(_ handler: @escaping @Sendable (URLRequest, Int) throws -> Reply) { self.handler = handler }
        func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
            let index = requests.count; requests.append(request)
            let reply = try handler(request, index)
            return (reply.data, HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!)
        }
    }
}
