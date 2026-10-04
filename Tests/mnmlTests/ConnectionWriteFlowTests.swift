import XCTest
import Combine
@testable import mnml

@MainActor
final class ConnectionWriteFlowTests: XCTestCase {
    private func account(writable: Bool = true) -> ConnectionAccount {
        ConnectionAccount(id: UUID(), provider: .google, title: "writer@example.invalid", services: [.drive],
            label: "Work account", writableServices: writable ? [.drive] : [])
    }
    private func source(_ id: String, account: ConnectionAccount) -> ConnectionHit {
        ConnectionHit(id: id, service: .drive, accountID: account.id, title: "Synthetic source",
            url: URL(string: "https://drive.google.com/file/d/\(id)/view")!, detail: "", snippet: "")
    }
    private func selection(_ account: ConnectionAccount) -> [ConnectionSelection] { [.init(service: .drive, accountID: account.id)] }

    func testWriteProtocolAcceptsBoundedPlanAndRejectsUnknownFieldsAndOperations() throws {
        let account = account()
        let plan = ConnectionWritePlan(operation: .createSheet, account: account.id, title: "Synthetic Sheet",
            values: [[.string("=literal"), .number(42), .bool(true), .empty]])
        let response = try Self.command(plan)
        XCTAssertEqual(try ConnectionFlow.lookup(response)?.write, plan)
        var gate = ConnectionFlow.Gate()
        for piece in ["<mnml-", "lookup>", String(response.dropFirst(ConnectionFlow.opening.count))] {
            XCTAssertNil(gate.push(piece))
        }
        XCTAssertNil(gate.finish()); XCTAssertTrue(gate.control)
        let write = try Self.object(plan)
        var unknownWrite = write; unknownWrite["delete"] = true
        var unsupported = write; unsupported["operation"] = "delete_drive"
        var invalidAccount = write; invalidAccount["account"] = "guessed account"
        var oversized = write; oversized["values"] = [Array(repeating: "value", count: 2_001)]
        var tooMuchText = write; tooMuchText["operation"] = "create_doc"; tooMuchText.removeValue(forKey: "values")
        tooMuchText["text"] = String(repeating: "x", count: 32_001)
        for object: [String: Any] in [
            ["action": "write", "write": write, "service": "drive"],
            ["action": "write", "write": write, "url": "https://example.invalid"],
            ["action": "write", "write": unknownWrite],
            ["action": "write", "write": unsupported],
            ["action": "write", "write": invalidAccount],
            ["action": "write", "write": oversized],
            ["action": "write", "write": tooMuchText],
            ["action": "write"],
            ["action": "search", "service": "drive", "query": "note", "write": write]
        ] {
            XCTAssertThrowsError(try ConnectionFlow.lookup(Self.tag(object)))
        }
    }

    func testCoordinatorRefusesUnknownAndCrossAccountSourcesBeforeTokenOrHTTP() async throws {
        let account = account(), other = self.account(), own = source("own-file", account: account)
        let foreign = source("foreign-file", account: other), ledger = Ledger()
        let writing = ConnectionWriting(accounts: { [account, other] }, token: { _ in
            await ledger.token(); XCTFail("Invalid source must not read a token"); return "fixture-token"
        }, http: { request in await ledger.http(request); XCTFail("Invalid source must not issue HTTP"); return Self.reply(request, [:]) })
        let choices = selection(account)
        let known = [own.reference: own, foreign.reference: foreign]
        let unknown = ConnectionWritePlan(operation: .appendDoc, account: account.id, source: "drive:unknown", text: "Text")
        let wrongSource = ConnectionWritePlan(operation: .appendDoc, account: account.id, source: foreign.reference, text: "Text")
        let wrongDestination = ConnectionWritePlan(operation: .moveDrive, account: account.id, source: own.reference, destination: foreign.reference)
        for plan in [unknown, wrongSource, wrongDestination] {
            do { _ = try await writing.prepare(plan, selections: choices, known: known, space: UUID()); XCTFail("Expected source refusal") }
            catch { XCTAssertTrue(error.localizedDescription.contains("same account")) }
        }
        let snapshot = await ledger.snapshot(); XCTAssertEqual(snapshot.tokens, 0); XCTAssertTrue(snapshot.requests.isEmpty)
    }

