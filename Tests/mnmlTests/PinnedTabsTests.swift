import XCTest
import AppKit
@testable import mnml

@MainActor
final class PinnedTabsTests: XCTestCase {
    func testGridKeepsSquareSizesAndColumnPositionsAcrossIncompleteRows() {
        for width: CGFloat in [160, 238, 400] {
            let eight = SideBar.pinCells(8, width: width)
            for count in [1, 3, 7, 8, 9] {
                let cells = SideBar.pinCells(count, width: width)
                XCTAssertEqual(cells.count, count)
                for (index, cell) in cells.enumerated() {
                    XCTAssertEqual(cell.width, cell.height)
                    XCTAssertEqual(cell.size, eight[0].size)
                    if index < eight.count { XCTAssertEqual(cell, eight[index]) }
                }
            }
            for (index, cell) in eight.enumerated() {
                XCTAssertEqual(SideBar.pinTarget(at: CGPoint(x: cell.midX, y: cell.midY), count: 7, width: width), index)
            }
        }
        XCTAssertTrue(SideBar.pinCells(0, width: 238).isEmpty)
    }

    private func withBrowser(_ check: (Browser) throws -> Void) rethrows {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let pins = Pins.defs(browser.spaceID)
        let sidebar = browser.prefs.sidebar, listed = browser.prefs.listsPins
        defer {
            browser.closeAll()
            Pins.set(browser.spaceID, pins, from: browser)
            browser.prefs.sidebar = sidebar
            browser.prefs.listsPins = listed
        }
        browser.closeAll()
        browser.prefs.sidebar = true
        browser.prefs.listsPins = true
        try check(browser)
    }

    private func tabs(_ names: [String], in browser: Browser) -> [Tab] {
        names.map { name in
            let tab = Tab()
            tab.restore(url: URL(string: "https://pin-drop-\(name.lowercased()).example/")!, title: name)
            browser.insert(tab, at: browser.tabs.count)
            return tab
        }
    }

    func testPinDropsInsertAtFirstMiddleEndAndKeepBatchOrderInSession() throws {
        try withBrowser { browser in
            let tabs = self.tabs(["A", "B", "C", "First", "Middle", "Last", "One", "Two"], in: browser)
            browser.placePins(Array(tabs.prefix(3)), before: nil)
            browser.placePins([tabs[3]], before: tabs[0].id)
            browser.placePins([tabs[4]], before: tabs[1].id)
            browser.placePins([tabs[5]], before: nil)
            browser.placePins([tabs[7], tabs[6]], before: tabs[2].id)
            let order = [3, 0, 4, 1, 6, 7, 2, 5].map { tabs[$0].id }
            XCTAssertEqual(browser.squarePins.map(\.id), order)
            XCTAssertEqual(Pins.defs(browser.spaceID).map(\.id), browser.squarePins.map { $0.pinID! })
            let saved = browser.readRow(browser.spaceID)
            let decoded = try JSONDecoder().decode(Session.Shape.self, from: JSONEncoder().encode(saved))
            XCTAssertEqual(decoded.tabs.compactMap(\.id), order)
            XCTAssertEqual(decoded.tabs.compactMap(\.pinID), browser.squarePins.map { $0.pinID! })
            XCTAssertTrue(decoded.tabs.allSatisfy { $0.home == $0.url && $0.listed == nil })

            let home = tabs[2].home, pinID = tabs[2].pinID
            browser.placePins([tabs[2]], before: tabs[3].id)
            XCTAssertEqual(browser.squarePins.first?.id, tabs[2].id)
            XCTAssertEqual(tabs[2].home, home)
            XCTAssertEqual(tabs[2].pinID, pinID)
        }
    }

    func testUnpinDropsAtFirstMiddleEndIncludingTheLastPin() {
        withBrowser { browser in
            let tabs = self.tabs(["A", "B", "C", "D", "E", "F"], in: browser)
            browser.placePins(Array(tabs.prefix(3)), before: nil)
            for (tab, anchor) in [(tabs[0], tabs[3].id as UUID?), (tabs[1], tabs[4].id as UUID?), (tabs[2], nil)] {
                browser.unpin(tab)
                browser.place([tab], .loose(before: anchor.map { .tab($0) }))
                XCTAssertNil(tab.pin)
                XCTAssertNil(tab.pinID)
                XCTAssertNil(tab.home)
                XCTAssertFalse(tab.listed)
            }
            let order = [0, 3, 1, 4, 5, 2].map { tabs[$0].id }
            XCTAssertEqual(browser.tabs.map(\.id), order)
            XCTAssertEqual(browser.pinnedCount, 0)
            XCTAssertTrue(Pins.defs(browser.spaceID).isEmpty)
            browser.writeSession(now: true)
            XCTAssertEqual(browser.readRow(browser.spaceID).tabs.compactMap(\.id), order)
        }
    }

    func testVisibleRowsStayListedAndHiddenGridDropsCanCrossTheirTier() {
        withBrowser { browser in
            let tabs = self.tabs(["A", "B", "Row", "Keep", "New", "Hidden", "End"], in: browser)
            browser.placePins(Array(tabs.prefix(2)), before: nil)
            browser.pin(tabs[2], listed: true)
            browser.pin(tabs[3], listed: true)
            let keptID = tabs[3].pinID, keptHome = tabs[3].home
            browser.placePins([tabs[2]], before: tabs[1].id)
            browser.placePins([tabs[4]], before: nil)
            XCTAssertEqual(browser.squarePins.map(\.id), [0, 2, 1, 4].map { tabs[$0].id })
            XCTAssertEqual(browser.listedPins.map(\.id), [tabs[3].id])

            browser.prefs.listsPins = false
            browser.placePins([tabs[5]], before: tabs[3].id)
            XCTAssertEqual(browser.squarePins.map(\.id), [0, 2, 1, 4, 5, 3].map { tabs[$0].id })
            XCTAssertTrue(tabs[5].listed)
            browser.placePins([tabs[3]], before: tabs[0].id)
            XCTAssertFalse(tabs[3].listed)
            XCTAssertEqual(tabs[3].pinID, keptID)
            XCTAssertEqual(tabs[3].home, keptHome)
            browser.placePins([tabs[6]], before: nil)
            XCTAssertTrue(tabs[6].listed, "Appending to a hidden row tier keeps its visual grid order")
            XCTAssertEqual(browser.squarePins.map(\.id), [3, 0, 2, 1, 4, 5, 6].map { tabs[$0].id })
            browser.prefs.listsPins = true
            XCTAssertEqual(browser.listedPins.map(\.id), [tabs[5].id, tabs[6].id])
        }
    }

    func testPinDropLeavesItsGroupAndUnpinCanLandInsideAnotherGroup() {
        withBrowser { browser in
            let tabs = self.tabs(["A", "B", "C", "D"], in: browser)
            let original = TabGroup(name: "Original", colour: 1)
            let target = TabGroup(name: "Target", colour: 2)
            tabs[0].group = original.id
            tabs[1].group = original.id
            tabs[2].group = target.id
            tabs[3].group = target.id
            browser.groups = [original, target]
            browser.placePins([tabs[0]], before: nil)
            XCTAssertNil(tabs[0].group)
            XCTAssertNil(browser.group(original.id), "A two-tab group dissolves when only one member remains")
            browser.unpin(tabs[0])
            browser.place([tabs[0]], .group(target.id, before: tabs[3].id))
            XCTAssertEqual(browser.members(of: target.id).map(\.id), [tabs[2].id, tabs[0].id, tabs[3].id])
            XCTAssertNil(tabs[0].home)
            XCTAssertNil(tabs[0].pinID)
        }
    }
}
