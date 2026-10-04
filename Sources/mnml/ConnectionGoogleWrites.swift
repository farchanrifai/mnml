import Foundation
import CryptoKit

/// Fixed Google mutations. The caller supplies only provider IDs resolved from
/// the current account's returned sources, never arbitrary HTTP requests.
struct ConnectionGoogleWrites {
    let http: ConnectionHTTP
    private static let sheet = "application/vnd.google-apps.spreadsheet"
    private static let doc = "application/vnd.google-apps.document"
    private static let folder = "application/vnd.google-apps.folder"
    private static let metadataFields = "id,name,mimeType,parents,version,driveId,trashed,capabilities(canEdit,canModifyContent,canAddChildren,canMoveItemWithinDrive)"

    func prepare(_ plan: ConnectionWritePlan, account: ConnectionAccount, target: ConnectionHit?,
                 destination: ConnectionHit?, token: String) async throws -> ConnectionPreparedWrite {
        try validate(plan, account: account, target: target, destination: destination)
        var state: [String: String] = [:], before = ""
        var freshTarget = target, freshDestination = destination
        var targetMetadata: [String: Any]?
        if let target {
            let metadata = try await file(target.id, token: token)
            try editable(metadata)
            targetMetadata = metadata
            state["target"] = try digest(metadata)
            freshTarget = hit(target.id, metadata: metadata, account: account)
        }
        if let destination {
            let metadata = try await file(destination.id, token: token)
            guard metadata["mimeType"] as? String == Self.folder,
                  capability(metadata, "canAddChildren") else {
                throw ConnectionFailure("The destination must be a writable Drive folder.")
            }
            state["destination"] = try digest(metadata)
            freshDestination = hit(destination.id, metadata: metadata, account: account)
            if [.createSheet, .createDoc].contains(plan.operation), metadata["driveId"] != nil {
                throw ConnectionFailure("Create the document in My Drive first. Creating directly inside a shared drive is not supported yet.")
            }
            if plan.operation == .moveDrive, let targetMetadata {
                guard targetMetadata["driveId"] as? String == metadata["driveId"] as? String else {
                    throw ConnectionFailure("Move files within the same Drive. Moving between My Drive and shared drives is not supported yet.")
                }
                let parents = targetMetadata["parents"] as? [String] ?? []
                guard !parents.contains(destination.id) else { throw ConnectionFailure("This file is already in the destination folder.") }
            }
        }
        switch plan.operation {
        case .updateSheet:
            guard let target, let metadata = targetMetadata, metadata["mimeType"] as? String == Self.sheet else {
                throw ConnectionFailure("Choose a Google Sheet before writing cells.")
            }
            let rectangle = try Self.rectangle(plan.range!, values: plan.values!)
            let values = try await sheetValues(target.id, range: plan.range!, token: token)
            try Self.checkReadValues(values, rectangle: rectangle)
            let data = try Self.canonical(values)
            guard data.count <= 32_000 else { throw ConnectionFailure("The existing cells exceed the 32 KB review limit. Choose a smaller range.") }
            state["values"] = Self.hash(data)
            before = Self.table(values)
        case .appendDoc:
            guard let target, let metadata = targetMetadata, metadata["mimeType"] as? String == Self.doc else {
                throw ConnectionFailure("Choose a Google Doc before appending text.")
            }
            let document = try await docState(target.id, token: token)
            state["revision"] = document.revision; state["tab"] = document.tab
            before = "Append to the first tab: \(document.title)\n\n" + String(document.text.suffix(2_000))
        case .moveDrive:
            guard let metadata = targetMetadata, metadata["mimeType"] as? String != Self.folder,
                  capability(metadata, "canMoveItemWithinDrive"), let parents = metadata["parents"] as? [String],
                  !parents.isEmpty else {
                throw ConnectionFailure("Only files with a writable current parent can be moved. Folder moves are not supported yet.")
            }
            state["parents"] = parents.sorted().joined(separator: ",")
            before = "Current parent folder: " + parents.joined(separator: ", ")
        case .createSheet, .createDoc:
            before = destination.map { "Create in folder: \($0.title)" } ?? "Create in My Drive."
        case .createNotion, .appendNotion:
            throw ConnectionFailure("Use the Notion connection for this operation.")
        }
        return ConnectionPreparedWrite(plan: plan, account: account, target: freshTarget,
            destination: freshDestination, before: before, state: state)
    }

