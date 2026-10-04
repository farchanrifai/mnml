import XCTest
import AppKit
@testable import mnml

@MainActor
final class FloatPerformanceTests: XCTestCase {
    func testProgressQueriesOnlyRunForVisibleControlsAndDoNotOverlap() throws {
        _ = NSApplication.shared
        let previousAway = mnml.Float.benchAway
        mnml.Float.benchAway = NSPoint(x: -10000, y: -10000)
        let floater = mnml.Float()
        defer { floater.drop(); mnml.Float.benchAway = previousAway }
        var replies: [(Double?, Bool?) -> Void] = []
        floater.onProgress = { replies.append($0) }
        let page = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        floater.lift(page)
        let controls = try XCTUnwrap(page.superview?.superview?.subviews.last)
        let event = try XCTUnwrap(NSEvent.otherEvent(with: .applicationDefined, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0))
        floater.refreshProgress()
        XCTAssertTrue(replies.isEmpty)

        controls.mouseEntered(with: event)
        for _ in 0..<20 { floater.refreshProgress() }
        XCTAssertEqual(replies.count, 1)
        // A failed query releases the next one without changing controls.
        replies[0](nil, nil)
        floater.refreshProgress()
        XCTAssertEqual(replies.count, 2)
        controls.mouseExited(with: event)
        replies[1](0.25, true)
        floater.refreshProgress()
        XCTAssertEqual(replies.count, 2)

        // A reply to the previous floating window cannot complete a query
        // or change the controls of its replacement.
        controls.mouseEntered(with: event)
        floater.refreshProgress()
        XCTAssertEqual(replies.count, 3)
        floater.drop()
        floater.lift(page)
        let replacement = try XCTUnwrap(page.superview?.superview?.subviews.last)
        replacement.mouseEntered(with: event)
        floater.refreshProgress()
        XCTAssertEqual(replies.count, 4)
        replies[2](0.5, false)
        floater.refreshProgress()
        XCTAssertEqual(replies.count, 4)
        replies[3](0.75, true)
        floater.refreshProgress()
        XCTAssertEqual(replies.count, 5)
    }
}
