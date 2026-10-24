import AppKit
import WebKit
import XCTest
@testable import mnml

@MainActor
final class SleepFullscreenTests: XCTestCase {
    private func backgroundTab(in browser: Browser) -> Tab {
        let tab = Tab(shy: true)
        tab.setAddressOptimistically(URL(string: "https://fullscreen-sleep.invalid/")!)
        _ = tab.web
        browser.insert(tab, at: browser.tabs.count)
        tab.touched = .distantPast
        return tab
    }

    func testEarlyFullscreenSignalPreventsSleepBeforeWebKitUpdates() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let tab = backgroundTab(in: browser)
        XCTAssertNil(browser.awake(because: tab))
        XCTAssertEqual(tab.web.fullscreenState, .notInFullscreen)
        tab.immersed = true
        XCTAssertEqual(browser.awake(because: tab), "full screen")
        var reason: String?
        browser.sleep(tab) { reason = $0 }
        XCTAssertEqual(reason, "full screen")
        XCTAssertTrue(browser.sleepRequests.isEmpty)
        XCTAssertNotNil(tab.built)
        tab.immersed = false
        XCTAssertNil(browser.awake(because: tab), "The tab may sleep again after fullscreen ends")
    }

    func testFullscreenBeginningDuringFormCheckCancelsSleep() async {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let tab = backgroundTab(in: browser)
        let page = tab.web
        let completed = expectation(description: "The pending sleep is cancelled")
        browser.sleep(tab) { reason in
            XCTAssertEqual(reason, "full screen")
            completed.fulfill()
        }
        XCTAssertEqual(browser.sleepRequests.count, 1)
        tab.immersed = true
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertTrue(tab.built === page)
        XCTAssertFalse(tab.asleep)
        XCTAssertTrue(browser.sleepRequests.isEmpty)
    }

}