    func execute(_ prepared: ConnectionPreparedWrite, token: String) async throws -> ConnectionWriteResult {
        // All preflight reads are repeated after approval. A changed source or
        // destination needs a new preview rather than a silent overwrite.
        let current = try await prepare(prepared.plan, account: prepared.account,
            target: prepared.target, destination: prepared.destination, token: token)
        guard current.state == prepared.state else {
            throw ConnectionFailure("The file or destination changed while this write was being reviewed. Review a new proposal before writing.")
        }
        let plan = prepared.plan
        switch plan.operation {
        case .createSheet: return try await createSheet(prepared, token: token)
        case .createDoc: return try await createDoc(prepared, token: token)
        case .updateSheet:
            let target = prepared.target!
            _ = try await mutation("sheets", path: "v4/spreadsheets/\(target.id)/values/\(Self.segment(plan.range!))",
                method: "PUT", query: ["valueInputOption": "RAW"],
                body: ["range": plan.range!, "majorDimension": "ROWS", "values": plan.values!.map { $0.map(\.json) }],
                token: token, existing: target)
            return ConnectionWriteResult(hit: current.target!, summary: "Wrote \(plan.range!) in \(current.target!.title).")
        case .appendDoc:
            let target = prepared.target!
            try await insertText(target.id, text: plan.text!, revision: prepared.state["revision"]!,
                tab: prepared.state["tab"]!, token: token, existing: target)
            return ConnectionWriteResult(hit: current.target!, summary: "Appended text to the first tab of \(current.target!.title).")
        case .moveDrive:
            let target = prepared.target!, destination = prepared.destination!
            _ = try await mutation("drive", path: "drive/v3/files/\(target.id)", method: "PATCH",
                query: ["addParents": destination.id, "removeParents": prepared.state["parents"]!,
                        "supportsAllDrives": "true", "fields": "id,name,mimeType"], body: [:], token: token, existing: target)
            return ConnectionWriteResult(hit: current.target!, summary: "Moved \(current.target!.title) into \(current.destination!.title).")
        case .createNotion, .appendNotion: throw ConnectionFailure("Use the Notion connection for this operation.")
        }
    }

    private func validate(_ plan: ConnectionWritePlan, account: ConnectionAccount,
                          target: ConnectionHit?, destination: ConnectionHit?) throws {
        try plan.validate()
        guard account.id == plan.account, account.provider == .google,
              account.services.contains(.drive), account.canWrite(.drive), plan.operation.service == .drive else {
            throw ConnectionFailure("Enable Drive write access for this account before proposing a change.")
        }
        guard plan.source == target?.reference, plan.destination == destination?.reference,
              (plan.operation.needsSource ? target != nil : target == nil),
              (plan.operation.needsDestination ? destination != nil : true) else {
            throw ConnectionFailure("The write proposal does not match its selected source and destination.")
        }
        if [.updateSheet, .appendDoc].contains(plan.operation), destination != nil {
            throw ConnectionFailure("This operation writes the existing source and does not accept a destination folder.")
        }
        for source in [target, destination].compactMap({ $0 }) {
            guard source.accountID == account.id, source.service == .drive else {
                throw ConnectionFailure("A write cannot use a source or destination from another account.")
            }
            _ = try ConnectionRetrieval.identifier(source.id)
        }
        if plan.operation == .moveDrive, target?.id == destination?.id {
            throw ConnectionFailure("A file cannot be moved into itself.")
        }
        if [.createSheet, .updateSheet].contains(plan.operation), let values = plan.values {
            for cell in values.flatMap({ $0 }) {
                if case .number(let number) = cell, !number.isFinite {
                    throw ConnectionFailure("Sheet numbers must be finite.")
                }
            }
            if plan.operation == .updateSheet { _ = try Self.rectangle(plan.range!, values: values) }
            else if plan.range != nil {
                throw ConnectionFailure("New Sheets start at Sheet1!A1. Omit a range when creating a Sheet.")
            }
        }
    }

