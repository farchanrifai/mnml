import XCTest
import Combine
@testable import mnml

@MainActor
final class ConnectionAccountPolicyTests: XCTestCase {
    private nonisolated let clock = Date(timeIntervalSince1970: 1_800_000_000)
    private let desktop = Data(#"{"installed":{"client_id":"fixture.apps.googleusercontent.com","client_secret":"fixture-client"}}"#.utf8)

    func testLegacyAccountDecodesWithoutLabelAndOnlyFirstSpaceInheritsGrants() async throws {
        let old = Data(#"{"id":"00000000-0000-0000-0000-000000000011","provider":"google","title":"old@example.invalid","services":["gmail"]}"#.utf8)
        let account = try JSONDecoder().decode(ConnectionAccount.self, from: old)
        XCTAssertNil(account.label)
        XCTAssertEqual(account.displayTitle, "old@example.invalid")
        XCTAssertEqual(account.displayIdentity, "old@example.invalid")
        let grant = credential(account: account)
        let store = try PolicyCredentials(stored: .init(credentials: [account.id.uuidString: grant]))
        let model = self.model(store)
        try await model.waitUntilReady()
        XCTAssertEqual(model.eligible(in: Space.firstID), [account])
        XCTAssertTrue(model.eligible(in: UUID()).isEmpty)
        XCTAssertTrue(model.policy(for: Space.firstID).automatic)
        await model.rename(account.id, label: "Personal account")
        let saved = try await store.decoded()
        XCTAssertEqual(saved.spacePolicies?[Space.firstID.uuidString]?.accountIDs, [account.id])
    }

    func testLabelsTrimLimitAndClearWithoutReplacingIdentity() async throws {
        let grant = credential()
        let store = try PolicyCredentials(stored: .init(credentials: [grant.account.id.uuidString: grant]))
        let model = self.model(store)
        await model.rename(grant.account.id, label: "  Personal account\n")
        XCTAssertNil(model.error)
        XCTAssertEqual(model.accounts.first?.displayTitle, "Personal account")
        XCTAssertEqual(model.accounts.first?.title, "person@example.invalid")
        XCTAssertEqual(model.accounts.first?.displayIdentity, "Personal account · person@example.invalid")
        let restored = self.model(store)
        try await restored.waitUntilReady()
        XCTAssertEqual(restored.accounts.first?.label, "Personal account")
        await model.rename(grant.account.id, label: String(repeating: "é", count: 75))
        XCTAssertEqual(model.accounts.first?.label?.count, 60)
        await model.rename(grant.account.id, label: " \n\t ")
        XCTAssertNil(model.accounts.first?.label)
        XCTAssertEqual(model.accounts.first?.displayIdentity, grant.account.title)
    }

    func testPerSpaceAssignmentsAndAutomaticChoicePersistWithoutChangingGrants() async throws {
        let first = credential()
        let second = credential(account: .init(id: UUID(), provider: .google, title: "work@example.invalid", services: [.gmail, .calendar]))
        let store = try PolicyCredentials(stored: .init(credentials: [first.account.id.uuidString: first, second.account.id.uuidString: second], spacePolicies: [:]))
        let model = self.model(store), work = UUID()
        await model.setEnabled(account: first.account.id, in: Space.firstID, enabled: true)
        await model.setEnabled(account: second.account.id, in: work, enabled: true)
        await model.setEnabled(account: second.account.id, in: work, enabled: true)
        await model.setAutomatic(false, in: work)
        XCTAssertEqual(model.eligible(in: Space.firstID).map(\.id), [first.account.id])
        XCTAssertEqual(model.eligible(in: work).map(\.id), [second.account.id])
        XCTAssertEqual(model.policy(for: work).accountIDs, [second.account.id])
        XCTAssertFalse(model.policy(for: work).automatic)
        XCTAssertTrue(model.policy(for: UUID()).automatic)
        let saved = try await store.decoded()
        XCTAssertEqual(saved.credentials[first.account.id.uuidString]?.tokens.refresh, first.tokens.refresh)
        let restored = self.model(store)
        try await restored.waitUntilReady()
        XCTAssertEqual(restored.policies, model.policies)
        await model.setEnabled(account: second.account.id, in: work, enabled: false)
        XCTAssertTrue(model.eligible(in: work).isEmpty)
        XCTAssertEqual(model.accounts.count, 2)
    }

    func testMultipleAccountSelectionsKeepServiceAndIdentityDistinct() async throws {
        let first = credential()
        let second = credential(account: .init(id: UUID(), provider: .google, title: "work@example.invalid", services: [.gmail, .drive]))
        let third = credential(account: .init(id: UUID(), provider: .notion, title: "Notion workspace", services: [.notion]))
        let work = UUID()
        let grants = [first, second, third]
        let store = try PolicyCredentials(stored: .init(credentials: Dictionary(uniqueKeysWithValues: grants.map { ($0.account.id.uuidString, $0) }), spacePolicies: [work.uuidString: .init(accountIDs: [first.account.id, second.account.id])]))
        let model = self.model(store)
        try await model.waitUntilReady()
        let selected = Set(model.selections(in: work))
        XCTAssertEqual(selected, Set([
            ConnectionSelection(service: .gmail, accountID: first.account.id),
            .init(service: .gmail, accountID: second.account.id),
            .init(service: .drive, accountID: second.account.id),
        ]))
        XCTAssertEqual(Set(selected.map(\.id)).count, 3)
        XCTAssertTrue(model.selections(in: Space.firstID).isEmpty)
    }

    func testNewGoogleConnectionBelongsOnlyToRequestedSpace() async throws {
        let store = PolicyCredentials(), http = PolicyHTTP()
        let model = ConnectionAccounts(store: store, http: http.http, authorize: Self.authorize, now: { self.clock })
        try await model.importGoogleCredentials(desktop)
        let work = UUID()
        await model.connectGoogle(in: work)
        XCTAssertNil(model.error)
        let account = try XCTUnwrap(model.accounts.first)
        XCTAssertTrue(model.eligible(in: Space.firstID).isEmpty)
        XCTAssertEqual(model.eligible(in: work).map(\.id), [account.id])
        XCTAssertTrue(model.eligible(in: UUID()).isEmpty)
    }

    func testReconnectPreservesLabelIDAndExistingAssignments() async throws {
        let grant = credential(account: .init(id: UUID(), provider: .google, title: "person@example.invalid", services: [.gmail], label: "Personal account"))
        let home = UUID(), work = UUID()
        let store = try PolicyCredentials(stored: .init(google: .init(id: "fixture.apps.googleusercontent.com", secret: "fixture-client"),
            credentials: [grant.account.id.uuidString: grant], spacePolicies: [home.uuidString: .init(accountIDs: [grant.account.id])]))
        let http = PolicyHTTP()
        let model = ConnectionAccounts(store: store, http: http.http, authorize: Self.authorize, now: { self.clock })
        await model.connectGoogle(in: work)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.accounts.count, 1)
        XCTAssertEqual(model.accounts.first?.id, grant.account.id)
        XCTAssertEqual(model.accounts.first?.label, "Personal account")
        XCTAssertEqual(model.accounts.first?.title, "person@example.invalid")
        XCTAssertEqual(model.eligible(in: home).map(\.id), [grant.account.id])
        XCTAssertEqual(model.eligible(in: work).map(\.id), [grant.account.id])
        XCTAssertTrue(model.eligible(in: Space.firstID).isEmpty)
    }

    func testRefreshKeepsLabelChangedDuringItsNetworkRequest() async throws {
        let grant = credential(expired: true)
        let store = try PolicyCredentials(stored: .init(credentials: [grant.account.id.uuidString: grant]))
        let http = PolicyHTTP(paused: true)
        let model = ConnectionAccounts(store: store, http: http.http, now: { self.clock })
        let refreshing = Task { try await model.token(for: grant.account.id) }
        await http.waitUntilPaused()
        await model.rename(grant.account.id, label: "Work account")
        await http.resume()
        let token = try await refreshing.value
        XCTAssertEqual(token, "new-access")
        XCTAssertEqual(model.accounts.first?.label, "Work account")
        let saved = try await store.decoded()
        XCTAssertEqual(saved.credentials[grant.account.id.uuidString]?.account.label, "Work account")
    }

    func testTokenRefreshDoesNotPublishUnchangedChatAccessMetadata() async throws {
        let grant = credential(expired: true)
        let store = try PolicyCredentials(stored: .init(credentials: [grant.account.id.uuidString: grant]))
        let http = PolicyHTTP()
        let model = ConnectionAccounts(store: store, http: http.http, now: { self.clock })
        try await model.waitUntilReady()
        var accountPublications = 0, policyPublications = 0
        let accountUpdates = model.$accounts.dropFirst().sink { _ in accountPublications += 1 }
        let policyUpdates = model.$policies.dropFirst().sink { _ in policyPublications += 1 }
        _ = try await model.token(for: grant.account.id)
        withExtendedLifetime((accountUpdates, policyUpdates)) {
            XCTAssertEqual(accountPublications, 0)
            XCTAssertEqual(policyPublications, 0)
        }
        let saved = try await store.decoded()
        XCTAssertEqual(saved.credentials[grant.account.id.uuidString]?.tokens.access, "new-access")
    }

    func testFailedConfigurationWritesPreserveAccountAndPolicies() async throws {
        let grant = credential()
        let store = try PolicyCredentials(stored: .init(credentials: [grant.account.id.uuidString: grant]))
        let model = self.model(store), work = UUID()
        try await model.waitUntilReady()
        let original = model.policies
        await store.failNext()
        await model.rename(grant.account.id, label: "Failed label")
        XCTAssertNotNil(model.error)
        XCTAssertNil(model.accounts.first?.label)
        await store.failNext()
        await model.setEnabled(account: grant.account.id, in: work, enabled: true)
        XCTAssertNotNil(model.error)
        XCTAssertEqual(model.policies, original)
        await store.failNext()
        await model.setAutomatic(false, in: work)
        XCTAssertEqual(model.policies, original)
        await store.failNext()
        await model.disconnect(grant.account.id)
        XCTAssertEqual(model.accounts, [grant.account])
        XCTAssertEqual(model.policies, original)
        let saved = try await store.decoded()
        XCTAssertEqual(saved.credentials[grant.account.id.uuidString]?.tokens.refresh, grant.tokens.refresh)
    }

    func testFailedReconnectDoesNotReplaceGrantOrAddSpaceAccess() async throws {
        let grant = credential(account: .init(id: UUID(), provider: .google, title: "person@example.invalid", services: [.gmail], label: "Personal account"))
        let home = UUID(), work = UUID()
        let store = try PolicyCredentials(stored: .init(google: .init(id: "fixture.apps.googleusercontent.com", secret: "fixture-client"),
            credentials: [grant.account.id.uuidString: grant], spacePolicies: [home.uuidString: .init(accountIDs: [grant.account.id])]))
        let http = PolicyHTTP()
        let model = ConnectionAccounts(store: store, http: http.http, authorize: Self.authorize, now: { self.clock })
        try await model.waitUntilReady()
        await store.failNext()
        await model.connectGoogle(in: work)
        XCTAssertNotNil(model.error)
        XCTAssertEqual(model.accounts, [grant.account])
        XCTAssertTrue(model.eligible(in: work).isEmpty)
        XCTAssertEqual(model.eligible(in: home), [grant.account])
        let saved = try await store.decoded()
        XCTAssertEqual(saved.credentials[grant.account.id.uuidString]?.tokens.access, grant.tokens.access)
    }

    func testConcurrentEditsSerializeAndPublishOnlyDurableChanges() async throws {
        let grant = credential()
        let store = try PolicyCredentials(stored: .init(credentials: [grant.account.id.uuidString: grant], spacePolicies: [:]))
        let model = self.model(store), work = UUID()
        try await model.waitUntilReady()
        await store.pauseNext()
        let naming = Task { await model.rename(grant.account.id, label: "Personal account") }
        await store.waitUntilPaused()
        XCTAssertNil(model.accounts.first?.label)
        let assigning = Task { await model.setEnabled(account: grant.account.id, in: work, enabled: true) }
        await Task.yield()
        await store.resume()
        await naming.value
        await assigning.value
        XCTAssertEqual(model.accounts.first?.label, "Personal account")
        XCTAssertEqual(model.eligible(in: work).map(\.id), [grant.account.id])
        let saved = try await store.decoded()
        XCTAssertEqual(saved.credentials[grant.account.id.uuidString]?.account.label, "Personal account")
        XCTAssertEqual(saved.spacePolicies?[work.uuidString]?.accountIDs, [grant.account.id])
    }

    func testDisconnectClearsAccountFromEverySpace() async throws {
        let grant = credential(), work = UUID()
        let store = try PolicyCredentials(stored: .init(credentials: [grant.account.id.uuidString: grant],
            spacePolicies: [Space.firstID.uuidString: .init(accountIDs: [grant.account.id]), work.uuidString: .init(accountIDs: [grant.account.id], automatic: false)]))
        let model = self.model(store)
        await model.disconnect(grant.account.id)
        XCTAssertNil(model.error)
        XCTAssertTrue(model.accounts.isEmpty)
        XCTAssertTrue(model.policy(for: Space.firstID).accountIDs.isEmpty)
        XCTAssertTrue(model.policy(for: work).accountIDs.isEmpty)
        XCTAssertFalse(model.policy(for: work).automatic)
        let saved = try await store.decoded()
        XCTAssertTrue(saved.credentials.isEmpty)
        XCTAssertTrue(saved.spacePolicies?.values.allSatisfy { $0.accountIDs.isEmpty } == true)
    }

    private func model(_ store: PolicyCredentials) -> ConnectionAccounts {
        ConnectionAccounts(store: store, http: { _ in throw ConnectionFailure("Unexpected fixture network request") }, now: { self.clock })
    }

    private func credential(account: ConnectionAccount? = nil, expired: Bool = false) -> ConnectionAccounts.Credential {
        let account = account ?? .init(id: UUID(), provider: .google, title: "person@example.invalid", services: [.gmail])
        return .init(account: account, identity: "google:fixture-user",
            client: .init(id: "fixture.apps.googleusercontent.com", secret: "fixture-client", tokenEndpoint: ConnectionOAuth.googleToken),
            tokens: .init(access: "old-access", refresh: "old-refresh", expires: clock.addingTimeInterval(expired ? -1 : 3600),
                scope: "openid email https://www.googleapis.com/auth/gmail.readonly", userID: nil, workspaceID: nil, emailDomain: nil))
    }

    private static let authorize: ConnectionOAuth.Authorize = { build in
        let redirect = URL(string: "http://127.0.0.1:54321/oauth/callback")!
        let authorization = try await build(redirect)
        let state = URLComponents(url: authorization, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "state" }!.value!
        var callback = URLComponents(url: redirect, resolvingAgainstBaseURL: false)!
        callback.queryItems = [.init(name: "code", value: "fixture-code"), .init(name: "state", value: state)]
        return .init(redirect: redirect, url: callback.url!)
    }
}

private actor PolicyCredentials: ConnectionCredentialStore {
    private var data: Data?
    private var failing = false
    private var pausing = false
    private var pause: CheckedContinuation<Void, Never>?
    private var paused: CheckedContinuation<Void, Never>?
    init() {}
    init(stored: ConnectionAccounts.Stored) throws { data = try JSONEncoder().encode(stored) }
    func load() -> Data? { data }
    func failNext() { failing = true }
    func pauseNext() { pausing = true }
    func waitUntilPaused() async {
        if pause != nil { return }
        await withCheckedContinuation { paused = $0 }
    }
    func resume() { pause?.resume(); pause = nil }
    func save(_ data: Data) async throws {
        if pausing {
            pausing = false
            await withCheckedContinuation { pause = $0; paused?.resume(); paused = nil }
        }
        if failing { failing = false; throw ConnectionFailure("Fixture Keychain write failed") }
        self.data = data
    }
    func decoded() throws -> ConnectionAccounts.Stored { try JSONDecoder().decode(ConnectionAccounts.Stored.self, from: data!) }
}

private actor PolicyHTTP {
    private var pausing: Bool
    private var pause: CheckedContinuation<Void, Never>?
    private var paused: CheckedContinuation<Void, Never>?
    init(paused: Bool = false) { pausing = paused }
    nonisolated var http: ConnectionHTTP { { request in try await self.send(request) } }
    func waitUntilPaused() async {
        if pause != nil { return }
        await withCheckedContinuation { paused = $0 }
    }
    func resume() { pause?.resume(); pause = nil }
    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if pausing {
            pausing = false
            await withCheckedContinuation { pause = $0; paused?.resume(); paused = nil }
        }
        let reply: [String: Any]
        if request.url?.host == "oauth2.googleapis.com" {
            reply = ["access_token": "new-access", "refresh_token": "new-refresh", "expires_in": 3600,
                     "scope": "openid email https://www.googleapis.com/auth/gmail.readonly", "token_type": "Bearer"]
        } else { reply = ["sub": "fixture-user", "email": "person@example.invalid", "email_verified": true] }
        return (try JSONSerialization.data(withJSONObject: reply), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
