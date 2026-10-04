import XCTest
import AppKit
import WebKit
@testable import mnml

@MainActor
final class StageViewTests: XCTestCase {
    func testRepeatedShowAndLayoutDoNotResizeAnUnchangedPage() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let stage = StageView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView = stage
        let page = FrameCountingView()
        stage.show(page)
        XCTAssertEqual(page.frame, stage.bounds)
        let initial = page.assignments
        for _ in 0..<20 {
            stage.show(page)
            stage.layout()
        }
        XCTAssertEqual(page.assignments, initial)

        stage.setFrameSize(NSSize(width: 900, height: 700))
        stage.layout()
        XCTAssertEqual(page.frame, stage.bounds)
        XCTAssertEqual(page.assignments, initial + 1)

        // A page moved by another container still comes back on the next
        // layout, even when the stage's own size has not changed.
        page.removeFromSuperview()
        page.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        stage.layout()
        XCTAssertTrue(page.superview === stage)
        XCTAssertEqual(page.frame, stage.bounds)
    }

    func testRepeatedShowKeepsFullscreenWatchAndPageSwitchReplacesIt() throws {
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let first = WKWebView(frame: .zero, configuration: configuration)
        let second = WKWebView(frame: .zero, configuration: configuration)
        let stage = StageView()
        stage.show(first)
        weak var previous = stage.fullscreenWatch
        let observation = ObjectIdentifier(try XCTUnwrap(stage.fullscreenWatch))
        stage.show(first)
        XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(stage.fullscreenWatch)), observation)

        stage.show(second)
        XCTAssertNotEqual(ObjectIdentifier(try XCTUnwrap(stage.fullscreenWatch)), observation)
        XCTAssertNil(previous)
        weak var current = stage.fullscreenWatch
        stage.show(nil)
        XCTAssertNil(stage.fullscreenWatch)
        XCTAssertNil(current)
    }

    private final class FrameCountingView: NSView {
        var assignments = 0
        override var frame: NSRect {
            get { super.frame }
            set { assignments += 1; super.frame = newValue }
        }
    }
}
