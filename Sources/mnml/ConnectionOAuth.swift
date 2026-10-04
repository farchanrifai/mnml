import Foundation
import CryptoKit
import Network
import AppKit

/// Native OAuth helpers. Neither the authorization code nor credentials are
/// passed through the chat process, URLs used for API reads, or diagnostic logs.
enum ConnectionOAuth {
    static let googleScopes = ["openid", "email",
        "https://www.googleapis.com/auth/gmail.readonly",
        "https://www.googleapis.com/auth/calendar.events.readonly",
        "https://www.googleapis.com/auth/drive.readonly"]
    static let googleDriveWriteScope = "https://www.googleapis.com/auth/drive"
    static let googleWriteScopes = Array(googleScopes.dropLast()) + [googleDriveWriteScope]
    static let googleToken = URL(string: "https://oauth2.googleapis.com/token")!
    static let notionResource = URL(string: "https://mcp.notion.com")!

    struct GoogleClient: Codable, Equatable, Sendable {
        var id: String
        var secret: String

        static func imported(_ data: Data) throws -> GoogleClient {
            guard data.count <= 65_536,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let installed = json["installed"] as? [String: Any],
                  let id = installed["client_id"] as? String, id.hasSuffix(".apps.googleusercontent.com"),
                  let secret = installed["client_secret"] as? String,
                  !secret.isEmpty, id.count <= 512, secret.count <= 512 else {
                throw ConnectionFailure("Import the JSON downloaded for a Google OAuth Desktop app client.")
            }
            return GoogleClient(id: id, secret: secret)
        }
    }

    struct Client: Codable, Equatable, Sendable {
        var id: String
        var secret: String?
        var tokenEndpoint: URL
    }

    struct Tokens: Codable, Equatable, Sendable {
        var access: String
        var refresh: String?
        var expires: Date
        var scope: String?
        var userID: String?
        var workspaceID: String?
        var emailDomain: String?
    }

    struct Metadata: Sendable {
        var authorization: URL
        var token: URL
        var registration: URL
    }

    struct PKCE: Sendable {
        let verifier: String
        let state: String
        var challenge: String { Self.challenge(verifier) }
        init() {
            verifier = ConnectionOAuth.random()
            state = ConnectionOAuth.random()
        }
        static func challenge(_ verifier: String) -> String {
            ConnectionOAuth.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        }
    }

    struct Callback: Sendable {
        var redirect: URL
        var url: URL
    }

    typealias Authorize = @MainActor @Sendable (@escaping @MainActor @Sendable (URL) async throws -> URL) async throws -> Callback

    struct Failure: LocalizedError, Sendable {
        var code: String
        var errorDescription: String? {
            switch code {
            case "invalid_grant", "invalid_token": "This connection expired or was revoked. Connect the account again."
            case "access_denied": "Account access was not granted."
            case "invalid_client": "The OAuth client could not be accepted. Check the imported Google Desktop credentials or reconnect Notion."
            default: "The account provider could not complete authorization. Try again."
            }
        }
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func random() -> String {
        var generator = SystemRandomNumberGenerator()
        return base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }

    /// Encode each UTF-8 byte; '&', '+', '=', and Unicode must not alter form fields.
    static func form(_ fields: [String: String]) -> Data {
        func escape(_ string: String) -> String {
            string.utf8.map { byte in
                switch byte {
                case 65...90, 97...122, 48...57, 45, 46, 95, 126: return String(UnicodeScalar(byte))
                default: return String(format: "%%%02X", byte)
                }
            }.joined()
        }
        return Data(fields.keys.sorted().map { escape($0) + "=" + escape(fields[$0]!) }.joined(separator: "&").utf8)
    }

    static func official(_ url: URL, provider: ConnectionProvider) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, url.fragment == nil else { return false }
        let hosts: Set<String> = provider == .google
            ? ["accounts.google.com", "oauth2.googleapis.com", "openidconnect.googleapis.com"]
            : ["mcp.notion.com", "api.notion.com", "www.notion.so", "notion.so", "www.notion.com", "notion.com"]
        return hosts.contains(url.host?.lowercased() ?? "")
    }

