// The setup Apple documents for a page under a sidebar (WWDC25, "Build an
// AppKit app with the new design"): an NSSplitViewController with a sidebar
// item, the content item extended beneath it (automaticallyAdjustsSafeAreaInsets),
// and an NSBackgroundExtensionView placing the page in the safe area and
// filling the rest from the page's edge.
//
//   swiftc -parse-as-library docs/mnml/scratch/SplitProbe.swift -o /tmp/split && /tmp/split [bands|youtube] [toggle]
//
// `bands` scrolls coloured bands 200 px a second. `toggle` hides and shows the
// sidebar every 1.5 s, as mnml's column comes and goes.

import AppKit
import WebKit

@main
struct SplitProbe {
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
    var window: NSWindow!
    let split = NSSplitViewController()
    let web = WKWebView(frame: .zero)
    let extended = NSBackgroundExtensionView()
    var sidebarItem: NSSplitViewItem!
    var safeWatch: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ note: Notification) {
        let args = CommandLine.arguments

        let side = NSViewController()
        side.view = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 820))
        let label = NSTextField(labelWithString: "Sidebar")
        label.frame = NSRect(x: 16, y: 700, width: 180, height: 20)
        side.view.addSubview(label)
        sidebarItem = NSSplitViewItem(sidebarWithViewController: side)
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 220

        let content = NSViewController()
        extended.contentView = web
        if args.contains("under") {
            // `under`: the top as Safari has it — the page runs to the
            // window's top and scrolls beneath a see-through bar, rather
            // than the extension mirroring into a covered top strip.
            let holder = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 820))
            extended.frame = holder.bounds
            extended.autoresizingMask = [.width, .height]
            holder.addSubview(extended)
            let bar = NSVisualEffectView(frame: NSRect(x: 0, y: holder.bounds.height - Self.bar, width: holder.bounds.width, height: Self.bar))
            // `material=<name>` to compare; `opacity=<n>` for the bar's.
            let materials: [String: NSVisualEffectView.Material] = [
                "titlebar": .titlebar, "headerView": .headerView, "sidebar": .sidebar, "menu": .menu,
                "popover": .popover, "hudWindow": .hudWindow, "fullScreenUI": .fullScreenUI,
                "underWindowBackground": .underWindowBackground, "contentBackground": .contentBackground,
                "windowBackground": .windowBackground, "sheet": .sheet, "toolTip": .toolTip]
            let named = args.first { $0.hasPrefix("material=") }.map { String($0.dropFirst(9)) }
            bar.material = named.flatMap { materials[$0] } ?? .headerView
            bar.blendingMode = .withinWindow
            bar.autoresizingMask = [.width, .minYMargin]
            // A little more of the page through the bar than the material gives.
            // `clearbar`: no material, only what's written on the bar.
            if args.contains("clearbar") { bar.alphaValue = 0 }
            if !args.contains("clearbar") { bar.alphaValue = args.first { $0.hasPrefix("opacity=") }.flatMap { Double($0.dropFirst(8)) }.map { CGFloat($0) } ?? Self.barOpacity }
            let title = NSTextField(labelWithString: "Top bar")
            title.frame = NSRect(x: 240, y: 16, width: 200, height: 20)
            title.autoresizingMask = [.maxXMargin]
            bar.addSubview(title)
            holder.addSubview(bar)
            // `glass`: Liquid Glass (macOS 26) behind the bar instead of a material.
            if args.contains("glass") {
                bar.alphaValue = 0
                let glass = NSGlassEffectView(frame: bar.frame)
                glass.autoresizingMask = [.width, .minYMargin]
                glass.cornerRadius = 0
                if args.contains("clear") { glass.style = .clear }
                holder.addSubview(glass)
                title.removeFromSuperview()
                title.frame = NSRect(x: 240, y: holder.bounds.height - 36, width: 200, height: 20)
                title.autoresizingMask = [.maxXMargin, .minYMargin]
                holder.addSubview(title)
            }
            if args.contains("clearbar") {
                title.removeFromSuperview()
                title.frame = NSRect(x: 240, y: holder.bounds.height - 36, width: 200, height: 20)
                title.autoresizingMask = [.maxXMargin, .minYMargin]
                holder.addSubview(title)
            }
            content.view = holder
            topInset(Self.bar)
        } else {
            content.view = extended
        }
        let contentItem = NSSplitViewItem(viewController: content)
        contentItem.automaticallyAdjustsSafeAreaInsets = true

        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(contentItem)

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1280, height: 820))
        window.center()

        if args.contains("bands") {
            let colours = ["#f00", "#0f0", "#00f", "#ff0", "#0ff", "#f0f", "#fff", "#000", "#f80", "#08f"]
            web.loadHTMLString("<body style='margin:0'>" + colours.map { "<div style='height:200px;background:\($0)'></div>" }.joined() + "</body>", baseURL: nil)
            for step in 1...5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2 + Double(step)) { [unowned self] in
                    web.evaluateJavaScript("scrollTo(0, \(step * 200))")
                }
            }
        } else if args.contains("text") {
            // Text and a picture right up at the top, scrolled so they sit under the bar.
            web.load(URLRequest(url: URL(string: "https://en.wikipedia.org/wiki/Japan")!))
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [unowned self] in web.evaluateJavaScript("scrollTo(0, 420)") }
        } else {
            // Any address given, else YouTube.
            let address = args.first { $0.hasPrefix("http") } ?? "https://www.youtube.com"
            web.load(URLRequest(url: URL(string: address)!))
        }
        if args.contains("toggle") {
            var n = 0
            Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [unowned self] _ in
                n += 1
                guard n <= 4 else { return }
                sidebarItem.animator().isCollapsed.toggle()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [unowned self] in report("toggle \(n) collapsed=\(sidebarItem.isCollapsed)") }
            }
        }
        // The extension places the page by the safe area only when laid
        // out; the sidebar collapsing changes the safe area, not its size.
        if !CommandLine.arguments.contains("nowatch") {
            safeWatch = extended.observe(\.safeAreaInsets) { view, _ in
                DispatchQueue.main.async { view.needsLayout = true }
            }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [unowned self] in report("start") }
        // Kept flipped: the extension may build its portal again.
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [unowned self] _ in
            if !CommandLine.arguments.contains("noflip") { flipPortals() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    /// The portal's copy of a web view comes out upside down (it runs up
    /// the page as the page scrolls down); flipped, it follows.
    private func flipPortals() {
        func find(_ l: CALayer) {
            if String(describing: type(of: l)) == "CAPortalLayer", !l.isGeometryFlipped { l.isGeometryFlipped = true }
            l.sublayers?.forEach(find)
        }
        extended.subviews.forEach { $0.layer.map(find) }
        // The reflection a little fainter, so the sidebar reads as the sidebar.
        extended.subviews.filter { $0 !== web }.forEach { $0.layer?.opacity = Self.sideBleed }
    }

    static let bar: CGFloat = 52
    // ponytail: tuned by eye on Wikipedia and YouTube; adjust by feel.
    static let barOpacity: CGFloat = 0.92
    /// How strongly the page's reflection shows under the sidebar.
    static let sideBleed: Float = 0.7

    /// The window's own top safe area (its title bar) taken back out, so
    /// the extension leaves the top alone; WebKit told the bar's height,
    /// so the page starts below it and scrolls up beneath it.
    private func topInset(_ height: CGFloat) {
        let off = NSSelectorFromString("_setAutomaticallyAdjustsContentInsets:")
        if web.responds(to: off) {
            typealias Set = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(web.method(for: off), to: Set.self)(web, off, false)
        }
        // `pocket`: WebKit's own macOS 26 top edge — the public obscured
        // inset, under which WebKit keeps a scroll pocket with the page
        // blurred live — instead of the older top content inset.
        if CommandLine.arguments.contains("pocket") {
            web.obscuredContentInsets = NSEdgeInsets(top: height, left: 0, bottom: 0, right: 0)
        }
        let top = NSSelectorFromString("_setTopContentInset:")
        if !CommandLine.arguments.contains("pocket"), web.responds(to: top) {
            typealias Set = @convention(c) (AnyObject, Selector, CGFloat) -> Void
            unsafeBitCast(web.method(for: top), to: Set.self)(web, top, height)
        }
        DispatchQueue.main.async { [unowned self] in
            let inherited = extended.safeAreaInsets.top - extended.additionalSafeAreaInsets.top
            extended.additionalSafeAreaInsets = NSEdgeInsets(top: -inherited, left: 0, bottom: 0, right: 0)
        }
    }

    private func report(_ when: String) {
        if !CommandLine.arguments.contains("noflip") { flipPortals() }
        var portal = "none"
        func find(_ l: CALayer) {
            if String(describing: type(of: l)) == "CAPortalLayer" {
                portal = "frame=\(l.frame) identity=\(CATransform3DIsIdentity(l.transform)) flipped=\(l.isGeometryFlipped)"
            }
            l.sublayers?.forEach(find)
        }
        extended.subviews.forEach { $0.layer.map(find) }
        print("\(when): content \(extended.frame) safe L\(extended.safeAreaInsets.left) T\(extended.safeAreaInsets.top) page \(web.frame) portal \(portal)")
    }
}
