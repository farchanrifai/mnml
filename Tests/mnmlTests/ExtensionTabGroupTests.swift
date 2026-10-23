import XCTest
@testable import mnml

final class ExtensionTabGroupTests: XCTestCase {
    func testEveryColourRoundTripsThroughChromesName() {
        for colour in 0..<TabGroup.colourCount {
            XCTAssertEqual(TabGroup.colour(chrome: TabGroup.chromeColour(colour)), colour)
        }
        XCTAssertNil(TabGroup.colour(chrome: "mauve"))
    }

    func testAGroupsNumberIsStableAndNeverNoGroup() {
        let id = UUID()
        XCTAssertEqual(TabGroup.number(id), TabGroup.number(id))
        XCTAssertGreaterThan(TabGroup.number(id), 0)
        XCTAssertEqual(TabGroup.number(UUID(uuid: (0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12))), 1)
    }
}
