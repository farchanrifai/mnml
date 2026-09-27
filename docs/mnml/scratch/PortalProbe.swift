// The page's edge mirrored under the column with a portal of our own — the
// live-copy layer AppKit's NSBackgroundExtensionView uses inside, without
// that view: in mnml it drew its copy over the page instead of beside it.
//
//   swiftc -parse-as-library docs/mnml/scratch/PortalProbe.swift -o /tmp/pp && /tmp/pp [bare] [bands|youtube] [upright]
//
// `bare` leaves the column's material off. `bands` scrolls coloured bands
// 200 px a second. `upright` leaves the portal's geometry unflipped.

import AppKit
import WebKit

@main
struct PortalProbe {
    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let probe = Probe()
        app.delegate = probe
        app.run()
    }
}

final class Probe: NSObject, NSApplicationDelegate {
    static let column: CGFloat = 220
    static let reach: CGFloat = 48
    var window: NSWindow!
    let stage = NSView()
    let web = WKWebView(frame: .zero)
    let side = NSVisualEffectView()
    var portal: CALayer?

    func applicationDidFinishLaunching(_ note: Notification) {
        let args = CommandLine.arguments
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                          styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.center()
        let root = NSView()
        window.contentView = root

        stage.wantsLayer = true
        stage.frame = root.bounds
        stage.autoresizingMask = [.width, .height]
        root.addSubview(stage)
        web.autoresizingMask = [.width, .height]
        stage.addSubview(web)
        web.frame = NSRect(x: Self.column, y: 0, width: stage.bounds.width - Self.column, height: stage.bounds.height)

        if !args.contains("bare") {
            side.material = .sidebar
            side.blendingMode = .withinWindow
            side.frame = NSRect(x: 0, y: 0, width: Self.column, height: root.bounds.height)
            side.autoresizingMask = [.height]
            root.addSubview(side)
        }

        if args.contains("bands") {
            let colours = ["#f00", "#0f0", "#00f", "#ff0", "#0ff", "#f0f", "#fff", "#000", "#f80", "#08f"]
            web.loadHTMLString("<body style='margin:0'>" + colours.map { "<div style='height:200px;background:\($0)'></div>" }.joined() + "</body>", baseURL: nil)
            for step in 1...5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2 + Double(step)) { [unowned self] in
                    web.evaluateJavaScript("scrollTo(0, \(step * 200))")
                }
            }
        } else {
            web.load(URLRequest(url: URL(string: "https://www.youtube.com")!))
        }

        // After the web view has its layer.
        DispatchQueue.main.async { [unowned self] in mirror(upright: args.contains("upright")) }
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: web, queue: .main) { [unowned self] _ in place() }
        web.postsFrameChangedNotifications = true
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    private func mirror(upright: Bool) {
        guard let type = NSClassFromString("CAPortalLayer") as? CALayer.Type, let source = web.layer else { print("no portal"); return }
        let portal = type.init()
        portal.setValue(source, forKey: "sourceLayer")
        portal.setValue(false, forKey: "matchesPosition")
        portal.setValue(false, forKey: "matchesTransform")
        portal.setValue(false, forKey: "hidesSourceLayer")
        portal.isGeometryFlipped = !upright
        // In a layer-hosting view of its own, below the page, as AppKit
        // keeps its portal: a layer added to a view's own AppKit-managed
        // layer isn't sure to be drawn.
        // `backed`: a plain layer-backed view with top-down coordinates,
        // as AppKit's own extension container is, rather than a layer-hosting one.
        let host: NSView
        if CommandLine.arguments.contains("backed") {
            host = FlippedView(frame: stage.bounds)
            host.wantsLayer = true
        } else {
            host = NSView(frame: stage.bounds)
            host.layer = CALayer()
            host.layer?.isGeometryFlipped = !CommandLine.arguments.contains("hostup")
            host.wantsLayer = true
        }
        host.autoresizingMask = [.width, .height]
        stage.addSubview(host, positioned: CommandLine.arguments.contains("below") ? .below : .above, relativeTo: web)
        host.layer?.addSublayer(portal)
        self.portal = portal
        place()
    }

    /// The page's frame, mirrored about its left edge, faded out beyond
    /// `reach` from it.
    private func place() {
        guard let portal else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let page = web.frame
        // As AppKit's own extension sets its portal (read from its layers):
        // centred anchor, placed at the page's corner, mirrored and moved
        // by half the page. A portal draws its source from its own centre,
        // not its frame; placed like a plain layer, it painted the page
        // again over the page's top left.
        portal.bounds = CGRect(origin: .zero, size: page.size)
        portal.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        portal.position = CGPoint(x: page.minX, y: page.minY)
        var mirror = CATransform3DIdentity
        mirror.m11 = -1
        mirror.m41 = -page.width / 2
        mirror.m42 = page.height / 2
        portal.transform = mirror

        let fade = CAGradientLayer()
        fade.frame = portal.bounds
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        fade.colors = [NSColor.black.cgColor, NSColor.clear.cgColor]
        fade.locations = [0, NSNumber(value: Double(Self.reach / max(page.width, 1)))]
        portal.mask = CommandLine.arguments.contains("nomask") ? nil : fade
        CATransaction.commit()
        print("portal frame \(portal.frame)")
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
