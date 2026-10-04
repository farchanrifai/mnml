import XCTest
import Combine
@testable import mnml

@MainActor
final class ConnectionSelectionTests: XCTestCase {
    private let personal = ConnectionAccount(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, provider: .google,
        title: "personal@example.invalid", services: [.gmail, .drive], label: "Personal account")
    private let work = ConnectionAccount(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, provider: .google,
        title: "work@example.invalid", services: [.gmail, .drive], label: "Work account")

    func testLookupCarriesAnExactAccountAndRejectsInvalidUUID() throws {
        let lookup = try XCTUnwrap(ConnectionFlow.lookup("<mnml-lookup>{\"action\":\"search\",\"service\":\"gmail\",\"query\":\"invoice\",\"account\":\"\(work.id.uuidString)\"}</mnml-lookup>"))
        XCTAssertEqual(lookup.account, work.id)
        XCTAssertThrowsError(try ConnectionFlow.lookup("<mnml-lookup>{\"action\":\"search\",\"service\":\"gmail\",\"query\":\"invoice\",\"account\":\"work\"}</mnml-lookup>"))
    }

    func testInstructionIncludesSelectedAccountLabelsAndIdentityOnly() {
        let outside = ConnectionAccount(id: UUID(), provider: .google, title: "outside@example.invalid",
                                        services: [.gmail], label: "Outside account")
        let instruction = ConnectionFlow.instruction([.gmail, .drive], selections: [
            .init(service: .gmail, accountID: personal.id), .init(service: .drive, accountID: work.id)
        ], accountDetails: [outside, work, personal])
        for expected in ["Personal account", personal.title, personal.id.uuidString,
                         "Work account", work.title, work.id.uuidString] {
            XCTAssertTrue(instruction.contains(expected), "The model needs \(expected) to route a request to the intended account")
        }
        XCTAssertFalse(instruction.contains(outside.title))
        XCTAssertFalse(instruction.contains(outside.id.uuidString))
    }