    static func googleAuthorization(client: GoogleClient, redirect: URL, pkce: PKCE, writing: Bool = false, loginHint: String? = nil) -> URL {
        var parts = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        parts.queryItems = ["client_id": client.id, "redirect_uri": redirect.absoluteString,
            "response_type": "code", "scope": (writing ? googleWriteScopes : googleScopes).joined(separator: " "),
            "state": pkce.state, "code_challenge": pkce.challenge, "code_challenge_method": "S256",
            "access_type": "offline", "prompt": "consent select_account"].sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        if let loginHint { parts.queryItems?.append(URLQueryItem(name: "login_hint", value: loginHint)) }
        return parts.url!
    }

    static func notionAuthorization(metadata: Metadata, client: Client, redirect: URL, pkce: PKCE) -> URL {
        var parts = URLComponents(url: metadata.authorization, resolvingAgainstBaseURL: false)!
        parts.queryItems = ["client_id": client.id, "redirect_uri": redirect.absoluteString,
            "response_type": "code", "scope": "default", "state": pkce.state, "code_challenge": pkce.challenge,
            "code_challenge_method": "S256", "resource": notionResource.absoluteString]
            .sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return parts.url!
    }

    static func code(from callback: Callback, state: String) throws -> String {
        let actual = callback.url
        guard callback.redirect.scheme == "http", callback.redirect.host == "127.0.0.1",
              callback.redirect.port != nil, callback.redirect.path == "/oauth/callback",
              actual.scheme == "http", actual.host == "127.0.0.1", actual.user == nil,
              actual.password == nil, actual.fragment == nil,
              actual.port == callback.redirect.port, actual.path == callback.redirect.path,
              let parts = URLComponents(url: actual, resolvingAgainstBaseURL: false) else {
            throw ConnectionFailure("The authorization callback was not the expected local address.")
        }
        let items = parts.queryItems ?? []
        let states = items.filter { $0.name == "state" }
        guard states.count == 1, states[0].value == state else {
            throw ConnectionFailure("The authorization state did not match. Connect the account again.")
        }
        let errors = items.filter { $0.name == "error" }
        if let error = errors.first?.value { throw Failure(code: error) }
        let codes = items.filter { $0.name == "code" }
        guard errors.isEmpty, codes.count == 1, let code = codes[0].value,
              !code.isEmpty, code.utf8.count <= 16_384 else {
            throw ConnectionFailure("The provider did not return an authorization code.")
        }
        return code
    }

    static func googleServices(_ scope: String?) -> [ConnectionService] {
        let scopes = Set((scope ?? "").split(separator: " ").map(String.init))
        let known: [(ConnectionService, String)] = [(.gmail, googleScopes[2]), (.calendar, googleScopes[3]), (.drive, googleScopes[4])]
        return known.compactMap { service, name in scopes.contains(name) || (service == .drive && scopes.contains(googleDriveWriteScope)) ? service : nil }
    }

    static func googleWritableServices(_ scope: String?) -> [ConnectionService] {
        Set((scope ?? "").split(separator: " ").map(String.init)).contains(googleDriveWriteScope) ? [.drive] : []
    }

    static func json(_ request: URLRequest, http: ConnectionHTTP) async throws -> [String: Any] {
        try Task.checkCancellation()
        let (data, response) = try await http(request)
        try Task.checkCancellation()
        guard data.count <= 1_048_576 else { throw ConnectionFailure("The account provider returned an oversized response.") }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(response.statusCode) else {
            // Never include raw response/error_description: it can contain credentials.
            if let code = json?["error"] as? String { throw Failure(code: code) }
            throw ConnectionFailure("The account provider returned HTTP \(response.statusCode). Try again.")
        }
        guard let json else { throw ConnectionFailure("The account provider returned an unreadable response.") }
        return json
    }

