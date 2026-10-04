import Foundation
import CryptoKit

/// Read sessions cannot invoke write tools. A separately prepared write session
/// executes only a reviewed, immutable create-page or append-page payload.
struct ConnectionNotion: Sendable {
    let http: ConnectionHTTP

    func prepareWrite(_ plan: ConnectionWritePlan, account: ConnectionAccount,
                      target: ConnectionHit?, destination: ConnectionHit?, token: String) async throws -> ConnectionPreparedWrite {
        try Self.validateWrite(plan, account: account, target: target, destination: destination)
        let page = plan.operation == .createNotion ? destination! : target!
        let session = Session(token: token, http: http, writes: true)
        try await session.connect()
        let tools = try await session.tools()
        let snapshot = try await Self.writePage(page, session: session, tools: tools)
        let tool = try Self.tool(plan.operation == .createNotion ? "create-pages" : "update-page", in: tools)
        try await Self.writeAccess(tool, session: session, tools: tools)
        let arguments = try Self.writeArguments(plan, page: page, content: snapshot.content, tool: tool)
        return ConnectionPreparedWrite(plan: plan, account: account, target: target, destination: destination,
            before: plan.operation == .appendNotion ? snapshot.content : "",
            state: ["notion.tool": tool.name, "notion.schema": try Self.json(tool.schema),
                    "notion.arguments": try Self.json(arguments), "notion.fingerprint": snapshot.fingerprint])
    }

    func executeWrite(_ prepared: ConnectionPreparedWrite, token: String) async throws -> ConnectionWriteResult {
        try Self.validateWrite(prepared.plan, account: prepared.account, target: prepared.target, destination: prepared.destination)
        let page = prepared.plan.operation == .createNotion ? prepared.destination! : prepared.target!
        let session = Session(token: token, http: http, writes: true)
        try await session.connect()
        let tools = try await session.tools()
        let tool = try Self.tool(prepared.plan.operation == .createNotion ? "create-pages" : "update-page", in: tools)
        guard prepared.state["notion.tool"] == tool.name,
              prepared.state["notion.schema"] == (try Self.json(tool.schema)) else {
            throw ConnectionFailure("Notion's write tool changed after the preview. Prepare this change again.")
        }
        try await Self.writeAccess(tool, session: session, tools: tools)
        let snapshot = try await Self.writePage(page, session: session, tools: tools)
        guard prepared.state["notion.fingerprint"] == snapshot.fingerprint else {
            throw ConnectionFailure("This Notion page changed after the preview. Prepare this change again.")
        }
        let arguments = try Self.writeArguments(prepared.plan, page: page, content: snapshot.content, tool: tool)
        guard prepared.state["notion.arguments"] == (try Self.json(arguments)) else {
            throw ConnectionFailure("The prepared Notion change no longer matches its reviewed payload.")
        }
        try Task.checkCancellation()
        // Never retry a mutation: a lost or incomplete reply may still mean that
        // Notion applied it. The caller must inspect the target before retrying.
        let result: [String: Any]
        do { result = try await session.call(tool.name, arguments: arguments) }
        catch { throw ConnectionFailure("Notion did not confirm the write. Check the page before trying again. " + String(error.localizedDescription.prefix(500))) }
        let object = Self.object(result)
        guard object["object"] as? String != "async_task" else {
            throw ConnectionFailure("Notion queued this write but has not confirmed completion. Check the page before trying again.")
        }
        let rows = (object["pages"] as? [[String: Any]]) ?? (object["results"] as? [[String: Any]]) ?? [object]
        guard rows.count == 1, let row = rows.first,
              let url = Self.notionURL(row["url"] as? String ?? row["page_url"] as? String),
              let id = Self.pageID(url),
              (row["id"] as? String ?? row["page_id"] as? String).map({ Self.normalizedID($0) == id }) ?? true,
              prepared.plan.operation == .createNotion || id == Self.pageID(page.url),
              row["success"] as? Bool != false else {
            throw ConnectionFailure("Notion returned an unconfirmed write response. Check the page before trying again.")
        }
        let title = prepared.plan.operation == .createNotion ? prepared.plan.title! : page.title
        let hit = ConnectionHit(id: id, service: .notion, accountID: prepared.account.id, title: title, url: url,
            detail: "", snippet: "", accountTitle: prepared.account.displayIdentity)
        return ConnectionWriteResult(hit: hit, summary: prepared.plan.operation == .createNotion ? "Created Notion note" : "Appended to Notion note")
    }