    func testSearchMergesSelectedAccountsWithoutCollidingSourceReferences() async throws {
        let fixture = gmailFixture(matches: 6)
        let accounts = [work, personal] // Deliberately differs from stable account-id order.
        let selected = accounts.map { ConnectionSelection(service: .gmail, accountID: $0.id) }
        let client = retrieval(accounts, fixture: fixture)
        let result = try await ConnectionFlow.perform(.init(action: "search", service: .gmail, query: "approval"),
            services: [.gmail], accounts: Set(accounts.map(\.id)), known: [:], room: ConnectionFlow.evidenceBudget,
            retrieval: client, selections: selected)
        XCTAssertEqual(result.hits.count, 10, "Each selected account contributes a bounded set of five matches")
        XCTAssertEqual(Set(result.hits.map(\.accountID)), Set(accounts.map(\.id)))
        XCTAssertEqual(Set(result.hits.map(\.reference)).count, 10, "The same Gmail message id in two accounts must remain distinct")
        XCTAssertEqual(Set(result.hits.map(\.id)).count, 5)
        XCTAssertEqual(result.hits.map(\.accountID), Array(repeating: personal.id, count: 5) + Array(repeating: work.id, count: 5))
        for hit in result.hits {
            let owner = try XCTUnwrap(accounts.first { $0.id == hit.accountID })
            XCTAssertTrue(hit.accountTitle?.contains(owner.title) == true)
            XCTAssertTrue(hit.accountTitle?.contains(owner.displayTitle) == true)
            let authuser = URLComponents(url: hit.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "authuser" }?.value
            XCTAssertEqual(authuser, owner.title, "Friendly labels must not replace Gmail's routing identity")
        }
        let matches = try XCTUnwrap(try payload(result.message)["matches"] as? [[String: Any]])
        XCTAssertEqual(Set(matches.compactMap { $0["source"] as? String }), Set(result.hits.map(\.reference)))
        let requests = await fixture.requests
        XCTAssertEqual(requests.count, 12)
        XCTAssertEqual(Set(requests.compactMap { $0.value(forHTTPHeaderField: "Authorization") }),
                       Set(accounts.map { "Bearer " + $0.id.uuidString }))
        for request in requests where request.url!.path.hasSuffix("/messages") {
            let limit = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "maxResults" }?.value
            XCTAssertEqual(limit, "5")
        }
    }

    func testExplicitAccountSearchReadsOnlyThatAccount() async throws {
        let fixture = gmailFixture(matches: 1), accounts = [personal, work]
        let result = try await ConnectionFlow.perform(.init(action: "search", service: .gmail, query: "approval", account: work.id),
            services: [.gmail], accounts: Set(accounts.map(\.id)), known: [:], room: 1_000,
            retrieval: retrieval(accounts, fixture: fixture),
            selections: accounts.map { .init(service: .gmail, accountID: $0.id) })
        XCTAssertEqual(result.hits.map(\.accountID), [work.id])
        let requests = await fixture.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer " + work.id.uuidString })
    }

    func testAuthoritativeTuplesRefuseCrossAccountServicesBeforeCredentialOrHTTPRead() async throws {
        let fixture = HTTPFixture { _ in XCTFail("A refused selection must not issue HTTP"); return .json([:]) }
        let accounts = [personal, work]
        let client = ConnectionRetrieval(accounts: { accounts }, token: { _ in
            XCTFail("A refused selection must not read account credentials"); return "unused"
        }, http: { try await fixture.send($0) })
        let selected: [ConnectionSelection] = [.init(service: .gmail, accountID: personal.id), .init(service: .drive, accountID: work.id)]
        let workMail = source(work, service: .gmail), personalDrive = source(personal, service: .drive)
        let commands: [ConnectionFlow.Lookup] = [
            .init(action: "search", service: .gmail, query: "approval", account: work.id),
            .init(action: "search", service: .drive, query: "approval", account: personal.id),
            .init(action: "search", service: .gmail, query: "approval", account: UUID()),
            .init(action: "fetch", source: workMail.reference),
            .init(action: "fetch", source: personalDrive.reference)
        ]
        for command in commands {
            do {
                _ = try await ConnectionFlow.perform(command, services: [.gmail, .drive], accounts: Set(accounts.map(\.id)),
                    known: [workMail.reference: workMail, personalDrive.reference: personalDrive], room: 1_000,
                    retrieval: client, selections: selected)
                XCTFail("A selected account and a selected service must not grant their unselected cross-product")
            } catch { XCTAssertTrue(error is ConnectionFailure) }
        }
        let requests = await fixture.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testServiceWithNoSelectedAccountAndDisabledConnectionsRefuseBeforeHTTP() async throws {
        let fixture = HTTPFixture { _ in XCTFail("A disabled connection must not issue HTTP"); return .json([:]) }
        let client = retrieval([personal, work], fixture: fixture)
        for (services, accounts, selections) in [
            (Set<ConnectionService>([.gmail, .drive]), Set([personal.id, work.id]), [ConnectionSelection(service: .drive, accountID: work.id)]),
            (Set<ConnectionService>(), Set<UUID>(), [ConnectionSelection]())
        ] {
            do {
                _ = try await ConnectionFlow.perform(.init(action: "search", service: .gmail, query: "approval"),
                    services: services, accounts: accounts, known: [:], room: 1_000,
                    retrieval: client, selections: selections)
                XCTFail("No account was enabled for Gmail")
            } catch { XCTAssertTrue(error is ConnectionFailure) }
        }
        let requests = await fixture.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testOmittedAccountRefusesMoreThanThreeEligibleAccountsBeforeAnyRead() async throws {
        let fixture = HTTPFixture { _ in XCTFail("The model must choose an account before a broad search reads data"); return .json([:]) }
        let accounts = (1...4).map { index in
            ConnectionAccount(id: UUID(), provider: .google, title: "reader\(index)@example.invalid", services: [.gmail])
        }
        let client = ConnectionRetrieval(accounts: { accounts }, token: { _ in
            XCTFail("An overbroad search must not read credentials"); return "unused"
        }, http: { try await fixture.send($0) })
        do {
            _ = try await ConnectionFlow.perform(.init(action: "search", service: .gmail, query: "approval"),
                services: [.gmail], accounts: Set(accounts.map(\.id)), known: [:], room: 1_000,
                retrieval: client, selections: accounts.map { .init(service: .gmail, accountID: $0.id) })
            XCTFail("A search must not silently omit one enabled account or exceed the fan-out limit")
        } catch {
            XCTAssertTrue(error is ConnectionFailure)
            XCTAssertTrue(error.localizedDescription.lowercased().contains("account"))
        }
        let requests = await fixture.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testOrdinaryAnswerAndWarmFollowupDoNotSearchConnectedAccounts() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = AntigravitySessions(automaticTimer: false), chat = UUID()
        defer { sessions.stopAll(); ConnectionActivity.shared.end(chat); try? FileManager.default.removeItem(at: folder) }
        let cli = try stub(in: folder, script: #"""
            while IFS= read -r input; do
                printf '%s\t%s\n' "$$" "$input" >> messages.jsonl
                printf '%s\n' '{"event":"result","result":{"status":"SUCCESS","response":"Four."}}'
            done
            """#)
        let fixture = HTTPFixture { _ in XCTFail("An ordinary answer must not fetch private source data"); return .json([:]) }
        let accounts = [personal, work]
        let client = ConnectionRetrieval(accounts: { accounts }, token: { _ in
            XCTFail("An ordinary answer must not read account credentials"); return "unused"
        }, http: { try await fixture.send($0) })
        let selections = accounts.map { ConnectionSelection(service: .gmail, accountID: $0.id) }
        let context = "PAGE MARKER", question = "What is two plus two?"
        let first = AIInput(system: ConnectionFlow.instruction([.gmail], selections: selections, accountDetails: accounts),
            turns: [(mine: true, text: context + "\n" + question)], files: [], context: context, question: question,
            connectionServices: [.gmail], connectionAccounts: accounts.map(\.id),
            connectionSelections: selections, connectionAccountDetails: accounts)
        let answer = try await collect(Antigravity.stream(first, model: AIProvider.antigravity.models[0], chat: chat,
            executable: cli, workspace: folder, sessions: sessions, retrieval: client))
        XCTAssertEqual(answer, "Four.")
        let pid = try XCTUnwrap(sessions.session(for: chat)?.pid)
        let second = AIInput(system: first.system,
            turns: [(mine: true, text: question), (mine: false, text: answer), (mine: true, text: context + "\nRepeat it.")],
            files: [], context: context, question: "Repeat it.", connectionServices: [.gmail],
            connectionAccounts: accounts.map(\.id), connectionSelections: selections, connectionAccountDetails: accounts)
        let repeated = try await collect(Antigravity.stream(second, model: AIProvider.antigravity.models[0], chat: chat,
            executable: cli, workspace: folder, sessions: sessions, retrieval: client))
        XCTAssertEqual(repeated, "Four.")
        XCTAssertEqual(sessions.session(for: chat)?.pid, pid)
        let sent = try messages(in: folder)
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(Set(sent.map(\.pid)), [pid])
        XCTAssertEqual(sent[1].content, "Repeat it.", "A warm follow-up must preserve quota efficiency without page reinjection")
        let requests = await fixture.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testNeededSearchFetchAndWarmFollowupPreserveAccountServiceSelection() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = AntigravitySessions(automaticTimer: false), chat = UUID()
        defer { sessions.stopAll(); ConnectionActivity.shared.end(chat); try? FileManager.default.removeItem(at: folder) }
        let workMail = source(work, service: .gmail)
        let script = #"""
            turn=0
            while IFS= read -r input; do
                turn=$((turn + 1))
                printf '%s\t%s\n' "$$" "$input" >> messages.jsonl
                case "$turn" in
                    1) printf '%s\n' '{"event":"result","result":{"status":"SUCCESS","response":"<mnml-lookup>{\"action\":\"search\",\"service\":\"gmail\",\"query\":\"approval\"}</mnml-lookup>"}}' ;;
                    2) printf '%s\n' '{"event":"result","result":{"status":"SUCCESS","response":"<mnml-lookup>{\"action\":\"fetch\",\"source\":\"__SOURCE_REFERENCE__\"}</mnml-lookup>"}}' ;;
                    3) printf '%s\n' '{"event":"result","result":{"status":"SUCCESS","response":"Approved: 42."}}' ;;
                    *) printf '%s\n' '{"event":"result","result":{"status":"SUCCESS","response":"43."}}' ;;
                esac
            done
            """#
        let cli = try stub(in: folder, script: script.replacingOccurrences(of: "__SOURCE_REFERENCE__", with: workMail.reference))
        let chosen = work
        let fixture = HTTPFixture { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + chosen.id.uuidString,
                           "Personal's Drive selection must never authorize a Gmail read")
            if request.url!.path.hasSuffix("/messages") { return .json(["messages": [["id": "a1"]]]) }
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if query.contains(where: { $0.name == "format" && $0.value == "full" }) {
                return .json(["payload": ["mimeType": "text/plain", "body": ["data": Data("Approved amount: 42".utf8).base64EncodedString()]]])
            }
            return .json(["threadId": "a1", "snippet": "Approval", "payload": ["headers": [["name": "Subject", "value": "Approval"]]]])
        }
        let accounts = [personal, work]
        let selected: [ConnectionSelection] = [.init(service: .drive, accountID: personal.id), .init(service: .gmail, accountID: work.id)]
        let client = retrieval(accounts, fixture: fixture)
        var sources: [ConnectionHit] = []
        let observation = ConnectionActivity.shared.$chats.sink { state in
            if let progress = state[chat], !progress.sources.isEmpty { sources = progress.sources }
        }
        defer { observation.cancel() }
        let context = "PAGE MARKER", question = "Find the approval and its amount."
        let first = AIInput(system: ConnectionFlow.instruction([.gmail, .drive], selections: selected, accountDetails: accounts),
            turns: [(mine: true, text: context + "\n" + question)], files: [], context: context, question: question,
            connectionServices: [.gmail, .drive], connectionAccounts: accounts.map(\.id),
            connectionSelections: selected, connectionAccountDetails: accounts)
        let answer = try await collect(Antigravity.stream(first, model: AIProvider.antigravity.models[0], chat: chat,
            executable: cli, workspace: folder, sessions: sessions, retrieval: client))
        XCTAssertEqual(answer, "Approved: 42.")
        XCTAssertEqual(sources.map(\.reference), [workMail.reference])
        let pid = try XCTUnwrap(sessions.session(for: chat)?.pid)
        let second = AIInput(system: first.system,
            turns: [(mine: true, text: question), (mine: false, text: answer), (mine: true, text: context + "\nWhat plus one?")],
            files: [], context: context, question: "What plus one?", connectionServices: [.gmail, .drive],
            connectionAccounts: accounts.map(\.id), connectionSources: sources,
            connectionSelections: selected, connectionAccountDetails: accounts)
        let next = try await collect(Antigravity.stream(second, model: AIProvider.antigravity.models[0], chat: chat,
            executable: cli, workspace: folder, sessions: sessions, retrieval: client))
        XCTAssertEqual(next, "43.")
        XCTAssertEqual(sessions.session(for: chat)?.pid, pid)
        let requests = await fixture.requests
        XCTAssertEqual(requests.count, 3)
        let sent = try messages(in: folder)
        XCTAssertEqual(sent.count, 4)
        XCTAssertEqual(sent[3].content, "What plus one?")
        XCTAssertFalse(sent.dropFirst().contains { $0.content.contains("PAGE MARKER") })
        XCTAssertTrue(sent[1].content.contains(work.title))
        XCTAssertFalse(sent[1].content.contains(personal.title))
    }

    func testWarmRuntimeIsReplacedWhenAccountServiceTuplesChange() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = AntigravitySessions(automaticTimer: false), chat = UUID()
        defer { sessions.stopAll(); ConnectionActivity.shared.end(chat); try? FileManager.default.removeItem(at: folder) }
        let cli = try stub(in: folder, script: #"""
            while IFS= read -r input; do
                printf '%s\t%s\n' "$$" "$input" >> messages.jsonl
                printf '%s\n' '{"event":"result","result":{"status":"SUCCESS","response":"Four."}}'
            done
            """#)
        let fixture = HTTPFixture { _ in XCTFail("An ordinary answer requires no source read"); return .json([:]) }
        let accounts = [personal, work], context = "PAGE MARKER", question = "What is two plus two?"
        let first = AIInput(system: "Use source data only when needed.",
            turns: [(mine: true, text: context + "\n" + question)], files: [], context: context, question: question,
            connectionServices: [.gmail, .drive], connectionAccounts: accounts.map(\.id),
            connectionSelections: [.init(service: .gmail, accountID: personal.id), .init(service: .drive, accountID: work.id)])
        let client = retrieval(accounts, fixture: fixture)
        let answer = try await collect(Antigravity.stream(first, model: AIProvider.antigravity.models[0], chat: chat,
            executable: cli, workspace: folder, sessions: sessions, retrieval: client))
        let originalPID = try XCTUnwrap(sessions.session(for: chat)?.pid)
        let second = AIInput(system: first.system,
            turns: [(mine: true, text: question), (mine: false, text: answer), (mine: true, text: context + "\nRepeat it.")],
            files: [], context: context, question: "Repeat it.", connectionServices: first.connectionServices,
            connectionAccounts: first.connectionAccounts,
            connectionSelections: [.init(service: .drive, accountID: personal.id), .init(service: .gmail, accountID: work.id)])
        _ = try await collect(Antigravity.stream(second, model: AIProvider.antigravity.models[0], chat: chat,
            executable: cli, workspace: folder, sessions: sessions, retrieval: client))
        let replacementPID = try XCTUnwrap(sessions.session(for: chat)?.pid)
        XCTAssertNotEqual(replacementPID, originalPID, "A worker retaining source data under the former account-service scope must be retired")
        let sent = try messages(in: folder)
        XCTAssertEqual(sent.count, 2)
        XCTAssertTrue(sent[1].content.contains("PAGE MARKER"), "The replacement worker must receive a complete bootstrap")
        let requests = await fixture.requests
        XCTAssertTrue(requests.isEmpty)
    }

    /// Opt-in routing check with the installed model, synthetic messages and
    /// no live connector OAuth, account tokens or private service requests.
    func testLiveCLIWithLabeledAccounts() async throws {
        guard ProcessInfo.processInfo.environment["MNML_CONNECTION_LIVE"] == "1" else {
            throw XCTSkip("Requires explicit live CLI validation")
        }
        let executable = try XCTUnwrap(Antigravity.executable)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = AntigravitySessions(automaticTimer: false), chat = UUID()
        defer { sessions.stopAll(); ConnectionActivity.shared.end(chat); try? FileManager.default.removeItem(at: folder) }
        let chosen = work, accounts = [personal, work]
        let selections = accounts.map { ConnectionSelection(service: .gmail, accountID: $0.id) }
        let fixture = HTTPFixture { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-work-token")
            if request.url!.path.hasSuffix("/messages") { return .json(["messages": [["id": "a1"]]]) }
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if query.contains(where: { $0.name == "format" && $0.value == "full" }) {
                return .json(["payload": ["mimeType": "text/plain", "body": ["data": Data(
                    "Approved amount: 42 USD. Synthetic routing validation data; no real email was accessed.".utf8
                ).base64EncodedString()]]])
            }
            return .json(["threadId": "a1", "snippet": "Synthetic approval email", "payload": ["headers": [
                ["name": "Subject", "value": "Approval"], ["name": "From", "value": "Finance"]]]])
        }
        let client = ConnectionRetrieval(accounts: { accounts }, token: { id in
            XCTAssertEqual(id, chosen.id, "A question naming Work account must never read Personal account")
            guard id == chosen.id else { throw ConnectionFailure("The question named Work account; choose its catalog UUID.") }
            return "synthetic-work-token"
        }, http: { try await fixture.send($0) })
        var sources: [ConnectionHit] = []
        let observation = ConnectionActivity.shared.$chats.sink { state in
            if let progress = state[chat], !progress.sources.isEmpty { sources = progress.sources }
        }
        defer { observation.cancel() }
        let question = "Find the approval email in my Work account (work@example.invalid), read it, and tell me the approved amount. Answer in one sentence."
        let first = AIInput(system: Chat.system + ConnectionFlow.instruction([.gmail], selections: selections, accountDetails: accounts),
            turns: [(mine: true, text: question)], files: [], context: "", question: question,
            connectionServices: [.gmail], connectionAccounts: accounts.map(\.id),
            connectionSelections: selections, connectionAccountDetails: accounts)
        let answer = try await collect(Antigravity.stream(first, model: AIProvider.antigravity.models[0], chat: chat,
            executable: executable, workspace: folder, sessions: sessions, retrieval: client))
        XCTAssertTrue(answer.contains("42"))
        XCTAssertFalse(answer.contains("mnml-lookup"))
        XCTAssertEqual(sources.map(\.accountID), [chosen.id])
        XCTAssertEqual(sources.map(\.reference), [source(chosen, service: .gmail).reference])
        let pid = try XCTUnwrap(sessions.session(for: chat)?.pid)
        let countBeforeFollowup = await fixture.requests.count
        XCTAssertGreaterThanOrEqual(countBeforeFollowup, 3, "The model should search metadata and read the message contents")
        let followupQuestion = "Using the amount in your answer, what is that amount plus seven? Answer briefly."
        let followup = AIInput(system: first.system,
            turns: [(mine: true, text: question), (mine: false, text: answer), (mine: true, text: followupQuestion)],
            files: [], context: "", question: followupQuestion, connectionServices: [.gmail],
            connectionAccounts: accounts.map(\.id), connectionSources: sources,
            connectionSelections: selections, connectionAccountDetails: accounts)
        let repeated = try await collect(Antigravity.stream(followup, model: AIProvider.antigravity.models[0], chat: chat,
            executable: executable, workspace: folder, sessions: sessions, retrieval: client))
        XCTAssertTrue(repeated.contains("49"))
        XCTAssertFalse(repeated.contains("mnml-lookup"))
        XCTAssertEqual(sessions.session(for: chat)?.pid, pid)
        let finalCount = await fixture.requests.count
        XCTAssertEqual(finalCount, countBeforeFollowup, "A calculation follow-up should use warm context and read no more service data")
    }

    private func retrieval(_ accounts: [ConnectionAccount], fixture: HTTPFixture) -> ConnectionRetrieval {
        ConnectionRetrieval(accounts: { accounts }, token: { id in
            guard accounts.contains(where: { $0.id == id }) else { throw ConnectionFailure("Unknown test account") }
            return id.uuidString
        }, http: { try await fixture.send($0) })
    }

    private func gmailFixture(matches count: Int) -> HTTPFixture {
        HTTPFixture { request in
            if request.url!.path.hasSuffix("/messages") {
                return .json(["messages": (1...count).map { ["id": "a\($0)"] }])
            }
            return .json(["threadId": "a1", "snippet": "Approval snippet", "payload": ["headers": [
                ["name": "Subject", "value": "Approval"], ["name": "From", "value": "Sender"]]]])
        }
    }

    private func source(_ account: ConnectionAccount, service: ConnectionService) -> ConnectionHit {
        ConnectionHit(id: "a1", service: service, accountID: account.id, title: "Approval",
            url: URL(string: "https://mail.google.com/mail/#all/a1")!, detail: "", snippet: "",
            accountTitle: account.displayIdentity)
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
            let fields = $0.split(separator: "\t", maxSplits: 1)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(fields[1].utf8)) as? [String: Any])
            return (try XCTUnwrap(Int32(fields[0])), try XCTUnwrap((object["message"] as? [String: Any])?["content"] as? String))
        }
    }

    private struct Reply: @unchecked Sendable {
        var data: Data
        static func json(_ object: [String: Any]) -> Reply { Reply(data: try! JSONSerialization.data(withJSONObject: object)) }
    }

    private actor HTTPFixture {
        var requests: [URLRequest] = []
        let handler: @Sendable (URLRequest) throws -> Reply
        init(_ handler: @escaping @Sendable (URLRequest) throws -> Reply) { self.handler = handler }
        func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
            requests.append(request)
            let reply = try handler(request)
            return (reply.data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!)
        }
    }
}
