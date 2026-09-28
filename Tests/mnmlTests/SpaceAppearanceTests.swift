import XCTest
import AppKit
@testable import mnml

@MainActor
final class SpaceAppearanceTests: XCTestCase {
    func testLegacyFilesAndAppearanceRoundTrip() throws {
        let old = Data("[{\"id\":\"00000000-0000-0000-0000-000000000001\",\"name\":\"Personal\",\"colour\":0}]".utf8)
        var spaces = try JSONDecoder().decode([Space].self, from: old)
        XCTAssertNil(spaces[0].appearance)
        let tint = SpaceAppearance(light: "3B82F6", dark: Tint.same, strength: 0.22)
        spaces[0].appearance = tint
        XCTAssertEqual(try JSONDecoder().decode([Space].self, from: JSONEncoder().encode(spaces)), spaces)
        XCTAssertEqual(tint.tint(darkMode: true), "3B82F6")
        XCTAssertEqual(SpaceAppearance(light: "3B82F6", dark: "", strength: 0.22).tint(darkMode: true), "")
    }

    func testInheritanceAndChangesAcrossWindows() {
        _ = NSApplication.shared
        let first = Browser(record: WindowRecord())
        let second = Browser(record: WindowRecord())
        second.spaces = first.spaces
        let id = first.spaceID
        let override = SpaceAppearance(light: "22C55E", dark: "8B5CF6", strength: 0.3)
        XCTAssertEqual(first.appearance(for: id), first.globalAppearance)
        first.setAppearance(override, for: id)
        XCTAssertEqual(first.appearance(for: id), override)
        XCTAssertEqual(first.effectiveAppearance, override)
        XCTAssertEqual(second.appearance(for: id), override)
        let none = SpaceAppearance(light: "", dark: "", strength: 0.22)
        first.setAppearance(none, for: id)
        XCTAssertEqual(first.appearance(for: id), none)
        first.setAppearance(nil, for: id)
        XCTAssertEqual(second.appearance(for: id), second.globalAppearance)
    }

    func testGestureBoundaries() {
        XCTAssertNil(SpaceSwipe.navigationTarget(from: 0, count: 1, step: 1))
        XCTAssertNil(SpaceSwipe.navigationTarget(from: 0, count: 1, step: -1))
        XCTAssertNil(SpaceSwipe.navigationTarget(from: 2, count: 3, step: 1))
        XCTAssertEqual(SpaceSwipe.navigationTarget(from: 1, count: 3, step: 1), 2)
        XCTAssertEqual(SpaceSwipe.navigationTarget(from: 2, count: 3, step: -1), 1)
        // A creation card explicitly opened by the menu still permits swiping back.
        XCTAssertEqual(SpaceSwipe.navigationTarget(from: 3, count: 3, step: -1), 2)
    }

    func testStaleTransitionCompletionDoesNotClearNewSwitch() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let old = browser.spaceTransitionTicket
        browser.clearSpaceTransition()
        browser.spaceTintFrom = browser.globalAppearance
        browser.spaceTintTo = SpaceAppearance(light: "22C55E", dark: Tint.same, strength: 0.22)
        browser.finishSpaceTransition(old)
        XCTAssertNotNil(browser.spaceTintTo)
        browser.clearSpaceTransition()
        XCTAssertNil(browser.spaceTintTo)
        XCTAssertEqual(browser.spaceTintProgress, 1)
    }
}
