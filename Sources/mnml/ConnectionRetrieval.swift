import Foundation
import PDFKit

/// Read-only service retrieval. No connector daemon, local mirror, or AI call is
/// needed: credentials stay in the accounts store and only selected text leaves
/// this layer for the chat's context budget.
final class ConnectionRetrieval: @unchecked Sendable {
    typealias Accounts = @Sendable () async throws -> [ConnectionAccount]
    typealias Token = @Sendable (UUID) async throws -> String

    static let shared = ConnectionRetrieval(
        accounts: {
            try await ConnectionAccounts.shared.waitUntilReady()
            return await MainActor.run { ConnectionAccounts.shared.accounts }
        },
        token: { try await ConnectionAccounts.shared.token(for: $0) }
    )

    private let accounts: Accounts
    private let token: Token
    private let http: ConnectionHTTP
    private let now: @Sendable () -> Date
    static let documentLimit = 80_000

    init(accounts: @escaping Accounts, token: @escaping Token,
         http: @escaping ConnectionHTTP = ConnectionRetrieval.network,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.accounts = accounts; self.token = token; self.http = http; self.now = now
    }

    func search(_ request: ConnectionSearch, allowedAccounts: Set<UUID>? = nil) async throws -> [ConnectionHit] {
        try Task.checkCancellation()
        guard let account = try await accounts().first(where: {
            $0.provider == request.service.provider && $0.services.contains(request.service) &&
                (allowedAccounts?.contains($0.id) ?? true)
        }) else { throw ConnectionFailure("Connect \(request.service.title) in Settings first.") }
        var request = request
        request.limit = min(10, max(1, request.limit))
        request.query = String(request.query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        let bearer = try await token(account.id)
        switch request.service {
        case .gmail: return try await gmailSearch(request, account: account, bearer: bearer)
        case .calendar: return try await calendarSearch(request, account: account, bearer: bearer)
        case .drive: return try await driveSearch(request, account: account, bearer: bearer)
        case .notion:
            return try await ConnectionNotion(http: http).search(request, account: account, token: bearer)
        }
    }

    func fetch(_ hit: ConnectionHit) async throws -> ConnectionDocument {
        try Task.checkCancellation()
        guard let account = try await accounts().first(where: {
            $0.id == hit.accountID && $0.provider == hit.service.provider && $0.services.contains(hit.service)
        }) else { throw ConnectionFailure("This \(hit.service.title) account is disconnected. Connect it again to read this source.") }
        let bearer = try await token(account.id)
        switch hit.service {
        case .gmail:
            let id = try Self.identifier(hit.id)
            let json = try await googleJSON("gmail/v1/users/me/messages/\(id)", query: ["format": "full"], bearer: bearer)
            guard let payload = json["payload"] as? [String: Any] else {
                throw ConnectionFailure("Gmail returned a message without readable content.")
            }
            let headers = Self.gmailHeaders(payload)
            let body = Self.gmailBody(payload)
            let text = [headers["subject"].map { "Subject: \($0)" }, headers["from"].map { "From: \($0)" },
                        headers["to"].map { "To: \($0)" }, headers["date"].map { "Date: \($0)" }, body]
                .compactMap { $0 }.joined(separator: "\n\n")
            guard !body.isEmpty else { throw ConnectionFailure("This Gmail message has no readable text body. Attachments are not fetched automatically.") }
            return ConnectionDocument(hit: hit, text: Self.bounded(text))
        case .calendar:
            let id = try Self.identifier(hit.id)
            let json = try await googleJSON("calendar/v3/calendars/primary/events/\(id)", bearer: bearer)
            return ConnectionDocument(hit: hit, text: Self.bounded(Self.calendarText(json)))
        case .drive: return try await driveFetch(hit, bearer: bearer)
        case .notion: return try await ConnectionNotion(http: http).fetch(hit, token: bearer)
        }
    }

    private func gmailSearch(_ request: ConnectionSearch, account: ConnectionAccount, bearer: String) async throws -> [ConnectionHit] {
        var query = request.query
        if let start = request.start { query += " after:\(Int(start.timeIntervalSince1970))" }
        if let end = request.end { query += " before:\(Int(end.timeIntervalSince1970))" }
        var hits: [ConnectionHit] = [], page: String?
        // At most two list pages and ten metadata fetches; deleted/inaccessible
        // individual messages may disappear between list and get.
        for _ in 0..<2 {
            var params = ["q": query, "maxResults": String(request.limit - hits.count)]
            if let page { params["pageToken"] = page }
            let json = try await googleJSON("gmail/v1/users/me/messages", query: params, bearer: bearer)
            for item in (json["messages"] as? [[String: Any]] ?? []).prefix(request.limit - hits.count) {
                guard let raw = item["id"] as? String else { continue }
                let id = try Self.identifier(raw)
                var metadata: [String: Any]
                do {
                    metadata = try await googleJSON("gmail/v1/users/me/messages/\(id)", query: ["format": "metadata"], bearer: bearer)
                } catch let failure as ConnectionFailure where failure.message.contains("no longer available") { continue }
                let headers = Self.gmailHeaders(metadata["payload"] as? [String: Any] ?? [:])
                let thread = (metadata["threadId"] as? String).flatMap { try? Self.identifier($0) } ?? id
                var components = URLComponents(string: "https://mail.google.com/mail/")!
                components.queryItems = [URLQueryItem(name: "authuser", value: account.title)]
                components.fragment = "all/\(thread)"
                hits.append(ConnectionHit(id: id, service: .gmail, accountID: account.id,
                    title: headers["subject"] ?? "Untitled email", url: components.url!,
                    detail: [headers["from"], headers["date"]].compactMap { $0 }.joined(separator: " · "),
                    snippet: String((metadata["snippet"] as? String ?? "").prefix(1_000)), accountTitle: account.displayIdentity))
            }
            guard hits.count < request.limit, let next = json["nextPageToken"] as? String, next != page else { break }
            page = next
        }
        return hits
    }

    private func calendarSearch(_ request: ConnectionSearch, account: ConnectionAccount, bearer: String) async throws -> [ConnectionHit] {
        let start = request.start ?? now()
        let end = request.end ?? start.addingTimeInterval(30 * 24 * 60 * 60)
        guard end > start else { throw ConnectionFailure("The calendar end date must be after the start date.") }
        let formatter = ISO8601DateFormatter()
        var params = ["q": request.query, "timeMin": formatter.string(from: start), "timeMax": formatter.string(from: end),
                      "singleEvents": "true", "orderBy": "startTime", "maxResults": String(request.limit)]
        var hits: [ConnectionHit] = [], page: String?
        for _ in 0..<2 {
            if let page { params["pageToken"] = page }
            let json = try await googleJSON("calendar/v3/calendars/primary/events", query: params, bearer: bearer)
            for event in (json["items"] as? [[String: Any]] ?? []) where event["status"] as? String != "cancelled" {
                guard hits.count < request.limit, let id = event["id"] as? String,
                      let url = Self.serviceURL(event["htmlLink"] as? String, hosts: ["calendar.google.com", "www.google.com"]) else { continue }
                hits.append(ConnectionHit(id: try Self.identifier(id), service: .calendar, accountID: account.id,
                    title: event["summary"] as? String ?? "Untitled event", url: url,
                    detail: Self.calendarDate(event) + (event["location"].map { " · \($0)" } ?? ""),
                    snippet: String(Self.plainHTML(event["description"] as? String ?? "").prefix(1_000)), accountTitle: account.displayIdentity))
            }
            guard hits.count < request.limit, let next = json["nextPageToken"] as? String, next != page else { break }
            page = next
        }
        return hits
    }

    private func driveSearch(_ request: ConnectionSearch, account: ConnectionAccount, bearer: String) async throws -> [ConnectionHit] {
        let literal = Self.driveLiteral(request.query)
        var query = "trashed = false"
        if !request.query.isEmpty { query += " and (fullText contains '\(literal)' or name contains '\(literal)')" }
        // Search also returns folders and non-readable files so reviewed move
        // operations can choose a real destination and arbitrary file type.
        var params = ["q": query, "pageSize": String(request.limit), "orderBy": "modifiedTime desc",
                      "fields": "nextPageToken,files(id,name,mimeType,webViewLink,description,modifiedTime,size)", "supportsAllDrives": "true", "includeItemsFromAllDrives": "true"]
        var hits: [ConnectionHit] = [], page: String?
        for _ in 0..<2 {
            if let page { params["pageToken"] = page }
            let json = try await googleJSON("drive/v3/files", query: params, bearer: bearer)
            for file in (json["files"] as? [[String: Any]] ?? []).prefix(request.limit - hits.count) {
                guard let raw = file["id"] as? String else { continue }
                let id = try Self.identifier(raw)
                let url = Self.serviceURL(file["webViewLink"] as? String, hosts: ["drive.google.com", "docs.google.com"])
                    ?? URL(string: "https://drive.google.com/file/d/\(id)/view")!
                hits.append(ConnectionHit(id: id, service: .drive, accountID: account.id,
                    title: file["name"] as? String ?? "Untitled file", url: url,
                    detail: [file["mimeType"] as? String, file["modifiedTime"] as? String].compactMap { $0 }.joined(separator: " · "),
                    snippet: String((file["description"] as? String ?? "").prefix(1_000)), accountTitle: account.displayIdentity))
            }
            guard hits.count < request.limit, let next = json["nextPageToken"] as? String, next != page else { break }
            page = next
        }
        return hits
    }

    private func driveFetch(_ hit: ConnectionHit, bearer: String) async throws -> ConnectionDocument {
        let id = try Self.identifier(hit.id)
        let metadata = try await googleJSON("drive/v3/files/\(id)", query: ["fields": "mimeType,size,name", "supportsAllDrives": "true"], bearer: bearer)
        let mime = metadata["mimeType"] as? String ?? ""
        if let size = metadata["size"] as? String, let bytes = Int(size), bytes > ConnectionRetrievalTransport.maximumBytes {
            throw ConnectionFailure("This Drive file exceeds the 8 MB context download limit.")
        }
        let data: Data
        switch mime {
        case "application/vnd.google-apps.document":
            data = try await googleData("drive/v3/files/\(id)/export", query: ["mimeType": "text/plain"], bearer: bearer)
        case "application/vnd.google-apps.spreadsheet":
            data = try await googleData("drive/v3/files/\(id)/export", query: ["mimeType": "text/csv"], bearer: bearer)
        case "text/plain", "text/csv", "application/pdf":
            data = try await googleData("drive/v3/files/\(id)", query: ["alt": "media", "supportsAllDrives": "true"], bearer: bearer)
        default: throw ConnectionFailure("This Drive file type cannot be used as text context yet. Choose a Google Doc, Google Sheet, text file, CSV, or text PDF.")
        }
        let text: String
        if mime == "application/pdf" {
            // PDFKit does not fetch links or OCR images. Stop extraction at the
            // context limit instead of accumulating an entire large document.
            guard let pdf = PDFDocument(data: data) else { throw ConnectionFailure("This PDF could not be opened.") }
            var pages: [String] = [], length = 0
            for index in 0..<min(pdf.pageCount, 300) {
                try Task.checkCancellation()
                let page = String((pdf.page(at: index)?.string ?? "").prefix(Self.documentLimit - length))
                if !page.isEmpty { pages.append("Page \(index + 1)\n\(page)"); length += page.count }
                if length >= Self.documentLimit { break }
            }
            text = pages.joined(separator: "\n\n")
            guard !text.isEmpty else { throw ConnectionFailure("This PDF has no extractable text. Scanned PDFs need OCR and are not supported yet.") }
        } else {
            guard let decoded = String(data: data, encoding: .utf8) else { throw ConnectionFailure("This Drive file is not UTF-8 text.") }
            text = decoded
        }
        let caveat = mime == "application/vnd.google-apps.spreadsheet" ? "Google Sheets CSV export includes the first sheet only.\n\n" : ""
        return ConnectionDocument(hit: hit, text: Self.bounded(caveat + text))
    }

    private func googleJSON(_ path: String, query: [String: String] = [:], bearer: String) async throws -> [String: Any] {
        let data = try await googleData(path, query: query, bearer: bearer)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConnectionFailure("The service returned an unreadable response.")
        }
        return object
    }

