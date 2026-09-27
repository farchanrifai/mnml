// Does Core Animation replicate a live WKWebView into the empty sidebar strip?
// The real web view begins at x=220, so no page content is covered.

import AppKit
import QuartzCore
import WebKit

@main
struct ReplicaProbe {
    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = ProbeDelegate()
        app.delegate = delegate
        print("starting replica probe")
        app.finishLaunching()
        app.run()
    }
}

private final class ProbeDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let stage = NSView()
    private let web = WKWebView(frame: .zero)
    private let sidebar = NSVisualEffectView()

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("creating replica window")
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                          styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        print("window created")
        window.title = "Replica probe"
        window.center()

        let root = NSView()
        window.contentView = root
        print("root added")
        let inset = CommandLine.arguments.contains("inset")
        let replicator = CAReplicatorLayer()
        replicator.instanceCount = 2
        // Reflect at the sidebar boundary: page x=220...440 appears at
        // x=220...0, while no replica can paint over the page at x>220.
        replicator.instanceTransform = CATransform3DMakeAffineTransform(
            CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 440 - root.bounds.width, ty: 0)
        )
        stage.wantsLayer = true
        stage.layer = replicator
        print("replicator added")
        stage.frame = inset ? root.bounds : NSRect(x: 220, y: 0, width: 1060, height: 820)
        stage.autoresizingMask = [.width, .height]
        root.addSubview(stage)

        web.frame = stage.bounds
        web.autoresizingMask = [.width, .height]
        stage.addSubview(web)
        if inset {
            web.obscuredContentInsets = NSEdgeInsets(top: 0, left: 220, bottom: 0, right: 0)
            let selector = NSSelectorFromString("_setUsesAutomaticContentInsetBackgroundFill:")
            if web.responds(to: selector) {
                typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
                unsafeBitCast(web.method(for: selector), to: Setter.self)(web, selector, true)
            }
        }
        print("web added")

        sidebar.material = .sidebar
        sidebar.blendingMode = .withinWindow
        sidebar.frame = NSRect(x: 0, y: 0, width: 220, height: 820)
        sidebar.autoresizingMask = [.height]
        root.addSubview(sidebar)
        print("sidebar added")

        let label = NSTextField(labelWithString: "Live replica? Scroll / watch moving colours at the edge")
        label.frame = NSRect(x: 12, y: 760, width: 200, height: 48)
        label.maximumNumberOfLines = 2
        sidebar.addSubview(label)

        let html = """
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        body { margin: 0; background: #111; color: white; font: 28px system-ui; }
        .edge { width: 220px; height: 100vh; animation: shift 1s steps(1) infinite; }
        @keyframes shift { 0% { background: #f00; } 50% { background: #00f; } }
        .row { height: 120px; background: linear-gradient(90deg, #fff, #333); }
        </style>
        <div class="edge"></div><div class="row">Scroll test</div><div class="row">More content</div>
        """
        web.loadHTMLString(html, baseURL: nil)
        print("page loading")
        window.makeKeyAndOrderFront(nil)
        print("window ordered")
        appActivate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    private func appActivate() { NSApp.activate(ignoringOtherApps: true) }
}
