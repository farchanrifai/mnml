import SwiftUI
import WebKit

enum ArchivePeriod: Int, CaseIterable, Identifiable {
    case hour = 1, halfDay = 12, day = 24, threeDays = 72, week = 168, fortnight = 336, month = 720
    var id: Int { rawValue }
    var duration: TimeInterval { Double(rawValue) * 3600 }
    var title: String {
        switch self {
        case .hour: return "1 hour"
        case .halfDay: return "12 hours"
        case .day: return "24 hours"
        case .threeDays: return "3 days"
        case .week: return "7 days"
        case .fortnight: return "14 days"
        case .month: return "30 days"
        }
    }
    static func read(from defaults: UserDefaults) -> ArchivePeriod {
        if let period = ArchivePeriod(rawValue: defaults.integer(forKey: "tabs.archiveHours")) { return period }
        switch defaults.integer(forKey: "tabs.archiveDays") {
        case 1: return .day
        case 30: return .month
        default: return .week
        }
    }
}

struct ArchivedTab: Codable, Equatable, Identifiable {
    var id: UUID
    var url: URL
    var title: String
    var name: String?
    var space: UUID
    var spaceName: String
    var archived: Date
    var restoreID: UUID?
    var restoreSpace: UUID?
    var label: String { name ?? (title.isEmpty ? Address.pretty(url) : title) }
}

@MainActor
final class ArchiveStore: ObservableObject {
    struct State: Codable {
        var entries: [ArchivedTab] = []
        // ponytail: one UUID per archived tab; prune only against verified session checkpoints if this grows large.
        var retired: Set<UUID> = []
    }
    static let shared: ArchiveStore = {
        let store = ArchiveStore(file: Store.file("archive.json"))
        let spaces = Set(Spaces.read().map(\.id) + store.entries.compactMap(\.restoreSpace))
        let ids = Set(spaces.flatMap { Session.read(space: $0).tabs.compactMap(\.id) }
            + Browsers.read().flatMap { $0.rows.values.flatMap { $0.tabs.compactMap(\.id) } })
        store.recoverRestores(durableIDs: ids)
        return store
    }()
    @Published private(set) var state = State()
    @Published private(set) var error: String?
    var entries: [ArchivedTab] { state.entries }
    private let file: URL
    private let write: (URL, Data) throws -> Void
    private var unreadable = false
    private var timer: Timer?
    private var wake: NSObjectProtocol?
    var checking: Set<UUID> = []

    init(file: URL, write: @escaping (URL, Data) throws -> Void = { try Disk.commit($0, data: $1) }) {
        self.file = file
        self.write = write
        if FileManager.default.fileExists(atPath: file.path) {
            do { state = try JSONDecoder().decode(State.self, from: Data(contentsOf: file)) }
            catch { unreadable = true; self.error = "Archive could not be read. Its file has been kept; tabs will stay open." }
        }
    }

    @discardableResult private func commit(_ next: State) -> Bool {
        guard !unreadable else { return false }
        do {
            try write(file, JSONEncoder().encode(next))
            state = next
            error = nil
            return true
        } catch { self.error = "Archive could not be saved. Your tab or archive entry has been kept."; return false }
    }
    @discardableResult func add(_ entry: ArchivedTab) -> Bool {
        var next = state
        guard !next.entries.contains(where: { $0.id == entry.id }) else { return true }
        next.entries.append(entry)
        next.retired.insert(entry.id)
        return commit(next)
    }
    @discardableResult func beginRestore(_ id: UUID, tab: UUID, space: UUID) -> Bool {
        var next = state
        guard let index = next.entries.firstIndex(where: { $0.id == id }) else { return false }
        next.entries[index].restoreID = tab
        next.entries[index].restoreSpace = space
        return commit(next)
    }
    @discardableResult func remove(_ id: UUID) -> Bool {
        var next = state; next.entries.removeAll { $0.id == id }; return commit(next)
    }
    func clear() { var next = state; next.entries = []; _ = commit(next) }
    func recoverRestores(durableIDs: Set<UUID>) {
        var next = state
        next.entries.removeAll { $0.restoreID.map { durableIDs.contains($0) } == true }
        if next.entries != state.entries { _ = commit(next) }
    }
    func filtered(_ shape: Session.Shape) -> Session.Shape {
        func retired(_ entry: Session.Entry) -> Bool { entry.id.map { state.retired.contains($0) } ?? false }
        let frontRemoved = shape.tabs.indices.contains(shape.active) && retired(shape.tabs[shape.active])
        let before = shape.tabs.prefix(max(0, shape.active)).filter(retired).count
        return Session.Shape(tabs: shape.tabs.filter { !retired($0) }, active: frontRemoved ? -1 : shape.active - before, groups: shape.groups)
    }