    private static func validateWrite(_ plan: ConnectionWritePlan, account: ConnectionAccount,
                                      target: ConnectionHit?, destination: ConnectionHit?) throws {
        try plan.validate()
        guard [.createNotion, .appendNotion].contains(plan.operation), plan.account == account.id,
              account.provider == .notion, account.services.contains(.notion), account.canWrite(.notion) else {
            throw ConnectionFailure("Enable Notion writes for this account before preparing a note.")
        }
        let page = plan.operation == .createNotion ? destination : target
        let reference = plan.operation == .createNotion ? plan.destination : plan.source
        guard let page, page.accountID == account.id, page.service == .notion, page.reference == reference,
              notionURL(page.url.absoluteString) != nil, pageID(page.url) != nil else {
            throw ConnectionFailure("Choose a Notion page found by this account as the write target or parent.")
        }
        if let target, target.accountID != account.id { throw ConnectionFailure("The Notion source belongs to another account.") }
        if let destination, destination.accountID != account.id { throw ConnectionFailure("The Notion destination belongs to another account.") }
    }

    private static func writeAccess(_ tool: Tool, session: Session, tools: [Tool]) async throws {
        let accessTool = try Self.tool("get-tool-access", in: tools)
        let result = try await session.call(accessTool.name, arguments: [:])
        guard let access = object(result)["current_tool_access"] as? [String: Any] else {
            throw ConnectionFailure("Notion could not report write permissions for this connection.")
        }
        // Some all-plan tools have no plan-specific entry. Their presence in
        // tools/list still comes from this connection's authorized tool list.
        if let entry = access[base(tool.name).replacingOccurrences(of: "-", with: "_")] as? [String: Any],
           !["available", "available_with_limit"].contains(entry["status"] as? String ?? "") {
            throw ConnectionFailure("Notion has not enabled this write tool for the connected workspace.")
        }
    }

    private struct WritePage {
        let content: String
        let fingerprint: String
    }

