import AppKit
import WebKit
import XCTest
@testable import Search

@available(macOS 15.4, *)
@MainActor
final class TabCaptureTests: XCTestCase {
    private var browser: Browser!
    private var windows: [NSWindow] = []
    private var activationPolicy: NSApplication.ActivationPolicy!
    private let permission = CapturePermission()

    override class func setUp() {
        setenv("SEARCH_PROBE", "tab-capture-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() {
        _ = NSApplication.shared
        activationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        browser.closeAll()
    }

    override func tearDown() {
        browser.closeAll()
        browser = nil
        for window in windows {
            if let web = window.contentView as? WKWebView {
                web.setCameraCaptureState(.none, completionHandler: nil)
                web.setMicrophoneCaptureState(.none, completionHandler: nil)
            }
            window.close()
        }
        windows = []
        NSApp.setActivationPolicy(activationPolicy)
    }

    func testClosingTabEndsCaptureWithoutStoppingAnotherTab() async throws {
        let tab = try await capture()
        let other = try await capture()
        let web = tab.web
        let otherWeb = other.web
        browser.close(tab)
        try await ended(web)
        XCTAssertTrue(browser.tabs.contains { $0 === other })
        XCTAssertEqual(otherWeb.cameraCaptureState, .active)
        XCTAssertEqual(otherWeb.microphoneCaptureState, .active)
    }

    func testClosingLastTabEndsCaptureAndLeavesBlankTab() async throws {
        let tab = try await capture()
        let web = tab.web
        XCTAssertEqual(browser.tabs.count, 1)
        browser.close(tab)
        try await ended(web)
        XCTAssertEqual(browser.tabs.count, 1)
        XCTAssertTrue(browser.tabs[0].isBlank)
    }

    func testClosingPinnedTabEndsCaptureAndKeepsPin() async throws {
        let tab = try await capture()
        tab.pin = "C"
        let web = tab.web
        browser.close(tab)
        try await ended(web)
        XCTAssertTrue(browser.tabs.contains { $0 === tab })
        XCTAssertTrue(tab.asleep)
        XCTAssertEqual(tab.pin, "C")
    }

    func testClosingAllTabsEndsItsCapture() async throws {
        let tab = try await capture()
        let web = tab.web
        browser.closeAll()
        try await ended(web)
        XCTAssertTrue(browser.tabs.isEmpty)
    }

    private func capture() async throws -> Tab {
        let configuration = Web.configuration(shy: true)
        // Refuse to use real hardware if WebKit removes its mock-device seam.
        guard configuration.preferences.responds(to: NSSelectorFromString("_setMockCaptureDevicesEnabled:")) else {
            throw XCTSkip("WebKit mock capture devices are unavailable")
        }
        let tab = Tab(shy: true, configuration: configuration)
        browser.prepare(tab)
        browser.insert(tab, at: browser.tabs.count)
        let web = tab.web
        web.uiDelegate = permission
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 640, height: 480),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        XCTAssertFalse(Bench.onScreen(window))
        window.orderBack(nil)
        XCTAssertFalse(Bench.onScreen(window))
        windows.append(window)
        web.loadHTMLString("<title>Capture fixture</title>", baseURL: URL(string: "http://localhost"))
        try await waitUntil("load") { web.title == "Capture fixture" && !web.isLoading }
        _ = try await web.evaluateJavaScript("""
            window.captureResult = 'pending';
            navigator.mediaDevices.getUserMedia({video: true, audio: true}).then(stream => {
                window.captureStream = stream;
                window.captureResult = 'started';
            }, error => { window.captureResult = error.name; });
            void 0;
            """)
        try await waitUntil("capture starts") { web.cameraCaptureState == .active && web.microphoneCaptureState == .active }
        try await waitUntil("stream returned") { try await web.evaluateJavaScript("window.captureResult !== 'pending'") as? Bool == true }
        let result = try await web.evaluateJavaScript("window.captureResult") as? String
        XCTAssertEqual(result, "started")
        return tab
    }

    private func ended(_ web: WKWebView) async throws {
        // Retaining the old view makes teardown independent of deallocation.
        try await waitUntil("capture ends") { web.cameraCaptureState == .none && web.microphoneCaptureState == .none }
        let states = try await web.evaluateJavaScript("window.captureStream.getTracks().map(track => track.readyState)") as? [String]
        XCTAssertEqual(states?.sorted(), ["ended", "ended"])
    }

    private func waitUntil(_ description: String, _ condition: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while try await condition() == false {
            guard Date() < deadline else {
                XCTFail("Timed out: \(description)")
                throw NSError(domain: "TabCaptureTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for WebKit capture state"])
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

@MainActor
private final class CapturePermission: NSObject, WKUIDelegate {
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.grant)
    }
}
