import Foundation

enum ConnectionProvider: String, Codable, Sendable { case google, notion }

enum ConnectionService: String, CaseIterable, Codable, Identifiable, Sendable {
    case gmail, calendar, drive, notion
    var id: String { rawValue }
    var provider: ConnectionProvider { self == .notion ? .notion : .google }
    var title: String {
        switch self { case .gmail: "Gmail"; case .calendar: "Calendar"; case .drive: "Drive"; case .notion: "Notion" }
    }
    var icon: String {
        switch self { case .gmail: "envelope"; case .calendar: "calendar"; case .drive: "doc.on.doc"; case .notion: "square.grid.2x2" }
    }
}

struct ConnectionAccount: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var provider: ConnectionProvider
    var title: String
    var services: [ConnectionService]
    var label: String? = nil
    var writableServices: [ConnectionService]? = nil
    func canWrite(_ service: ConnectionService) -> Bool { writableServices?.contains(service) == true }

    var displayTitle: String {
        let name = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? title : name
    }
    /// A friendly label never replaces the provider's account identity.
    var displayIdentity: String { displayTitle == title ? title : displayTitle + " · " + title }
}

struct ConnectionSelection: Codable, Hashable, Identifiable, Sendable {
    var service: ConnectionService
    var accountID: UUID
    var id: String { service.rawValue + ":" + accountID.uuidString }
}

struct ConnectionSpacePolicy: Codable, Equatable, Sendable {
    var accountIDs: [UUID]
    var automatic: Bool = true
    var writeAccountIDs: [UUID]? = nil
}

/// Identifiers and citation metadata may be kept with a chat; OAuth credentials
/// and complete fetched documents never belong in saved turns.
struct ConnectionHit: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var service: ConnectionService
    var accountID: UUID
    var title: String
    var url: URL
    var detail: String
    var snippet: String
    var accountTitle: String? = nil
    /// The provider ID alone can collide between services or accounts.
    var reference: String { service.rawValue + ":" + accountID.uuidString + ":" + id }
}

struct ConnectionDocument: Sendable {
    var hit: ConnectionHit
    var text: String
}

struct ConnectionSearch: Sendable {
    var service: ConnectionService
    var query: String
    var limit: Int = 5
    var start: Date? = nil
    var end: Date? = nil
}

struct ConnectionFailure: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

/// A shared seam for authenticated API clients and deterministic fixture tests.
typealias ConnectionHTTP = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