    private static func writePage(_ hit: ConnectionHit, session: Session, tools: [Tool]) async throws -> WritePage {
        let tool = try Self.tool("fetch", in: tools)
        guard let key = ["id", "url", "page_id"].first(where: { tool.properties[$0] != nil }),
              let id = pageID(hit.url) else { throw ConnectionFailure("Notion's page-read schema is not supported for writes.") }
        let arguments: [String: Any] = [key: key == "page_id" ? id : hit.url.absoluteString]
        try tool.validate(arguments)
        let result = try await session.call(tool.name, arguments: arguments)
        let object = Self.object(result)
        let nested = object["page"] as? [String: Any] ?? [:]
        guard object["truncated"] as? Bool != true,
              nested["truncated"] as? Bool != true,
              ((object["unknown_block_count"] as? NSNumber)?.intValue ?? 0) == 0,
              ((nested["unknown_block_count"] as? NSNumber)?.intValue ?? 0) == 0,
              (object["unknown_block_ids"] as? [Any] ?? []).isEmpty else {
            throw ConnectionFailure("Notion returned a partial page. Load a complete smaller page before writing.")
        }
        if let kind = object["type"] as? String ?? object["object"] as? String,
           ["database", "data_source", "block", "view"].contains(kind) {
            throw ConnectionFailure("Choose a Notion page for this note, rather than a database or view.")
        }
        if let raw = object["url"] as? String ?? object["page_url"] as? String,
           notionURL(raw).flatMap(pageID) != id { throw ConnectionFailure("Notion returned a different page from the selected write target.") }
        let body = object["markdown"] as? String ?? object["content"] as? String
            ?? nested["markdown"] as? String ?? nested["content"] as? String
        let content: String
        if let body { content = body }
        else {
            // Hosted Notion fetch also returns its documented page envelope as
            // text. Only its content section is an editable Markdown anchor.
            let text = object["text"] as? String ?? Self.text(result)
            guard let start = text.range(of: "<content>"), let end = text.range(of: "</content>", range: start.upperBound..<text.endIndex) else {
                throw ConnectionFailure("Notion returned no complete editable page content for the preview.")
            }
            content = String(text[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .newlines)
            guard !text.contains("[Notion returned partial page content]"), !text.contains("<unknown") else {
                throw ConnectionFailure("Notion returned a partial page. Load a complete smaller page before writing.")
            }
        }
        guard content.utf8.count <= 32_000 else { throw ConnectionFailure("Use a Notion page of at most 32 KB for a reviewed write.") }
        let edited = object["page_last_edited_at"] as? String ?? object["last_edited_time"] as? String
            ?? nested["page_last_edited_at"] as? String ?? nested["last_edited_time"] as? String ?? ""
        let fingerprint = SHA256.hash(data: Data((id + "\n" + edited + "\n" + content).utf8)).map { String(format: "%02x", $0) }.joined()
        return WritePage(content: content, fingerprint: fingerprint)
    }

    private static func writeArguments(_ plan: ConnectionWritePlan, page: ConnectionHit, content: String, tool: Tool) throws -> [String: Any] {
        guard let id = pageID(page.url) else { throw ConnectionFailure("The Notion page identifier is invalid.") }
        if plan.operation == .createNotion {
            var arguments: [String: Any] = ["parent": ["page_id": id], "pages": [["properties": ["title": plan.title!], "content": plan.text!]]]
            if tool.properties["allow_async"] != nil { arguments["allow_async"] = false }
            try tool.validateWrite(arguments)
            return arguments
        }
        guard !content.isEmpty else { throw ConnectionFailure("This empty Notion page has no stable append anchor. Create a new note instead.") }
        let anchor = String(content.suffix(500))
        guard content.components(separatedBy: anchor).count == 2 else {
            throw ConnectionFailure("This Notion page has no unique append anchor. Create a new note instead.")
        }
        let change: [String: Any] = ["old_str": anchor, "new_str": anchor + "\n\n" + plan.text!]
        var candidates: [[String: Any]] = [
            ["page_id": id, "command": "update_content", "content_updates": [change]]
        ]
        // Older hosted schemas express append as an insertion after a unique
        // selection. Ellipses have special matching semantics in that command.
        if !anchor.contains("...") && !anchor.contains("…") {
            candidates.append(["page_id": id, "command": "insert_content_after", "selection_with_ellipsis": anchor, "new_str": "\n\n" + plan.text!])
        }
        for data in candidates {
            var arguments = tool.properties["data"] != nil ? ["data": data] : data
            if tool.properties["allow_async"] != nil { arguments["allow_async"] = false }
            if let _ = try? tool.validateWrite(arguments) { return arguments }
        }
        throw ConnectionFailure("Notion's append tool schema is not supported by this version of mnml.")
    }

    private static func normalizedID(_ raw: String) -> String? {
        let value = raw.replacingOccurrences(of: "-", with: "").lowercased()
        guard value.count == 32, value.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        return value
    }
    private static func pageID(_ url: URL) -> String? {
        let component = url.lastPathComponent
        if let id = normalizedID(component) { return id }
        if component.count >= 36, let id = normalizedID(String(component.suffix(36))) { return id }
        return component.count >= 32 ? normalizedID(String(component.suffix(32))) : nil
    }
    private static func json(_ object: [String: Any]) throws -> String {
        String(data: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)!
    }

    func search(_ request: ConnectionSearch, account: ConnectionAccount, token: String) async throws -> [ConnectionHit] {
        let session = Session(token: token, http: http)
        try await session.connect()
        let tools = try await session.tools()
        let accessTool = try Self.tool("get-tool-access", in: tools)
        let accessResult = try await session.call(accessTool.name, arguments: [:])
        guard let access = Self.object(accessResult)["current_tool_access"] as? [String: Any] else {
            throw ConnectionFailure("Notion could not report search permissions for this connection.")
        }
        let ai = access["ai_search"] as? [String: Any] ?? [:]
        let status = ai["status"] as? String
        let advertisedAI = tools.first { Self.base($0.name) == "ai-search" }
        let advertisedSearch = tools.first { Self.base($0.name) == "search" }
        let tool: Tool
        var notices: [String] = []
        if status == "available", let advertisedAI { tool = advertisedAI }
        else if status == "not_enabled" {
            throw ConnectionFailure("Notion AI search is disabled for this workspace. Ask the workspace owner to review its connection or billing settings.")
        } else if let advertisedSearch {
            tool = advertisedSearch
            if status == "upgrade_required" || status == "plan_required" {
                notices.append("Notion keyword search only; connected-source AI search is unavailable on this plan.")
            }
        } else if let advertisedAI, status == "upgrade_required" || status == "plan_required" {
            tool = advertisedAI
            notices.append("Notion keyword search only; connected-source AI search is unavailable on this plan.")
        } else { throw ConnectionFailure("This Notion connection does not expose a usable read-only search tool.") }

        var arguments: [String: Any] = [:]
        guard tool.properties["query"] != nil else { throw ConnectionFailure("Notion's search tool schema is not supported by this version of mnml.") }
        arguments["query"] = String(request.query.split(whereSeparator: { $0.isWhitespace }).prefix(50).joined(separator: " ").prefix(500))
        if tool.properties["query_type"] != nil { arguments["query_type"] = "internal" }
        for key in ["limit", "page_size", "max_results"] where tool.properties[key] != nil {
            arguments[key] = min(10, max(1, request.limit)); break
        }
        try tool.validate(arguments)
        let result = try await session.call(tool.name, arguments: arguments)
        let content = Self.object(result)
        notices += Self.notices(content)
        guard let rows = Self.resultRows(content) else {
            throw ConnectionFailure("Notion returned a search response that mnml could not read.")
        }
        var hits: [ConnectionHit] = [], seen = Set<String>(), excluded = false
        for row in rows.prefix(100) {
            guard let url = Self.notionURL(row["url"] as? String ?? row["page_url"] as? String) else {
                // AI search can include other connected services. Their fetch
                // contract and consent belong to their own connector.
                excluded = true; continue
            }
            let id = row["id"] as? String ?? url.absoluteString
            guard seen.insert(id).inserted else { continue }
            let title = Self.string(row["title"]) ?? row["name"] as? String ?? "Untitled Notion page"
            let detail = [row["last_edited_time"] as? String, row["page_last_edited_at"] as? String,
                          Self.string(row["path"])].compactMap { $0 }.joined(separator: " · ")
            let snippet = row["snippet"] as? String ?? row["highlight"] as? String ?? row["content"] as? String ?? ""
            hits.append(ConnectionHit(id: String(id.prefix(500)), service: .notion, accountID: account.id,
                title: String(title.prefix(500)), url: url, detail: detail, snippet: String(snippet.prefix(1_000)), accountTitle: account.displayIdentity))
            if hits.count >= min(10, max(1, request.limit)) { break }
        }
        if excluded { notices.append("Results from other connected apps are omitted; select their mnml connection to search and read them.") }
        let notice = Array(Set(notices)).sorted().joined(separator: " ")
        if !notice.isEmpty {
            if hits.isEmpty { throw ConnectionFailure("No readable Notion page matched this search. \(notice)") }
            for index in hits.indices { hits[index].detail += (hits[index].detail.isEmpty ? "" : " · ") + notice }
        }
        return hits
    }

    func fetch(_ hit: ConnectionHit, token: String) async throws -> ConnectionDocument {
        guard let url = Self.notionURL(hit.url.absoluteString) else {
            throw ConnectionFailure("Only Notion pages found by this connection can be fetched with Notion.")
        }
        let session = Session(token: token, http: http)
        try await session.connect()
        let tool = try Self.tool("fetch", in: try await session.tools())
        guard let key = ["id", "url", "page_id"].first(where: { tool.properties[$0] != nil }) else {
            throw ConnectionFailure("Notion's fetch tool schema is not supported by this version of mnml.")
        }
        let arguments: [String: Any] = [key: key == "page_id" ? hit.id : url.absoluteString]
        try tool.validate(arguments)
        let result = try await session.call(tool.name, arguments: arguments)
        let content = Self.object(result)
        let text = content["markdown"] as? String ?? content["text"] as? String ?? content["content"] as? String
            ?? (content["page"] as? [String: Any]).flatMap { $0["markdown"] as? String ?? $0["content"] as? String }
            ?? Self.text(result)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConnectionFailure("This Notion page returned no readable text.")
        }
        let truncated = content["truncated"] as? Bool == true ? "\n[Notion returned partial page content]" : ""
        return ConnectionDocument(hit: hit, text: ConnectionRetrieval.bounded(text) + truncated)
    }

