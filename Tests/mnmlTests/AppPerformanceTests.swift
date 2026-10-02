import AppKit
import Combine
import XCTest
@testable import mnml

@MainActor
final class AppPerformanceTests: XCTestCase {
    func testTabOwnerSubscriptionsAreReplacedAndCancelledOnClose() throws {
        _ = NSApplication.shared
        let first = Browser(record: WindowRecord())
        let second = Browser(record: WindowRecord())
        let tab = Tab()
        let url = URL(string: "https://owner-\(UUID().uuidString.lowercased()).example/")!
        defer {
            tab.close()
            first.closeAll()
            second.closeAll()
            first.history.forget(History.identity(for: url))
        }
        first.history.record(url, title: "Original")
        first.prepare(tab)
        tab.restore(url: url, title: "Original")
        for index in 0..<20 {
            weak var previous = try XCTUnwrap(tab.ownerWatch.first)
            (index.isMultiple(of: 2) ? second : first).prepare(tab)
            XCTAssertNil(previous, "The previous window's subscriptions must be released")
            XCTAssertEqual(tab.ownerWatch.count, 2)
        }
        tab.restore(url: url, title: "Current")
        XCTAssertEqual(first.history.everything(matching: url.host()!).first?.title, "Current")
        tab.close()
        tab.restore(url: url, title: "After close")
        XCTAssertEqual(first.history.everything(matching: url.host()!).first?.title, "Current")
        XCTAssertTrue(tab.ownerWatch.isEmpty)
    }

    func testSessionRestorePublishesCompletedRowWithoutBuildingBackgroundPages() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let entries = (0..<200).map { index in
            Session.Entry(url: "https://restore-audit.example/\(index)", title: "Page \(index)", split: index == 1 ? true : nil, id: UUID())
        }
        browser.record.rows[browser.spaceID.uuidString] = Session.Shape(tabs: entries, active: -1)
        var publications = 0
        let observer = browser.$tabs.dropFirst().sink { _ in publications += 1 }
        browser.restoreSession()
        let ids = Set(entries.compactMap(\.id))
        let restored = browser.tabs.filter { ids.contains($0.id) }
        XCTAssertEqual(restored.map(\.id), entries.compactMap(\.id))
        XCTAssertEqual(restored[1].partner, restored[0].id)
        XCTAssertTrue(restored.allSatisfy { $0.built == nil })
        XCTAssertLessThanOrEqual(publications, 3, "A large session must not publish each restored tab separately")
        withExtendedLifetime(observer) {}
    }

    func testDiscardedBrowserInvalidatesItsSleepTimer() throws {
        _ = NSApplication.shared
        var browser: Browser? = Browser(record: WindowRecord())
        weak var released = browser
        let timer = try XCTUnwrap(browser?.dozing)
        XCTAssertTrue(timer.isValid)
        browser?.closeAll()
        browser = nil
        XCTAssertNil(released)
        XCTAssertFalse(timer.isValid)
    }

    func testUnchangedDownloadProgressDoesNotRepublishFields() {
        let entry = FetchEntry(name: "file.zip", request: nil, webView: nil)
        let progress = Progress(totalUnitCount: 100)
        progress.completedUnitCount = 40
        entry.record(progress)
        var changes = 0
        let observer = entry.objectWillChange.sink { changes += 1 }
        for _ in 0..<10 { entry.record(progress) }
        XCTAssertEqual(changes, 0)
        progress.completedUnitCount = 50
        entry.record(progress)
        XCTAssertEqual(changes, 2)
        XCTAssertEqual(entry.completedBytes, 50)
        XCTAssertEqual(entry.fraction, 0.5)
        withExtendedLifetime(observer) {}
    }

    func testHoverPreviewRejectsStaleRequestAndChangedTabState() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let preview = TabPreview()
        let first = Tab(), second = Tab()
        let address = URL(string: "https://preview-audit.example/first")!
        first.restore(url: address, title: "First")
        second.restore(url: URL(string: "https://preview-audit.example/second")!, title: "Second")
        browser.insert(first, at: browser.tabs.count)
        browser.insert(second, at: browser.tabs.count)
        defer { preview.hide(); browser.closeAll() }

        preview.hover(true, tab: first, browser: browser, beside: .zero)
        let old = preview.generation
        XCTAssertTrue(preview.accepts(old, tab: first, address: address, browser: browser))
        preview.hover(true, tab: second, browser: browser, beside: .zero)
        preview.hover(true, tab: first, browser: browser, beside: .zero)
        let current = preview.generation
        XCTAssertFalse(preview.accepts(old, tab: first, address: address, browser: browser), "Returning to the same row cannot revive its old decode")
        XCTAssertTrue(preview.accepts(current, tab: first, address: address, browser: browser))

        first.restore(url: URL(string: "https://preview-audit.example/changed")!, title: "Changed")
        XCTAssertFalse(preview.accepts(current, tab: first, address: address, browser: browser))
        first.restore(url: address, title: "First")
        let active = browser.activeID
        browser.activeID = first.id
        XCTAssertFalse(preview.accepts(current, tab: first, address: address, browser: browser))
        browser.activeID = active
        browser.beginTabEdit(first)
        XCTAssertFalse(preview.accepts(current, tab: first, address: address, browser: browser))
        browser.cancelTabEdit()
        XCTAssertTrue(preview.accepts(current, tab: first, address: address, browser: browser))
        browser.close(first)
        XCTAssertFalse(preview.accepts(current, tab: first, address: address, browser: browser))
        preview.hide()
        XCTAssertNotEqual(preview.generation, current)
    }
}