    func watch() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 300, repeats: true) { _ in MainActor.assumeIsolated { Self.shared.sweep() } }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        wake = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Self.shared.sweep() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { Self.shared.sweep() }
    }
    func sweep(now: Date = Date()) {
        for browser in Browsers.all where browser.extensionPopup == nil && browser.prefs.archivesTabs {
            let cutoff = now.addingTimeInterval(-browser.prefs.archivePeriod.duration)
            for tab in browser.tabs + browser.parkedTabs where tab.touched <= cutoff {
                browser.archive(tab, cutoff: cutoff)
            }
        }
    }
}

extension Browser {
    func archiveReason(_ tab: Tab, manual: Bool = false) -> String? {
        let row = tabs + parkedTabs
        guard row.contains(where: { $0 === tab }) else { return "not an open tab" }
        guard let url = tab.pending ?? tab.address, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              Browser.extensionHost(of: url) == nil else { return "not a web page" }
        if editingTab == tab.id { return "being renamed" }
        if tab.pin != nil { return "pinned" }
        if tab.group != nil { return "in a group" }
        if tab.partner != nil || row.contains(where: { $0.partner == tab.id }) { return "in a split" }
        if tab.shy || tab.bench || tab.held != nil { return "private or temporary" }
        if peekOrigin == tab.id { return "has a preview open" }
        let owners = Browsers.all.contains(where: { $0 === self }) ? Browsers.all : [self]
        for owner in owners {
            if (!manual || owner !== self), owner.activeID == tab.id || owner.split(of: owner.activeID)?.has(tab.id) == true { return "on screen" }
            if let reason = owner.activityKeeping(tab) { return reason }
        }
        return nil
    }

    func archive(_ tab: Tab, manual: Bool = false, cutoff: Date? = nil, done: ((Bool) -> Void)? = nil) {
        archive(tab, manual: manual, cutoff: cutoff, using: .shared, done: done)
    }