    private func googleData(_ path: String, query: [String: String] = [:], bearer: String) async throws -> Data {
        var components = URLComponents(string: "https://www.googleapis.com/\(path)")!
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!, timeoutInterval: 30)
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await ConnectionRetrievalTransport.checked(request, http: http).0
    }

    static func identifier(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.count <= 256,
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw ConnectionFailure("The source has an invalid identifier.")
        }
        return value
    }

    static func driveLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    }

    static func serviceURL(_ raw: String?, hosts: Set<String>) -> URL? {
        guard let raw, let url = URL(string: raw), url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased(), hosts.contains(host) else { return nil }
        return url
    }

    static func bounded(_ text: String) -> String {
        text.count > documentLimit ? String(text.prefix(documentLimit)) + "\n[Source text truncated]" : text
    }

    static func gmailHeaders(_ payload: [String: Any]) -> [String: String] {
        var headers: [String: String] = [:]
        for header in payload["headers"] as? [[String: String]] ?? [] {
            if let name = header["name"]?.lowercased(), let value = header["value"] { headers[name] = String(value.prefix(2_000)) }
        }
        return headers
    }

    static func gmailBody(_ payload: [String: Any], depth: Int = 0) -> String {
        guard depth < 20 else { return "" }
        // Ignore attachments even when their MIME type is text/plain.
        if let filename = payload["filename"] as? String, !filename.isEmpty { return "" }
        let mime = payload["mimeType"] as? String ?? ""
        let parts = payload["parts"] as? [[String: Any]] ?? []
        if !parts.isEmpty {
            if mime == "multipart/alternative" {
                let plain = parts.filter { $0["mimeType"] as? String != "text/html" }.map { gmailBody($0, depth: depth + 1) }.filter { !$0.isEmpty }
                if !plain.isEmpty { return bounded(plain.joined(separator: "\n\n")) }
            }
            return bounded(parts.prefix(100).map { gmailBody($0, depth: depth + 1) }.filter { !$0.isEmpty }.joined(separator: "\n\n"))
        }
        guard mime == "text/plain" || mime == "text/html", let body = payload["body"] as? [String: Any],
              let encoded = body["data"] as? String, encoded.utf8.count <= ConnectionRetrievalTransport.maximumBytes else { return "" }
        var base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return "" }
        var text = String(data: data, encoding: .utf8)
        if text == nil, let contentType = gmailHeaders(payload)["content-type"]?.lowercased(), contentType.contains("iso-8859-1") {
            text = String(data: data, encoding: .isoLatin1)
        }
        guard let text else { return "" }
        return bounded(mime == "text/html" ? plainHTML(text) : text)
    }

    /// Text-only HTML conversion; no WebKit, attributed HTML import, remote
    /// resources, or scripts. Rich messages remain data rather than a web page.
    static func plainHTML(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "(?is)<(script|style)\\b[^>]*>.*?</\\1\\s*>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)<(?:br\\s*/?|/p|/div|/li|/tr|/h[1-6])\\s*>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?s)<[^>]*>", with: "", options: .regularExpression)
        for (entity, value) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func calendarDate(_ event: [String: Any]) -> String {
        let start = event["start"] as? [String: String] ?? [:], end = event["end"] as? [String: String] ?? [:]
        return (start["dateTime"] ?? start["date"] ?? "") + " — " + (end["dateTime"] ?? end["date"] ?? "")
    }

    private static func calendarText(_ event: [String: Any]) -> String {
        [event["summary"] as? String, calendarDate(event), (event["location"] as? String).map { "Location: \($0)" },
         (event["description"] as? String).map { plainHTML($0) },
         (event["attendees"] as? [[String: Any]]).map { "Attendees: " + $0.compactMap { $0["email"] as? String }.joined(separator: ", ") }]
            .compactMap { $0 }.joined(separator: "\n\n")
    }

    static func network(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await ConnectionRetrievalTransport.network(request)
    }
}