    func testCoordinatorRefusesDeniedSpaceReadOnlyAndUnselectedTupleBeforeTokenOrHTTP() async throws {
        for mode in 0..<3 {
            let account = account(writable: mode != 1), ledger = Ledger(), deniedSpace = UUID()
            let writing = ConnectionWriting(accounts: { [account] }, token: { _ in
                await ledger.token(); XCTFail("Policy refusal must precede token access"); return "fixture-token"
            }, http: { request in await ledger.http(request); XCTFail("Policy refusal must precede HTTP"); return Self.reply(request, [:]) },
            allowed: { _, space in mode != 0 || space != deniedSpace })
            let choices = mode == 2 ? [ConnectionSelection(service: .gmail, accountID: account.id)] : selection(account)
            let plan = ConnectionWritePlan(operation: .createSheet, account: account.id, title: "Sheet", values: [[.string("Text")]])
            do { _ = try await writing.prepare(plan, selections: choices, known: [:], space: deniedSpace); XCTFail("Expected policy refusal") }
            catch { XCTAssertTrue(error.localizedDescription.contains("not enabled")) }
            let snapshot = await ledger.snapshot(); XCTAssertEqual(snapshot.tokens, 0); XCTAssertTrue(snapshot.requests.isEmpty)
        }
    }

    func testCoordinatorRechecksPermissionAfterApprovalAndAttemptsPreviewOnlyOnce() async throws {
        let account = account(), ledger = Ledger(), policy = Policy()
        let writing = ConnectionWriting(accounts: { [account] }, token: { _ in await ledger.token(); return "fixture-token" },
            http: { request in await ledger.http(request); return Self.reply(request, ["spreadsheetId": "created-sheet"]) },
            allowed: { _, _ in await policy.allowed })
        let plan = ConnectionWritePlan(operation: .createSheet, account: account.id, title: "Sheet", values: [[.string("Text")]])
        let prepared = try await writing.prepare(plan, selections: selection(account), known: [:], space: UUID())
        await policy.set(false)
        do { _ = try await writing.execute(prepared, selections: selection(account), space: UUID()); XCTFail("Revoked writes must not execute") }
        catch { XCTAssertTrue(error.localizedDescription.contains("not enabled")) }
        var snapshot = await ledger.snapshot(); XCTAssertEqual(snapshot.tokens, 1); XCTAssertTrue(snapshot.requests.isEmpty)
        await policy.set(true)
        do { _ = try await writing.execute(prepared, selections: selection(account), space: UUID()); XCTFail("A failed attempt cannot be retried by reusing approval") }
        catch { XCTAssertTrue(error.localizedDescription.contains("already been attempted")) }
        snapshot = await ledger.snapshot(); XCTAssertEqual(snapshot.tokens, 1); XCTAssertTrue(snapshot.requests.isEmpty)
    }

    func testApprovalIsBoundToImmutablePreviewIDAndResolvesOnlyOnce() async throws {
        let account = account(), chat = UUID(), manager = ConnectionWriteApprovals(timeout: .seconds(1))
        var plan = ConnectionWritePlan(operation: .createDoc, account: account.id, title: "Original", text: "Approved bytes")
        let prepared = ConnectionPreparedWrite(plan: plan, account: account)
        let waiting = Task { try await manager.request(prepared, chat: chat) }
        defer { waiting.cancel(); manager.cancel(chat: chat) }
        try await pending(manager, chat: chat)
        plan.title = "Changed elsewhere"; plan.text = "Different bytes"
        manager.approve(chat: chat, id: UUID())
        XCTAssertEqual(manager.pending[chat]?.id, prepared.id)
        XCTAssertEqual(manager.pending[chat]?.prepared.plan.title, "Original")
        XCTAssertEqual(manager.pending[chat]?.prepared.plan.text, "Approved bytes")
        manager.approve(chat: chat, id: prepared.id)
        manager.reject(chat: chat, id: prepared.id)
        let approved = try await waiting.value; XCTAssertTrue(approved); XCTAssertNil(manager.pending[chat])
    }

