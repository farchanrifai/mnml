import AppKit
import XCTest
@testable import mnml

final class FaviconAppearanceTests: XCTestCase {
    func testOnlyTransparentMonochromeMarksUseChromeInk() {
        XCTAssertTrue(Favicons.isMonochromeMark(icon(mark: .black)))
        XCTAssertTrue(Favicons.isMonochromeMark(icon(mark: .white)))
        XCTAssertFalse(Favicons.isMonochromeMark(icon(mark: .systemBlue)))
        XCTAssertFalse(Favicons.isMonochromeMark(icon(mark: .black, background: .white)))
    }

    private func icon(mark: NSColor, background: NSColor? = nil) -> NSImage {
        let image = NSImage(size: NSSize(width: 64, height: 64))
        image.lockFocus()
        (background ?? .clear).setFill()
        NSRect(x: 0, y: 0, width: 64, height: 64).fill(using: .copy)
        mark.setFill()
        NSBezierPath(ovalIn: NSRect(x: 12, y: 12, width: 40, height: 40)).fill()
        image.unlockFocus()
        return image
    }
}
