import XCTest
@testable import mnml

@MainActor
final class ConnectionAuthTests: XCTestCase {
    private nonisolated let clock = Date(timeIntervalSince1970: 1_800_000_000)
    private let desktop = Data(#"{"installed":{"client_id":"fixture.apps.googleusercontent.com","client_secret":"fixture-client"}}"#.utf8)

    func testPKCEAndFormEncoding() throws {
        XCTAssertEqual(ConnectionOAuth.PKCE.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let pkce = ConnectionOAuth.PKCE()
        XCTAssertEqual(pkce.verifier.count, 43)
        XCTAssertEqual(pkce.state.count, 43)
        XCTAssertNotEqual(pkce.verifier, pkce.state)
        XCTAssertFalse(pkce.challenge.contains("="))
        let encoded = ConnectionOAuth.form(["refresh_token": "a+b&c=é", "space": "one two"])
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "refresh_token=a%2Bb%26c%3D%C3%A9&space=one%20two")
        XCTAssertEqual(formValues(encoded)["refresh_token"], "a+b&c=é")
    }

    func testImportedCredentialsAreDesktopOnlyAndEndpointsAreFixed() throws {
        XCTAssertThrowsError(try ConnectionOAuth.GoogleClient.imported(Data(#"{"web":{"client_id":"x","client_secret":"x"}}"#.utf8)))
        XCTAssertThrowsError(try ConnectionOAuth.GoogleClient.imported(Data(#"{"installed":{"client_id":"https://evil.invalid","client_secret":"x"}}"#.utf8)))
        let input = Data(#"{"installed":{"client_id":"fixture.apps.googleusercontent.com","client_secret":"fixture-client","auth_uri":"https://evil.invalid"}}"#.utf8)
        let client = try ConnectionOAuth.GoogleClient.imported(input)
        let redirect = URL(string: "http://127.0.0.1:54321/oauth/callback")!
        let authorization = ConnectionOAuth.googleAuthorization(client: client, redirect: redirect, pkce: .init())
        XCTAssertEqual(authorization.host, "accounts.google.com")
        XCTAssertEqual(URLComponents(url: authorization, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "redirect_uri" }?.value,
                       redirect.absoluteString)
    }

    func testCallbackValidatesStateAndExactLoopback() throws {
        let redirect = URL(string: "http://127.0.0.1:54321/oauth/callback")!
        func callback(_ text: String) -> ConnectionOAuth.Callback { .init(redirect: redirect, url: URL(string: text)!) }
        XCTAssertEqual(try ConnectionOAuth.code(from: callback("http://127.0.0.1:54321/oauth/callback?state=expected&code=a%2Bb"), state: "expected"), "a+b")
        for text in ["http://127.0.0.1:54321/oauth/callback?state=wrong&code=a",
                     "http://127.0.0.1:54321/oauth/callback?state=expected&state=expected&code=a",
                     "http://127.0.0.1:54321/oauth/callback?state=expected&code=a&code=b",
                     "http://localhost:54321/oauth/callback?state=expected&code=a",
                     "http://127.0.0.1:54322/oauth/callback?state=expected&code=a",
                     "http://127.0.0.1:54321/other?state=expected&code=a"] {
            XCTAssertThrowsError(try ConnectionOAuth.code(from: callback(text), state: "expected"))
        }
        XCTAssertThrowsError(try ConnectionOAuth.code(from: callback("http://127.0.0.1:54321/oauth/callback?state=expected&error=access_denied"), state: "expected"))
    }

    func testOfficialHostsRejectCredentialForwardingTargets() async throws {
        for url in ["http://mcp.notion.com/token", "https://mcp.notion.com.evil.invalid/token",
                    "https://evil.invalid/token", "https://user:password@mcp.notion.com/token",
                    "https://mcp.notion.com:8443/token"] {
            XCTAssertFalse(ConnectionOAuth.official(URL(string: url)!, provider: .notion))
        }
        let fixture = AuthHTTP { request in
            if request.url!.path.contains("oauth-protected-resource") {
                return (200, ["resource": "https://mcp.notion.com", "authorization_servers": ["https://mcp.notion.com"]])
            }
            return (200, ["issuer": "https://mcp.notion.com", "authorization_endpoint": "https://mcp.notion.com/authorize",
                          "token_endpoint": "https://evil.invalid/token", "registration_endpoint": "https://mcp.notion.com/register"])
        }
        do { _ = try await ConnectionOAuth.discoverNotion(http: fixture.http); XCTFail("Untrusted endpoint accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("unsupported")) }
        let requests = await fixture.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.url?.host == "mcp.notion.com" })
    }

    func testGoogleConnectPersistsIdentityAndOnlyGrantedServices() async throws {
        let fixture = AuthHTTP { request in
            if request.url?.host == "oauth2.googleapis.com" {
                return (200, ["access_token": "fixture-access", "refresh_token": "fixture-refresh", "expires_in": 3600,
                              "scope": "openid email https://www.googleapis.com/auth/gmail.readonly", "token_type": "Bearer"])
            }
            return (200, ["sub": "fixture-google-user", "email": "person@example.invalid", "email_verified": true])
        }
        let store = MemoryCredentials()
        let model = ConnectionAccounts(store: store, http: fixture.http, authorize: Self.authorize, now: { self.clock })
        try await model.importGoogleCredentials(desktop)
        await model.connectGoogle()
        XCTAssertNil(model.error)
        XCTAssertFalse(model.busy)
        let account = try XCTUnwrap(model.accounts.first)
        XCTAssertEqual(account.title, "person@example.invalid")
        XCTAssertEqual(account.services, [.gmail])
        XCTAssertNil(model.account(for: .drive))
        let token = try await model.token(for: account.id)
        XCTAssertEqual(token, "fixture-access")
        let requests = await fixture.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(formValues(requests[0].httpBody!)["grant_type"], "authorization_code")
        XCTAssertNotNil(formValues(requests[0].httpBody!)["code_verifier"])
        let reloaded = ConnectionAccounts(store: store, http: fixture.http, authorize: Self.authorize, now: { self.clock })
        let reloadedToken = try await reloaded.token(for: account.id)
        XCTAssertEqual(reloadedToken, "fixture-access")
        XCTAssertEqual(reloaded.accounts, model.accounts)
    }

    func testGoogleRefreshPreservesMissingRefreshAndOriginalClient() async throws {
        let credential = credential(provider: .google)
        let store = try MemoryCredentials(stored: .init(credentials: [credential.account.id.uuidString: credential]))
        let fixture = AuthHTTP { _ in (200, ["access_token": "new-access", "expires_in": 3600]) }
        let model = ConnectionAccounts(store: store, http: fixture.http, now: { self.clock })
        try await model.importGoogleCredentials(Data(#"{"installed":{"client_id":"new.apps.googleusercontent.com","client_secret":"new-client"}}"#.utf8))
        let token = try await model.token(for: credential.account.id)
        XCTAssertEqual(token, "new-access")
        let saved = try await store.decoded()
        let refreshed = try XCTUnwrap(saved.credentials[credential.account.id.uuidString])
        XCTAssertEqual(refreshed.tokens.refresh, "fixture-refresh")
        XCTAssertEqual(refreshed.account.services, [.gmail])
        let requests = await fixture.requests
        XCTAssertEqual(formValues(requests[0].httpBody!)["client_id"], "fixture-client")
        XCTAssertEqual(formValues(requests[0].httpBody!)["refresh_token"], "fixture-refresh")
    }

    func testNotionRefreshRotationIsSingleFlightAndDurable() async throws {
        let credential = credential(provider: .notion)
        let store = try MemoryCredentials(stored: .init(credentials: [credential.account.id.uuidString: credential]))
        let fixture = AuthHTTP { _ in
            try await Task.sleep(for: .milliseconds(30))
            return (200, ["access_token": "rotated-access", "refresh_token": "rotated-refresh", "expires_in": 3600])
        }
        let model = ConnectionAccounts(store: store, http: fixture.http, now: { self.clock })
        async let one = model.token(for: credential.account.id)
        async let two = model.token(for: credential.account.id)
        let values = try await [one, two]
        XCTAssertEqual(values, ["rotated-access", "rotated-access"])
        let requests = await fixture.requests
        XCTAssertEqual(requests.count, 1)
        let saved = try await store.decoded()
        let refreshed = try XCTUnwrap(saved.credentials[credential.account.id.uuidString])
        XCTAssertEqual(refreshed.tokens.refresh, "rotated-refresh")
        XCTAssertEqual(refreshed.tokens.workspaceID, "fixture-workspace")
        XCTAssertEqual(refreshed.tokens.userID, "fixture-user")
        XCTAssertEqual(refreshed.tokens.emailDomain, "example.invalid")
        XCTAssertEqual(formValues(requests[0].httpBody!)["resource"], "https://mcp.notion.com")
    }

    func testInvalidGrantClearsCredentialsWithoutRetryOrSecretInError() async throws {
        let credential = credential(provider: .notion)
        let store = try MemoryCredentials(stored: .init(credentials: [credential.account.id.uuidString: credential]))
        let fixture = AuthHTTP { _ in (400, ["error": "invalid_grant", "error_description": "fixture-refresh must never be shown"]) }
        let model = ConnectionAccounts(store: store, http: fixture.http, now: { self.clock })
        do { _ = try await model.token(for: credential.account.id); XCTFail("Revoked grant accepted") }
        catch { XCTAssertFalse(error.localizedDescription.contains("fixture-refresh")) }
        XCTAssertTrue(model.accounts.isEmpty)
        let saved = try await store.decoded()
        XCTAssertTrue(saved.credentials.isEmpty)
        do { _ = try await model.token(for: credential.account.id); XCTFail("Revoked connection retried") } catch {}
        let requests = await fixture.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testNotionMissingRotatedTokenEndsTheGrant() async throws {
        let credential = credential(provider: .notion)
        let store = try MemoryCredentials(stored: .init(credentials: [credential.account.id.uuidString: credential]))
        let fixture = AuthHTTP { _ in (200, ["access_token": "rotated-access", "expires_in": 3600]) }
        let model = ConnectionAccounts(store: store, http: fixture.http, now: { self.clock })
        do { _ = try await model.token(for: credential.account.id); XCTFail("Retired refresh token retained") } catch {}
        XCTAssertTrue(model.accounts.isEmpty)
        let saved = try await store.decoded()
        XCTAssertTrue(saved.credentials.isEmpty)
    }

    func testNotionConnectDiscoversRegistersAndRetainsIdentity() async throws {
        let fixture = AuthHTTP { request in
            switch request.url!.path {
            case "/.well-known/oauth-protected-resource":
                return (200, ["resource": "https://mcp.notion.com", "authorization_servers": ["https://mcp.notion.com"]])
            case "/.well-known/oauth-authorization-server":
                return (200, ["issuer": "https://mcp.notion.com", "authorization_endpoint": "https://mcp.notion.com/authorize",
                              "token_endpoint": "https://mcp.notion.com/token", "registration_endpoint": "https://mcp.notion.com/register"])
            case "/register": return (201, ["client_id": "fixture-notion-client"])
            default: return (200, ["access_token": "fixture-access", "refresh_token": "fixture-refresh", "expires_in": 3600,
                                  "user_id": "fixture-user", "workspace_id": "fixture-workspace", "email_domain": "example.invalid"])
            }
        }
        let store = MemoryCredentials()
        let model = ConnectionAccounts(store: store, http: fixture.http, authorize: Self.authorize, now: { self.clock })
        await model.connectNotion()
        XCTAssertNil(model.error)
        XCTAssertEqual(model.accounts.first?.provider, .notion)
        XCTAssertEqual(model.accounts.first?.services, [.notion])
        let saved = try await store.decoded()
        let grant = try XCTUnwrap(saved.credentials.values.first)
        XCTAssertEqual(grant.identity, "notion:fixture-workspace:fixture-user")
        XCTAssertEqual(grant.client.id, "fixture-notion-client")
        let requests = await fixture.requests
        XCTAssertEqual(requests.count, 4)
        let registration = try JSONSerialization.jsonObject(with: requests[2].httpBody!) as! [String: Any]
        XCTAssertEqual(registration["token_endpoint_auth_method"] as? String, "none")
        XCTAssertEqual(registration["redirect_uris"] as? [String], ["http://127.0.0.1:54321/oauth/callback"])
    }

    func testTemporaryRefreshFailureKeepsGrantAndSanitizesError() async throws {
        let credential = credential(provider: .google)
        let store = try MemoryCredentials(stored: .init(credentials: [credential.account.id.uuidString: credential]))
        let fixture = AuthHTTP { _ in (503, ["error_description": "fixture-refresh"]) }
        let model = ConnectionAccounts(store: store, http: fixture.http, now: { self.clock })
        do { _ = try await model.token(for: credential.account.id); XCTFail("Transient failure accepted") }
        catch { XCTAssertFalse(error.localizedDescription.contains("fixture-refresh")) }
        XCTAssertEqual(model.accounts.count, 1)
        let saved = try await store.decoded()
        XCTAssertEqual(saved.credentials[credential.account.id.uuidString]?.tokens.refresh, "fixture-refresh")
    }

    func testDisconnectCannotBeUndoneByAnInflightRefresh() async throws {
        let credential = credential(provider: .notion)
        let store = try MemoryCredentials(stored: .init(credentials: [credential.account.id.uuidString: credential]))
        let fixture = AuthHTTP { _ in
            try await Task.sleep(for: .milliseconds(100))
            return (200, ["access_token": "rotated-access", "refresh_token": "rotated-refresh", "expires_in": 3600])
        }
        let model = ConnectionAccounts(store: store, http: fixture.http, now: { self.clock })
        let refreshing = Task { try await model.token(for: credential.account.id) }
        await fixture.waitForRequest()
        await model.disconnect(credential.account.id)
        do { _ = try await refreshing.value; XCTFail("Disconnected account returned a token") } catch {}
        XCTAssertTrue(model.accounts.isEmpty)
        let saved = try await store.decoded()
        XCTAssertTrue(saved.credentials.isEmpty)
    }

    func testCancelAuthorizationClearsBusyWithoutCreatingAnAccount() async throws {
        let fixture = AuthHTTP { _ in XCTFail("Cancelled authorization called the token endpoint"); return (500, [:]) }
        let model = ConnectionAccounts(store: MemoryCredentials(), http: fixture.http, authorize: { _ in
            try await Task.sleep(for: .seconds(60))
            throw CancellationError()
        }, now: { self.clock })
        try await model.importGoogleCredentials(desktop)
        let connecting = Task { await model.connectGoogle() }
        await Task.yield()
        XCTAssertTrue(model.busy)
        model.cancelAuthorization()
        await connecting.value
        XCTAssertFalse(model.busy)
        XCTAssertTrue(model.accounts.isEmpty)
        XCTAssertNil(model.error)
    }

    private func credential(provider: ConnectionProvider) -> ConnectionAccounts.Credential {
        let account = ConnectionAccount(id: UUID(), provider: provider, title: "Fixture", services: provider == .google ? [.gmail] : [.notion])
        return .init(account: account, identity: provider.rawValue + ":fixture",
                     client: .init(id: "fixture-client", secret: nil, tokenEndpoint: provider == .google ? ConnectionOAuth.googleToken : URL(string: "https://mcp.notion.com/token")!),
                     tokens: .init(access: "expired-access", refresh: "fixture-refresh", expires: clock.addingTimeInterval(-1),
                                   scope: "https://www.googleapis.com/auth/gmail.readonly", userID: "fixture-user",
                                   workspaceID: "fixture-workspace", emailDomain: "example.invalid"))
    }

    private static let authorize: ConnectionOAuth.Authorize = { build in
        let redirect = URL(string: "http://127.0.0.1:54321/oauth/callback")!
        let authorization = try await build(redirect)
        let state = URLComponents(url: authorization, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "state" }!.value!
        var callback = URLComponents(url: redirect, resolvingAgainstBaseURL: false)!
        callback.queryItems = [.init(name: "code", value: "fixture-code"), .init(name: "state", value: state)]
        return .init(redirect: redirect, url: callback.url!)
    }

    private func formValues(_ data: Data) -> [String: String] {
        let items = URLComponents(string: "https://fixture.invalid/?" + String(decoding: data, as: UTF8.self))!.queryItems!
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }
}

private actor MemoryCredentials: ConnectionCredentialStore {
    private var data: Data?
    init() {}
    init(stored: ConnectionAccounts.Stored) throws { data = try JSONEncoder().encode(stored) }
    func load() -> Data? { data }
    func save(_ data: Data) { self.data = data }
    func decoded() throws -> ConnectionAccounts.Stored { try JSONDecoder().decode(ConnectionAccounts.Stored.self, from: data!) }
}

private actor AuthHTTP {
    typealias Reply = @Sendable (URLRequest) async throws -> (Int, [String: Any])
    private let reply: Reply
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var requests: [URLRequest] = []
    init(_ reply: @escaping Reply) { self.reply = reply }
    nonisolated var http: ConnectionHTTP { { request in try await self.send(request) } }
    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request); waiter?.resume(); waiter = nil
        let (status, json) = try await reply(request)
        return (try JSONSerialization.data(withJSONObject: json), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    func waitForRequest() async {
        if !requests.isEmpty { return }
        await withCheckedContinuation { waiter = $0 }
    }
}
