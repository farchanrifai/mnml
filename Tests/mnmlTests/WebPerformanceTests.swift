import AppKit
import WebKit
import XCTest
@testable import mnml

@MainActor
final class WebPerformanceTests: XCTestCase {
    private func fixture(_ name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mnml-web-performance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name + ".html")
        try "<!doctype html><title>\(name)</title><p>\(name)</p>".write(to: file, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return file
    }

    func testRestAndCloseCancelWakeWithoutRebuildingThePage() async throws {
        _ = NSApplication.shared
        let url = try fixture("wake")
        for resting in [true, false] {
            let tab = Tab(shy: true)
            tab.restore(url: url, title: "Wake")
            XCTAssertTrue(tab.wake())
            XCTAssertNotNil(tab.built)
            if resting { tab.rest() } else { tab.close() }
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertNil(tab.built, "A queued stage retry must not rebuild a discarded page")
            XCTAssertEqual(tab.address, url)
            XCTAssertEqual(tab.asleep, resting)
            tab.close()
        }
    }

    func testNewNavigationCancelsTheOlderWakeRequest() async throws {
        _ = NSApplication.shared
        let original = try fixture("original")
        let replacement = try fixture("replacement")
        let tab = Tab(shy: true)
        defer { tab.close() }
        tab.restore(url: original, title: "Original")
        XCTAssertTrue(tab.wake())
        tab.go(to: replacement)
        // With no stage window, the old request would retry for a second
        // before loading its original address over this navigation.
        try await Task.sleep(for: .milliseconds(1300))
        XCTAssertEqual(tab.address, replacement)
        XCTAssertEqual(tab.built?.url, replacement)
    }

    func testStopCancelsAQueuedWakeAndDoesNotBuildASleepingPage() async throws {
        _ = NSApplication.shared
        let tab = Tab(shy: true)
        defer { tab.close() }
        tab.restore(url: try fixture("stopped"), title: "Stopped")
        tab.stop()
        XCTAssertNil(tab.built)
        XCTAssertTrue(tab.wake())
        tab.stop()
        try await Task.sleep(for: .milliseconds(1150))
        XCTAssertTrue(tab.built?.url == nil || tab.built?.url?.absoluteString == "about:blank")
        XCTAssertFalse(tab.built?.isLoading ?? true)
    }

    func testBlockerDoesNotRetainControllersWaitingForCompilation() {
        let blocker = Shield()
        weak var released: WKUserContentController?
        autoreleasepool {
            let controller = WKUserContentController()
            released = controller
            blocker.protect(controller)
            blocker.protect(controller)
        }
        XCTAssertNil(released, "A closed page must release its scripts even before the rule list is ready")
        withExtendedLifetime(blocker) {}
    }

}
