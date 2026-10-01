import XCTest
import AppKit
@testable import mnml

@MainActor
final class CommandBarTests: XCTestCase {
    private var browser: Browser!
    private var oldActions = false, oldInline = false, oldSidebar = false, oldSpaces = false
    private var pins: [PinDef] = []

    override func setUp() {
        _ = NSApplication.shared
        browser = Browser(record: WindowRecord())
        oldActions = browser.prefs.commandActions
        oldInline = browser.prefs.addressCommands
        oldSidebar = browser.prefs.sidebar
        oldSpaces = browser.prefs.usesSpaces
        browser.prefs.commandActions = true
        browser.prefs.addressCommands = false
        browser.prefs.sidebar = true
        pins = Pins.defs(browser.spaceID)
    }

    override func tearDown() {
        Pins.set(browser.spaceID, pins, from: browser)
        browser.closeAll()
        browser.prefs.commandActions = oldActions
        browser.prefs.addressCommands = oldInline
        browser.prefs.sidebar = oldSidebar
        browser.prefs.usesSpaces = oldSpaces
        browser = nil
    }

    func testExactActionWinsTabTieAndSearchRemains() {
        let tab = Suggestion(key: "Settings", title: "", url: URL(string: "https://example.com")!, kind: .open)
        let search = Suggestion(key: "settings", title: "Search", url: URL(string: "https://example.com/?q=settings")!, kind: .search)
        let list = CommandRank.sorted([tab, search, .command(.settings)], for: "settings")
        XCTAssertEqual(list.first?.kind, .command(.settings))
        XCTAssertEqual(list.last?.kind, .search)
        XCTAssertEqual(CommandRank.match("sett", text: "settings"), 1)
        XCTAssertEqual(CommandRank.match("private new", text: "new private tab"), 2)
        XCTAssertNil(CommandRank.match("settings for gmail", text: "settings"))
    }

    func testReturnRunsFirstActionAndSelectedSearchOverridesIt() {
        browser.editing = true
        browser.typed = "settings"
        XCTAssertEqual(browser.offers.first?.kind, .command(.settings))
        XCTAssertNil(browser.ending)
        browser.submit()
        XCTAssertTrue(browser.tuning)
        browser.tuning = false
        browser.editing = true
        browser.typed = "settings"
        browser.picked = browser.offers.firstIndex { $0.kind == .search }
        XCTAssertNotNil(browser.picked)
        let url = browser.searchURL(for: "settings")
        browser.submit()
        XCTAssertFalse(browser.tuning)
        XCTAssertEqual(browser.active?.address, url)
    }

    func testValidURLFirstAndSearchStillAvailable() {
        browser.typed = "settings.com"
        XCTAssertEqual(browser.offers.first?.url, Address.url(from: "settings.com"))
        XCTAssertFalse(browser.offers.first?.kind.isCommand ?? true)
        XCTAssertTrue(browser.offers.contains { $0.kind == .search })
        XCTAssertEqual(Set(browser.offers.map(\.id)).count, browser.offers.count)
        browser.submit()
        XCTAssertEqual(browser.active?.address?.host(), "settings.com")
        XCTAssertEqual(browser.active?.address?.scheme, "https")
        browser.typed = "google.com"
        XCTAssertEqual(Set(browser.offers.map(\.id)).count, browser.offers.count)
    }

    func testReturnSwitchesToFirstMatchingTabWithoutDuplicatingIt() {
        let target = browser.open(URL(string: "http://127.0.0.1:9/target")!, foreground: true)
        target.name = "Unique Command Bar Target"
        _ = browser.open(URL(string: "http://127.0.0.1:9/current")!, foreground: true)
        let count = browser.tabs.count
        browser.typed = "Target Unique"
        XCTAssertEqual(browser.offers.first?.tab, target.id)
        browser.typed = "Unique Command Bar Target"
        XCTAssertEqual(browser.offers.first?.tab, target.id)
        XCTAssertNil(browser.picked)
        browser.submit()
        XCTAssertEqual(browser.activeID, target.id)
        XCTAssertEqual(browser.tabs.count, count)
    }

