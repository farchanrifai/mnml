import XCTest
import AppKit
@testable import mnml

@MainActor
final class UpstreamSyncTests: XCTestCase {
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
