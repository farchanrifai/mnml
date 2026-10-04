import XCTest
import Combine
@testable import mnml

@MainActor
final class ConnectionFlowTests: XCTestCase {
    private let account = ConnectionAccount(id: UUID(), provider: .google, title: "reader@example.invalid",
                                            services: [.gmail, .drive, .calendar])

    func testLookupAcceptsReadCommandsAndRejectsWritesMalformedRequests() throws {
        XCTAssertEqual(try ConnectionFlow.lookup(" \n<mnml-lookup>{\"action\":\"search\",\"service\":\"gmail\",\"query\":\"invoice\"}</mnml-lookup> \n"),
                       ConnectionFlow.Lookup(action: "search", service: .gmail, query: "invoice"))
        XCTAssertEqual(try ConnectionFlow.lookup("<mnml-lookup>{\"action\":\"fetch\",\"source\":\"a123\"}</mnml-lookup>"),
                       ConnectionFlow.Lookup(action: "fetch", source: "a123"))
        XCTAssertNil(try ConnectionFlow.lookup("The invoice is approved."))
        for response in [
            "<mnml-lookup>{\"action\":\"delete\",\"source\":\"a123\"}</mnml-lookup>",
            "<mnml-lookup>{\"action\":\"send\",\"service\":\"gmail\"}</mnml-lookup>",
            "<mnml-lookup>{\"action\":\"search\",\"service\":\"slack\",\"query\":\"invoice\"}</mnml-lookup>",
            "<mnml-lookup>not JSON</mnml-lookup>",
            "<mnml-lookup>{\"action\":\"search\"}",
            "<mnml-look",
            "<mnml-lookup>{\"action\":\"search\"}</lookup>",
            "<mnml-lookup>{\"action\":\"search\"}</mnml-lookup> extra",
            "<mnml-lookup>" + String(repeating: "x", count: 4_097) + "</mnml-lookup>"
        ] {
            XCTAssertThrowsError(try ConnectionFlow.lookup(response), response)
        }
    }

    func testGateHidesFragmentedControlAndPreservesOrdinaryAnswerStreaming() {
        var control = ConnectionFlow.Gate()
        for piece in [" \n", "<mn", "ml-", "lookup>", "{\"action\":\"search\"}", "</mnml-lookup>"] {
            XCTAssertNil(control.push(piece))
        }
        XCTAssertTrue(control.control)
        XCTAssertNil(control.finish())

        var incompleteBody = ConnectionFlow.Gate()
        XCTAssertNil(incompleteBody.push("<mnml-lookup>"))
        XCTAssertNil(incompleteBody.push("{\"action\":"))
        XCTAssertNil(incompleteBody.finish())
        var incompletePrefix = ConnectionFlow.Gate()
        XCTAssertNil(incompletePrefix.push("<mnml-look"))
        XCTAssertNil(incompletePrefix.finish(), "An interrupted transport prefix must not appear in the answer")

        var answer = ConnectionFlow.Gate()
        XCTAssertEqual(answer.push("Approved"), "Approved")
        XCTAssertEqual(answer.push(": 42."), ": 42.")
        XCTAssertNil(answer.finish())
        var possibleTag = ConnectionFlow.Gate()
        XCTAssertNil(possibleTag.push("<mn"))
        XCTAssertEqual(possibleTag.push("emonic>"), "<mnemonic>")
        XCTAssertEqual(possibleTag.push("plain text"), "plain text")
    }

