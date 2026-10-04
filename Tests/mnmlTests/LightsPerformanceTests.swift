import XCTest
import AppKit
@testable import mnml

@MainActor
final class LightsPerformanceTests: XCTestCase {
    func testRetiringWindowReleasesLightPlacementCallbacks() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 800, height: 600),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { Lights.forget(window); window.close() }
        var owner: Owner? = Owner()
        weak var observed = owner
        Lights.keep(window, centreX: { Lights.centre.x }, moved: { [owner] in owner?.moves += 1 })
        owner = nil
        XCTAssertNotNil(observed)
        Lights.forget(window)
        XCTAssertNil(observed)

        // Another view can take over the same retained AppKit window.
        var replacement: Owner? = Owner()
        weak var next = replacement
        Lights.keep(window, centreX: { Lights.centre.x }, moved: { [replacement] in replacement?.moves += 1 })
        replacement = nil
        XCTAssertNotNil(next, "The replacement light controller must retain its callback")
        Lights.forget(window)
        XCTAssertNil(next)
    }

    private final class Owner { var moves = 0 }
}
