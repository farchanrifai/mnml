import XCTest
import AppKit
@testable import mnml

@MainActor
final class UpstreamSyncTests: XCTestCase {
    func testClearReopensNonadjacentSplitWithRetainedPin() throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let pin = try XCTUnwrap(browser.active)
        pin.restore(url: URL(string: "http://127.0.0.1:9/pin")!, title: "Pin")
        browser.pin(pin)
        browser.newTab(bar: false)
        let other = try XCTUnwrap(browser.active)
        other.restore(url: URL(string: "http://127.0.0.1:9/other")!, title: "Other")
        browser.newTab(bar: false)
        let companion = try XCTUnwrap(browser.active)
        companion.restore(url: URL(string: "http://127.0.0.1:9/companion")!, title: "Companion")
        companion.partner = pin.id
        browser.activeID = companion.id
        browser.clearTabs()
        XCTAssertTrue(browser.tabs.contains { $0 === pin })
        XCTAssertEqual(browser.ghosts.count, 2)
        browser.reopen()
        let restored = try XCTUnwrap(browser.tabs.first { $0.address == companion.address })
        XCTAssertEqual(browser.split(of: pin.id), Split(left: pin.id, right: restored.id))
        XCTAssertEqual(browser.activeID, restored.id)
        XCTAssertTrue(browser.ghosts.isEmpty)
    }

    func testCloseCommandDismissesArchiveAbovePeekAndSettingsBeforeTab() throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let origin = try XCTUnwrap(browser.active)
        let preview = Tab()
        browser.presentPeek(preview, from: origin)
        browser.archiveShowing = true
        browser.run("file.closeTab")
        XCTAssertFalse(browser.archiveShowing)
        XCTAssertTrue(browser.peekTab === preview)
        XCTAssertFalse(browser.peekClosing)
        browser.tuning = true
        browser.run("file.closeTab")
        XCTAssertFalse(browser.tuning)
        XCTAssertTrue(browser.peekTab === preview)
        XCTAssertTrue(browser.active === origin)
    }

    @available(macOS 15.4, *)
    func testOnlyExtensionsDeclaringNativeMessagingCanReachHosts() {
        XCTAssertFalse(Extensions.nativeDeclared(required: true, optional: false, added: ["nativeMessaging"]))
        XCTAssertTrue(Extensions.nativeDeclared(required: true, optional: false, added: []))
        XCTAssertTrue(Extensions.nativeDeclared(required: true, optional: true, added: ["nativeMessaging"]))
        XCTAssertFalse(Extensions.nativeDeclared(required: false, optional: false, added: []))
    }

    func testGroundedSiteChoiceCanBeSetAndCleared() {
        let host = "sync9-video.example"
        Grounded.set(false, for: host)
        XCTAssertFalse(Grounded.holds(host))
        Grounded.set(true, for: host)
        XCTAssertTrue(Grounded.holds(host))
        Grounded.set(false, for: host)
        XCTAssertFalse(Grounded.holds(host))
    }

    func testPinnedRowsKeepTheirTierAndSavedState() throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let a = browser.active!
        a.restore(url: URL(string: "https://sync8-a.example/")!, title: "A")
        browser.pin(a)
        browser.newTab(bar: false)
        let b = browser.active!
        b.restore(url: URL(string: "https://sync8-b.example/")!, title: "B")
        browser.pin(b, listed: true)
        browser.newTab(bar: false)
        let c = browser.active!
        c.restore(url: URL(string: "https://sync8-c.example/")!, title: "C")
        browser.pin(c)
        browser.activeID = a.id
        browser.move(b, to: 0)
        XCTAssertEqual(browser.tabs.map(\.id), [a.id, c.id, b.id])
        browser.setListed(c, true)
        XCTAssertEqual(browser.tabs.map(\.id), [a.id, c.id, b.id])
        let row = try XCTUnwrap(browser.allRows()[browser.spaceID.uuidString])
        XCTAssertEqual(row.tabs.map(\.listed), [nil, true, true])
        let decoded = try JSONDecoder().decode(Session.Shape.self, from: JSONEncoder().encode(row))
        XCTAssertEqual(decoded.tabs.map(\.listed), [nil, true, true])
        let legacy = try JSONDecoder().decode(Session.Entry.self, from: Data(#"{"url":"https://example.com/","title":"Old"}"#.utf8))
        XCTAssertNil(legacy.listed)
    }

    func testPointerDoesNotStealKeyboardChoiceUntilItMoves() {
        let ids = [UUID(), UUID(), UUID()]
        let switcher = TabSwitcher()
        switcher.step(eligible: ids, current: ids[0], backwards: false)
        switcher.move(.right)
        switcher.cardFrames = [ids[0]: CGRect(x: 0, y: 0, width: 80, height: 80)]
        switcher.hover(at: CGPoint(x: 10, y: 10))
        XCTAssertEqual(switcher.selectedID, ids[2])
        switcher.hover(at: CGPoint(x: 20, y: 10))
        XCTAssertEqual(switcher.selectedID, ids[0])
        switcher.cancel()
        XCTAssertTrue(switcher.cardFrames.isEmpty)
    }
}
