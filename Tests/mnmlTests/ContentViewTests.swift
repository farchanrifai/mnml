import XCTest
import AppKit
import SwiftUI
import WebKit
@testable import mnml

@MainActor
final class ContentViewTests: XCTestCase {
    func testInsetPageFrameFollowsChromeAndClearsForVideoFullscreen() async throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        browser.welcoming = false
        browser.editing = false
        let prefs = browser.prefs
        let previous = (prefs.sidebar, prefs.frostedSidebar, prefs.bookmarksBar, prefs.askMode)
        defer {
            prefs.sidebar = previous.0
            prefs.frostedSidebar = previous.1
            prefs.bookmarksBar = previous.2
            prefs.askMode = previous.3
        }
        browser.prefs.bookmarksBar = false
        browser.prefs.askMode = .side
        let tab = try XCTUnwrap(browser.active)
        tab.restore(url: URL(string: "about:blank")!, title: "Frame test")
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 800, height: 600),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { browser.closeAll(); window.close() }

        for (sidebar, immersive, chat) in [(true, false, false), (false, false, false),
                                           (true, false, true), (true, true, false)] {
            browser.prefs.sidebar = sidebar
            browser.prefs.frostedSidebar = true
            browser.folded = false
            browser.chatting = chat ? [tab.id] : []
            tab.immersed = immersive
            let host = NSHostingView(rootView: ContentView(browser: browser))
            host.safeAreaRegions = []
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            await drainMainQueue()
            host.layoutSubtreeIfNeeded()
            let stage = try XCTUnwrap(findStage(in: host))
            let frame = stage.convert(stage.bounds, to: host)
            let chromeWidth = sidebar && !immersive ? browser.prefs.sideWidth : 0
            let chromeHeight = !sidebar && !immersive ? Metrics.strip : 0
            let inset: CGFloat = immersive ? 0 : PageCard.gap
            XCTAssertEqual(frame.minX, chromeWidth + inset, accuracy: 0.5)
            XCTAssertEqual(frame.width, host.bounds.width - chromeWidth - browser.askRoom - inset * 2, accuracy: 0.5)
            let visibleTop = host.isFlipped ? frame.minY : host.bounds.maxY - frame.maxY
            XCTAssertEqual(visibleTop, chromeHeight + inset, accuracy: 0.5)
            let visibleHeight = frame.height
            XCTAssertEqual(visibleHeight, host.bounds.height - chromeHeight - inset * 2, accuracy: 0.5)
            XCTAssertEqual(stage.layer?.cornerRadius, immersive ? 0 : 10)
            XCTAssertEqual(browser.pageFrame.width, host.bounds.width - chromeWidth - browser.askRoom - inset * 2, accuracy: 0.5)
            XCTAssertEqual(browser.pageFrame.height, visibleHeight, accuracy: 0.5)
            XCTAssertEqual(browser.pageFrame.minY, visibleTop, accuracy: 0.5)
        }

        tab.immersed = false
        let second = Tab()
        second.restore(url: URL(string: "about:blank")!, title: "Second pane")
        second.partner = tab.id
        browser.insert(second, at: browser.tabs.count)
        let host = NSHostingView(rootView: ContentView(browser: browser))
        host.safeAreaRegions = []
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        await drainMainQueue()
        host.layoutSubtreeIfNeeded()
        let stage = try XCTUnwrap(findStage(in: host))
        let frame = stage.convert(stage.bounds, to: host)
        XCTAssertEqual(frame.minX, prefs.sideWidth + PageCard.gap, accuracy: 0.5)
        XCTAssertEqual(frame.width, (host.bounds.width - prefs.sideWidth - PageCard.gap * 3) / 2, accuracy: 0.5)
        XCTAssertEqual(frame.height, host.bounds.height - PageCard.gap * 2, accuracy: 0.5)
    }

    private func findStage(in view: NSView) -> StageView? {
        if let stage = view as? StageView { return stage }
        return view.subviews.lazy.compactMap { self.findStage(in: $0) }.first
    }

    /// A held page keeps its size, pinned to the card's top-left corner, as
    /// the card moves; let go, it is the card's size again.
    func testHeldPageKeepsItsSizeWhileTheStageMoves() {
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 900, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let stage = StageView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        window.contentView?.addSubview(stage)
        let page = NSView()
        stage.show(page)
        stage.hold = CGSize(width: 800, height: 520)
        for width: CGFloat in [600, 650, 720, 800] {
            stage.frame.size = CGSize(width: width, height: 500)
            stage.layoutSubtreeIfNeeded()
            XCTAssertEqual(page.frame.size, CGSize(width: 800, height: 520))
            XCTAssertEqual(page.frame.maxY, stage.bounds.maxY, "pinned to the top")
            XCTAssertEqual(page.frame.minX, 0)
        }
        stage.hold = nil
        stage.layoutSubtreeIfNeeded()
        XCTAssertEqual(page.frame, stage.bounds)
    }

    /// WebKit keeps the block until the page has drawn, and calls it then.
    func testDrawnCallsBackOnceThePageHasDrawn() async {
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let web = WKWebView(frame: window.contentView!.bounds)
        window.contentView?.addSubview(web)
        window.orderBack(nil)
        web.loadHTMLString("<p>drawn</p>", baseURL: nil)
        let drawn = expectation(description: "drawn")
        Drawn.after(web) { drawn.fulfill() }
        web.frame.size.width = 300
        await fulfillment(of: [drawn], timeout: 5)
    }

    func testQueuedFocusHandoffRespectsNewFieldAndPanel() async {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        browser.welcoming = false
        browser.editing = false
        let tab = browser.active!
        tab.go(to: URL(string: "http://127.0.0.1:9/focus-test")!)
        let web = tab.web
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        window.contentView?.addSubview(web)
        window.contentView?.addSubview(field)
        window.makeFirstResponder(field)
        let responder = window.firstResponder
        let view = ContentView(browser: browser)
        defer { browser.closeAll(); window.close() }

        view.handBack()
        browser.editing = true
        await drainMainQueue()
        XCTAssertTrue(window.firstResponder === responder)

        browser.editing = false
        view.handBack()
        browser.tuning = true
        await drainMainQueue()
        XCTAssertTrue(window.firstResponder === responder)

        browser.tuning = false
        view.handBack()
        await drainMainQueue()
        XCTAssertTrue(window.firstResponder === web)
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
