import AppKit
import WebKit
import XCTest
@testable import mnml

@MainActor
final class PopupGestureRelayTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "popup-relay-\(getpid())", 1)
        super.setUp()
    }

    func testRelayLooksUpTheMessageViewInsteadOfTheLastBuiltTab() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        let url = try XCTUnwrap(URL(string: "about:blank"))
        let first = browser.benchOpen(url)
        let second = browser.benchOpen(url)
        // A shared controller can call the very same handler for either view.
        // A handler bound to `second` must not steal or discard `first`'s input.
        XCTAssertTrue(PopupGestureRelay.tab(for: first.web) === first)
        XCTAssertTrue(PopupGestureRelay.tab(for: second.web) === second)
        XCTAssertNil(PopupGestureRelay.tab(for: WKWebView(frame: .zero)))
        XCTAssertTrue(NSApp.windows.allSatisfy { !$0.isVisible })
        XCTAssertFalse(NSApp.isActive)
    }

    func testPeekAndLittleWindowKeepTheirOwnPopupPermission() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        let url = try XCTUnwrap(URL(string: "about:blank"))
        let source = browser.benchOpen(url)
        browser.peek(url, from: source)
        let peek = try XCTUnwrap(browser.peekTab)
        XCTAssertTrue(PopupGestureRelay.tab(for: peek.web) === peek)
        browser.closePeek()
        LittleWindow.show(url, for: browser, front: false)
        let little = try XCTUnwrap(LittleWindow.all.last)
        defer { little.close() }
        XCTAssertTrue(PopupGestureRelay.tab(for: little.tab.web) === little.tab)
        XCTAssertTrue(NSApp.windows.allSatisfy { !$0.isVisible })
    }


}