enum ConnectionRetrievalTransport {
    static let maximumBytes = 8 * 1_024 * 1_024
    private static let allowedHosts: Set<String> = ["www.googleapis.com", "sheets.googleapis.com", "docs.googleapis.com", "mcp.notion.com"]

    static func checked(_ request: URLRequest, http: ConnectionHTTP) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        guard let url = request.url, url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host, allowedHosts.contains(host) else {
            throw ConnectionFailure("The connector refused an unrecognized service address.")
        }
        let (data, response) = try await http(request)
        try Task.checkCancellation()
        guard data.count <= maximumBytes else { throw ConnectionFailure("The service response exceeds the 8 MB context download limit.") }
        guard response.url?.host == url.host, response.url?.scheme == "https" else { throw ConnectionFailure("The connector refused a service redirect.") }
        switch response.statusCode {
        case 200..<300: return (data, response)
        case 401: throw ConnectionFailure("The service connection expired. Reconnect this account in Settings.")
        case 403: throw ConnectionFailure("This account does not have permission to read this source. Check the connection's read permissions.")
        case 404: throw ConnectionFailure("This source is no longer available to the connected account.")
        case 429:
            let retry = response.value(forHTTPHeaderField: "Retry-After").flatMap { Int($0) }.map { " Try again in \($0) seconds." } ?? " Try again shortly."
            throw ConnectionFailure("The service is limiting searches.\(retry)")
        case 300..<400: throw ConnectionFailure("The connector refused a service redirect.")
        default: throw ConnectionFailure("The service could not complete this request (HTTP \(response.statusCode)).")
        }
    }

    static func network(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 45
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, raw) = try await session.bytes(for: request)
        guard let response = raw as? HTTPURLResponse else { throw ConnectionFailure("The service returned an unreadable response.") }
        if response.expectedContentLength > maximumBytes { throw ConnectionFailure("The service response exceeds the 8 MB context download limit.") }
        var data = Data()
        data.reserveCapacity(min(maximumBytes, max(0, Int(response.expectedContentLength))))
        for try await byte in bytes {
            if data.count >= maximumBytes { throw ConnectionFailure("The service response exceeds the 8 MB context download limit.") }
            data.append(byte)
        }
        return (data, response)
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
