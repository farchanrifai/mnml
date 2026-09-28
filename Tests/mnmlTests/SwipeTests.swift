import XCTest
@testable import mnml

final class SwipeTests: XCTestCase {
    func testSheetsKeepsHorizontalSwipes() {
        XCTAssertTrue(Swipe.pageUsesHorizontalSwipe(URL(string: "https://docs.google.com/spreadsheets/d/sheet-id/edit")))
        XCTAssertTrue(Swipe.pageUsesHorizontalSwipe(URL(string: "https://docs.google.com/spreadsheets/u/0/")))
        XCTAssertFalse(Swipe.pageUsesHorizontalSwipe(URL(string: "https://docs.google.com/document/d/doc-id/edit")))
        XCTAssertFalse(Swipe.pageUsesHorizontalSwipe(URL(string: "https://docs.google.com.evil.example/spreadsheets/d/id")))
    }
}