    static func discoverNotion(http: ConnectionHTTP) async throws -> Metadata {
        let resourceURL = URL(string: "https://mcp.notion.com/.well-known/oauth-protected-resource")!
        let resource = try await json(URLRequest(url: resourceURL), http: http)
        guard let advertised = (resource["resource"] as? String).flatMap(URL.init(string:)), advertised == notionResource,
              let servers = resource["authorization_servers"] as? [String],
              let issuer = servers.compactMap(URL.init(string:)).first(where: { official($0, provider: .notion) }) else {
            throw ConnectionFailure("Notion did not advertise a supported authorization server.")
        }
        var discovery = URLComponents(url: issuer, resolvingAgainstBaseURL: false)!
        discovery.path = "/.well-known/oauth-authorization-server" + (issuer.path == "/" ? "" : issuer.path)
        discovery.query = nil
        let metadata = try await json(URLRequest(url: discovery.url!), http: http)
        guard let issuerText = metadata["issuer"] as? String, URL(string: issuerText) == issuer,
              let authorization = (metadata["authorization_endpoint"] as? String).flatMap(URL.init(string:)),
              let token = (metadata["token_endpoint"] as? String).flatMap(URL.init(string:)),
              let registration = (metadata["registration_endpoint"] as? String).flatMap(URL.init(string:)),
              [authorization, token, registration].allSatisfy({ official($0, provider: .notion) }) else {
            throw ConnectionFailure("Notion advertised unsupported OAuth endpoints.")
        }
        return Metadata(authorization: authorization, token: token, registration: registration)
    }