    static func notionURL(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw), url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased(),
              ["notion.so", "notion.com", "notion.site"].contains(where: { host == $0 || host.hasSuffix("." + $0) }),
              !url.path.isEmpty, url.path != "/" else { return nil }
        return url
    }

    private static func base(_ name: String) -> String {
        name.hasPrefix("notion-") ? String(name.dropFirst(7)) : name
    }

    private static func tool(_ base: String, in tools: [Tool]) throws -> Tool {
        guard let tool = tools.first(where: { Self.base($0.name) == base }) else {
            throw ConnectionFailure("Notion has not enabled the \(base) tool for this connection.")
        }
        return tool
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let parts = value as? [[String: Any]] {
            let text = parts.compactMap { $0["plain_text"] as? String ?? ($0["text"] as? [String: Any])?["content"] as? String }.joined()
            return text.isEmpty ? nil : text
        }
        return nil
    }

    private static func resultRows(_ object: [String: Any]) -> [[String: Any]]? {
        for key in ["results", "pages", "search_results"] {
            if let rows = object[key] as? [[String: Any]] { return rows }
        }
        if let data = object["data"] as? [String: Any] { return resultRows(data) }
        return nil
    }

    private static func notices(_ object: [String: Any]) -> [String] {
        (object["notices"] as? [Any] ?? []).compactMap {
            if let text = $0 as? String { return String(text.prefix(500)) }
            if let notice = $0 as? [String: Any], let text = notice["message"] as? String ?? notice["reason"] as? String { return String(text.prefix(500)) }
            return nil
        }
    }

    private static func object(_ result: [String: Any]) -> [String: Any] {
        if let structured = result["structuredContent"] as? [String: Any] { return structured }
        for block in result["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "text" {
            if let value = block["text"] as? String, let data = value.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return object }
        }
        return [:]
    }

    private static func text(_ result: [String: Any]) -> String {
        (result["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }.joined(separator: "\n\n")
    }

    private struct Tool {
        let name: String
        let schema: [String: Any]
        let properties: [String: Any]
        let required: [String]
        func validate(_ arguments: [String: Any]) throws {
            if required.contains(where: { arguments[$0] == nil }) {
                throw ConnectionFailure("Notion's \(name) tool requires options this version of mnml does not support.")
            }
        }
        func validateWrite(_ arguments: [String: Any]) throws {
            guard Self.matches(arguments, schema: schema, root: schema), !properties.isEmpty else {
                throw ConnectionFailure("Notion's \(name) write schema is not supported by this version of mnml.")
            }
        }
        /// Validate the subset of JSON Schema used by the hosted page tools.
        /// Unknown required options and generated fields absent from the schema
        /// fail closed; a tool name alone never authorizes a payload.
        private static func matches(_ value: Any, schema: [String: Any], root: [String: Any], depth: Int = 0) -> Bool {
            guard depth < 24 else { return false }
            if let reference = schema["$ref"] as? String {
                guard reference.hasPrefix("#/"), reference.utf8.count < 512 else { return false }
                var current: Any = root
                for part in reference.dropFirst(2).split(separator: "/") {
                    guard let next = (current as? [String: Any])?[String(part)] else { return false }; current = next
                }
                guard let resolved = current as? [String: Any] else { return false }
                return matches(value, schema: resolved, root: root, depth: depth + 1)
            }
            for key in ["anyOf", "oneOf"] {
                if let alternatives = schema[key] as? [[String: Any]] {
                    return alternatives.contains { matches(value, schema: $0, root: root, depth: depth + 1) }
                }
            }
            if let all = schema["allOf"] as? [[String: Any]], !all.allSatisfy({ matches(value, schema: $0, root: root, depth: depth + 1) }) { return false }
            if let enumeration = schema["enum"] as? [String] {
                guard let text = value as? String, enumeration.contains(text) else { return false }
            }
            if let constant = schema["const"] as? String, value as? String != constant { return false }
            let type = schema["type"] as? String
            if let object = value as? [String: Any] {
                guard type == nil || type == "object" else { return false }
                let fields = schema["properties"] as? [String: Any] ?? [:]
                let required = schema["required"] as? [String] ?? []
                guard required.allSatisfy({ object[$0] != nil }) else { return false }
                for (key, item) in object {
                    if let field = fields[key] as? [String: Any] {
                        guard matches(item, schema: field, root: root, depth: depth + 1) else { return false }
                    } else if let additional = schema["additionalProperties"] as? [String: Any] {
                        guard matches(item, schema: additional, root: root, depth: depth + 1) else { return false }
                    } else if schema["additionalProperties"] as? Bool != true { return false }
                }
                return true
            }
            if let array = value as? [Any] {
                guard type == nil || type == "array", let item = schema["items"] as? [String: Any],
                      array.count >= (schema["minItems"] as? Int ?? 0), array.count <= (schema["maxItems"] as? Int ?? Int.max) else { return false }
                return array.allSatisfy { matches($0, schema: item, root: root, depth: depth + 1) }
            }
            if let text = value as? String {
                return (type == nil || type == "string") && text.count >= (schema["minLength"] as? Int ?? 0) && text.count <= (schema["maxLength"] as? Int ?? Int.max)
            }
            if value is Bool { return type == nil || type == "boolean" }
            return value is NSNull && type == "null"
        }
    }

    private final class Session {
        let token: String
        let http: ConnectionHTTP
        let writes: Bool
        var sessionID: String?
        var version = "2025-06-18"
        init(token: String, http: @escaping ConnectionHTTP, writes: Bool = false) {
            self.token = token; self.http = http; self.writes = writes
        }

        func connect() async throws {
            let initialized = try await rpc("initialize", params: ["protocolVersion": version, "capabilities": [:],
                "clientInfo": ["name": "mnml", "version": "1.0"]])
            guard let negotiated = initialized["protocolVersion"] as? String,
                  ["2025-06-18", "2025-03-26"].contains(negotiated) else {
                throw ConnectionFailure("Notion requires an MCP protocol version this mnml build does not support.")
            }
            version = negotiated
            _ = try await rpc("notifications/initialized", params: [:], notification: true)
        }

        func tools() async throws -> [Tool] {
            var result: [Tool] = [], cursor: String?
            for _ in 0..<3 {
                let page = try await rpc("tools/list", params: cursor.map { ["cursor": $0] } ?? [:])
                for item in page["tools"] as? [[String: Any]] ?? [] {
                    guard let name = item["name"] as? String,
                          (["get-tool-access", "search", "ai-search", "fetch"] + (writes ? ["create-pages", "update-page"] : [])).contains(ConnectionNotion.base(name)),
                          let schema = item["inputSchema"] as? [String: Any] else { continue }
                    result.append(Tool(name: name, schema: schema, properties: schema["properties"] as? [String: Any] ?? [:], required: schema["required"] as? [String] ?? []))
                }
                guard let next = page["nextCursor"] as? String, next != cursor else { break }
                cursor = next
            }
            return result
        }

        func call(_ name: String, arguments: [String: Any]) async throws -> [String: Any] {
            guard (["get-tool-access", "search", "ai-search", "fetch"] + (writes ? ["create-pages", "update-page"] : [])).contains(ConnectionNotion.base(name)) else {
                throw ConnectionFailure("This Notion tool is not allowed by the read-only connector.")
            }
            let result = try await rpc("tools/call", params: ["name": name, "arguments": arguments])
            if result["isError"] as? Bool == true {
                let object = ConnectionNotion.object(result)
                if let error = object["error"] as? [String: Any], error["code"] as? String == "rate_limited" {
                    let retry = (error["retry_after_seconds"] as? NSNumber).map { " Try again in \($0.intValue) seconds." } ?? ""
                    throw ConnectionFailure("Notion is limiting requests.\(retry)")
                }
                // Tool failures are data from a remote service; show a bounded
                // message and do not act on returned links/instructions.
                let message = ConnectionNotion.text(result)
                throw ConnectionFailure("Notion could not complete this request. " + String(message.prefix(500)))
            }
            return result
        }

        func rpc(_ method: String, params: [String: Any], notification: Bool = false) async throws -> [String: Any] {
            let id = UUID().uuidString
            var message: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
            if !notification { message["id"] = id }
            var request = URLRequest(url: URL(string: "https://mcp.notion.com/mcp")!, timeoutInterval: 30)
            request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: message)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue("mnml/1.0", forHTTPHeaderField: "User-Agent")
            if method != "initialize" { request.setValue(version, forHTTPHeaderField: "MCP-Protocol-Version") }
            if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
            let (data, response) = try await ConnectionRetrievalTransport.checked(request, http: http)
            if method == "initialize", let opaque = response.value(forHTTPHeaderField: "Mcp-Session-Id"), opaque.utf8.count <= 1_024 {
                sessionID = opaque
            }
            if notification { return [:] }
            let envelope = try ConnectionNotion.envelope(data, contentType: response.value(forHTTPHeaderField: "Content-Type") ?? "application/json", id: id)
            if let error = envelope["error"] as? [String: Any] {
                throw ConnectionFailure("Notion returned an MCP error: " + String((error["message"] as? String ?? "Request failed").prefix(500)))
            }
            guard let result = envelope["result"] as? [String: Any] else {
                throw ConnectionFailure("Notion returned an incomplete MCP response.")
            }
            return result
        }
    }

    /// Streamable HTTP may answer each POST with JSON or a finite SSE stream.
    /// Match the RPC id; notifications and unrelated messages are never treated
    /// as the requested result. CRLF and multi-line data fields are supported.
    static func envelope(_ data: Data, contentType: String, id: String) throws -> [String: Any] {
        let payloads: [Data]
        if contentType.lowercased().contains("text/event-stream") {
            guard let text = String(data: data, encoding: .utf8) else { throw ConnectionFailure("Notion returned unreadable stream data.") }
            payloads = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n").prefix(1_000).compactMap { event in
                let lines = event.components(separatedBy: "\n").compactMap { line -> String? in
                    guard line.hasPrefix("data:") else { return nil }
                    let value = String(line.dropFirst(5)); return value.hasPrefix(" ") ? String(value.dropFirst()) : value
                }
                return lines.isEmpty ? nil : lines.joined(separator: "\n").data(using: .utf8)
            }
        } else { payloads = [data] }
        for payload in payloads {
            guard let value = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  value["jsonrpc"] as? String == "2.0", value["id"] as? String == id else { continue }
            return value
        }
        throw ConnectionFailure("Notion did not return the requested MCP result.")
    }
}