    private func createSheet(_ prepared: ConnectionPreparedWrite, token: String) async throws -> ConnectionWriteResult {
        let plan = prepared.plan, values = plan.values!
        let rows: [[String: Any]] = values.map { row in
            ["values": row.map { cell -> [String: Any] in
                let entered: [String: Any]
                switch cell {
                case .string(let text): entered = ["stringValue": text]
                case .number(let number): entered = ["numberValue": number]
                case .bool(let bool): entered = ["boolValue": bool]
                case .empty: entered = ["stringValue": ""]
                }
                return ["userEnteredValue": entered]
            }]
        }
        let response = try await mutation("sheets", path: "v4/spreadsheets", method: "POST",
            query: ["fields": "spreadsheetId"],
            body: ["properties": ["title": plan.title!], "sheets": [["properties": ["title": "Sheet1",
                "gridProperties": ["rowCount": max(1_000, values.count), "columnCount": max(26, values[0].count)]],
                "data": [["startRow": 0, "startColumn": 0, "rowData": rows]]]]], token: token)
        guard let raw = response["spreadsheetId"] as? String, let id = try? ConnectionRetrieval.identifier(raw) else {
            throw ConnectionFailure("Google may have created the Sheet, but did not return its ID. Check Drive before trying again.")
        }
        let created = hit(id, metadata: ["name": plan.title!, "mimeType": Self.sheet], account: prepared.account)
        do { try await placeCreated(created, prepared: prepared, token: token) }
        catch { throw ConnectionWritePartialFailure(hit: created, message: "The Sheet was created at \(created.url.absoluteString), but folder placement failed: \(error.localizedDescription) Check the created Sheet before retrying.") }
        return ConnectionWriteResult(hit: created, summary: "Created Google Sheet \(created.title).")
    }

    private func createDoc(_ prepared: ConnectionPreparedWrite, token: String) async throws -> ConnectionWriteResult {
        let plan = prepared.plan
        let response = try await mutation("docs", path: "v1/documents", method: "POST", body: ["title": plan.title!], token: token)
        guard let raw = response["documentId"] as? String, let id = try? ConnectionRetrieval.identifier(raw) else {
            throw ConnectionFailure("Google may have created the Doc, but did not return its ID. Check Drive before trying again.")
        }
        let created = hit(id, metadata: ["name": plan.title!, "mimeType": Self.doc], account: prepared.account)
        do {
            let document = try await docState(id, token: token)
            try await insertText(id, text: plan.text!, revision: document.revision, tab: document.tab, token: token, existing: created)
        } catch {
            throw ConnectionWritePartialFailure(hit: created, message: "The Doc was created at \(created.url.absoluteString), but its text was not confirmed: \(error.localizedDescription) Check the created Doc before retrying.")
        }
        do { try await placeCreated(created, prepared: prepared, token: token) }
        catch { throw ConnectionWritePartialFailure(hit: created, message: "The Doc and its text were created at \(created.url.absoluteString), but folder placement failed: \(error.localizedDescription) Check the created Doc before retrying.") }
        return ConnectionWriteResult(hit: created, summary: "Created Google Doc \(created.title).")
    }

    private func placeCreated(_ created: ConnectionHit, prepared: ConnectionPreparedWrite, token: String) async throws {
        guard let destination = prepared.destination else { return }
        let folder = try await file(destination.id, token: token)
        guard try digest(folder) == prepared.state["destination"], folder["driveId"] == nil,
              capability(folder, "canAddChildren") else {
            throw ConnectionFailure("The destination folder changed since approval.")
        }
        let metadata = try await file(created.id, token: token)
        try editable(metadata)
        guard metadata["driveId"] == nil, capability(metadata, "canMoveItemWithinDrive"),
              let parents = metadata["parents"] as? [String], !parents.isEmpty else {
            throw ConnectionFailure("The created file could not be moved out of its current folder.")
        }
        _ = try await mutation("drive", path: "drive/v3/files/\(created.id)", method: "PATCH",
            query: ["addParents": destination.id, "removeParents": parents.sorted().joined(separator: ","),
                    "supportsAllDrives": "true", "fields": "id,name,mimeType"], body: [:], token: token, existing: created)
    }

