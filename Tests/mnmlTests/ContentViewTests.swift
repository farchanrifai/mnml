import XCTest
import AppKit
import SwiftUI
@testable import mnml

@MainActor
final class ContentViewTests: XCTestCase {
    func testInsetPageFrameFollowsChromeAndClearsForVideoFullscreen() async throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        browser.welcoming = false
        browser.editing = false
        let prefs = browser.prefs
        let previous = (prefs.sidebar, prefs.pageUnder, prefs.frostedSidebar, prefs.bookmarksBar, prefs.askMode)
        defer {
            prefs.sidebar = previous.0
            prefs.pageUnder = previous.1
            prefs.frostedSidebar = previous.2
            prefs.bookmarksBar = previous.3
            prefs.askMode = previous.4
        }
        browser.prefs.bookmarksBar = false
        browser.prefs.askMode = .side
        let tab = try XCTUnwrap(browser.active)
        tab.restore(url: URL(string: "about:blank")!, title: "Frame test")
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 800, height: 600),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { browser.closeAll(); window.close() }

        for (sidebar, under, immersive, chat) in [(true, false, false, false), (false, false, false, false),
                                                 (true, true, false, false), (false, true, false, false),
                                                 (true, true, false, true), (true, false, true, false)] {
            browser.prefs.sidebar = sidebar
            browser.prefs.frostedSidebar = true
            browser.prefs.pageUnder = under
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
            let inset: CGFloat = immersive ? 0 : 6
            XCTAssertEqual(frame.minX, chromeWidth + inset, accuracy: 0.5)
            XCTAssertEqual(frame.width, host.bounds.width - chromeWidth - browser.askRoom - inset * 2, accuracy: 0.5)
            let visibleTop = (host.isFlipped ? frame.minY : host.bounds.maxY - frame.maxY) + stage.under.top
            XCTAssertEqual(visibleTop, chromeHeight + inset, accuracy: 0.5)
            let visibleHeight = frame.height - stage.under.top
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
        XCTAssertEqual(frame.minX, prefs.sideWidth + 6, accuracy: 0.5)
        XCTAssertEqual(frame.width, (host.bounds.width - prefs.sideWidth - 18) / 2, accuracy: 0.5)
        XCTAssertEqual(frame.height, host.bounds.height - 12, accuracy: 0.5)
    }

    private func findStage(in view: NSView) -> StageView? {
        if let stage = view as? StageView { return stage }
        return view.subviews.lazy.compactMap { self.findStage(in: $0) }.first
    }

    func testPageFrameMaskTracksViewportWidthWithoutAnInteriorEdge() {
        let rim = PageFrame(inset: 6, corner: 10)
        for width: CGFloat in [320, 481.5, 584, 799.75, 800] {
            let rect = CGRect(x: 17, y: 9, width: width, height: 600)
            let path = rim.path(in: rect)
            XCTAssertTrue(path.contains(CGPoint(x: rect.maxX - 3, y: rect.midY), eoFill: true))
            XCTAssertFalse(path.contains(CGPoint(x: rect.maxX - 7, y: rect.midY), eoFill: true))
            XCTAssertTrue(path.contains(CGPoint(x: rect.minX + 3, y: rect.midY), eoFill: true))
            XCTAssertFalse(path.contains(CGPoint(x: rect.midX, y: rect.midY), eoFill: true))
            XCTAssertTrue(path.contains(CGPoint(x: rect.minX + 6, y: rect.minY + 6), eoFill: true))
            XCTAssertFalse(path.contains(CGPoint(x: rect.maxX + 1, y: rect.midY), eoFill: true))
        }
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
