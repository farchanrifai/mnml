import AppKit
import XCTest
@testable import mnml

@MainActor
final class AntigravitySessionUITests: XCTestCase {
    override class func setUp() {
        if ProcessInfo.processInfo.environment["MNML_PROBE"] == nil {
            setenv("MNML_PROBE", "antigravity-ui-\(getpid())", 1)
        }
        super.setUp()
    }

    override func setUp() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
    }

    func testGoFindsParkedChatAndReopensItsSpaceAndPanel() throws {
        let (browser, tab, chat) = fixture()
        let usesSpaces = browser.prefs.usesSpaces
        browser.prefs.usesSpaces = true
        defer {
            browser.closeAll()
            browser.prefs.usesSpaces = usesSpaces
        }
        let home = browser.spaceID
        let other = Space(id: UUID(), name: "Other", colour: 0, sharesSignIns: true)
        browser.spaces.append(other)
        browser.switchSpace(to: other.id, animated: false)
        browser.chatting.remove(tab.id)
        browser.tuning = true

        let owner = try XCTUnwrap(AntigravitySessionUI.owner(of: chat.sessionID))
        XCTAssertTrue(owner.browser === browser)
        XCTAssertTrue(owner.tab === tab)
        XCTAssertEqual(owner.space.id, home)
        let focus = browser.askFocusTick
        XCTAssertTrue(AntigravitySessionUI.go(to: chat.sessionID))
        XCTAssertEqual(browser.spaceID, home)
        XCTAssertEqual(browser.activeID, tab.id)
        XCTAssertTrue(browser.askShowing)
        XCTAssertFalse(browser.fieldShowing)
        XCTAssertFalse(browser.tuning, "Go reveals the chat even from an app panel")
        XCTAssertGreaterThan(browser.askFocusTick, focus)
        XCTAssertTrue(NSApp.windows.allSatisfy { !$0.isVisible }, "model navigation must not open a test window")
    }

    func testOwnerFollowsChatIntoNewTabAndAnotherWindow() throws {
        let (source, original, chat) = fixture()
        let (destination, _, _) = fixture()
        defer { source.closeAll(); destination.closeAll() }

        source.askInNewTab(from: original)
        let moved = try XCTUnwrap(source.active)
        XCTAssertNotEqual(moved.id, original.id)
        XCTAssertTrue(source.chats[moved.id] === chat)
        XCTAssertEqual(AntigravitySessionUI.owner(of: chat.sessionID)?.tab.id, moved.id)
        source.moveToWindow(moved, destination)
        let owner = try XCTUnwrap(AntigravitySessionUI.owner(of: chat.sessionID))
        XCTAssertTrue(owner.browser === destination)
        XCTAssertTrue(owner.tab === moved)
        XCTAssertFalse(source.tabs.contains { $0 === moved })
    }

    func testTwoInstancesOfSavedHistoryHaveSeparateSessionOwners() throws {
        let (browser, first, chat) = fixture()
        defer { browser.closeAll() }
        let second = Tab(configuration: Web.configuration(space: browser.spaceID))
        let restored = Chat(id: chat.id)
        browser.showRow([first, second], active: first.id)
        browser.chats[second.id] = restored
        AntigravitySessionUI.bind(chat: restored.sessionID, to: second.id)

        XCTAssertEqual(chat.id, restored.id)
        XCTAssertNotEqual(chat.sessionID, restored.sessionID)
        XCTAssertEqual(AntigravitySessionUI.owner(of: chat.sessionID)?.tab.id, first.id)
        XCTAssertEqual(AntigravitySessionUI.owner(of: restored.sessionID)?.tab.id, second.id)
        restored.stop()
        XCTAssertEqual(AntigravitySessionUI.owner(of: chat.sessionID)?.tab.id, first.id)
        browser.close(first)
        XCTAssertNil(AntigravitySessionUI.owner(of: chat.sessionID), "closed source cannot resolve to another instance of its saved history")
        XCTAssertEqual(AntigravitySessionUI.owner(of: restored.sessionID)?.tab.id, second.id)
    }

    func testDeletedParkedSourceCannotNavigateToRetainedHistory() {
        let (browser, _, chat) = fixture()
        let usesSpaces = browser.prefs.usesSpaces
        browser.prefs.usesSpaces = true
        defer {
            browser.closeAll()
            browser.prefs.usesSpaces = usesSpaces
        }
        let home = browser.spaceID
        let other = Space(id: UUID(), name: "Other", colour: 0, sharesSignIns: true)
        browser.spaces.append(other)
        browser.switchSpace(to: other.id, animated: false)
        browser.forget(space: home)

        XCTAssertNil(AntigravitySessionUI.owner(of: chat.sessionID))
        XCTAssertFalse(AntigravitySessionUI.go(to: chat.sessionID))
        XCTAssertEqual(browser.spaceID, other.id)
    }

    private func fixture() -> (Browser, Tab, Chat) {
        let browser = Browser(record: WindowRecord())
        let tab = Tab(configuration: Web.configuration(space: browser.spaceID))
        tab.restore(url: URL(string: "about:blank")!, title: "Fixture bill")
        browser.showRow([tab], active: tab.id)
        let chat = browser.chat(for: tab)
        AntigravitySessionUI.bind(chat: chat.sessionID, to: tab.id)
        Browsers.register(browser)
        return (browser, tab, chat)
    }
}