    func archive(_ tab: Tab, manual: Bool = false, cutoff: Date? = nil, using store: ArchiveStore, done: ((Bool) -> Void)? = nil) {
        if let reason = archiveReason(tab, manual: manual) { if manual { announce("Tab kept: \(reason)") }; done?(false); return }
        guard cutoff.map({ tab.touched <= $0 }) ?? true, !store.checking.contains(tab.id),
              let url = tab.pending ?? tab.address else { done?(false); return }
        store.checking.insert(tab.id)
        let web = tab.built
        var finished = false
        let finish: (Bool) -> Void = { success in
            guard !finished else { return }; finished = true
            store.checking.remove(tab.id); done?(success)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { finish(false) }
        let save: () -> Void = { [weak self, weak tab] in
            guard !finished, let self, let tab,
                  self.archiveReason(tab, manual: manual) == nil,
                  cutoff.map({ tab.touched <= $0 }) ?? true,
                  (tab.pending ?? tab.address) == url, tab.built === web else { finish(false); return }
            let source = self.tabs.contains(where: { $0 === tab }) ? self.spaceID : self.parked.first { $0.value.tabs.contains { $0 === tab } }?.key
            guard let source else { finish(false); return }
            let entry = ArchivedTab(id: tab.id, url: url, title: tab.title, name: tab.name, space: source,
                spaceName: self.spaces.first { $0.id == source }?.name ?? "Space", archived: Date())
            // Legacy sessions may not yet have IDs; checkpoint them before retiring this identity.
            do { try self.commitArchiveSession() } catch {
                if manual { self.announce("Tab kept: its session could not be saved") }
                finish(false); return
            }
            guard store.add(entry) else { if manual { self.announce(store.error ?? "Tab kept") }; finish(false); return }
            // The durable retirement ID also filters stale sessions after an interrupted close.
            self.removeArchivedTab(tab, space: source)
            tab.close()
            if let row = self.allRows()[source.uuidString] { self.writeRow(source, row, now: true) }
            if manual { self.announce("Tab archived") }
            finish(true)
        }
        guard let web else { save(); return }
        web.requestMediaPlaybackState { state in
            MainActor.assumeIsolated {
                guard !finished, state != .playing else { finish(false); return }
                // An unavailable form monitor is uncertain, not permission to discard a page.
                web.evaluateInSearch("typeof window.__officeForms?.unsaved === 'function' ? window.__officeForms.unsaved() : null") { value in
                    MainActor.assumeIsolated {
                        guard !finished, let unsent = value as? Bool, !unsent else {
                            if manual { self.announce("Tab kept: unsent edits or page could not be checked") }
                            finish(false); return
                        }
                        save()
                    }
                }
            }
        }
    }

    func commitArchiveSession() throws {
        if usesFiles {
            for (id, row) in allRows() {
                guard let space = UUID(uuidString: id) else { continue }
                try Session.commit(space: space, row)
            }
        } else {
            guard Browsers.all.contains(where: { $0 === self }) else { throw CocoaError(.fileWriteUnknown) }
            record.rows = allRows()
            try Browsers.commit()
        }
    }

    func restoreArchive(_ entry: ArchivedTab) { restoreArchive(entry, using: .shared) }

    func restoreArchive(_ entry: ArchivedTab, using store: ArchiveStore) {
        guard let current = store.entries.first(where: { $0.id == entry.id }) else { return }
        let entry = current
        if checkingPeek || peekClosing { announce("Finish closing the preview first"); return }
        if peekTab != nil { closePeek { [weak self] in self?.restoreArchive(entry, using: store) }; return }
        let existing = ([self] + Browsers.all.filter { $0 !== self }).first { browser in
            (browser.tabs + browser.parkedTabs).contains { $0.id == entry.restoreID }
        }
        let owner = existing ?? self
        let destination = existing.flatMap { browser in
            browser.tabs.contains { $0.id == entry.restoreID } ? browser.spaceID : browser.parked.first { $0.value.tabs.contains { $0.id == entry.restoreID } }?.key
        } ?? (prefs.usesSpaces && spaces.contains { $0.id == entry.space } ? entry.space : spaceID)
        let id = entry.restoreID ?? UUID()
        guard store.beginRestore(entry.id, tab: id, space: destination) else { announce(store.error ?? "Restore could not be saved"); return }
        if destination != owner.spaceID {
            guard owner.prefs.usesSpaces else { announce("Enable Spaces to return to the restored tab"); return }
            owner.switchSpace(to: destination, animated: false)
        }
        guard owner.spaceID == destination else { return }
        let tab: Tab
        if let found = owner.tabs.first(where: { $0.id == id }) { tab = found }
        else {
            tab = Tab(configuration: Web.configuration(space: destination), id: id)
            owner.prepare(tab)
            tab.restore(url: entry.url, title: entry.title, name: entry.name)
            owner.insert(tab, at: owner.tabs.count)
        }
        owner.select(tab)
        owner.archiveShowing = false
        if Browsers.all.contains(where: { $0 === owner }) { Browsers.show(owner) }
        do {
            try owner.commitArchiveSession()
            guard store.remove(entry.id) else { owner.announce("Tab restored; Archive cleanup will retry"); return }
            owner.announce(destination == entry.space ? "Tab restored" : "Original Space unavailable; restored in this Space")
        } catch { owner.announce("Tab restored; Archive entry kept until its session can be saved") }
    }
}

struct ArchivePanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var store = ArchiveStore.shared
    @State private var hunt = ""
    @FocusState private var hunting: Bool
    private var entries: [ArchivedTab] {
        store.entries.filter { hunt.isEmpty || ($0.label + " " + $0.url.absoluteString).localizedCaseInsensitiveContains(hunt) }
            .sorted { $0.archived > $1.archived }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Archive").font(.system(size: 17, weight: .semibold))
                Spacer()
                Door(icon: "xmark", help: "Done   esc") { browser.archiveShowing = false }
            }
            TextField("Search title or URL", text: $hunt).textFieldStyle(.roundedBorder).focused($hunting)
            ScrollView {
                LazyVStack(spacing: 8) {
                    if entries.isEmpty { Text(hunt.isEmpty ? "No archived tabs" : "No matching tabs").foregroundStyle(Palette.muted).padding(30) }
                    ForEach(entries) { entry in
                        Card {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.label).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                    Text(entry.url.absoluteString).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
                                    Text("\(browser.spaces.first { $0.id == entry.space }?.name ?? entry.spaceName) · \(entry.archived.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                                }
                                Spacer(minLength: 0)
                                Button("Restore") { browser.restoreArchive(entry) }
                                Button("Delete", role: .destructive) { _ = store.remove(entry.id) }
                            }.padding(12)
                        }
                    }
                }
            }
            if let error = store.error { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
            HStack {
                Text(store.entries.count == 1 ? "1 archived tab" : "\(store.entries.count) archived tabs").font(.system(size: 12)).foregroundStyle(Palette.muted)
                Spacer()
                Button("Clear Archive…") {
                    Ask.sure("Clear Archive?", detail: "Permanently deletes all archived tab entries. Open tabs and recently closed tabs are kept.", confirm: "Clear Archive") { store.clear() }
                }.disabled(store.entries.isEmpty)
            }
        }.padding(20).frame(maxWidth: 650, maxHeight: 480)
            .background(Palette.ground, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.16), radius: 34, y: 12)
            .padding(16)
            .onAppear { hunting = true }
    }
}
