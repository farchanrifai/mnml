import XCTest
import AppKit
import SwiftUI
@testable import mnml

@MainActor
final class ContentViewPerformanceTests: XCTestCase {
    func testKeyWatchersAreRemovedWhenTheViewLeavesAndTheBrowserCloses() async throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        browser.welcoming = false
        let visibility = Visibility()
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 800, height: 600),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: Fixture(browser: browser, visibility: visibility))
        host.safeAreaRegions = []
        window.contentView = host
        defer { browser.closeAll(); window.close() }
        let id = ObjectIdentifier(browser)
        host.layoutSubtreeIfNeeded()
        await drain()
        XCTAssertNotNil(ContentView.keyHooks[id])

        visibility.shown = false
        await drain()
        host.layoutSubtreeIfNeeded()
        await drain()
        XCTAssertNil(ContentView.keyHooks[id])

        visibility.shown = true
        await drain()
        host.layoutSubtreeIfNeeded()
        await drain()
        XCTAssertNotNil(ContentView.keyHooks[id])
        browser.closeAll()
        XCTAssertNil(ContentView.keyHooks[id])
    }

    private func drain() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private final class Visibility: ObservableObject {
        @Published var shown = true
    }

    private struct Fixture: View {
        let browser: Browser
        @ObservedObject var visibility: Visibility
        var body: some View {
            if visibility.shown { ContentView(browser: browser) }
        }
    }
}