    private func insertText(_ id: String, text: String, revision: String, tab: String,
                            token: String, existing: ConnectionHit) async throws {
        _ = try await mutation("docs", path: "v1/documents/\(id):batchUpdate", method: "POST",
            body: ["writeControl": ["requiredRevisionId": revision],
                   "requests": [["insertText": ["text": text, "endOfSegmentLocation": ["tabId": tab]]]]],
            token: token, existing: existing)
    }

    private func file(_ raw: String, token: String) async throws -> [String: Any] {
        let id = try ConnectionRetrieval.identifier(raw)
        let response = try await json("drive", path: "drive/v3/files/\(id)",
            query: ["fields": Self.metadataFields, "supportsAllDrives": "true"], token: token)
        guard response["id"] as? String == id, response["trashed"] as? Bool == false,
              let version = response["version"] as? String, !version.isEmpty, version.count <= 32,
              response["mimeType"] is String, response["name"] is String else {
            throw ConnectionFailure("Drive did not return an available, versioned file for review.")
        }
        if let parents = response["parents"] as? [String] {
            guard parents.count <= 1 else { throw ConnectionFailure("Drive returned an unsupported parent list.") }
            for parent in parents { _ = try ConnectionRetrieval.identifier(parent) }
        }
        if let drive = response["driveId"] as? String { _ = try ConnectionRetrieval.identifier(drive) }
        return response
    }

