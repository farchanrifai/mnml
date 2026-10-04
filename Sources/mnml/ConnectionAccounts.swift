import Foundation
import Combine
import Security

protocol ConnectionCredentialStore: Sendable {
    func load() async throws -> Data?
    func save(_ data: Data) async throws
}

/// Actor isolation keeps blocking Security calls off the UI actor. Updating one
/// item atomically also preserves a rotated refresh token together with its
/// access token/client credentials; there is never a delete-then-add gap.
actor ConnectionKeychain: ConnectionCredentialStore {
    private let service: String
    init(world: String? = Store.world) {
        service = "com.farchan.mnml.connections" + (world.map { ".world-" + $0 } ?? "")
    }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: "accounts"]
    }
    func load() throws -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw ConnectionFailure("Connections could not be read from Keychain (\(status)).")
        }
        return data
    }
    func save(_ data: Data) throws {
        let attributes = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "mnml — account connections"
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ConnectionFailure("Connections could not be saved to Keychain (\(status)).") }
    }
}

/// Disposable native UI fixtures stay in memory and cannot alter Keychain.
private actor ConnectionPreviewCredentials: ConnectionCredentialStore {
    private var data: Data
    init(_ data: Data) { self.data = data }
    func load() -> Data? { data }
    func save(_ data: Data) { self.data = data }
}