    func testPinAndSplitApplicabilityAndPickerFlow() throws {
        XCTAssertFalse(AddressCommand.pinTab.available(in: browser))
        let source = browser.open(URL(string: "http://127.0.0.1:9/source")!, foreground: true)
        let other = browser.open(URL(string: "http://127.0.0.1:9/other")!, foreground: true)
        browser.select(source)
        browser.typed = "pin tab"
        browser.submit()
        XCTAssertNotNil(source.pin)
        XCTAssertFalse(AddressCommand.pinTab.available(in: browser))
        XCTAssertTrue(AddressCommand.unpinTab.available(in: browser))
        browser.typed = "split page"
        browser.submit()
        XCTAssertEqual(browser.splitPicking?.tab, source.id)
        browser.pickSplit(other)
        XCTAssertNotNil(browser.shownSplit)
        browser.typed = "separate split"
        browser.submit()
        XCTAssertNil(browser.shownSplit)
        browser.newShyTab()
        browser.active?.go(to: URL(string: "http://127.0.0.1:9/private")!)
        XCTAssertFalse(AddressCommand.pinTab.available(in: browser))
    }

    func testPeekPromotionTargetsPreviewAndPreservesLiveView() throws {
        let source = browser.open(URL(string: "http://127.0.0.1:9/source")!, foreground: true)
        browser.peek(URL(string: "http://127.0.0.1:9/preview")!, from: source)
        let preview = try XCTUnwrap(browser.peekTab)
        let web = preview.web
        XCTAssertFalse(AddressCommand.pinTab.available(in: browser))
        browser.newTab()
        browser.typed = "split peek"
        XCTAssertEqual(browser.offers.first?.kind, .command(.splitPeek))
        browser.submit()
        XCTAssertNil(browser.peekTab)
        XCTAssertTrue(browser.active === preview)
        XCTAssertTrue(preview.built === web)
        XCTAssertEqual(browser.shownSplit, Split(left: source.id, right: preview.id))
    }

    func testSpaceActionsUseStableDestinationAndRespectSettings() {
        let destination = Space(id: UUID(), name: "Work", colour: 0, icon: nil)
        XCTAssertNotEqual(Suggestion.command(.switchSpace(destination.id, "Work")).id,
                          Suggestion.command(.switchSpace(UUID(), "Work")).id)
        browser.spaces.append(destination)
        browser.prefs.usesSpaces = true
        browser.typed = "switch to work"
        XCTAssertEqual(browser.offers.first?.kind, .command(.switchSpace(destination.id, "Work")))
        browser.prefs.usesSpaces = false
        XCTAssertFalse(AddressCommand.switchSpace(destination.id, "Work").available(in: browser))
        browser.prefs.usesSpaces = true
        browser.spaces.removeAll { $0.id == destination.id }
        XCTAssertFalse(AddressCommand.switchSpace(destination.id, "Work").available(in: browser))
    }

    func testMoveStaysInCurrentSpaceAndSwitchIsSeparate() {
        let original = browser.spaceID
        let current = Spaces.current
        defer { Spaces.current = current }
        let destination = Space(id: UUID(), name: "Command Test Work", colour: 0, icon: nil, sharesSignIns: true)
        browser.spaces.append(destination)
        browser.prefs.usesSpaces = true
        let page = browser.open(URL(string: "http://127.0.0.1:9/move")!, foreground: true)
        browser.typed = "move tab to Command Test Work"
        browser.submit()
        XCTAssertEqual(browser.spaceID, original)
        XCTAssertFalse(browser.tabs.contains { $0 === page })
        XCTAssertTrue(browser.parked[destination.id]?.tabs.contains { $0 === page } == true)
        browser.typed = "switch to Command Test Work"
        browser.submit()
        XCTAssertEqual(browser.spaceID, destination.id)
        XCTAssertTrue(browser.tabs.contains { $0 === page })
        browser.switchSpace(to: original, animated: false)
        browser.spaces.removeAll { $0.id == destination.id }
    }

    func testDisableMixedActionsAndInlinePreferenceRemainIndependent() {
        browser.prefs.commandActions = false
        browser.typed = "settings"
        XCTAssertFalse(browser.offers.contains { $0.kind.isCommand })
        browser.prefs.addressCommands = true
        browser.typed = "settings"
        XCTAssertEqual(browser.offers.first?.kind, .command(.settings))
        browser.typed = "sett"
        XCTAssertFalse(browser.offers.contains { $0.kind.isCommand })
    }

    func testEmptyInputAndSummonStayRecentTabsOnly() {
        _ = browser.open(URL(string: "http://127.0.0.1:9/one")!, foreground: true)
        _ = browser.open(URL(string: "http://127.0.0.1:9/two")!, foreground: true)
        browser.typed = ""
        XCTAssertFalse(browser.offers.isEmpty)
        XCTAssertTrue(browser.offers.allSatisfy { $0.kind == .open })
        browser.summon()
        browser.typed = "settings"
        XCTAssertFalse(browser.offers.contains { $0.kind.isCommand })
    }
}