    private func editable(_ metadata: [String: Any]) throws {
        guard capability(metadata, "canEdit"), (metadata["capabilities"] as? [String: Any])?["canModifyContent"] as? Bool != false else {
            throw ConnectionFailure("The connected account cannot edit this file.")
        }
    }
    private func capability(_ metadata: [String: Any], _ key: String) -> Bool {
        (metadata["capabilities"] as? [String: Any])?[key] as? Bool == true
    }
    private func digest(_ metadata: [String: Any]) throws -> String { Self.hash(try Self.canonical(metadata)) }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func canonical(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) }

    private func sheetValues(_ id: String, range: String, token: String) async throws -> [[Any]] {
        let response = try await json("sheets", path: "v4/spreadsheets/\(id)/values/\(Self.segment(range))",
            query: ["valueRenderOption": "FORMULA", "majorDimension": "ROWS"], token: token)
        if response["values"] == nil { return [] }
        guard let values = response["values"] as? [[Any]] else { throw ConnectionFailure("Google returned unreadable existing cells.") }
        return values
    }

    private func docState(_ id: String, token: String) async throws -> (revision: String, tab: String, title: String, text: String) {
        let response = try await json("docs", path: "v1/documents/\(id)", query: ["includeTabsContent": "true",
            "fields": "revisionId,title,tabs(tabProperties,documentTab(body(content)))"], token: token)
        guard let revision = response["revisionId"] as? String, !revision.isEmpty, revision.utf8.count <= 1_024,
              let first = (response["tabs"] as? [[String: Any]])?.first,
              let properties = first["tabProperties"] as? [String: Any], let tab = properties["tabId"] as? String,
              !tab.isEmpty, tab.utf8.count <= 256, let document = first["documentTab"] as? [String: Any] else {
            throw ConnectionFailure("Google did not return a writable revision and first document tab.")
        }
        let content = (document["body"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        let text = content.flatMap { (($0["paragraph"] as? [String: Any])?["elements"] as? [[String: Any]] ?? []) }
            .compactMap { ($0["textRun"] as? [String: Any])?["content"] as? String }.joined()
        return (revision, tab, properties["title"] as? String ?? "First tab", text)
    }

    private func hit(_ id: String, metadata: [String: Any], account: ConnectionAccount) -> ConnectionHit {
        let mime = metadata["mimeType"] as? String ?? "", url: URL
        switch mime {
        case Self.sheet: url = URL(string: "https://docs.google.com/spreadsheets/d/\(id)/edit")!
        case Self.doc: url = URL(string: "https://docs.google.com/document/d/\(id)/edit")!
        case Self.folder: url = URL(string: "https://drive.google.com/drive/folders/\(id)")!
        default: url = URL(string: "https://drive.google.com/file/d/\(id)/view")!
        }
        return ConnectionHit(id: id, service: .drive, accountID: account.id,
            title: metadata["name"] as? String ?? "Untitled file", url: url, detail: mime, snippet: "", accountTitle: account.displayIdentity)
    }

    private func json(_ api: String, path: String, method: String = "GET", query: [String: String] = [:],
                      body: [String: Any]? = nil, token: String) async throws -> [String: Any] {
        let host = api == "sheets" ? "sheets.googleapis.com" : api == "docs" ? "docs.googleapis.com" : "www.googleapis.com"
        var components = URLComponents(string: "https://\(host)/\(path)")!
        components.queryItems = query.isEmpty ? nil : query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { request.httpBody = try Self.canonical(body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let data = try await ConnectionRetrievalTransport.checked(request, http: http).0
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConnectionFailure("Google returned an unreadable write response.")
        }
        return response
    }

    private func mutation(_ api: String, path: String, method: String, query: [String: String] = [:],
                          body: [String: Any], token: String, existing: ConnectionHit? = nil) async throws -> [String: Any] {
        // A write is sent once. Network failure or cancellation cannot safely
        // prove that the service did not apply it; never retry automatically.
        do { return try await json(api, path: path, method: method, query: query, body: body, token: token) }
        catch {
            let address = existing.map { " Check \($0.url.absoluteString) before trying again." } ?? " Check Drive before trying again."
            throw ConnectionFailure("The write did not return a confirmed result and may already have been applied.\(address) \(error.localizedDescription)")
        }
    }

    private static func segment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~")))!
    }
    private struct Rectangle { let rows: Int; let columns: Int }
    private static func rectangle(_ range: String, values: [[ConnectionCell]]) throws -> Rectangle {
        // Named ranges and open-ended rows/columns can address unexpectedly
        // large areas. Require an explicit sheet and exact finite rectangle.
        let expression = try NSRegularExpression(pattern: "^(?:'(?:[^']|'')+'|[A-Za-z_][A-Za-z0-9_. ]*)!([A-Z]{1,3})([1-9][0-9]{0,6})(?::([A-Z]{1,3})([1-9][0-9]{0,6}))?$")
        let ns = range as NSString
        guard let match = expression.firstMatch(in: range, range: NSRange(location: 0, length: ns.length)) else {
            throw ConnectionFailure("Choose an exact sheet-qualified range, for example 'Sheet1'!A1:B2.")
        }
        func group(_ n: Int) -> String? { match.range(at: n).location == NSNotFound ? nil : ns.substring(with: match.range(at: n)) }
        func column(_ value: String) -> Int { value.utf8.reduce(0) { $0 * 26 + Int($1) - 64 } }
        let startColumn = column(group(1)!), startRow = Int(group(2)!)!
        let endColumn = column(group(3) ?? group(1)!), endRow = Int(group(4) ?? group(2)!)!
        let rows = endRow - startRow + 1, columns = endColumn - startColumn + 1
        guard rows > 0, columns > 0, rows <= 2_000, columns <= 2_000, rows * columns <= 2_000,
              values.count == rows, values.allSatisfy({ $0.count == columns }) else {
            throw ConnectionFailure("The proposed cells must exactly fit the reviewed A1 range, with at most 2,000 cells.")
        }
        return Rectangle(rows: rows, columns: columns)
    }
    private static func checkReadValues(_ values: [[Any]], rectangle: Rectangle) throws {
        guard values.count <= rectangle.rows, values.allSatisfy({ $0.count <= rectangle.columns }),
              values.flatMap({ $0 }).allSatisfy({ $0 is String || $0 is NSNumber || $0 is NSNull }) else {
            throw ConnectionFailure("Google returned cells outside the range being reviewed.")
        }
    }
    private static func table(_ values: [[Any]]) -> String {
        if values.isEmpty { return "The selected cells are empty." }
        return (try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}