@MainActor
final class ConnectionAccounts: ObservableObject {
    static let shared = ConnectionAccounts(store: sharedStore())
    private static func sharedStore() -> any ConnectionCredentialStore {
        if Store.testing, let path = ProcessInfo.processInfo.environment["MNML_CONNECTION_FIXTURE"] {
            let file = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
            let folder = URL(fileURLWithPath: "/private/tmp", isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
            if file.path.hasPrefix(folder.path + "/"),
               let properties = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
               properties.isRegularFile == true, let size = properties.fileSize, size <= 4_194_304,
               let data = try? Data(contentsOf: file), data.count <= 4_194_304 {
                return ConnectionPreviewCredentials(data)
            }
        }
        return ConnectionKeychain()
    }
    @Published private(set) var accounts: [ConnectionAccount] = []
    @Published private(set) var policies: [String: ConnectionSpacePolicy] = [:]
    @Published private(set) var busy = false
    @Published var error: String?
    @Published private(set) var googleConfigured = false
    /// Empty accounts during initial Keychain loading are not authoritative.
    /// Consumers may prune restored selections only after this becomes true.
    @Published private(set) var loaded = false

    struct Credential: Codable, Sendable {
        var account: ConnectionAccount
        var identity: String
        var client: ConnectionOAuth.Client
        var tokens: ConnectionOAuth.Tokens
        var revision = UUID()
    }
    struct Stored: Codable, Sendable {
        var google: ConnectionOAuth.GoogleClient?
        var credentials: [String: Credential] = [:]
        var spacePolicies: [String: ConnectionSpacePolicy]? = nil
    }
    private struct Refresh {
        var id = UUID()
        var task: Task<String, Error>
    }
    private var stored = Stored()
    private var loading: Task<Stored, Error>?
    private var authorization: Task<Void, Error>?
    private var authorizationID: UUID?
    private var refreshes: [UUID: Refresh] = [:]
    private var writing = false
    private var writers: [CheckedContinuation<Void, Never>] = []
    private let store: any ConnectionCredentialStore
    private let http: ConnectionHTTP
    private let browser = ConnectionOAuth.Browser()
    private let injectedAuthorize: ConnectionOAuth.Authorize?
    private let now: @Sendable () -> Date

    init(store: any ConnectionCredentialStore = ConnectionKeychain(), http: @escaping ConnectionHTTP = ConnectionOAuth.http,
         authorize: ConnectionOAuth.Authorize? = nil, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store; self.http = http; injectedAuthorize = authorize; self.now = now
        loading = Task {
            guard let data = try await store.load() else { return Stored() }
            guard data.count <= 4_194_304 else { throw ConnectionFailure("Saved account credentials are too large to load.") }
            do { return try JSONDecoder().decode(Stored.self, from: data) }
            catch { throw ConnectionFailure("Saved account credentials could not be read. Reconnect your accounts.") }
        }
        Task { [weak self] in
            do { try await self?.ready() }
            catch { self?.error = Self.message(error) }
        }
    }

    private func ready() async throws {
        guard !loaded else { return }
        guard let loading else { throw ConnectionFailure("Account credentials could not be loaded.") }
        let result = try await loading.value
        // Multiple callers can wait on initial load. Only the first publishes it.
        guard !loaded else { return }
        stored = result
        // Before space assignments existed, connections belonged to the
        // original space. New spaces start empty instead of inheriting access.
        if stored.spacePolicies == nil {
            stored.spacePolicies = [Space.firstID.uuidString: .init(accountIDs: result.credentials.values.map(\.account.id).sorted { $0.uuidString < $1.uuidString })]
        }
        self.loading = nil; publish(); loaded = true
    }

    func waitUntilReady() async throws { try await ready() }

    private func publish() {
        let nextAccounts = stored.credentials.values.map(\.account).sorted {
            if $0.provider != $1.provider { return $0.provider.rawValue < $1.provider.rawValue }
            let order = $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }
        let nextPolicies = stored.spacePolicies ?? [:]
        let nextConfigured = stored.google != nil
        // A token refresh changes credentials but usually no UI metadata.
        // Avoid waking every chat or invalidating warm workers for that case.
        if accounts != nextAccounts { accounts = nextAccounts }
        if policies != nextPolicies { policies = nextPolicies }
        if googleConfigured != nextConfigured { googleConfigured = nextConfigured }
    }

    /// Persist candidate state before publishing it. Serializing this region
    /// protects account edits and rotated tokens from overwriting one another
    /// while the Keychain actor is saving; a failed edit leaves grants intact.
    private func update(_ change: (inout Stored) throws -> Void,
                        onFailure: ((inout Stored) -> Void)? = nil) async throws {
        if writing { await withCheckedContinuation { writers.append($0) } }
        else { writing = true }
        defer {
            if writers.isEmpty { writing = false }
            else { writers.removeFirst().resume() }
        }
        try Task.checkCancellation()
        var candidate = stored
        try change(&candidate)
        do {
            try await store.save(JSONEncoder().encode(candidate))
            stored = candidate; publish()
        } catch {
            // A failed token rotation cannot retain a potentially retired
            // grant. Ordinary configuration changes need no failure action.
            if let onFailure { onFailure(&stored); publish() }
            throw error
        }
    }

    func account(for service: ConnectionService) -> ConnectionAccount? {
        accounts.first { $0.services.contains(service) }
    }

    func policy(for space: UUID) -> ConnectionSpacePolicy {
        policies[space.uuidString] ?? .init(accountIDs: [])
    }

    func eligible(in space: UUID) -> [ConnectionAccount] {
        let enabled = Set(policy(for: space).accountIDs)
        return accounts.filter { enabled.contains($0.id) }
    }

    func selections(in space: UUID) -> [ConnectionSelection] {
        eligible(in: space).flatMap { account in
            ConnectionService.allCases.filter { account.services.contains($0) }.map {
                .init(service: $0, accountID: account.id)
            }
        }
    }

    func writesEnabled(account id: UUID, in space: UUID) -> Bool {
        let policy = policy(for: space)
        guard policy.accountIDs.contains(id), policy.writeAccountIDs?.contains(id) == true,
              let account = accounts.first(where: { $0.id == id }) else { return false }
        return account.canWrite(account.provider == .google ? .drive : .notion)
    }

    func setWritesEnabled(account id: UUID, in space: UUID, enabled: Bool) async {
        do {
            try await ready()
            try await update { next in
                guard let account = next.credentials[id.uuidString]?.account else { throw ConnectionFailure("This account is no longer connected.") }
                var policy = next.spacePolicies?[space.uuidString] ?? .init(accountIDs: [])
                guard !enabled || (policy.accountIDs.contains(id) && account.canWrite(account.provider == .google ? .drive : .notion)) else {
                    throw ConnectionFailure("Enable this account and its write permission first.")
                }
                var writes = policy.writeAccountIDs ?? []
                writes.removeAll { $0 == id }; if enabled { writes.append(id) }
                policy.writeAccountIDs = writes
                next.spacePolicies?[space.uuidString] = policy
            }
            error = nil
        } catch { self.error = Self.message(error) }
    }

    func enableWrites(account id: UUID, in space: UUID) async {
        do {
            try await ready()
            guard let credential = stored.credentials[id.uuidString], policy(for: space).accountIDs.contains(id) else {
                throw ConnectionFailure("Enable this account in the current Space first.")
            }
            if credential.account.provider == .google {
                await connect(.google, in: space, writing: true, expectedAccount: id)
            } else {
                try await update { next in
                    guard next.credentials[id.uuidString]?.revision == credential.revision else { throw CancellationError() }
                    next.credentials[id.uuidString]?.account.writableServices = [.notion]
                    var policy = next.spacePolicies?[space.uuidString] ?? .init(accountIDs: [])
                    guard policy.accountIDs.contains(id) else { throw CancellationError() }
                    var writes = policy.writeAccountIDs ?? []
                    if !writes.contains(id) { writes.append(id) }; policy.writeAccountIDs = writes
                    next.spacePolicies?[space.uuidString] = policy
                }
                error = nil
            }
        } catch { self.error = Self.message(error) }
    }

    func rename(_ id: UUID, label: String) async {
        do {
            try await ready()
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = trimmed.isEmpty ? nil : String(trimmed.prefix(60))
            try await update { next in
                guard next.credentials[id.uuidString] != nil else { throw ConnectionFailure("This account is no longer connected.") }
                next.credentials[id.uuidString]?.account.label = name
            }
            error = nil
        } catch { self.error = Self.message(error) }
    }

    func setEnabled(account id: UUID, in space: UUID, enabled: Bool) async {
        do {
            try await ready()
            try await update { next in
                guard next.credentials[id.uuidString] != nil else { throw ConnectionFailure("This account is no longer connected.") }
                var policy = next.spacePolicies?[space.uuidString] ?? .init(accountIDs: [])
                policy.accountIDs.removeAll { $0 == id }
                if enabled { policy.accountIDs.append(id) }
                else { policy.writeAccountIDs?.removeAll { $0 == id } }
                next.spacePolicies?[space.uuidString] = policy
            }
            error = nil
        } catch { self.error = Self.message(error) }
    }

    func setAutomatic(_ automatic: Bool, in space: UUID) async {
        do {
            try await ready()
            try await update { next in
                var policy = next.spacePolicies?[space.uuidString] ?? .init(accountIDs: [])
                policy.automatic = automatic
                next.spacePolicies?[space.uuidString] = policy
            }
            error = nil
        } catch { self.error = Self.message(error) }
    }

    func importGoogleCredentials(_ data: Data) async throws {
        try await ready()
        let client = try ConnectionOAuth.GoogleClient.imported(data)
        try await update { $0.google = client }
        error = nil
    }

    func connectGoogle(in space: UUID = Space.firstID) async { await connect(.google, in: space) }
    func connectNotion(in space: UUID = Space.firstID) async { await connect(.notion, in: space) }

    private func connect(_ provider: ConnectionProvider, in space: UUID, writing: Bool = false, expectedAccount: UUID? = nil) async {
        guard !busy else { return }
        busy = true; error = nil
        let id = UUID(); authorizationID = id
        let task = Task { try await self.authorize(provider, in: space, writing: writing, expectedAccount: expectedAccount) }
        authorization = task
        do { try await task.value }
        catch {
            if authorizationID == id, !(error is CancellationError) { self.error = Self.message(error) }
        }
        if authorizationID == id { busy = false; authorization = nil; authorizationID = nil }
    }

    func cancelAuthorization() {
        authorization?.cancel(); browser.cancel()
        authorization = nil; authorizationID = nil; busy = false
    }

    private func callback(_ build: @escaping @MainActor @Sendable (URL) async throws -> URL) async throws -> ConnectionOAuth.Callback {
        if let injectedAuthorize { return try await injectedAuthorize(build) }
        return try await browser.authorize(build)
    }

    private func authorize(_ provider: ConnectionProvider, in space: UUID, writing: Bool, expectedAccount: UUID?) async throws {
        try await ready(); try Task.checkCancellation()
        let expected = expectedAccount.flatMap { stored.credentials[$0.uuidString] }
        if expectedAccount != nil && expected == nil { throw ConnectionFailure("This account is no longer connected.") }
        let pkce = ConnectionOAuth.PKCE()
        let client: ConnectionOAuth.Client
        let callback: ConnectionOAuth.Callback
        if provider == .google {
            guard let google = stored.google else { throw ConnectionFailure("Import your Google Desktop OAuth credentials before connecting.") }
            client = ConnectionOAuth.Client(id: google.id, secret: google.secret, tokenEndpoint: ConnectionOAuth.googleToken)
            callback = try await self.callback { redirect in ConnectionOAuth.googleAuthorization(client: google, redirect: redirect, pkce: pkce, writing: writing, loginHint: expected?.account.title) }
        } else {
            let metadata = try await ConnectionOAuth.discoverNotion(http: http)
            // Registration is native and uses the actual loopback address. The
            // resulting client stays attached to this grant for every refresh.
            var registration: ConnectionOAuth.Client?
            callback = try await self.callback { redirect in
                let client = try await ConnectionOAuth.registerNotion(metadata, redirect: redirect, http: self.http)
                registration = client
                return ConnectionOAuth.notionAuthorization(metadata: metadata, client: client, redirect: redirect, pkce: pkce)
            }
            guard let registered = registration else { throw ConnectionFailure("Notion's OAuth client was not registered.") }
            client = registered
        }
        try Task.checkCancellation()
        let code = try ConnectionOAuth.code(from: callback, state: pkce.state)
        var tokens = try await ConnectionOAuth.tokens(client: client, provider: provider,
            fields: ["grant_type": "authorization_code", "code": code, "redirect_uri": callback.redirect.absoluteString,
                     "code_verifier": pkce.verifier], http: http, now: now())
        let title: String
        let identity: String
        let services: [ConnectionService]
        if provider == .google {
            var request = URLRequest(url: URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!)
            request.setValue("Bearer " + tokens.access, forHTTPHeaderField: "Authorization")
            let user = try await ConnectionOAuth.json(request, http: http)
            guard let sub = user["sub"] as? String, !sub.isEmpty,
                  let email = user["email"] as? String, !email.isEmpty,
                  user["email_verified"] as? Bool == true else {
                throw ConnectionFailure("Google did not return a verified account identity. Grant the email identity permission and try again.")
            }
            services = ConnectionOAuth.googleServices(tokens.scope)
            guard !services.isEmpty else { throw ConnectionFailure("No Gmail, Calendar, or Drive read permission was granted.") }
            title = email; identity = "google:" + sub
        } else {
            guard let workspace = tokens.workspaceID, !workspace.isEmpty,
                  let user = tokens.userID, !user.isEmpty else {
                throw ConnectionFailure("Notion did not return its workspace and user identity. Connect again.")
            }
            services = [.notion]; identity = "notion:" + workspace + ":" + user
            title = "Notion · " + (tokens.emailDomain ?? "Workspace") + " · " + String(workspace.prefix(8))
        }
        try Task.checkCancellation()
        if let expected, expected.identity != identity { throw ConnectionFailure("Choose the same Google account when enabling writes. Its existing connection has been kept.") }
        if writing && ConnectionOAuth.googleWritableServices(tokens.scope).isEmpty { throw ConnectionFailure("Google did not grant Drive write access. The existing connection has been kept.") }
        try await update { next in
            if let expected {
                guard next.credentials[expected.account.id.uuidString]?.revision == expected.revision,
                      next.spacePolicies?[space.uuidString]?.accountIDs.contains(expected.account.id) == true else { throw CancellationError() }
            }
            let existing = next.credentials.values.first { $0.identity == identity }
            // Google's consent flow can omit a previously issued refresh
            // token. Reuse one only for this same identity AND client.
            if tokens.refresh == nil, existing?.client == client { tokens.refresh = existing?.tokens.refresh }
            guard tokens.refresh != nil else { throw ConnectionFailure("The provider did not grant offline access. Connect again and approve the requested access.") }
            let account = ConnectionAccount(id: existing?.account.id ?? UUID(), provider: provider, title: title,
                                            services: services, label: existing?.account.label,
                                            writableServices: provider == .google ? ConnectionOAuth.googleWritableServices(tokens.scope) : existing?.account.writableServices)
            let credential = Credential(account: account, identity: identity, client: client, tokens: tokens)
            refreshes.removeValue(forKey: account.id)?.task.cancel()
            next.credentials[account.id.uuidString] = credential
            var policy = next.spacePolicies?[space.uuidString] ?? .init(accountIDs: [])
            if !policy.accountIDs.contains(account.id) { policy.accountIDs.append(account.id) }
            if writing {
                var writes = policy.writeAccountIDs ?? []
                if !writes.contains(account.id) { writes.append(account.id) }; policy.writeAccountIDs = writes
            }
            next.spacePolicies?[space.uuidString] = policy
        }
    }

    func disconnect(_ id: UUID) async {
        do {
            try await ready()
            if busy { cancelAuthorization() }
            refreshes.removeValue(forKey: id)?.task.cancel()
            try await update { next in
                next.credentials.removeValue(forKey: id.uuidString)
                Self.removeAssignment(id, from: &next)
            }
            error = nil
        } catch { self.error = Self.message(error) }
    }

    func token(for accountID: UUID) async throws -> String {
        try await ready()
        guard let credential = stored.credentials[accountID.uuidString] else { throw ConnectionFailure("Connect this account again before searching.") }
        if credential.tokens.expires.timeIntervalSince(now()) > 60 { return credential.tokens.access }
        if let refresh = refreshes[accountID] { return try await refresh.task.value }
        let task = Task { try await self.refresh(credential) }
        let refresh = Refresh(task: task)
        refreshes[accountID] = refresh
        defer { if refreshes[accountID]?.id == refresh.id { refreshes.removeValue(forKey: accountID) } }
        return try await task.value
    }

    private func refresh(_ credential: Credential) async throws -> String {
        let id = credential.account.id.uuidString
        guard let refresh = credential.tokens.refresh else { throw ConnectionFailure("This account needs to be connected again.") }
        do {
            var tokens = try await ConnectionOAuth.tokens(client: credential.client, provider: credential.account.provider,
                fields: ["grant_type": "refresh_token", "refresh_token": refresh], http: http, now: now())
            try Task.checkCancellation()
            if credential.account.provider == .notion, tokens.refresh == nil {
                // A successful Notion refresh rotates the grant. Never replay
                // a possibly retired token after an incomplete response.
                throw ConnectionOAuth.Failure(code: "invalid_grant")
            }
            tokens.refresh = tokens.refresh ?? credential.tokens.refresh
            tokens.scope = tokens.scope ?? credential.tokens.scope
            tokens.userID = tokens.userID ?? credential.tokens.userID
            tokens.workspaceID = tokens.workspaceID ?? credential.tokens.workspaceID
            tokens.emailDomain = tokens.emailDomain ?? credential.tokens.emailDomain
            let revision = UUID()
            try await update({ state in
                guard var next = state.credentials[id], next.revision == credential.revision else { throw CancellationError() }
                // Labels may have changed during the network request. Build
                // from the current account metadata, not the expired snapshot.
                next.tokens = tokens; next.revision = revision
                if credential.account.provider == .google {
                    next.account.services = ConnectionOAuth.googleServices(tokens.scope)
                    let writes = ConnectionOAuth.googleWritableServices(tokens.scope)
                    if !writes.isEmpty || next.account.writableServices != nil { next.account.writableServices = writes }
                }
                state.credentials[id] = next
            }, onFailure: { state in
                if state.credentials[id]?.revision == credential.revision {
                    state.credentials.removeValue(forKey: id)
                    Self.removeAssignment(credential.account.id, from: &state)
                }
            })
            try Task.checkCancellation()
            guard stored.credentials[id]?.revision == revision else { throw CancellationError() }
            return tokens.access
        } catch {
            if let failure = error as? ConnectionOAuth.Failure,
               ["invalid_grant", "invalid_token", "invalid_client"].contains(failure.code),
               stored.credentials[id]?.revision == credential.revision {
                try? await update({ state in
                    guard state.credentials[id]?.revision == credential.revision else { return }
                    state.credentials.removeValue(forKey: id)
                    Self.removeAssignment(credential.account.id, from: &state)
                }, onFailure: { state in
                    if state.credentials[id]?.revision == credential.revision {
                        state.credentials.removeValue(forKey: id)
                        Self.removeAssignment(credential.account.id, from: &state)
                    }
                })
                self.error = Self.message(error)
            }
            throw error
        }
    }

    private static func removeAssignment(_ id: UUID, from stored: inout Stored) {
        for space in stored.spacePolicies?.keys.map({ $0 }) ?? [] {
            stored.spacePolicies?[space]?.accountIDs.removeAll { $0 == id }
            stored.spacePolicies?[space]?.writeAccountIDs?.removeAll { $0 == id }
        }
    }

    private static func message(_ error: Error) -> String {
        if let failure = error as? ConnectionFailure { return failure.message }
        if let failure = error as? ConnectionOAuth.Failure { return failure.localizedDescription }
        return "The account connection could not be completed. Check your network and try again."
    }
}
