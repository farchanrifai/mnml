import XCTest
import AppKit
import SwiftUI
@testable import mnml

final class SplitPairTests: XCTestCase {
    func testNonadjacentPairsAndMissingMembers() {
        let left = UUID(), right = UUID(), other = UUID()
        let members: [(id: UUID, partner: UUID?)] = [(left, nil), (other, nil), (right, left)]
        XCTAssertEqual(Split.pair(of: left, in: members), Split(left: left, right: right))
        XCTAssertEqual(Split.pair(of: right, in: members), Split(left: left, right: right))
        XCTAssertNil(Split.pair(of: other, in: members))
        XCTAssertNil(Split.pair(of: right, in: [(right, left)]))
        XCTAssertNil(Split.pair(of: left, in: [(left, left)]))
    }

    func testSessionRoundTripAndLegacy() throws {
        let legacy = Data(#"{"tabs":[{"url":"https://example.com","title":"Example","split":true}],"active":0}"#.utf8)
        let old = try JSONDecoder().decode(Session.Shape.self, from: legacy)
        XCTAssertNil(old.tabs[0].id)
        XCTAssertTrue(old.tabs[0].split == true)
        var entry = old.tabs[0]
        entry.id = UUID(); entry.partner = UUID(); entry.touched = Date(timeIntervalSince1970: 100)
        let restored = try JSONDecoder().decode(Session.Entry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(restored.id, entry.id)
        XCTAssertEqual(restored.partner, entry.partner)
        XCTAssertEqual(restored.touched, entry.touched)
    }
}

@MainActor
final class PeekModelTests: XCTestCase {
    func testPeekZoomKeepsLiveViewportFixed() throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let preview = browser.open(URL(string: "http://127.0.0.1:9/preview")!, foreground: true)
        let surface = PeekSurfaceView(panel: PeekPanel(browser: browser, tab: preview))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = surface
        defer { window.contentView = nil }
        surface.layoutSubtreeIfNeeded()
        surface.host.layoutSubtreeIfNeeded()
        let web = preview.web
        let viewport = web.bounds
        XCTAssertGreaterThan(viewport.width, 0)
        XCTAssertGreaterThan(viewport.height, 0)
        // A zoom transform changes presentation only; repeated layout must keep
        // the live page's viewport and identity, including while it is opening.
        surface.needsLayout = true
        surface.layoutSubtreeIfNeeded()
        XCTAssertEqual(web.bounds, viewport)
        XCTAssertTrue(preview.built === web)
        XCTAssertEqual(surface.host.frame.size.width, surface.bounds.width * 0.88, accuracy: 1)
        XCTAssertEqual(surface.host.frame.size.height, surface.bounds.height * 0.86, accuracy: 1)
        let closed = expectation(description: "One completed native close")
        closed.assertForOverFulfill = true
        surface.close { closed.fulfill() }
        XCTAssertTrue(surface.backdrop.isDescendant(of: surface))
        XCTAssertEqual(web.bounds, viewport)
        XCTAssertTrue(web.isDescendant(of: surface))
        XCTAssertEqual(surface.layer?.opacity, 0)
        XCTAssertNotNil(surface.layer?.animation(forKey: "peek.close"))
        surface.close { XCTFail("Repeated close must not complete twice") }
        XCTAssertTrue(web.isDescendant(of: surface))
        CATransaction.flush()
        wait(for: [closed], timeout: 1)
    }

    func testCloseThroughMountedPeekLayerCompletes() throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let preview = Tab()
        browser.presentPeek(preview, from: try XCTUnwrap(browser.active))
        let host = NSHostingView(rootView: PeekLayer(browser: browser))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        let closed = expectation(description: "Mounted Peek dismisses through browser")
        browser.closePeek { closed.fulfill() }
        wait(for: [closed], timeout: 2)
        XCTAssertNil(browser.peekTab)
        XCTAssertFalse(browser.peekClosing)
        XCTAssertNil(browser.peekDismissal)
    }

    func testClosingPeekCannotBePromoted() throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let preview = Tab()
        browser.presentPeek(preview, from: try XCTUnwrap(browser.active))
        browser.peekClosing = true
        browser.keepPeek()
        browser.splitPeek()
        browser.closePeek()
        XCTAssertTrue(browser.peekTab === preview)
        XCTAssertFalse(browser.tabs.contains { $0 === preview })
        browser.closeAll()
        XCTAssertFalse(browser.peekClosing)
        XCTAssertNil(browser.peekTab)
    }

    func testEditingPreviewKeepsArrowShortcutsInTheField() throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let preview = Tab()
        browser.presentPeek(preview, from: try XCTUnwrap(browser.active))
        preview.typing = true
        XCTAssertTrue(browser.editingText)
        XCTAssertFalse(try XCTUnwrap(Command.named("tabs.backArrow")).run(browser))
        XCTAssertFalse(try XCTUnwrap(Command.named("tabs.forwardArrow")).run(browser))
    }

    func testPinnedPromotionPreservesLivePageAndSessionIdentity() throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let pins = Pins.defs(browser.spaceID)
        defer { browser.closeAll(); Pins.set(browser.spaceID, pins, from: browser) }
        let source = browser.open(URL(string: "http://127.0.0.1:9/source")!, foreground: true)
        browser.pin(source)
        browser.peek(URL(string: "http://127.0.0.1:9/preview")!, from: source)
        let preview = try XCTUnwrap(browser.peekTab)
        let view = preview.web
        XCTAssertTrue(preview.store === source.store)
        XCTAssertTrue(browser.tab(for: view) === preview)
        XCTAssertTrue(browser.pageTarget === preview)
        let unrelated = Tab()
        browser.insert(unrelated, at: browser.tabs.count)
        browser.splitPeek()
        XCTAssertNil(browser.peekTab)
        XCTAssertTrue(browser.active === preview)
        XCTAssertTrue(preview.built === view)
        XCTAssertNotNil(source.pin)
        XCTAssertEqual(browser.shownSplit, Split(left: source.id, right: preview.id))
        browser.writeSession(now: true)
        let saved = browser.readRow(browser.spaceID)
        XCTAssertEqual(saved.tabs.first { $0.id == preview.id }?.partner, source.id)
        browser.close(preview)
        XCTAssertNil(browser.split(of: source.id))
        XCTAssertNotNil(source.pin)
        XCTAssertTrue(browser.tabs.contains { $0 === source })
    }

    func testReplacingOppositePaneKeepsDisplacedTab() throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let pins = Pins.defs(browser.spaceID)
        defer { browser.closeAll(); Pins.set(browser.spaceID, pins, from: browser) }
        let left = browser.open(URL(string: "http://127.0.0.1:9/left")!, foreground: true)
        let right = browser.open(URL(string: "http://127.0.0.1:9/right")!, foreground: true)
        browser.makeSplit(right, beside: left, on: .right)
        browser.peek(URL(string: "http://127.0.0.1:9/new")!, from: right)
        let preview = try XCTUnwrap(browser.peekTab)
        browser.splitPeek()
        XCTAssertEqual(browser.shownSplit, Split(left: preview.id, right: right.id))
        XCTAssertTrue(browser.tabs.contains { $0 === left })
        XCTAssertNil(browser.split(of: left.id))
    }
}
