import Foundation
import Combine
import Darwin

// App-wide, including parked spaces. No worker is launched until a question
// is sent, and at most two workers (busy or warm) can exist at once.
@MainActor
final class AntigravitySessions: ObservableObject {
    static let shared = AntigravitySessions()
    static let idleLimit: TimeInterval = 180
    static let warningLimit: TimeInterval = 60

    struct Snapshot: Identifiable {
        let id: UUID
        let pid: Int32
        let rssBytes: UInt64?
        let busy: Bool
        let idle: TimeInterval
        let remaining: Int?
    }

    @Published private(set) var sessions: [Snapshot] = []
    private struct Entry {
        let run: Antigravity.Run
        var busy = true
        var touched: TimeInterval
    }
    private var entries: [UUID: Entry] = [:]
    private var retiring: [ObjectIdentifier: Antigravity.Run] = [:]
    private var waiting: [(UUID, CheckedContinuation<Void, Error>)] = []
    private let maximum: Int
    private let now: () -> TimeInterval
    private let automaticTimer: Bool
    private var timer: Timer?

    init(maximum: Int = 2, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         automaticTimer: Bool = true) {
        self.maximum = max(1, maximum); self.now = now; self.automaticTimer = automaticTimer
    }

    func session(for chat: UUID) -> Snapshot? { sessions.first { $0.id == chat } }

    func acquire(_ input: AIInput, model: AIModel, chat: UUID, executable override: URL?,
                 workspace: URL?) async throws -> Antigravity.Run {
        guard let executable = override ?? Antigravity.executable else { throw Antigravity.Failure(message: Antigravity.setup) }
        let folder = workspace ?? Store.file("antigravity").appendingPathComponent(chat.uuidString, isDirectory: true)
        while true {
            try Task.checkCancellation()
            if let old = entries[chat], !old.busy {
                if old.run.matches(input, model: model, executable: executable, workspace: folder) {
                    entries[chat]?.busy = true; entries[chat]?.touched = now(); publish()
                    return old.run
                }
                remove(chat, reason: "contextChanged")
            }
            if entries[chat] == nil {
                if entries.count >= maximum,
                   let oldest = entries.filter({ !$0.value.busy }).min(by: { $0.value.touched < $1.value.touched }) {
                    remove(oldest.key, reason: "evicted")
                }
                if entries.count + retiring.count < maximum {
                    let run = Antigravity.Run(input: input, model: model, chat: chat, executable: executable, workspace: folder)
                    run.onExit = { [weak self, weak run] in
                        Task { @MainActor in
                            guard let self, let run, self.entries[chat]?.run === run else { return }
                            self.entries.removeValue(forKey: chat); self.publish(); self.wake()
                        }
                    }
                    do { try run.start() }
                    catch { run.stop(error: error); retire(run); throw error }
                    entries[chat] = Entry(run: run, touched: now()); publish()
                    return run
                }
            }
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in waiting.append((id, continuation)) }
            } onCancel: {
                Task { @MainActor in self.cancelWait(id) }
            }
        }
    }

    func completed(_ run: Antigravity.Run) {
        guard entries[run.chat]?.run === run else { return }
        entries[run.chat]?.busy = false; entries[run.chat]?.touched = now()
        publish(); wake()
    }

    func failed(_ run: Antigravity.Run) {
        guard entries[run.chat]?.run === run else { return }
        remove(run.chat, reason: "requestFailed"); publish(); wake()
    }

    func keepLive(_ chat: UUID) {
        guard entries[chat] != nil else { return }
        entries[chat]?.touched = now(); publish()
    }

    func kill(_ chat: UUID) {
        ConnectionWriteApprovals.shared.cancel(chat: chat)
        remove(chat, reason: "killed"); publish(); wake()
    }

    func stopAll() {
        for chat in ConnectionWriteApprovals.shared.pending.keys { ConnectionWriteApprovals.shared.cancel(chat: chat) }
        for chat in Array(entries.keys) { remove(chat, reason: "quit") }
        let pending = waiting; waiting.removeAll()
        pending.forEach { $0.1.resume(throwing: CancellationError()) }
        publish()
    }

    func tick() {
        let time = now()
        for (chat, entry) in entries where !entry.busy && time - entry.touched >= Self.idleLimit + Self.warningLimit {
            remove(chat, reason: "idleTimeout")
        }
        publish(); wake()
    }

    // The isolated test bench advances the actual lifecycle, without waiting
    // four minutes or changing production defaults. Busy turns cannot be aged.
    func age(_ chat: UUID, by seconds: TimeInterval) {
        guard Store.testing, seconds.isFinite, seconds >= 0, entries[chat]?.busy == false else { return }
        entries[chat]?.touched -= seconds; tick()
    }

    private func remove(_ chat: UUID, reason: String) {
        guard let entry = entries.removeValue(forKey: chat) else { return }
        entry.run.stop(reason: reason)
        retire(entry.run)
    }

    private func retire(_ run: Antigravity.Run) {
        let id = ObjectIdentifier(run)
        retiring[id] = run
        // A retiring process still occupies a slot, but waiting for its exit
        // must not block scrolling, typing or the toast's other controls.
        Task.detached(priority: .utility) { [self] in
            run.reap()
            await reaped(id)
        }
    }

    private func reaped(_ id: ObjectIdentifier) {
        retiring.removeValue(forKey: id)
        publish(); wake()
    }

    private func cancelWait(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.0 == id }) else { return }
        waiting.remove(at: index).1.resume(throwing: CancellationError())
    }

    private func wake() {
        if !waiting.isEmpty, entries.count + retiring.count < maximum || entries.contains(where: { !$0.value.busy }) {
            waiting.removeFirst().1.resume()
        }
    }

    private func publish() {
        let time = now()
        sessions = entries.map { chat, entry in
            let idle = entry.busy ? 0 : max(0, time - entry.touched)
            return Snapshot(id: chat, pid: entry.run.process.processIdentifier,
                            rssBytes: Self.rss(entry.run.process.processIdentifier), busy: entry.busy, idle: idle,
                            remaining: idle >= Self.idleLimit ? max(0, Int(ceil(Self.idleLimit + Self.warningLimit - idle))) : nil)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        if sessions.isEmpty { timer?.invalidate(); timer = nil }
        else if automaticTimer, timer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            timer.tolerance = 0.2
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    private static func rss(_ pid: Int32) -> UInt64? {
        var info = proc_taskinfo()
        let size = MemoryLayout<proc_taskinfo>.size
        let read = withUnsafeMutablePointer(to: &info) { proc_pidinfo(pid, PROC_PIDTASKINFO, 0, $0, Int32(size)) }
        return read == Int32(size) ? info.pti_resident_size : nil
    }
}
