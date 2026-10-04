import Foundation
import Combine

struct ConnectionPendingWrite: Identifiable {
    let prepared: ConnectionPreparedWrite
    var id: UUID { prepared.id }
}

/// Approval belongs to this chat and this immutable preview. Leaving a chat,
/// stopping its request, or changing its account policy cancels the approval.
@MainActor
final class ConnectionWriteApprovals: ObservableObject {
    static let shared = ConnectionWriteApprovals()
    @Published private(set) var pending: [UUID: ConnectionPendingWrite] = [:]
    private var waits: [UUID: CheckedContinuation<Bool, Error>] = [:]
    private var timers: [UUID: Task<Void, Never>] = [:]
    private let timeout: Duration
    init(timeout: Duration = .seconds(600)) { self.timeout = timeout }

    func request(_ prepared: ConnectionPreparedWrite, chat: UUID) async throws -> Bool {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                cancel(chat: chat)
                waits[chat] = continuation
                pending[chat] = ConnectionPendingWrite(prepared: prepared)
                timers[chat] = Task { [weak self] in
                    do { try await Task.sleep(for: self?.timeout ?? .seconds(600)) }
                    catch { return }
                    self?.resolve(chat: chat, id: prepared.id, result: .success(false))
                }
            }
        } onCancel: {
            Task { @MainActor in self.resolve(chat: chat, id: prepared.id, result: .failure(CancellationError())) }
        }
    }
    func approve(chat: UUID, id: UUID) { resolve(chat: chat, id: id, result: .success(true)) }
    func reject(chat: UUID, id: UUID) { resolve(chat: chat, id: id, result: .success(false)) }
    func cancel(chat: UUID) {
        guard let id = pending[chat]?.id else { return }
        resolve(chat: chat, id: id, result: .failure(CancellationError()))
    }
    private func resolve(chat: UUID, id: UUID, result: Result<Bool, Error>) {
        guard pending[chat]?.id == id, let wait = waits.removeValue(forKey: chat) else { return }
        timers.removeValue(forKey: chat)?.cancel()
        pending.removeValue(forKey: chat)
        wait.resume(with: result)
    }
}

/// This is a finite native API bridge, not a general CLI tool executor. Model
/// output can only propose a plan using sources already returned to its chat.
actor ConnectionWriting {
    typealias Allowed = @Sendable (ConnectionSelection, UUID?) async throws -> Bool
    static let shared = ConnectionWriting(
        accounts: {
            try await ConnectionAccounts.shared.waitUntilReady()
            return await MainActor.run { ConnectionAccounts.shared.accounts }
        }, token: { try await ConnectionAccounts.shared.token(for: $0) }, allowed: { selection, space in
            guard let space else { return false }
            return await MainActor.run {
                ConnectionAccounts.shared.writesEnabled(account: selection.accountID, in: space)
            }
        }
    )
    private let accounts: ConnectionRetrieval.Accounts
    private let token: ConnectionRetrieval.Token
    private let allowed: Allowed
    private let http: ConnectionHTTP
    private var attempted: Set<UUID> = []
    init(accounts: @escaping ConnectionRetrieval.Accounts, token: @escaping ConnectionRetrieval.Token,
         http: @escaping ConnectionHTTP = ConnectionRetrieval.network,
         allowed: @escaping Allowed = { _, _ in true }) {
        self.accounts = accounts; self.token = token; self.http = http; self.allowed = allowed
    }

    private func account(_ plan: ConnectionWritePlan, selections: [ConnectionSelection], space: UUID?) async throws -> ConnectionAccount {
        let selection = ConnectionSelection(service: plan.operation.service, accountID: plan.account)
        guard selections.contains(selection), try await allowed(selection, space),
              let account = try await accounts().first(where: { $0.id == plan.account }),
              account.provider == selection.service.provider, account.services.contains(selection.service), account.canWrite(selection.service) else {
            throw ConnectionFailure("Writes are not enabled for this account in this chat and Space. Enable writes in Connections first.")
        }
        return account
    }
    func prepare(_ plan: ConnectionWritePlan, selections: [ConnectionSelection], known: [String: ConnectionHit], space: UUID? = nil) async throws -> ConnectionPreparedWrite {
        try Task.checkCancellation(); try plan.validate()
        var account = try await account(plan, selections: selections, space: space)
        func source(_ reference: String?) throws -> ConnectionHit? {
            guard let reference else { return nil }
            guard let hit = known[reference], hit.reference == reference, hit.accountID == account.id,
                  hit.service == plan.operation.service else {
                throw ConnectionFailure("Choose a source or destination returned by a search in this chat, from this same account.")
            }
            return hit
        }
        let target = try source(plan.source), destination = try source(plan.destination)
        let bearer = try await token(account.id)
        // Refresh may reduce the grant. Check current metadata again before API reads.
        account = try await self.account(plan, selections: selections, space: space)
        if account.provider == .google {
            return try await ConnectionGoogleWrites(http: http).prepare(plan, account: account, target: target, destination: destination, token: bearer)
        }
        return try await ConnectionNotion(http: http).prepareWrite(plan, account: account, target: target, destination: destination, token: bearer)
    }
    func execute(_ prepared: ConnectionPreparedWrite, selections: [ConnectionSelection], space: UUID? = nil) async throws -> ConnectionWriteResult {
        try Task.checkCancellation()
        guard attempted.insert(prepared.id).inserted else { throw ConnectionFailure("This approved write has already been attempted. Check its result before proposing another write.") }
        let account = try await account(prepared.plan, selections: selections, space: space)
        guard account.provider == prepared.account.provider, account.title == prepared.account.title else {
            throw ConnectionFailure("The account changed while this write was being reviewed. Request a fresh preview.")
        }
        let bearer = try await token(account.id)
        _ = try await self.account(prepared.plan, selections: selections, space: space)
        try Task.checkCancellation()
        if account.provider == .google { return try await ConnectionGoogleWrites(http: http).execute(prepared, token: bearer) }
        return try await ConnectionNotion(http: http).executeWrite(prepared, token: bearer)
    }
    static func message(_ result: ConnectionWriteResult) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["status": "applied", "source": result.hit.reference,
            "title": result.hit.title, "url": result.hit.url.absoluteString, "account": result.hit.accountTitle ?? "", "summary": result.summary], options: [.sortedKeys])
        return "mnml approved write result:\n" + String(decoding: data, as: UTF8.self)
    }
}
