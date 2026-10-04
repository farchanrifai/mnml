import XCTest
@testable import mnml

@MainActor
final class ConnectionWritePolicyTests: XCTestCase {
    private nonisolated let clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var readScope: String { ConnectionOAuth.googleScopes.joined(separator: " ") }
    private var writeScope: String { ConnectionOAuth.googleWriteScopes.joined(separator: " ") }

    func testLegacyAccountsAndSpacePoliciesRemainReadOnly() async throws {
        let data = Data(#"{"id":"00000000-0000-0000-0000-000000000077","provider":"google","title":"person@example.invalid","services":["drive"]}"#.utf8)
        let account = try JSONDecoder().decode(ConnectionAccount.self, from: data)
        XCTAssertNil(account.writableServices)
        XCTAssertFalse(account.canWrite(.drive))
        let policy = try JSONDecoder().decode(ConnectionSpacePolicy.self,
            from: Data(#"{"accountIDs":["00000000-0000-0000-0000-000000000077"],"automatic":true}"#.utf8))
        XCTAssertNil(policy.writeAccountIDs)
        let grant = credential(account: account)
        let store = try WritePolicyCredentials(stored: stored(grant))
        let model = model(store)
        try await model.waitUntilReady()
        XCTAssertEqual(model.eligible(in: Space.firstID).map(\.id), [account.id])
        XCTAssertFalse(model.writesEnabled(account: account.id, in: Space.firstID))
        XCTAssertFalse(model.writesEnabled(account: account.id, in: UUID()))
    }

    func testSpaceWritesRequireBothAssignmentAndProviderCapability() async throws {
        let reader = credential(), writer = credential(writes: true), space = UUID()
        let store = try WritePolicyCredentials(stored: .init(credentials: [reader.account.id.uuidString: reader, writer.account.id.uuidString: writer],
            spacePolicies: [space.uuidString: .init(accountIDs: [reader.account.id], writeAccountIDs: [reader.account.id, writer.account.id])]))
        let model = model(store)
        try await model.waitUntilReady()
        XCTAssertFalse(model.writesEnabled(account: reader.account.id, in: space))
        XCTAssertFalse(model.writesEnabled(account: writer.account.id, in: space))
        await model.setWritesEnabled(account: reader.account.id, in: space, enabled: true)
        XCTAssertNotNil(model.error)
        await model.setWritesEnabled(account: writer.account.id, in: space, enabled: true)
        XCTAssertNotNil(model.error)
        await model.setEnabled(account: writer.account.id, in: space, enabled: true)
        await model.setWritesEnabled(account: writer.account.id, in: space, enabled: true)
        XCTAssertNil(model.error)
        XCTAssertTrue(model.writesEnabled(account: writer.account.id, in: space))
        XCTAssertFalse(model.writesEnabled(account: writer.account.id, in: UUID()))
    }

    func testWritableGrantStartsOffInEachSpaceUntilExplicitlyEnabled() async throws {
        let grant = credential(writes: true), home = UUID(), work = UUID()
        let store = try WritePolicyCredentials(stored: stored(grant, policies: [
            home.uuidString: .init(accountIDs: [grant.account.id]), work.uuidString: .init(accountIDs: [grant.account.id])]))
        let model = model(store)
        try await model.waitUntilReady()
        XCTAssertFalse(model.writesEnabled(account: grant.account.id, in: home))
        XCTAssertFalse(model.writesEnabled(account: grant.account.id, in: work))
        await model.setWritesEnabled(account: grant.account.id, in: work, enabled: true)
        XCTAssertNil(model.error)
        XCTAssertTrue(model.writesEnabled(account: grant.account.id, in: work))
        XCTAssertFalse(model.writesEnabled(account: grant.account.id, in: home))
        let restored = self.model(store)
        try await restored.waitUntilReady()
        XCTAssertTrue(restored.writesEnabled(account: grant.account.id, in: work))
        XCTAssertFalse(restored.writesEnabled(account: grant.account.id, in: home))
    }

    func testGoogleWriteUpgradePreservesIdentityLabelAndEnablesOnlyCurrentSpace() async throws {
        let grant = credential(label: "Personal account"), home = UUID(), work = UUID()
        let store = try WritePolicyCredentials(stored: stored(grant, policies: [
            home.uuidString: .init(accountIDs: [grant.account.id]), work.uuidString: .init(accountIDs: [grant.account.id])]))
        let http = WritePolicyHTTP(scope: writeScope)
        let model = model(store, http: http)
        await model.enableWrites(account: grant.account.id, in: work)
        XCTAssertNil(model.error)
        XCTAssertFalse(model.busy)
        let account = try XCTUnwrap(model.accounts.first)
        XCTAssertEqual(model.accounts.count, 1)
        XCTAssertEqual(account.id, grant.account.id)
        XCTAssertEqual(account.title, grant.account.title)
        XCTAssertEqual(account.label, "Personal account")
        XCTAssertEqual(account.services, [.gmail, .calendar, .drive])
        XCTAssertEqual(account.writableServices, [.drive])
        XCTAssertTrue(model.writesEnabled(account: account.id, in: work))
        XCTAssertFalse(model.writesEnabled(account: account.id, in: home))
        XCTAssertTrue(model.eligible(in: Space.firstID).isEmpty)
        let saved = try await store.decoded()
        let upgraded = try XCTUnwrap(saved.credentials[account.id.uuidString])
        XCTAssertEqual(upgraded.identity, grant.identity)
        XCTAssertEqual(upgraded.tokens.access, "upgraded-access")
        XCTAssertEqual(upgraded.tokens.refresh, "upgraded-refresh")
        XCTAssertEqual(saved.spacePolicies?[home.uuidString]?.writeAccountIDs, nil)
        XCTAssertEqual(saved.spacePolicies?[work.uuidString]?.writeAccountIDs, [account.id])
    }

    func testWrongGoogleIdentityOrDeniedDriveScopeKeepsOriginalGrant() async throws {
        for wrongIdentity in [false, true] {
            let grant = credential(label: "Work account"), space = UUID()
            let original = stored(grant, policies: [space.uuidString: .init(accountIDs: [grant.account.id])])
            let store = try WritePolicyCredentials(stored: original)
            let http = WritePolicyHTTP(scope: wrongIdentity ? writeScope : readScope,
                identity: wrongIdentity ? "different-user" : "fixture-user")
            let model = model(store, http: http)
            await model.enableWrites(account: grant.account.id, in: space)
            XCTAssertNotNil(model.error)
            XCTAssertEqual(model.accounts, [grant.account])
            XCTAssertFalse(model.writesEnabled(account: grant.account.id, in: space))
            let saved = try await store.decoded()
            let unchanged = try XCTUnwrap(saved.credentials[grant.account.id.uuidString])
            XCTAssertEqual(unchanged.tokens, grant.tokens)
            XCTAssertEqual(unchanged.identity, grant.identity)
            XCTAssertEqual(unchanged.revision, grant.revision)
            XCTAssertEqual(saved.spacePolicies, original.spacePolicies)
            XCTAssertEqual(saved.credentials.count, 1)
        }
    }

    func testRefreshScopeShrinkClearsWriteCapabilityWithoutLosingReadAccess() async throws {
        let grant = credential(writes: true, expired: true), space = UUID()
        let store = try WritePolicyCredentials(stored: stored(grant, policies: [
            space.uuidString: .init(accountIDs: [grant.account.id], writeAccountIDs: [grant.account.id])]))
        let http = WritePolicyHTTP(scope: readScope)
        let model = model(store, http: http)
        try await model.waitUntilReady()
        XCTAssertTrue(model.writesEnabled(account: grant.account.id, in: space))
        let token = try await model.token(for: grant.account.id)
        XCTAssertEqual(token, "upgraded-access")
        XCTAssertFalse(model.accounts[0].canWrite(.drive))
        XCTAssertFalse(model.writesEnabled(account: grant.account.id, in: space))
        XCTAssertEqual(model.accounts[0].services, [.gmail, .calendar, .drive])
        XCTAssertEqual(model.eligible(in: space).map(\.id), [grant.account.id])
        let saved = try await store.decoded()
        XCTAssertEqual(saved.credentials[grant.account.id.uuidString]?.account.writableServices, [])
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(Self.form(requests[0].httpBody!)["grant_type"], "refresh_token")
    }

    func testDisablingSpaceAccountRemovesLocalWritePermissionAndDoesNotRestoreItOnReenable() async throws {
        let grant = credential(writes: true), home = UUID(), work = UUID()
        let policy = ConnectionSpacePolicy(accountIDs: [grant.account.id], writeAccountIDs: [grant.account.id])
        let store = try WritePolicyCredentials(stored: stored(grant, policies: [home.uuidString: policy, work.uuidString: policy]))
        let model = model(store)
        await model.setEnabled(account: grant.account.id, in: work, enabled: false)
        XCTAssertNil(model.error)
        XCTAssertFalse(model.writesEnabled(account: grant.account.id, in: work))
        XCTAssertTrue(model.writesEnabled(account: grant.account.id, in: home))
        XCTAssertEqual(model.policy(for: work).writeAccountIDs, [])
        await model.setEnabled(account: grant.account.id, in: work, enabled: true)
        XCTAssertFalse(model.writesEnabled(account: grant.account.id, in: work))
        XCTAssertTrue(model.accounts[0].canWrite(.drive))
        let saved = try await store.decoded()
        XCTAssertEqual(saved.spacePolicies?[work.uuidString]?.writeAccountIDs, [])
    }

    func testNotionEnableWritesIsLocalOptInForOnlyOneAssignedSpace() async throws {
        let grant = credential(provider: .notion), home = UUID(), work = UUID()
        let store = try WritePolicyCredentials(stored: stored(grant, policies: [
            home.uuidString: .init(accountIDs: [grant.account.id]), work.uuidString: .init(accountIDs: [grant.account.id])]))
        let model = model(store)
        await model.enableWrites(account: grant.account.id, in: UUID())
        XCTAssertNotNil(model.error)
        await model.enableWrites(account: grant.account.id, in: work)
        XCTAssertNil(model.error)
        XCTAssertTrue(model.accounts[0].canWrite(.notion))
        XCTAssertTrue(model.writesEnabled(account: grant.account.id, in: work))
        XCTAssertFalse(model.writesEnabled(account: grant.account.id, in: home))
        let saved = try await store.decoded()
        XCTAssertEqual(saved.credentials[grant.account.id.uuidString]?.tokens, grant.tokens)
    }

    func testFailedWritePolicyNotionEnableAndGoogleUpgradeRollBackDurably() async throws {
        let writer = credential(writes: true), space = UUID()
        let original = stored(writer, policies: [space.uuidString: .init(accountIDs: [writer.account.id])])
        let store = try WritePolicyCredentials(stored: original)
        let model = model(store)
        try await model.waitUntilReady()
        await store.failNext()
        await model.setWritesEnabled(account: writer.account.id, in: space, enabled: true)
        XCTAssertNotNil(model.error)
        XCTAssertFalse(model.writesEnabled(account: writer.account.id, in: space))
        XCTAssertEqual(model.policies, original.spacePolicies)
        let unchangedPolicy = try await store.decoded()
        XCTAssertEqual(unchangedPolicy.spacePolicies, original.spacePolicies)

        for provider in [ConnectionProvider.google, .notion] {
            let grant = credential(provider: provider, label: "Work account")
            let original = stored(grant, policies: [space.uuidString: .init(accountIDs: [grant.account.id])])
            let store = try WritePolicyCredentials(stored: original)
            let model = self.model(store, http: WritePolicyHTTP(scope: writeScope))
            try await model.waitUntilReady()
            await store.failNext()
            await model.enableWrites(account: grant.account.id, in: space)
            XCTAssertNotNil(model.error)
            XCTAssertEqual(model.accounts, [grant.account])
            XCTAssertEqual(model.policies, original.spacePolicies)
            XCTAssertFalse(model.writesEnabled(account: grant.account.id, in: space))
            let saved = try await store.decoded()
            XCTAssertEqual(saved.credentials[grant.account.id.uuidString]?.tokens, grant.tokens)
            XCTAssertEqual(saved.credentials[grant.account.id.uuidString]?.account, grant.account)
            XCTAssertEqual(saved.spacePolicies, original.spacePolicies)
        }
    }

    func testGoogleWriteAuthorizationAddsDriveOnlyAndKeepsOtherServicesReadOnly() {
        let client = ConnectionOAuth.GoogleClient(id: "fixture.apps.googleusercontent.com", secret: "fixture-client")
        let redirect = URL(string: "http://127.0.0.1:54321/oauth/callback")!
        let read = ConnectionOAuth.googleAuthorization(client: client, redirect: redirect, pkce: .init())
        let write = ConnectionOAuth.googleAuthorization(client: client, redirect: redirect, pkce: .init(), writing: true, loginHint: "person@example.invalid")
        let readItems = URLComponents(url: read, resolvingAgainstBaseURL: false)!.queryItems!
        let writeItems = URLComponents(url: write, resolvingAgainstBaseURL: false)!.queryItems!
        let readScopes = Set(readItems.first { $0.name == "scope" }!.value!.split(separator: " ").map(String.init))
        let writeScopes = Set(writeItems.first { $0.name == "scope" }!.value!.split(separator: " ").map(String.init))
        XCTAssertFalse(readScopes.contains(ConnectionOAuth.googleDriveWriteScope))
        XCTAssertEqual(writeScopes.subtracting(readScopes), [ConnectionOAuth.googleDriveWriteScope])
        XCTAssertEqual(readScopes.subtracting(writeScopes), ["https://www.googleapis.com/auth/drive.readonly"])
        XCTAssertTrue(writeScopes.contains("https://www.googleapis.com/auth/gmail.readonly"))
        XCTAssertTrue(writeScopes.contains("https://www.googleapis.com/auth/calendar.events.readonly"))
        XCTAssertEqual(writeItems.first { $0.name == "login_hint" }?.value, "person@example.invalid")
        XCTAssertEqual(ConnectionOAuth.googleWritableServices("https://www.googleapis.com/auth/drive.file"), [])
    }

    private func credential(provider: ConnectionProvider = .google, writes: Bool = false, expired: Bool = false,
                            label: String? = nil, account: ConnectionAccount? = nil) -> ConnectionAccounts.Credential {
        let account = account ?? ConnectionAccount(id: UUID(), provider: provider,
            title: provider == .google ? "person@example.invalid" : "Notion workspace",
            services: provider == .google ? [.gmail, .calendar, .drive] : [.notion], label: label,
            writableServices: writes ? [provider == .google ? .drive : .notion] : nil)
        return .init(account: account, identity: provider == .google ? "google:fixture-user" : "notion:fixture-workspace:fixture-user",
            client: .init(id: "fixture.apps.googleusercontent.com", secret: "fixture-client", tokenEndpoint: provider == .google ? ConnectionOAuth.googleToken : URL(string: "https://mcp.notion.com/token")!),
            tokens: .init(access: "original-access", refresh: "original-refresh", expires: clock.addingTimeInterval(expired ? -1 : 3600),
                scope: provider == .google ? (writes ? writeScope : readScope) : "default",
                userID: provider == .notion ? "fixture-user" : nil, workspaceID: provider == .notion ? "fixture-workspace" : nil, emailDomain: nil))
    }
    private func stored(_ grant: ConnectionAccounts.Credential, policies: [String: ConnectionSpacePolicy]? = nil) -> ConnectionAccounts.Stored {
        .init(google: .init(id: "fixture.apps.googleusercontent.com", secret: "fixture-client"),
            credentials: [grant.account.id.uuidString: grant], spacePolicies: policies)
    }
    private func model(_ store: WritePolicyCredentials, http: WritePolicyHTTP? = nil) -> ConnectionAccounts {
        let transport: ConnectionHTTP = { request in
            guard let http else { throw ConnectionFailure("Unexpected fixture network request") }
            return try await http.http(request)
        }
        return ConnectionAccounts(store: store, http: transport, authorize: Self.authorize, now: { self.clock })
    }
    private static let authorize: ConnectionOAuth.Authorize = { build in
        let redirect = URL(string: "http://127.0.0.1:54321/oauth/callback")!
        let authorization = try await build(redirect)
        let items = URLComponents(url: authorization, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.first { $0.name == "login_hint" }?.value, "person@example.invalid")
        XCTAssertTrue(items.first { $0.name == "scope" }!.value!.split(separator: " ").contains(Substring(ConnectionOAuth.googleDriveWriteScope)))
        let state = items.first { $0.name == "state" }!.value!
        var callback = URLComponents(url: redirect, resolvingAgainstBaseURL: false)!
        callback.queryItems = [.init(name: "code", value: "fixture-code"), .init(name: "state", value: state)]
        return .init(redirect: redirect, url: callback.url!)
    }
    private static func form(_ data: Data) -> [String: String] {
        let text = String(decoding: data, as: UTF8.self)
        return Dictionary(uniqueKeysWithValues: text.split(separator: "&").map {
            let item = $0.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return (String(item[0]).removingPercentEncoding!, String(item[1]).removingPercentEncoding!)
        })
    }
}

private actor WritePolicyCredentials: ConnectionCredentialStore {
    private var data: Data
    private var failing = false
    init(stored: ConnectionAccounts.Stored) throws { data = try JSONEncoder().encode(stored) }
    func load() -> Data? { data }
    func failNext() { failing = true }
    func save(_ data: Data) throws {
        if failing { failing = false; throw ConnectionFailure("Fixture Keychain write failed") }
        self.data = data
    }
    func decoded() throws -> ConnectionAccounts.Stored { try JSONDecoder().decode(ConnectionAccounts.Stored.self, from: data) }
}

private actor WritePolicyHTTP {
    var requests: [URLRequest] = []
    let scope: String
    let identity: String
    init(scope: String, identity: String = "fixture-user") { self.scope = scope; self.identity = identity }
    nonisolated var http: ConnectionHTTP { { request in try await self.send(request) } }
    private func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response: [String: Any]
        switch request.url?.host {
        case "oauth2.googleapis.com": response = ["access_token": "upgraded-access", "refresh_token": "upgraded-refresh", "expires_in": 3600, "scope": scope, "token_type": "Bearer"]
        case "openidconnect.googleapis.com": response = ["sub": identity, "email": "person@example.invalid", "email_verified": true]
        default: throw ConnectionFailure("Unexpected fixture network request")
        }
        return (try JSONSerialization.data(withJSONObject: response), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