    func testSelectionGuardsRefuseUnselectedServiceAndUnfoundOrForeignAccountSource() async throws {
        let fixture = HTTPFixture { _, _ in XCTFail("A refused lookup must not issue HTTP"); return .json([:]) }
        let retrieval = client(account, fixture: fixture)
        let hit = source(account)
        let commands: [(ConnectionFlow.Lookup, Set<ConnectionService>, Set<UUID>, [String: ConnectionHit])] = [
            (.init(action: "search", service: .drive, query: "invoice"), [.gmail], [account.id], [:]),
            (.init(action: "search", service: .gmail, query: "  "), [.gmail], [account.id], [:]),
            (.init(action: "search", service: .gmail, query: String(repeating: "x", count: 513)), [.gmail], [account.id], [:]),
            (.init(action: "search", service: .calendar, query: "meeting", start: "tomorrow"), [.calendar], [account.id], [:]),
            (.init(action: "fetch", source: "not-found-in-this-chat"), [.gmail], [account.id], [hit.reference: hit]),
            (.init(action: "fetch", source: hit.reference), [.drive], [account.id], [hit.reference: hit]),
            (.init(action: "fetch", source: hit.reference), [.gmail], [UUID()], [hit.reference: hit])
        ]
        for (command, services, accounts, known) in commands {
            do {
                _ = try await ConnectionFlow.perform(command, services: services, accounts: accounts, known: known,
                                                       room: ConnectionFlow.evidenceBudget, retrieval: retrieval)
                XCTFail("A service, source or account outside this chat was accepted")
            } catch { XCTAssertTrue(error is ConnectionFailure) }
        }
        let requests = await fixture.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testSearchDetectsChangedAccountBeforeReturningMatches() async throws {
        let changed = ConnectionAccount(id: UUID(), provider: .google, title: "other@example.invalid", services: [.gmail])
        let fixture = gmailFixture(body: "Approved: 42")
        do {
            _ = try await ConnectionFlow.perform(.init(action: "search", service: .gmail, query: "approval"),
                                                services: [.gmail], accounts: [account.id], known: [:], room: 100,
                                                retrieval: client(changed, fixture: fixture))
            XCTFail("Matches from a replacement account must not enter the chat")
        } catch { XCTAssertTrue(error is ConnectionFailure) }
        let requests = await fixture.requests
        XCTAssertTrue(requests.isEmpty, "A replacement account must not be read before the captured account guard")
    }

    func testFetchUsesRemainingEvidenceBudgetAndRefusesZeroRoomBeforeHTTP() async throws {
        let text = String(repeating: "é", count: 30_000)
        let fixture = HTTPFixture { request, _ in
            XCTAssertTrue(request.url!.path.contains("/drive/v3/files/a123"), "The Drive reference must not resolve to the Gmail source with the same raw id")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if query.contains(where: { $0.name == "alt" && $0.value == "media" }) { return Reply(data: Data(text.utf8)) }
            return .json(["mimeType": "text/plain"])
        }
        let retrieval = client(account, fixture: fixture), hit = source(account, service: .drive)
        let gmail = source(account)
        XCTAssertEqual(gmail.id, hit.id)
        XCTAssertNotEqual(gmail.reference, hit.reference)
        let known = [gmail.reference: gmail, hit.reference: hit]
        let command = ConnectionFlow.Lookup(action: "fetch", source: hit.reference)
        let first = try await ConnectionFlow.perform(command, services: [.gmail, .drive], accounts: [account.id], known: known,
                                                    room: ConnectionFlow.evidenceBudget, retrieval: retrieval)
        let second = try await ConnectionFlow.perform(command, services: [.gmail, .drive], accounts: [account.id], known: known,
                                                     room: ConnectionFlow.evidenceBudget - first.characters, retrieval: retrieval)
        XCTAssertEqual(first.characters, 16_000)
        XCTAssertEqual(second.characters, 8_000)
        XCTAssertEqual((try payload(first.message))["content"] as? String, String(text.prefix(16_000)))
        XCTAssertEqual((try payload(second.message))["content"] as? String, String(text.prefix(8_000)))
        XCTAssertEqual((try payload(first.message))["truncated"] as? Bool, true)
        XCTAssertEqual(first.fetched, hit)
        do {
            _ = try await ConnectionFlow.perform(command, services: [.gmail, .drive], accounts: [account.id], known: known,
                                                room: 0, retrieval: retrieval)
            XCTFail("An exhausted evidence budget must not fetch another document")
        } catch { XCTAssertTrue(error.localizedDescription.contains("context limit")) }
        let requests = await fixture.requests
        XCTAssertEqual(requests.count, 4)
    }

    func testLookupCycleAndWarmFollowupUseOneProcessAndExposeOnlyFinalAnswer() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = AntigravitySessions(automaticTimer: false), chat = UUID()
        defer { sessions.stopAll(); ConnectionActivity.shared.end(chat); try? FileManager.default.removeItem(at: folder) }
        let script = #"""
            turn=0
            while IFS= read -r input; do
                turn=$((turn + 1))
                printf '%s\t%s\n' "$$" "$input" >> messages.jsonl
                case "$turn" in
                    1)
                        printf '%s\n' '{"event":"step_update","step_update":{"step_type":"agent_response","text_delta":"<mn"}}'
                        printf '%s\n' '{"event":"step_update","step_update":{"step_type":"agent_response","text_delta":"ml-lookup>"}}'
                        printf '%s\n' '{"event":"step_update","step_update":{"step_type":"agent_response","text_delta":"{\"action\":\"search\",\"service\":\"gmail\",\"query\":\"approval\"}</mnml-lookup>"}}'
                        printf '%s\n' '{"event":"result","result":{"status":"SUCCESS","response":"<mnml-lookup>{\"action\":\"search\",\"service\":\"gmail\",\"query\":\"approval\"}</mnml-lookup>"}}'
                        ;;
                    2) printf '%s\n' '{"event":"result","result":{"status":"SUCCESS","response":"<mnml-lookup>{\"action\":\"fetch\",\"source\":\"__SOURCE_REFERENCE__\"}</mnml-lookup>"}}' ;;
                    3)
                        printf '%s\n' '{"event":"step_update","step_update":{"step_type":"agent_response","text_delta":"Approved: "}}'
                        printf '%s\n' '{"event":"step_update","step_update":{"step_type":"agent_response","text_delta":"42."}}'
                        printf '%s\n' '{"event":"result","result":{"status":"SUCCESS","response":"Approved: 42."}}'
                        ;;
                    *) printf '%s\n' '{"event":"result","result":{"status":"SUCCESS","response":"43."}}' ;;
                esac
            done
            """#
        let cli = try stub(in: folder, script: script.replacingOccurrences(of: "__SOURCE_REFERENCE__", with: source(account).reference))
        var reported: [ConnectionHit] = [], labels: [String] = []
        let observation = ConnectionActivity.shared.$chats.sink { state in
            if let progress = state[chat] {
                reported.append(contentsOf: progress.sources)
                if let label = progress.label { labels.append(label) }
            }
        }
        defer { observation.cancel() }
        let fixture = gmailFixture(body: "Approved amount: 42")
        let retrieval = client(account, fixture: fixture)
        let context = "<page>PAGE MARKER</page>", question = "What was approved?"
        let first = AIInput(system: Chat.system + ConnectionFlow.instruction([.gmail]),
                            turns: [(mine: true, text: context + "\n" + question)], files: [], context: context, question: question,
                            connectionServices: [.gmail], connectionAccounts: [account.id])
        let answer = try await collect(Antigravity.stream(first, model: AIProvider.antigravity.models[0], chat: chat,
                                                        executable: cli, workspace: folder, sessions: sessions, retrieval: retrieval))
        XCTAssertEqual(answer, "Approved: 42.")
        XCTAssertFalse(answer.contains("mnml-lookup"))
        let pid = try XCTUnwrap(sessions.session(for: chat)?.pid)
        let cited = try XCTUnwrap(reported.first)
        XCTAssertEqual(cited.id, "a123")
        XCTAssertEqual(cited.accountID, account.id)
        XCTAssertEqual(cited.snippet, "Approval snippet")
        XCTAssertTrue(labels.contains("Reading Gmail…"))
        XCTAssertNil(ConnectionActivity.shared.chats[chat])
        let followup = AIInput(system: first.system,
                               turns: [(mine: true, text: question), (mine: false, text: answer),
                                       (mine: true, text: context + "\nWhat plus one?")],
                               files: [], context: context, question: "What plus one?", connectionServices: [.gmail],
                               connectionAccounts: [account.id], connectionSources: [cited])
        let nextAnswer = try await collect(Antigravity.stream(followup, model: AIProvider.antigravity.models[0], chat: chat,
                                                             executable: cli, workspace: folder, sessions: sessions, retrieval: retrieval))
        XCTAssertEqual(nextAnswer, "43.")
        XCTAssertEqual(sessions.session(for: chat)?.pid, pid)
        let sent = try messages(in: folder)
        XCTAssertEqual(sent.count, 4)
        XCTAssertEqual(Set(sent.map(\.pid)), [pid])
        XCTAssertTrue(sent[0].content.contains("PAGE MARKER"))
        XCTAssertTrue(sent[1].content.contains("\"matches\""))
        XCTAssertTrue(sent[2].content.contains("Approved amount: 42"))
        XCTAssertEqual(sent[3].content, "What plus one?")
        XCTAssertFalse(sent.dropFirst().contains { $0.content.contains("PAGE MARKER") })
        XCTAssertFalse(sent.contains { $0.content.contains("fixture-token") })
        let requests = await fixture.requests
        XCTAssertEqual(requests.count, 3)
        let definition = try String(contentsOf: folder.appendingPathComponent(".agents/agents/mnml-chat/agent.md"), encoding: .utf8)
        XCTAssertTrue(definition.contains("tools: [finish]"))
    }

    func testSearchFailureIsReturnedToModelWithoutInventedContent() async throws {
        let fixture = HTTPFixture { _, _ in Reply(data: Data("PRIVATE HTTP ERROR BODY".utf8), status: 403) }
        let (answer, sent, sources) = try await twoTurnSearch(fixture: fixture)
        XCTAssertEqual(answer, "Search failed.")
        XCTAssertTrue(sent[1].content.contains("mnml connection lookup failed:"))
        XCTAssertTrue(sent[1].content.contains("No source content was retrieved"))
        XCTAssertFalse(sent[1].content.contains("PRIVATE HTTP ERROR BODY"))
        XCTAssertTrue(sources.isEmpty)
    }

    func testRepeatedLookupIsLimitedToSixRequests() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = AntigravitySessions(automaticTimer: false), chat = UUID()
        defer { sessions.stopAll(); ConnectionActivity.shared.end(chat); try? FileManager.default.removeItem(at: folder) }
        let cli = try stub(in: folder, script: #"""
            while IFS= read -r input; do
                printf '%s\n' '{"event":"result","result":{"status":"SUCCESS","response":"<mnml-lookup>{\"action\":\"search\",\"service\":\"drive\",\"query\":\"approval\"}</mnml-lookup>"}}'
            done
            """#)
        let fixture = HTTPFixture { _, _ in .json(["files": []]) }
        let input = AIInput(system: ConnectionFlow.instruction([.drive]), turns: [(mine: true, text: "Find approval")],
                            files: [], context: "", question: "Find approval", connectionServices: [.drive], connectionAccounts: [account.id])
        var visible = ""
        do {
            for try await piece in Antigravity.stream(input, model: AIProvider.antigravity.models[0], chat: chat,
                                                      executable: cli, workspace: folder, sessions: sessions,
                                                      retrieval: client(account, fixture: fixture)) { visible += piece }
            XCTFail("A model repeating lookups must not run indefinitely")
        } catch { XCTAssertTrue(error.localizedDescription.contains("search limit")) }
        XCTAssertTrue(visible.isEmpty)
        XCTAssertNil(sessions.session(for: chat))
        XCTAssertNil(ConnectionActivity.shared.chats[chat])
        let requests = await fixture.requests
        XCTAssertEqual(requests.count, ConnectionFlow.maximumLookups)
    }

    func testSavedHistoryDecodesWithoutConnectionFieldsAndRoundTripsSourceMetadata() throws {
        let legacy: [String: Any] = ["id": UUID().uuidString, "title": "Approval", "site": "example.invalid", "updated": 0,
            "mentions": [], "turns": [["id": UUID().uuidString, "mine": false, "text": "Approved: 42.", "about": [], "failed": false]]]
        var saved = try JSONDecoder().decode(Chat.Saved.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(saved.connectionServices)
        XCTAssertNil(saved.turns[0].sources)
        saved.connectionServices = [.gmail]
        saved.turns[0].sources = [source(account)]
        let back = try JSONDecoder().decode(Chat.Saved.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(back.connectionServices, [.gmail])
        XCTAssertEqual(back.turns[0].sources, saved.turns[0].sources)
    }

    /// Opt-in protocol check using the installed CLI, with synthetic HTTP data
    /// and no service OAuth or private account access.
    func testLiveCLIWithSyntheticConnection() async throws {
        guard ProcessInfo.processInfo.environment["MNML_CONNECTION_LIVE"] == "1" else {
            throw XCTSkip("Requires explicit live CLI validation")
        }
        let executable = try XCTUnwrap(Antigravity.executable)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = AntigravitySessions(automaticTimer: false), chat = UUID()
        defer { sessions.stopAll(); ConnectionActivity.shared.end(chat); try? FileManager.default.removeItem(at: folder) }
        var cited: [ConnectionHit] = []
        let observation = ConnectionActivity.shared.$chats.sink { state in
            if let progress = state[chat] { cited = progress.sources.isEmpty ? cited : progress.sources }
        }
        defer { observation.cancel() }
        let fixture = gmailFixture(body: "Approved amount: 42 USD. This is synthetic validation data.")
        let question = "Find the approval email in Gmail and read it. What is the approved amount? Answer in one sentence."
        let input = AIInput(system: Chat.system + ConnectionFlow.instruction([.gmail]),
                            turns: [(mine: true, text: question)], files: [], context: "", question: question,
                            connectionServices: [.gmail], connectionAccounts: [account.id])
        let answer = try await collect(Antigravity.stream(input, model: AIProvider.antigravity.models[0], chat: chat,
                                                        executable: executable, workspace: folder, sessions: sessions,
                                                        retrieval: client(account, fixture: fixture)))
        XCTAssertTrue(answer.contains("42"))
        XCTAssertFalse(answer.contains("mnml-lookup"))
        XCTAssertEqual(cited.first?.id, "a123")
        let pid = try XCTUnwrap(sessions.session(for: chat)?.pid)
        let followup = AIInput(system: input.system,
                               turns: [(mine: true, text: question), (mine: false, text: answer),
                                       (mine: true, text: "What is that amount plus seven? Answer briefly.")],
                               files: [], context: "", question: "What is that amount plus seven? Answer briefly.",
                               connectionServices: [.gmail], connectionAccounts: [account.id], connectionSources: cited)
        let next = try await collect(Antigravity.stream(followup, model: AIProvider.antigravity.models[0], chat: chat,
                                                       executable: executable, workspace: folder, sessions: sessions,
                                                       retrieval: client(account, fixture: fixture)))
        XCTAssertTrue(next.contains("49"))
        XCTAssertEqual(sessions.session(for: chat)?.pid, pid)
        let requests = await fixture.requests
        XCTAssertEqual(requests.count, 3)
        if let bytes = sessions.session(for: chat)?.rssBytes {
            print("Synthetic connection validation: one warm CLI, \(bytes / 1_048_576) MiB RSS, \(requests.count) mocked HTTP reads")
        }
    }

    private func client(_ account: ConnectionAccount, fixture: HTTPFixture) -> ConnectionRetrieval {
        ConnectionRetrieval(accounts: { [account] }, token: { id in
            guard id == account.id else { throw ConnectionFailure("Wrong fixture account") }
            return "fixture-token"
        }, http: { try await fixture.send($0) })
    }

    private func source(_ account: ConnectionAccount, service: ConnectionService = .gmail) -> ConnectionHit {
        ConnectionHit(id: "a123", service: service, accountID: account.id, title: "Approval",
                      url: URL(string: service == .gmail ? "https://mail.google.com/mail/#all/a123" : "https://drive.google.com/file/d/a123/view")!,
                      detail: "", snippet: "Approval snippet", accountTitle: account.title)
    }

    private func gmailFixture(body: String) -> HTTPFixture {
        HTTPFixture { request, _ in
            if request.url!.path.hasSuffix("/messages") { return .json(["messages": [["id": "a123"]]]) }
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if query.contains(where: { $0.name == "format" && $0.value == "full" }) {
                return .json(["payload": ["mimeType": "text/plain", "headers": [["name": "Subject", "value": "Approval"]],
                                          "body": ["data": Self.base64(body)]]])
            }
            return .json(["threadId": "a123", "snippet": "Approval snippet", "payload": ["headers": [["name": "Subject", "value": "Approval"]]]])
        }
    }

    private func twoTurnSearch(fixture: HTTPFixture) async throws -> (String, [(pid: Int32, content: String)], [ConnectionHit]) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = AntigravitySessions(automaticTimer: false), chat = UUID()
        defer { sessions.stopAll(); ConnectionActivity.shared.end(chat); try? FileManager.default.removeItem(at: folder) }
        let cli = try stub(in: folder, script: #"""
            turn=0
            while IFS= read -r input; do
                turn=$((turn + 1))
                printf '%s\t%s\n' "$$" "$input" >> messages.jsonl
                if [ "$turn" -eq 1 ]; then
                    printf '%s\n' '{"event":"result","result":{"status":"SUCCESS","response":"<mnml-lookup>{\"action\":\"search\",\"service\":\"drive\",\"query\":\"approval\"}</mnml-lookup>"}}'
                else
                    printf '%s\n' '{"event":"result","result":{"status":"SUCCESS","response":"Search failed."}}'
                fi
            done
            """#)
        var sources: [ConnectionHit] = []
        let observation = ConnectionActivity.shared.$chats.sink { if let progress = $0[chat] { sources += progress.sources } }
        defer { observation.cancel() }
        let input = AIInput(system: ConnectionFlow.instruction([.drive]), turns: [(mine: true, text: "Find approval")],
                            files: [], context: "", question: "Find approval", connectionServices: [.drive], connectionAccounts: [account.id])
        let answer = try await collect(Antigravity.stream(input, model: AIProvider.antigravity.models[0], chat: chat,
                                                        executable: cli, workspace: folder, sessions: sessions,
                                                        retrieval: client(account, fixture: fixture)))
        return (answer, try messages(in: folder), sources)
    }

    private func payload(_ message: String) throws -> [String: Any] {
        let body = try XCTUnwrap(message.split(separator: "\n", maxSplits: 1).last)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
    }

    private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> String {
        var answer = ""
        for try await piece in stream { answer += piece }
        return answer
    }

    private func stub(in folder: URL, script: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let cli = folder.appendingPathComponent("fake-agy")
        try ("#!/bin/sh\n" + script + "\n").write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        return cli
    }

    private func messages(in folder: URL) throws -> [(pid: Int32, content: String)] {
        try String(contentsOf: folder.appendingPathComponent("messages.jsonl"), encoding: .utf8).split(separator: "\n").map {
            let parts = $0.split(separator: "\t", maxSplits: 1)
            let pid = try XCTUnwrap(Int32(parts[0]))
            let message = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(parts[1].utf8)) as? [String: Any])
            return (pid, try XCTUnwrap((message["message"] as? [String: Any])?["content"] as? String))
        }
    }

    private nonisolated static func base64(_ text: String) -> String {
        Data(text.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private struct Reply: @unchecked Sendable {
        var data: Data
        var status = 200
        static func json(_ object: [String: Any]) -> Reply { Reply(data: try! JSONSerialization.data(withJSONObject: object)) }
    }

    private actor HTTPFixture {
        var requests: [URLRequest] = []
        let handler: @Sendable (URLRequest, Int) throws -> Reply
        init(_ handler: @escaping @Sendable (URLRequest, Int) throws -> Reply) { self.handler = handler }
        func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
            let index = requests.count; requests.append(request)
            let reply = try handler(request, index)
            return (reply.data, HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                              headerFields: ["Content-Type": "application/json"])!)
        }
    }
}
