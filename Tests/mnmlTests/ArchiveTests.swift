import XCTest
import AppKit
import WebKit
@testable import mnml

@MainActor
final class ArchiveTests: XCTestCase {
    private var folder: URL!
    private var file: URL { folder.appendingPathComponent("archive.json") }
    override func setUp() { folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() { try? FileManager.default.removeItem(at: folder) }
    private func entry(id: UUID = UUID(), space: UUID = Space.firstID) -> ArchivedTab {
        ArchivedTab(id: id, url: URL(string: "http://127.0.0.1:9/archive")!, title: "A page", name: "Custom", space: space, spaceName: "Work", archived: Date())
    }
    private func page(in browser: Browser) -> Tab {
        let tab = Tab(configuration: Web.configuration(space: browser.spaceID))
        browser.prepare(tab)
        tab.restore(url: URL(string: "http://127.0.0.1:9/archive")!, title: "A page")
        browser.insert(tab, at: browser.tabs.count)
        return tab
    }
    func testInactivityPeriodMigrationAndPersistence() {
        let suite = "mnml.archive.periods." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(ArchivePeriod.read(from: defaults), .week)
        for (days, expected) in [(1, ArchivePeriod.day), (7, .week), (30, .month)] {
            defaults.set(days, forKey: "tabs.archiveDays")
            XCTAssertEqual(ArchivePeriod.read(from: defaults), expected)
        }
        defaults.set(12, forKey: "tabs.archiveHours")
        XCTAssertEqual(ArchivePeriod.read(from: defaults), .halfDay)
        XCTAssertEqual(ArchivePeriod.read(from: defaults).duration, 43200)
        defaults.set(1, forKey: "tabs.archiveHours")
        XCTAssertEqual(ArchivePeriod.read(from: defaults).duration, 3600)
        defaults.set(336, forKey: "tabs.archiveHours")
        XCTAssertEqual(ArchivePeriod.read(from: defaults), .fortnight)
        defaults.set(-1, forKey: "tabs.archiveHours")
        defaults.set(0, forKey: "tabs.archiveDays")
        XCTAssertEqual(ArchivePeriod.read(from: defaults), .week)
    }
    func testLeavingSpacesAndVisibleSplitsRefreshesPersistedUseTime() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let oldSpaces = browser.prefs.usesSpaces, current = Spaces.current
        defer { browser.closeAll(); browser.prefs.usesSpaces = oldSpaces; Spaces.current = current }
        browser.prefs.usesSpaces = true
        let first = page(in: browser), second = page(in: browser)
        second.partner = first.id
        browser.activeID = first.id
        let old = Date().addingTimeInterval(-30 * 86400)
        first.touched = old; second.touched = old
        let origin = browser.spaceID
        let destination = Space(id: UUID(), name: "Other", colour: 0, icon: nil, sharesSignIns: true)
        browser.spaces.append(destination)
        let began = Date()
        browser.switchSpace(to: destination.id, animated: false)
        XCTAssertGreaterThanOrEqual(first.touched, began)
        XCTAssertGreaterThanOrEqual(second.touched, began)
        let saved = browser.readRow(origin)
        XCTAssertGreaterThanOrEqual(saved.tabs.first { $0.id == first.id }?.touched ?? old, began)
        XCTAssertGreaterThanOrEqual(saved.tabs.first { $0.id == second.id }?.touched ?? old, began)
        browser.switchSpace(to: origin, animated: false)
        first.touched = old; second.touched = old
        browser.unsplit(first.id)
        XCTAssertGreaterThanOrEqual(first.touched, began)
        XCTAssertGreaterThanOrEqual(second.touched, began)
        first.touched = old
        browser.flushSession()
        XCTAssertGreaterThanOrEqual(browser.readRow(origin).tabs.first { $0.id == first.id }?.touched ?? old, began)
    }
    func testInterruptedArchiveFiltersStaleSessionAndKeepsRetirementAfterClear() {
        let store = ArchiveStore(file: file)
        let item = entry()
        XCTAssertTrue(store.add(item))
        XCTAssertTrue(store.add(item))
        XCTAssertEqual(store.entries.count, 1)
        let kept = Session.Entry(url: "https://example.com", title: "Kept", id: UUID())
        let stale = Session.Shape(tabs: [Session.Entry(url: item.url.absoluteString, title: item.title, id: item.id), kept], active: 1)
        let restarted = ArchiveStore(file: file)
        XCTAssertEqual(restarted.filtered(stale).tabs.count, 1)
        XCTAssertEqual(restarted.filtered(stale).active, 0)
        XCTAssertEqual(restarted.entries.first?.name, "Custom")
        restarted.clear()
        XCTAssertTrue(ArchiveStore(file: file).entries.isEmpty)
        XCTAssertEqual(ArchiveStore(file: file).filtered(stale).tabs.count, 1)
        let legacy = Session.Shape(tabs: [Session.Entry(url: "https://example.com", title: "Legacy")], active: 0)
        XCTAssertEqual(restarted.filtered(legacy).active, 0)
    }
    func testFailedArchiveWriteLeavesTabOpen() {
        _ = NSApplication.shared
        let store = ArchiveStore(file: file, write: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let tab = page(in: browser)
        browser.becomePrimary()
        var outcome: Bool?
        browser.archive(tab, using: store) { outcome = $0 }
        XCTAssertEqual(outcome, false)
        XCTAssertTrue(browser.tabs.contains { $0 === tab })
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertNotNil(store.error)
    }
    func testEligibilityCutoffAndManualArchiveStaySeparateFromRecentlyClosed() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let tab = page(in: browser)
        browser.becomePrimary()
        let store = ArchiveStore(file: file)
        let cutoff = Date().addingTimeInterval(-86400)
        tab.touched = cutoff.addingTimeInterval(1)
        browser.archive(tab, cutoff: cutoff, using: store)
        XCTAssertTrue(store.entries.isEmpty)
        tab.pin = "A"; XCTAssertNotNil(browser.archiveReason(tab)); tab.pin = nil
        tab.group = UUID(); XCTAssertNotNil(browser.archiveReason(tab)); tab.group = nil
        tab.partner = UUID(); XCTAssertNotNil(browser.archiveReason(tab)); tab.partner = nil
        let privatePage = Tab(shy: true, configuration: Web.configuration(shy: true, space: browser.spaceID))
        privatePage.restore(url: tab.address ?? tab.pending!, title: "Private")
        browser.insert(privatePage, at: browser.tabs.count)
        XCTAssertNotNil(browser.archiveReason(privatePage))
        browser.activeID = tab.id
        XCTAssertNotNil(browser.archiveReason(tab))
        XCTAssertNil(browser.archiveReason(tab, manual: true))
        let closed = browser.ghosts.count
        browser.activeID = browser.tabs.first { $0 !== tab }?.id
        tab.touched = cutoff
        browser.archive(tab, cutoff: cutoff, using: store)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertFalse(browser.tabs.contains { $0 === tab })
        XCTAssertEqual(browser.ghosts.count, closed)
    }
    func testInterruptedRestorationOnlyCompletesWhenTabIsDurable() {
        let store = ArchiveStore(file: file)
        let item = entry()
        XCTAssertTrue(store.add(item))
        let restoredID = UUID()
        XCTAssertTrue(store.beginRestore(item.id, tab: restoredID, space: item.space))
        let restarted = ArchiveStore(file: file)
        restarted.recoverRestores(durableIDs: [])
        XCTAssertEqual(restarted.entries.first?.restoreID, restoredID)
        let row = Session.Shape(tabs: [Session.Entry(url: item.url.absoluteString, title: item.title, id: restoredID)], active: 0)
        try? Session.commit(space: item.space, row)
        restarted.recoverRestores(durableIDs: Set(Session.read(space: item.space).tabs.compactMap(\.id)))
        XCTAssertTrue(ArchiveStore(file: file).entries.isEmpty)
        XCTAssertEqual(restarted.filtered(row).tabs.first?.id, restoredID)
    }
    func testRestoreRetryReusesTabAndDeletedSpaceFallsBack() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let store = ArchiveStore(file: file)
        let item = entry(space: UUID())
        XCTAssertTrue(store.add(item))
        browser.restoreArchive(item, using: store)
        XCTAssertEqual(browser.spaceID, Space.firstID)
        XCTAssertEqual(browser.active?.name, "Custom")
        XCTAssertEqual(store.entries.count, 1) // This detached test browser cannot commit a window session.
        let pending = store.entries[0]
        let count = browser.tabs.count
        browser.restoreArchive(item, using: store)
        XCTAssertEqual(browser.tabs.count, count)
        XCTAssertEqual(browser.active?.id, pending.restoreID)
    }
    func testLivePageProtectionRequiresCleanFormMonitor() async throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let tab = browser.open(URL(string: "http://127.0.0.1:9/form")!, foreground: false)
        let web = tab.web
        web.loadHTMLString("<textarea id='draft'></textarea>", baseURL: URL(string: "http://127.0.0.1:9/form"))
        func js(_ script: String) async -> Any? {
            await withCheckedContinuation { continuation in
                web.evaluateInSearch(script) { continuation.resume(returning: $0) }
            }
        }
        let until = Date().addingTimeInterval(5)
        while Date() < until {
            if !tab.loading, await js("typeof window.__officeForms?.unsaved === 'function'") as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let monitored = await js("typeof window.__officeForms?.unsaved === 'function'") as? Bool
        XCTAssertEqual(monitored, true)
        // Inject monitor outcomes in the real isolated WebKit world; synthetic DOM events are not trusted input.
        browser.becomePrimary()
        XCTAssertNil(browser.archiveReason(tab))
        _ = await js("window.__officeForms.unsaved = () => true; true")
        let unsent = await js("window.__officeForms.unsaved()") as? Bool
        XCTAssertEqual(unsent, true)
        let store = ArchiveStore(file: file)
        let kept = await withCheckedContinuation { continuation in
            browser.archive(tab, using: store) { continuation.resume(returning: $0) }
        }
        XCTAssertFalse(kept)
        XCTAssertTrue(browser.tabs.contains { $0 === tab })
        XCTAssertTrue(store.entries.isEmpty)
        _ = await js("delete window.__officeForms; true")
        let uncertain = await withCheckedContinuation { continuation in
            browser.archive(tab, using: store) { continuation.resume(returning: $0) }
        }
        XCTAssertFalse(uncertain)
        XCTAssertTrue(browser.tabs.contains { $0 === tab })
        _ = await js("window.__officeForms = {unsaved: () => false}; true")
        let clean = await withCheckedContinuation { continuation in
            browser.archive(tab, using: store) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(clean)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertFalse(browser.tabs.contains { $0 === tab })
    }
    func testCorruptArchiveAndFailedCleanupPreserveData() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: file)
        let corrupt = ArchiveStore(file: file)
        XCTAssertFalse(corrupt.add(entry()))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "broken")
        try FileManager.default.removeItem(at: file)
        var fail = false
        let store = ArchiveStore(file: file, write: { url, data in
            if fail { throw CocoaError(.fileWriteOutOfSpace) }
            try Disk.commit(url, data: data)
        })
        let item = entry()
        XCTAssertTrue(store.add(item))
        fail = true
        XCTAssertFalse(store.remove(item.id))
        XCTAssertEqual(ArchiveStore(file: file).entries, [item])
    }
}
