import XCTest
import AppKit
import WebKit
@testable import mnml

@MainActor
final class StageViewTests: XCTestCase {
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
}
