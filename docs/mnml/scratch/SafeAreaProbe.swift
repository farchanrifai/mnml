// Page under a covered strip, the strip changing while it runs — as mnml's
// column comes and goes, or swaps for the strip across the top. Two ways:
//
//   manual  the page's frame set by hand (automaticallyPlacesContentView off)
//   safe    the covered strip given as a safe area, the extension placing the page
//
//   swiftc -parse-as-library docs/mnml/scratch/SafeAreaProbe.swift -o /tmp/sa && /tmp/sa safe
//
// Every 1.5 s the cover changes: left 220 → top 52 → none → left 220 …,
// and a line says where the page and the extension's copy ended up.

import AppKit
import WebKit

@main
struct SafeAreaProbe {
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
    let web = WKWebView(frame: .zero)
    let extended = NSBackgroundExtensionView()
    let safe = CommandLine.arguments.contains("safe")
    let covers = [NSEdgeInsets(top: 0, left: 220, bottom: 0, right: 0),
                  NSEdgeInsets(top: 52, left: 0, bottom: 0, right: 0),
                  NSEdgeInsets(),
                  NSEdgeInsets(top: 0, left: 220, bottom: 0, right: 0)]
    var step = 0

    func applicationDidFinishLaunching(_ note: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                          styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.center()
        // `inlayout`: the page moved from inside the root's own layout pass,
        // as mnml's stage does. `later`: the same, then handed over again on
        // the next turn of the run loop.
        let root = LayingOut()
        root.probe = self
        window.contentView = root
        extended.frame = root.bounds
        extended.autoresizingMask = [.width, .height]
        extended.automaticallyPlacesContentView = safe
        extended.contentView = web
        root.addSubview(extended)
        // The page's own colours by column: a copy of it drawn over itself
        // shows as the wrong colour somewhere on the right.
        web.loadHTMLString("""
        <body style='margin:0;display:flex;height:100vh'>
        <div style='flex:1;background:#f00'></div><div style='flex:1;background:#0f0'></div>
        <div style='flex:1;background:#00f'></div><div style='flex:1;background:#ff0'></div></body>
        """, baseURL: nil)
        apply()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [unowned self] _ in
            step += 1
            if step < covers.count {
                if CommandLine.arguments.contains("inlayout") { window.contentView?.needsLayout = true } else { apply() }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    func apply() {
        let cover = covers[step]
        if safe {
            // The window's own safe area (its titlebar) taken back out, so
            // only the chrome's strip counts.
            let inherited = extended.safeAreaInsets
            let extra = extended.additionalSafeAreaInsets
            extended.additionalSafeAreaInsets = NSEdgeInsets(
                top: cover.top - (inherited.top - extra.top), left: cover.left - (inherited.left - extra.left),
                bottom: 0, right: 0)
        } else {
            let b = extended.bounds
            let place = NSRect(x: cover.left, y: 0, width: b.width - cover.left, height: b.height - cover.top)
            web.frame = place
            if CommandLine.arguments.contains("later") {
                DispatchQueue.main.async { [unowned self] in
                    extended.contentView = nil
                    extended.contentView = web
                    web.frame = place
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [unowned self] in
            var portal = "-"
            func find(_ l: CALayer) { if String(describing: type(of: l)) == "CAPortalLayer" { portal = "\(l.frame)" }; l.sublayers?.forEach(find) }
            extended.subviews.forEach { $0.layer.map(find) }
            print("step \(step) cover L\(Int(cover.left)) T\(Int(cover.top)) | safe \(extended.safeAreaInsets.left),\(extended.safeAreaInsets.top) | page \(web.frame) | portal \(portal)")
        }
    }
}

final class LayingOut: NSView {
    weak var probe: Probe?
    private var last = -1
    override func layout() {
        super.layout()
        guard let probe, probe.step != last else { return }
        last = probe.step
        probe.apply()
    }
}
