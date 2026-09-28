import XCTest
import AppKit
@testable import mnml

@MainActor
final class PiPSpaceTests: XCTestCase {
    func testReturnFindsVideoInParkedSpace() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let usesSpaces = browser.prefs.usesSpaces
        let floatsOnLeave = browser.prefs.floatsOnLeave
        browser.prefs.usesSpaces = true
        browser.prefs.floatsOnLeave = false
        defer {
            browser.prefs.usesSpaces = usesSpaces
            browser.prefs.floatsOnLeave = floatsOnLeave
            browser.land()
        }
        let home = browser.spaceID
        let video = browser.active!
        let other = Space(id: UUID(), name: "PiP test", colour: 0, icon: "briefcase", sharesSignIns: true)
        browser.spaces.append(other)
        browser.systemPiP = video.id
        browser.switchSpace(to: other.id)
        XCTAssertTrue(browser.parkedTabs.contains { $0.id == video.id })
        XCTAssertEqual(browser.systemPiP, video.id)

        NotificationCenter.default.post(name: SystemPiP.returned, object: nil)
        XCTAssertEqual(browser.spaceID, home)
        XCTAssertEqual(browser.activeID, video.id)
        XCTAssertNil(browser.systemPiP)

        browser.switchSpace(to: other.id)
        browser.systemPiP = video.id
        browser.land()
        XCTAssertNil(browser.systemPiP)
        browser.systemPiP = video.id
        browser.forget(space: home)
        XCTAssertNil(browser.systemPiP)
        XCTAssertFalse(browser.parkedTabs.contains { $0.id == video.id })
    }
}
