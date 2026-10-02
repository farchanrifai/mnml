import XCTest
import AppKit
@testable import mnml

@MainActor
final class ContentViewTests: XCTestCase {
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
