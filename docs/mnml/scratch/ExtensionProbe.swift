// Does AppKit's own background extension (NSBackgroundExtensionView, macOS 26)
// fill the strip under the column with the live page, mirrored and blurred?
//
// The web view is placed right of the column by hand
// (automaticallyPlacesContentView off), so nothing of the page is covered; the
// extension view fills the rest of its bounds from the page's edge.
//
//   swiftc -parse-as-library docs/mnml/scratch/ExtensionProbe.swift -o /tmp/ext && /tmp/ext [bare] [youtube]
//
// `bare` leaves the column's material off, to see the extension itself.
// `youtube` loads YouTube instead of the red/blue stripe.

import AppKit
import WebKit
import SwiftUI

@main
struct ExtensionProbe {
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
    var window: NSWindow!
    let web = WKWebView(frame: .zero)
    lazy var extended: NSBackgroundExtensionView = CommandLine.arguments.contains("flipped") ? FlippedExtension() : NSBackgroundExtensionView()
    let side = NSVisualEffectView()

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

        // `zero`: the extension starts with no size and gets it a moment
        // later, as a SwiftUI-hosted stage does.
        let zero = args.contains("zero")
        extended.frame = zero ? .zero : root.bounds
        extended.autoresizingMask = zero ? [] : [.width, .height]
        extended.automaticallyPlacesContentView = false
        extended.contentView = web
        if args.contains("swiftui") {
            // As mnml has it: the extension in a clipping, layer-backed view
            // that SwiftUI hosts.
            let holder = NSView()
            holder.wantsLayer = true
            holder.layer?.masksToBounds = true
            holder.addSubview(extended)
            let hosting = NSHostingView(rootView: Hosted(view: holder).ignoresSafeArea())
            hosting.frame = root.bounds
            hosting.autoresizingMask = [.width, .height]
            root.addSubview(hosting)
            holder.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: holder, queue: .main) { [unowned self] _ in
                self.extended.frame = holder.bounds
                self.web.frame = NSRect(x: Self.column, y: 0, width: holder.bounds.width - Self.column, height: holder.bounds.height)
            }
        } else {
            root.addSubview(extended)
        }
        web.frame = zero ? .zero : NSRect(x: Self.column, y: 0, width: root.bounds.width - Self.column, height: root.bounds.height)
        web.autoresizingMask = zero ? [] : [.width, .height]
        if zero {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [unowned self] in
                extended.frame = root.bounds
                web.frame = NSRect(x: Self.column, y: 0, width: root.bounds.width - Self.column, height: root.bounds.height)
            }
        }

        if !args.contains("bare") {
            side.material = .sidebar
            side.blendingMode = .withinWindow
            side.frame = NSRect(x: 0, y: 0, width: Self.column, height: root.bounds.height)
            side.autoresizingMask = [.height]
            root.addSubview(side)
        }

        if args.contains("bands") {
            // Bands 200 px tall, scrolled 200 px a second: the strip should
            // follow the page's colours down the bands, not climb them.
            let colours = ["#f00", "#0f0", "#00f", "#ff0", "#0ff", "#f0f", "#fff", "#000", "#f80", "#08f"]
            web.loadHTMLString("<body style='margin:0'>" + colours.map { "<div style='height:200px;background:\($0)'></div>" }.joined() + "</body>", baseURL: nil)
            for step in 1...5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2 + Double(step)) { [unowned self] in
                    web.evaluateJavaScript("scrollTo(0, \(step * 200))")
                    print("scrolled", step * 200)
                }
            }
        } else if args.contains("halves") {
            web.loadHTMLString("<body style='margin:0'><div style='height:50vh;background:#f00'></div><div style='height:50vh;background:#00f'></div>", baseURL: nil)
        } else if args.contains("youtube") {
            web.load(URLRequest(url: URL(string: "https://www.youtube.com")!))
        } else {
            web.loadHTMLString("""
            <style>body{margin:0;background:#111}
            .edge{width:220px;height:100vh;animation:s 1s steps(1) infinite}
            @keyframes s{0%{background:#f00}50%{background:#00f}}</style><div class="edge"></div>
            """, baseURL: nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // `resize`: the window grows after the page is in, as mnml's stage does.
        if args.contains("resize") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.window.setFrame(NSRect(x: 60, y: 60, width: 1500, height: 950), display: true)
            }
        }
        // `fixflip`: the portal in the same top-down geometry as its parent.
        if args.contains("fixflip") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [unowned self] in
                func find(_ l: CALayer) { if String(describing: type(of: l)) == "CAPortalLayer" { l.isGeometryFlipped = true; print("flipped portal") }; l.sublayers?.forEach(find) }
                extended.subviews.forEach { $0.layer.map(find) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.dump(self.extended, 0) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    private func walk(_ layer: CALayer, _ depth: Int) {
        guard depth < 7 else { return }
        var extra = ""
        if String(describing: type(of: layer)) == "CAPortalLayer" {
            for key in ["sourceLayer", "sourceLayerRenderId", "sourceContextId", "hidesSourceLayer", "matchesOpacity", "matchesPosition", "matchesTransform", "allowsBackdropGroups", "crossDisplay", "excludeSeparated", "allowedInContextTransform", "overrides", "sourceLayerOpacityScale"] {
                extra += " \(key)=\(layer.value(forKey: key).map { "\($0)" } ?? "nil")"
            }
            let t = layer.transform
            extra += " POS=\(layer.position) BOUNDS=\(layer.bounds) T=[\(t.m11) \(t.m12) \(t.m21) \(t.m22) | \(t.m41) \(t.m42) \(t.m43)] sublayerT=\(CATransform3DIsIdentity(layer.sublayerTransform)) contentsScale=\(layer.contentsScale)"
            extra += " webLayer=\(web.layer.map { "\(Unmanaged.passUnretained($0).toOpaque())" } ?? "-")"
        }
        print(String(repeating: "  ", count: depth) + "\(type(of: layer)) \(layer.name ?? "") t=[\(layer.transform.m11) \(layer.transform.m22) \(layer.transform.m41) \(layer.transform.m42)] anchor=\(layer.anchorPoint) frame=\(layer.frame) hidden=\(layer.isHidden) opacity=\(layer.opacity)\(extra) filters=\(layer.filters?.count ?? 0) superlayerFlipped=\(layer.superlayer?.isGeometryFlipped ?? false) flipped=\(layer.isGeometryFlipped)")
        layer.sublayers?.forEach { walk($0, depth + 1) }
    }

    private func dump(_ v: NSView, _ depth: Int) {
        if depth == 0 { v.subviews.filter { !($0 is WKWebView) }.forEach { if let l = $0.layer { walk(l, 1) } } }
        guard depth < 5, !(v is WKWebView) else { print(String(repeating: "  ", count: depth) + "WKWebView \(v.frame)"); return }
        print(String(repeating: "  ", count: depth) + "\(type(of: v)) \(v.frame) hidden=\(v.isHidden)")
        v.subviews.forEach { dump($0, depth + 1) }
    }
}

struct Hosted: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ view: NSView, context: Context) {}
}

/// `flipped`: the extension in the top-down coordinates SwiftUI's views use.
final class FlippedExtension: NSBackgroundExtensionView {
    override var isFlipped: Bool { true }
}