    func testApprovalRejectCancellationReplacementAndTimeoutClearPending() async throws {
        let account = account(), chat = UUID(), manager = ConnectionWriteApprovals(timeout: .milliseconds(200))
        let plan = ConnectionWritePlan(operation: .createDoc, account: account.id, title: "Note", text: "Text")
        let first = ConnectionPreparedWrite(plan: plan, account: account)
        let rejected = Task { try await manager.request(first, chat: chat) }
        try await pending(manager, chat: chat); manager.reject(chat: chat, id: first.id)
        let accepted = try await rejected.value; XCTAssertFalse(accepted); XCTAssertNil(manager.pending[chat])
        let cancelled = Task { try await manager.request(first, chat: chat) }
        try await pending(manager, chat: chat); manager.cancel(chat: chat)
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        let old = Task { try await manager.request(first, chat: chat) }
        try await pending(manager, chat: chat)
        let second = ConnectionPreparedWrite(plan: plan, account: account)
        let replacement = Task { try await manager.request(second, chat: chat) }
        try await pending(manager, chat: chat, id: second.id)
        do { _ = try await old.value; XCTFail("Replacing a proposal must cancel its old waiter") } catch { XCTAssertTrue(error is CancellationError) }
        manager.approve(chat: chat, id: first.id); XCTAssertEqual(manager.pending[chat]?.id, second.id)
        let timedOut = try await replacement.value; XCTAssertFalse(timedOut); XCTAssertNil(manager.pending[chat])
        let taskCancelled = Task { try await manager.request(first, chat: chat) }
        try await pending(manager, chat: chat); taskCancelled.cancel()
        do { _ = try await taskCancelled.value; XCTFail("Task cancellation must release approval") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(manager.pending[chat])
    }

    func testSyntheticCLIProposalWaitsForApprovalThenWritesOnceAndPublishesNativeReceipt() async throws {
        let fixture = try setupCLI(final: "The Sheet is ready.")
        defer { fixture.sessions.stopAll(); fixture.approvals.cancel(chat: fixture.chat); ConnectionActivity.shared.end(fixture.chat); try? FileManager.default.removeItem(at: fixture.folder) }
        var receipts: [ConnectionWriteReceipt] = []
        let observer = ConnectionActivity.shared.$chats.sink { if let progress = $0[fixture.chat] { receipts += progress.writes } }
        defer { observer.cancel() }
        let job = Task { try await Self.collect(fixture.stream) }
        let watchdog = watchdog(job, fixture: fixture)
        defer { watchdog.cancel(); job.cancel() }
        try await pending(fixture.approvals, chat: fixture.chat)
        let before = await fixture.ledger.snapshot(); XCTAssertTrue(before.requests.isEmpty)
        let preview = try XCTUnwrap(fixture.approvals.pending[fixture.chat])
        XCTAssertEqual(preview.prepared.plan.title, "Synthetic Sheet")
        fixture.approvals.approve(chat: fixture.chat, id: preview.id)
        fixture.approvals.approve(chat: fixture.chat, id: preview.id)
        let answer = try await job.value; XCTAssertEqual(answer, "The Sheet is ready."); XCTAssertFalse(answer.contains("mnml-lookup"))
        let after = await fixture.ledger.snapshot(); XCTAssertEqual(after.requests.count, 1); XCTAssertEqual(after.requests.first?.httpMethod, "POST")
        XCTAssertTrue(receipts.contains { $0.id == preview.id && $0.hit?.id == "created-sheet" && $0.summary.contains("Created Google Sheet") })
        XCTAssertNil(fixture.approvals.pending[fixture.chat])
        let sent = try Self.messages(fixture.folder); XCTAssertEqual(sent.count, 2)
        XCTAssertTrue(sent[1].contains("\"status\":\"applied\"")); XCTAssertFalse(sent.joined().contains("fixture-token"))
    }

    func testSyntheticCLIRejectedProposalReturnsCancellationWithoutMutation() async throws {
        let fixture = try setupCLI(final: "Cancelled. No write was submitted.")
        defer { fixture.sessions.stopAll(); fixture.approvals.cancel(chat: fixture.chat); ConnectionActivity.shared.end(fixture.chat); try? FileManager.default.removeItem(at: fixture.folder) }
        let job = Task { try await Self.collect(fixture.stream) }, watchdog = watchdog(job, fixture: fixture)
        defer { watchdog.cancel(); job.cancel() }
        try await pending(fixture.approvals, chat: fixture.chat)
        let preview = try XCTUnwrap(fixture.approvals.pending[fixture.chat]); fixture.approvals.reject(chat: fixture.chat, id: preview.id)
        let answer = try await job.value; XCTAssertEqual(answer, "Cancelled. No write was submitted.")
        let snapshot = await fixture.ledger.snapshot(); XCTAssertTrue(snapshot.requests.isEmpty)
        XCTAssertNil(fixture.approvals.pending[fixture.chat])
        let sent = try Self.messages(fixture.folder); XCTAssertTrue(sent.last?.contains("No write was submitted") == true)
    }

    func testStoppingSyntheticCLIWhileAwaitingApprovalClearsPreviewAndWorker() async throws {
        let fixture = try setupCLI(final: "Must not be reached")
        defer { fixture.sessions.stopAll(); fixture.approvals.cancel(chat: fixture.chat); ConnectionActivity.shared.end(fixture.chat); try? FileManager.default.removeItem(at: fixture.folder) }
        let job = Task { try await Self.collect(fixture.stream) }, watchdog = watchdog(job, fixture: fixture)
        defer { watchdog.cancel(); job.cancel() }
        try await pending(fixture.approvals, chat: fixture.chat)
        XCTAssertNotNil(fixture.sessions.session(for: fixture.chat))
        job.cancel(); fixture.approvals.cancel(chat: fixture.chat); fixture.sessions.kill(fixture.chat)
        do { _ = try await job.value; XCTFail("Stopped question must be cancelled") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(fixture.approvals.pending[fixture.chat]); XCTAssertNil(fixture.sessions.session(for: fixture.chat))
        let snapshot = await fixture.ledger.snapshot(); XCTAssertTrue(snapshot.requests.isEmpty)
        let sent = try Self.messages(fixture.folder); XCTAssertEqual(sent.count, 1)
    }

    func testLiveCLIWriteProposalUsesOnlySyntheticHTTPAndWaitsForNativeApproval() async throws {
        guard ProcessInfo.processInfo.environment["MNML_CONNECTION_LIVE"] == "1" else {
            throw XCTSkip("Set MNML_CONNECTION_LIVE=1 to validate the installed CLI with synthetic write transport.")
        }
        guard let executable = Antigravity.executable else { throw XCTSkip("Antigravity CLI is not installed.") }
        let account = account(), choices = selection(account), chat = UUID()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mnml-synthetic-write-" + UUID().uuidString)
        let sessions = AntigravitySessions(automaticTimer: false), approvals = ConnectionWriteApprovals(timeout: .seconds(90)), ledger = Ledger()
        defer { sessions.stopAll(); approvals.cancel(chat: chat); ConnectionActivity.shared.end(chat); try? FileManager.default.removeItem(at: folder) }
        let http: ConnectionHTTP = { request in
            await ledger.http(request)
            guard request.httpMethod == "POST", request.url?.host == "sheets.googleapis.com", request.url?.path == "/v4/spreadsheets" else {
                XCTFail("Live CLI may only use the expected synthetic Sheet creation route")
                throw ConnectionFailure("Only synthetic Sheet creation is available in this test.")
            }
            return Self.reply(request, ["spreadsheetId": "mnml-synthetic-sheet"])
        }
        let writing = ConnectionWriting(accounts: { [account] }, token: { _ in await ledger.token(); return "fixture-token" }, http: http)
        let retrieval = ConnectionRetrieval(accounts: { [account] }, token: { _ in return "fixture-token" }, http: http)
        let system = Chat.system + ConnectionFlow.instruction([.drive], selections: choices, accountDetails: [account], writes: choices)
        let question = "Create a new Google Sheet titled Synthetic write validation in my Work account, in My Drive. Use exactly two rows: Item, Amount; Rent, 42. The amount 42 must be a number. No search is needed for this new document. Propose it for mnml native approval."
        let input = AIInput(system: system, turns: [(mine: true, text: question)], files: [], context: "", question: question,
            connectionServices: [.drive], connectionAccounts: [account.id], connectionSelections: choices,
            connectionAccountDetails: [account], connectionWrites: choices, connectionSpaceID: UUID())
        let job = Task { try await Self.collect(Antigravity.stream(input, model: AIProvider.antigravity.models[0], chat: chat,
            executable: executable, workspace: folder, sessions: sessions, retrieval: retrieval, writing: writing, approvals: approvals)) }
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(120)) } catch { return }
            XCTFail("Synthetic live write flow exceeded two minutes")
            job.cancel(); approvals.cancel(chat: chat); sessions.kill(chat)
        }
        defer { timeout.cancel(); job.cancel() }
        try await pending(approvals, chat: chat, seconds: 60)
        let before = await ledger.snapshot(); XCTAssertTrue(before.requests.isEmpty, "No mutation is permitted before native approval")
        let preview = try XCTUnwrap(approvals.pending[chat])
        XCTAssertEqual(preview.prepared.plan.operation, .createSheet)
        XCTAssertEqual(preview.prepared.plan.account, account.id)
        XCTAssertEqual(preview.prepared.plan.title, "Synthetic write validation")
        XCTAssertEqual(preview.prepared.plan.values, [[.string("Item"), .string("Amount")], [.string("Rent"), .number(42)]])
        approvals.approve(chat: chat, id: preview.id)
        let answer = try await job.value
        XCTAssertTrue(answer.contains("https://docs.google.com/spreadsheets/d/mnml-synthetic-sheet"))
        XCTAssertFalse(answer.contains("mnml-lookup")); XCTAssertNil(approvals.pending[chat])
        let after = await ledger.snapshot(); XCTAssertEqual(after.requests.count, 1)
        print("Synthetic live write validation: native approval first, one mocked POST, no real cloud writes.")
    }

    private struct CLIFixture {
        let folder: URL, chat: UUID
        let sessions: AntigravitySessions, approvals: ConnectionWriteApprovals, ledger: Ledger
        let stream: AsyncThrowingStream<String, Error>
    }
    private func setupCLI(final: String) throws -> CLIFixture {
        let account = account(), chat = UUID(), folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let plan = ConnectionWritePlan(operation: .createSheet, account: account.id, title: "Synthetic Sheet", values: [[.string("Approved bytes"), .number(42)]])
        let first = try Self.event(Self.command(plan)), second = try Self.event(final)
        // Payloads are JSON encoded and base64 encoded before entering shell
        // source. No model/provider text is evaluated as shell syntax.
        let first64 = Data(first.utf8).base64EncodedString(), second64 = Data(second.utf8).base64EncodedString()
        let script = """
        #!/bin/sh
        turn=0
        while IFS= read -r input; do
            turn=$((turn + 1))
            printf '%s\\n' "$input" >> messages.jsonl
            if [ "$turn" -eq 1 ]; then
                printf '%s' '\(first64)' | /usr/bin/base64 -D
            else
                printf '%s' '\(second64)' | /usr/bin/base64 -D
            fi
            printf '\\n'
        done
        """
        let executable = folder.appendingPathComponent("fake-agy")
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let ledger = Ledger(), choices = selection(account)
        let writing = ConnectionWriting(accounts: { [account] }, token: { _ in await ledger.token(); return "fixture-token" },
            http: { request in
                await ledger.http(request)
                XCTAssertEqual(request.httpMethod, "POST"); XCTAssertEqual(request.url?.host, "sheets.googleapis.com")
                return Self.reply(request, ["spreadsheetId": "created-sheet"])
            })
        let sessions = AntigravitySessions(automaticTimer: false), approvals = ConnectionWriteApprovals(timeout: .seconds(4))
        let system = ConnectionFlow.instruction([.drive], selections: choices, accountDetails: [account], writes: choices)
        let input = AIInput(system: system, turns: [(mine: true, text: "Create the synthetic Sheet.")], files: [], context: "", question: "Create the synthetic Sheet.",
            connectionServices: [.drive], connectionAccounts: [account.id], connectionSelections: choices,
            connectionAccountDetails: [account], connectionWrites: choices, connectionSpaceID: UUID())
        let stream = Antigravity.stream(input, model: AIProvider.antigravity.models[0], chat: chat,
            executable: executable, workspace: folder, sessions: sessions, writing: writing, approvals: approvals)
        return CLIFixture(folder: folder, chat: chat, sessions: sessions, approvals: approvals, ledger: ledger, stream: stream)
    }
    private func pending(_ manager: ConnectionWriteApprovals, chat: UUID, id: UUID? = nil, seconds: Int = 3) async throws {
        for _ in 0..<(seconds * 100) {
            if let pending = manager.pending[chat], id == nil || pending.id == id { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Write preview did not become pending within \(seconds) seconds")
        throw ConnectionFailure("Synthetic approval wait timed out")
    }
    private func watchdog(_ job: Task<String, Error>, fixture: CLIFixture) -> Task<Void, Never> {
        Task {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            XCTFail("Synthetic write flow exceeded five seconds")
            job.cancel(); fixture.approvals.cancel(chat: fixture.chat); fixture.sessions.kill(fixture.chat)
        }
    }
    private nonisolated static func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> String {
        var text = ""; for try await piece in stream { text += piece }; try Task.checkCancellation(); return text
    }
    private nonisolated static func object(_ plan: ConnectionWritePlan) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
    }
    private nonisolated static func tag(_ object: [String: Any]) throws -> String {
        ConnectionFlow.opening + String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self) + ConnectionFlow.closing
    }
    private nonisolated static func command(_ plan: ConnectionWritePlan) throws -> String { try tag(["action": "write", "write": object(plan)]) }
    private nonisolated static func event(_ response: String) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["event": "result", "result": ["status": "SUCCESS", "response": response]]), as: UTF8.self)
    }
    private nonisolated static func reply(_ request: URLRequest, _ object: [String: Any]) -> (Data, HTTPURLResponse) {
        (try! JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!)
    }
    private nonisolated static func messages(_ folder: URL) throws -> [String] {
        try String(contentsOf: folder.appendingPathComponent("messages.jsonl"), encoding: .utf8).split(separator: "\n").map { line in
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            return try XCTUnwrap((object["message"] as? [String: Any])?["content"] as? String)
        }
    }
    private actor Ledger {
        var tokens = 0, requests: [URLRequest] = []
        func token() { tokens += 1 }
        func http(_ request: URLRequest) { requests.append(request) }
        func snapshot() -> (tokens: Int, requests: [URLRequest]) { (tokens, requests) }
    }
    private actor Policy {
        var allowed = true
        func set(_ value: Bool) { allowed = value }
    }
}
