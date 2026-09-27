// WebKit's own blur under a top bar (macOS 26's scroll pocket): does
// registering the bar with -registerPocketContainer:onEdge: bring it out?
//
//   swiftc -parse-as-library docs/mnml/scratch/PocketProbe.swift -o /tmp/pk && /tmp/pk <edge 0-3> [hard]

import AppKit
import WebKit

@main
struct PocketProbe {
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
    let bar = NSView()

    func applicationDidFinishLaunching(_ note: Notification) {
        let args = CommandLine.arguments
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                          styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        let root = NSView()
        window.contentView = root
        web.frame = root.bounds
        web.autoresizingMask = [.width, .height]
        root.addSubview(web)
        bar.frame = NSRect(x: 0, y: root.bounds.height - 52, width: root.bounds.width, height: 52)
        bar.autoresizingMask = [.width, .minYMargin]
        root.addSubview(bar)
        web.obscuredContentInsets = NSEdgeInsets(top: 52, left: 0, bottom: 0, right: 0)
        if args.contains("hard") {
            let hard = NSSelectorFromString("_setPrefersSolidColorHardScrollPocket:")
            typealias SetB = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(web.method(for: hard), to: SetB.self)(web, hard, true)
        }
        if let edge = args.dropFirst().first.flatMap({ Int($0) }) {
            let register = NSSelectorFromString("registerPocketContainer:onEdge:")
            typealias Reg = @convention(c) (AnyObject, Selector, AnyObject, Int) -> Void
            unsafeBitCast(web.method(for: register), to: Reg.self)(web, register, bar, edge)
            print("registered on edge \(edge)")
        }
        web.load(URLRequest(url: URL(string: "https://en.wikipedia.org/wiki/Japan#Geography")!))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
