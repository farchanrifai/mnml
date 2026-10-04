import Foundation

enum ConnectionWriteOperation: String, Codable, CaseIterable, Sendable {
    case createSheet = "create_sheet", updateSheet = "update_sheet"
    case createDoc = "create_doc", appendDoc = "append_doc", moveDrive = "move_drive"
    case createNotion = "create_notion", appendNotion = "append_notion"
    var service: ConnectionService { self == .createNotion || self == .appendNotion ? .notion : .drive }
    var title: String {
        switch self {
        case .createSheet: return "Create Google Sheet"
        case .updateSheet: return "Write Google Sheet cells"
        case .createDoc: return "Create Google Doc"
        case .appendDoc: return "Append to Google Doc"
        case .moveDrive: return "Move Drive file"
        case .createNotion: return "Create Notion note"
        case .appendNotion: return "Append to Notion note"
        }
    }
    var needsSource: Bool { [.updateSheet, .appendDoc, .moveDrive, .appendNotion].contains(self) }
    var needsDestination: Bool { [.moveDrive, .createNotion].contains(self) }
}

/// RAW cells preserve numbers and booleans without evaluating model-generated
/// formulas. A leading '=' in a string stays literal text.
enum ConnectionCell: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), empty
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .empty }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let number = try? value.decode(Double.self), number.isFinite { self = .number(number) }
        else { self = .string(try value.decode(String.self)) }
    }
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let text): try value.encode(text)
        case .number(let number): try value.encode(number)
        case .bool(let bool): try value.encode(bool)
        case .empty: try value.encodeNil()
        }
    }
    var json: Any {
        switch self { case .string(let text): return text; case .number(let number): return number
        case .bool(let bool): return bool; case .empty: return "" }
    }
    var display: String {
        switch self { case .string(let text): return text; case .number(let number): return String(number)
        case .bool(let bool): return String(bool); case .empty: return "" }
    }
}

struct ConnectionWritePlan: Codable, Equatable, Sendable {
    var operation: ConnectionWriteOperation
    var account: UUID
    var source: String? = nil
    var destination: String? = nil
    var title: String? = nil
    var text: String? = nil
    var range: String? = nil
    var values: [[ConnectionCell]]? = nil
    var preview: String {
        if [.createSheet, .updateSheet].contains(operation), let values { return values.map { $0.map(\.display).joined(separator: "\t") }.joined(separator: "\n") }
        return operation == .moveDrive ? "Move the selected file into the destination folder." : (text ?? "")
    }
    func validate() throws {
        let sheet = [.createSheet, .updateSheet].contains(operation)
        let prose = [.createDoc, .appendDoc, .createNotion, .appendNotion].contains(operation)
        let creates = [.createSheet, .createDoc, .createNotion].contains(operation)
        guard (operation.needsSource || source == nil),
              (operation.needsDestination || [.createSheet, .createDoc].contains(operation) || destination == nil),
              (creates || title == nil), (prose || text == nil), (sheet || values == nil),
              (operation == .updateSheet || range == nil) else {
            throw ConnectionFailure("The proposed write includes fields that do not belong to this operation.")
        }
        if operation.needsSource && source == nil { throw ConnectionFailure("Choose the existing source before proposing this write.") }
        if operation.needsDestination && destination == nil { throw ConnectionFailure("Choose a destination before proposing this write.") }
        for reference in [source, destination].compactMap({ $0 }) where reference.isEmpty || reference.utf8.count > 1_024 {
            throw ConnectionFailure("The write source reference is too long.")
        }
        if [.createSheet, .createDoc, .createNotion].contains(operation) {
            guard let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 200 else {
                throw ConnectionFailure("A new document needs a title of at most 200 characters.")
            }
        }
        if [.createDoc, .appendDoc, .createNotion, .appendNotion].contains(operation) {
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 32_000 else {
                throw ConnectionFailure("Write at most 32 KB of text in one operation.")
            }
        }
        if [.createSheet, .updateSheet].contains(operation) {
            guard let values, !values.isEmpty, let width = values.first?.count, width > 0,
                  values.allSatisfy({ $0.count == width }), values.count * width <= 2_000,
                  preview.utf8.count <= 32_000 else { throw ConnectionFailure("Use a rectangular table of at most 2,000 cells and 32 KB per write.") }
            if operation == .updateSheet {
                guard let range, !range.isEmpty, range.count <= 200 else { throw ConnectionFailure("Choose the sheet name and exact A1 range to write.") }
            }
        }
        guard (try JSONEncoder().encode(self)).count <= 48_000 else { throw ConnectionFailure("This proposed write is too large. Split it into smaller changes.") }
    }
}

/// The UI approves this frozen preflight snapshot; model output cannot edit it
/// while the user reviews. Source content remains in memory, not chat history.
struct ConnectionPreparedWrite: Identifiable, Sendable {
    let id: UUID
    let plan: ConnectionWritePlan
    let account: ConnectionAccount
    let target: ConnectionHit?
    let destination: ConnectionHit?
    let before: String
    let state: [String: String]
    init(id: UUID = UUID(), plan: ConnectionWritePlan, account: ConnectionAccount,
         target: ConnectionHit? = nil, destination: ConnectionHit? = nil, before: String = "", state: [String: String] = [:]) {
        self.id = id; self.plan = plan; self.account = account; self.target = target
        self.destination = destination; self.before = before; self.state = state
    }
}
struct ConnectionWriteResult: Sendable { var hit: ConnectionHit; var summary: String }

struct ConnectionWritePartialFailure: LocalizedError, Sendable {
    let hit: ConnectionHit
    let message: String
    var errorDescription: String? { message }
}

struct ConnectionWriteReceipt: Codable, Equatable, Sendable {
    var id: UUID
    var hit: ConnectionHit?
    var summary: String
}