    static func registerNotion(_ metadata: Metadata, redirect: URL, http: ConnectionHTTP) async throws -> Client {
        var request = URLRequest(url: metadata.registration)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["client_name": "mnml",
            "redirect_uris": [redirect.absoluteString], "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"], "token_endpoint_auth_method": "none", "scope": "default"])
        let registration = try await json(request, http: http)
        guard let id = registration["client_id"] as? String, !id.isEmpty, id.count <= 4096 else {
            throw ConnectionFailure("Notion did not register the OAuth client.")
        }
        return Client(id: id, secret: registration["client_secret"] as? String, tokenEndpoint: metadata.token)
    }

    static func tokens(client: Client, provider: ConnectionProvider, fields: [String: String],
                       http: ConnectionHTTP, now: Date) async throws -> Tokens {
        guard official(client.tokenEndpoint, provider: provider) else {
            throw ConnectionFailure("The stored OAuth endpoint is not an official provider address.")
        }
        var fields = fields
        fields["client_id"] = client.id
        if let secret = client.secret { fields["client_secret"] = secret }
        if provider == .notion { fields["resource"] = notionResource.absoluteString }
        var request = URLRequest(url: client.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = form(fields)
        let result = try await json(request, http: http)
        guard let access = result["access_token"] as? String, !access.isEmpty, access.utf8.count <= 65_536,
              let expires = result["expires_in"] as? NSNumber,
              expires.doubleValue.isFinite, expires.doubleValue > 0, expires.doubleValue <= 31_536_000,
              (result["token_type"] as? String ?? "Bearer").lowercased() == "bearer" else {
            throw ConnectionFailure("The provider returned incomplete access credentials. Connect the account again.")
        }
        let refresh = (result["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return Tokens(access: access, refresh: refresh, expires: now.addingTimeInterval(expires.doubleValue),
                      scope: result["scope"] as? String, userID: result["user_id"] as? String,
                      workspaceID: result["workspace_id"] as? String, emailDomain: result["email_domain"] as? String)
    }

    private static let transport = Transport()
    static let http: ConnectionHTTP = { request in try await transport.send(request) }

    private final class Transport: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private var session: URLSession!
        override init() {
            super.init()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            var request = request
            request.timeoutInterval = 30
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw ConnectionFailure("The account provider returned an invalid HTTP response.") }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 1_048_576 else { bytes.task.cancel(); throw ConnectionFailure("The account provider returned an oversized response.") }
                data.append(byte)
            }
            return (data, response)
        }
    }

    @MainActor
    final class Browser {
        private var callback: Loopback?
        func authorize(_ build: @escaping @MainActor @Sendable (URL) async throws -> URL) async throws -> Callback {
            let callback = try Loopback()
            self.callback = callback
            defer { callback.cancel(); if self.callback === callback { self.callback = nil } }
            let redirect = try await callback.start()
            let url = try await build(redirect)
            try Task.checkCancellation()
            guard NSWorkspace.shared.open(url) else { throw ConnectionFailure("The system browser could not open the account sign-in page.") }
            return Callback(redirect: redirect, url: try await callback.wait())
        }
        func cancel() { callback?.cancel(); callback = nil }
    }

    /// Bound only to 127.0.0.1, never a LAN interface. One short-lived listener
    /// owns one callback and is cancelled on completion, timeout, or UI cancel.
    private final class Loopback: @unchecked Sendable {
        private let queue = DispatchQueue(label: "mnml.connections.oauth-loopback")
        private let listener: NWListener
        private var started: CheckedContinuation<URL, Error>?
        private var waiting: CheckedContinuation<URL, Error>?
        private var result: Result<URL, Error>?
        private var redirect: URL?
        private var connections: [NWConnection] = []
        private var timeout: DispatchWorkItem?

        init() throws {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: parameters)
        }

        func start() async throws -> URL {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    queue.async {
                        if let result = self.result { continuation.resume(with: result); return }
                        self.started = continuation
                        self.listener.stateUpdateHandler = { [weak self] state in
                            guard let self else { return }
                            switch state {
                            case .ready:
                                guard let port = self.listener.port else { self.complete(.failure(ConnectionFailure("Could not bind the account callback."))); return }
                                let url = URL(string: "http://127.0.0.1:\(port.rawValue)/oauth/callback")!
                                self.redirect = url; self.started?.resume(returning: url); self.started = nil
                            case .failed: self.complete(.failure(ConnectionFailure("Could not start the local account callback.")))
                            default: break
                            }
                        }
                        self.listener.newConnectionHandler = { [weak self] connection in self?.receive(connection) }
                        let timeout = DispatchWorkItem { [weak self] in self?.complete(.failure(ConnectionFailure("Account sign-in timed out. Connect the account again."))) }
                        self.timeout = timeout; self.queue.asyncAfter(deadline: .now() + 600, execute: timeout)
                        self.listener.start(queue: self.queue)
                    }
                }
            } onCancel: { self.cancel() }
        }

        func wait() async throws -> URL {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    queue.async {
                        if let result = self.result { continuation.resume(with: result) }
                        else { self.waiting = continuation }
                    }
                }
            } onCancel: { self.cancel() }
        }

        func cancel() { queue.async { self.complete(.failure(CancellationError())) } }

        private func receive(_ connection: NWConnection) {
            guard connections.count < 8, result == nil else { connection.cancel(); return }
            connections.append(connection)
            connection.start(queue: queue)
            read(connection, data: Data())
        }

        private func read(_ connection: NWConnection, data: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] chunk, _, ended, error in
                guard let self, self.result == nil else { connection.cancel(); return }
                var data = data; if let chunk { data.append(chunk) }
                guard data.count <= 8192, error == nil else { connection.cancel(); return }
                guard let text = String(data: data, encoding: .utf8), text.contains("\r\n\r\n") else {
                    if ended { connection.cancel() } else { self.read(connection, data: data) }; return
                }
                let request = text.components(separatedBy: "\r\n")[0].split(separator: " ")
                guard request.count == 3, request[0] == "GET", request[1].hasPrefix("/oauth/callback?"),
                      let redirect = self.redirect,
                      let url = URL(string: String(request[1]), relativeTo: redirect)?.absoluteURL,
                      url.path == redirect.path else { connection.cancel(); return }
                // The callback validator checks state and code after this. Do
                // not echo either into the page or append them to a log.
                let body = "Account authorization returned to mnml. You can close this browser tab."
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                self.complete(.success(url), replying: connection)
            }
        }

        private func complete(_ result: Result<URL, Error>, replying: NWConnection? = nil) {
            guard self.result == nil else { return }
            self.result = result; timeout?.cancel(); timeout = nil; listener.cancel()
            connections.filter { $0 !== replying }.forEach { $0.cancel() }; connections.removeAll()
            started?.resume(with: result); started = nil
            waiting?.resume(with: result); waiting = nil
        }
    }
}
