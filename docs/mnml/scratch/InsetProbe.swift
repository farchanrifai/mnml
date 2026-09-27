// Step 1 of page-under-chrome.md: does WebKit keep a page clear of a strip
// it is told is covered, on the left as well as the top, and fill that strip
// with the page's edge colours?
//
// A bare window: a web view the full size of it, a see-through column on the
// left and a bar across the top, both over the page. Switches in the bar turn
// each part on and off; Measure asks the page how wide it thinks it is.
//
//   swiftc -parse-as-library docs/mnml/scratch/InsetProbe.swift -o /tmp/probe && /tmp/probe
//
// Everything WebKit is asked for is asked for by name, so it builds with any
// SDK; what the running WebKit doesn't answer is printed as "missing".

import AppKit
import WebKit

@main
struct InsetProbe {
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
    static let bar: CGFloat = 52

    var window: NSWindow!
    let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    let side = NSVisualEffectView()
    let top = NSVisualEffectView()
    let readout = NSTextField(labelWithString: "")

    var left = true, above = true, fill = true, within = true, adjusts = false

    let sites: [(String, String)] = [
        ("YouTube", "https://www.youtube.com"),
        ("Sheets", "https://docs.google.com/spreadsheets/"),
        ("Apple", "https://www.apple.com"),
        ("Wide", "data:text/html,<body style='margin:0;background:linear-gradient(90deg,%23c33,%2333c)'><div style='width:3000px;height:3000px;font:40px system-ui;color:white;padding:20px'>left edge → 3000 px wide</div></body>"),
    ]

    func applicationDidFinishLaunching(_ note: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.center()

        let content = NSView()
        window.contentView = content

        web.autoresizingMask = [.width, .height]
        content.addSubview(web)

        for view in [side, top] {
            view.material = .sidebar
            view.state = .followsWindowActiveState
            content.addSubview(view)
        }
        side.autoresizingMask = [.height]
        top.autoresizingMask = [.width, .minYMargin]

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10
        row.addArrangedSubview(toggle("Left inset", \.left))
        row.addArrangedSubview(toggle("Top inset", \.above))
        row.addArrangedSubview(toggle("Fill", \.fill))
        row.addArrangedSubview(toggle("Within window", \.within))
        row.addArrangedSubview(toggle("Auto-adjust", \.adjusts))
        for (index, site) in sites.enumerated() {
            let button = NSButton(title: site.0, target: self, action: #selector(go(_:)))
            button.tag = index
            row.addArrangedSubview(button)
        }
        row.addArrangedSubview(NSButton(title: "Measure", target: self, action: #selector(measure)))
        row.translatesAutoresizingMaskIntoConstraints = false
        top.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: top.leadingAnchor, constant: Self.column + 12),
            row.centerYAnchor.constraint(equalTo: top.centerYAnchor, constant: 6),
        ])

        readout.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        readout.maximumNumberOfLines = 0
        readout.frame = NSRect(x: 12, y: 12, width: Self.column - 24, height: 400)
        readout.autoresizingMask = [.maxYMargin]
        side.addSubview(readout)

        NotificationCenter.default.addObserver(self, selector: #selector(resized), name: NSWindow.didResizeNotification, object: window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        report("setObscuredContentInsets:", web.responds(to: NSSelectorFromString("setObscuredContentInsets:")))
        report("_setUsesAutomaticContentInsetBackgroundFill:", web.responds(to: NSSelectorFromString("_setUsesAutomaticContentInsetBackgroundFill:")))
        report("_setAutomaticallyAdjustsContentInsets:", web.responds(to: NSSelectorFromString("_setAutomaticallyAdjustsContentInsets:")))
        report("_setTopContentInset:", web.responds(to: NSSelectorFromString("_setTopContentInset:")))

        resized()
        // Scriptable without clicking: `probe <site index> [nofill] [behind] [noleft]`.
        let args = CommandLine.arguments
        fill = !args.contains("nofill"); within = !args.contains("behind"); left = !args.contains("noleft")
        apply()
        load(Int(args.dropFirst().first ?? "") ?? 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            if args.contains("scroll") { self.web.evaluateJavaScript("scrollTo(0, 500)") }
            self.measure()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.inspect() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    private func report(_ name: String, _ ok: Bool) {
        print("\(name) \(ok ? "present" : "missing")")
    }

    private func toggle(_ title: String, _ key: ReferenceWritableKeyPath<Probe, Bool>) -> NSButton {
        let box = NSButton(checkboxWithTitle: title, target: self, action: #selector(flipped(_:)))
        box.state = self[keyPath: key] ? .on : .off
        box.identifier = NSUserInterfaceItemIdentifier(title)
        return box
    }

    @objc private func flipped(_ box: NSButton) {
        let on = box.state == .on
        switch box.identifier?.rawValue {
        case "Left inset": left = on
        case "Top inset": above = on
        case "Fill": fill = on
        case "Within window": within = on
        case "Auto-adjust": adjusts = on
        default: break
        }
        apply()
    }

    @objc private func go(_ button: NSButton) { load(button.tag) }

    private func load(_ index: Int) {
        guard let url = URL(string: sites[index].1) else { return }
        web.load(URLRequest(url: url))
    }

    @objc private func resized() {
        guard let content = window.contentView else { return }
        let bounds = content.bounds
        web.frame = bounds
        side.frame = NSRect(x: 0, y: 0, width: Self.column, height: bounds.height)
        top.frame = NSRect(x: 0, y: bounds.height - Self.bar, width: bounds.width, height: Self.bar)
        apply()
    }

    private func apply() {
        let blending: NSVisualEffectView.BlendingMode = within ? .withinWindow : .behindWindow
        side.blendingMode = blending
        top.blendingMode = blending

        let adjust = NSSelectorFromString("_setAutomaticallyAdjustsContentInsets:")
        if web.responds(to: adjust) {
            typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(web.method(for: adjust), to: Setter.self)(web, adjust, adjusts)
        }

        let insets = NSEdgeInsets(top: above ? Self.bar : 0, left: left ? Self.column : 0, bottom: 0, right: 0)
        let set = NSSelectorFromString("setObscuredContentInsets:")
        if web.responds(to: set) {
            typealias Setter = @convention(c) (AnyObject, Selector, NSEdgeInsets) -> Void
            unsafeBitCast(web.method(for: set), to: Setter.self)(web, set, insets)
        }

        let fills = NSSelectorFromString("_setUsesAutomaticContentInsetBackgroundFill:")
        if web.responds(to: fills) {
            typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(web.method(for: fills), to: Setter.self)(web, fills, fill)
        }
        measure()
    }

    /// What WebKit's fill is working from: the colours it sampled from fixed
    /// content at each edge, whether it shows an extension view there, and
    /// the views it has put inside the web view.
    private func inspect() {
        for name in ["_sampledTopFixedPositionContentColor", "_sampledLeftFixedPositionContentColor",
                     "_sampledPageTopColor", "_fixedContainerEdges", "_containerForFixedColorExtension",
                     "_topScrollPocket", "underPageBackgroundColor"] {
            let sel = NSSelectorFromString(name)
            guard web.responds(to: sel), let m = class_getInstanceMethod(WKWebView.self, sel) else { print(name, "missing"); continue }
            let type = String(cString: method_copyReturnType(m))
            print(name, type == "@" ? String(describing: web.perform(sel)?.takeUnretainedValue()) : "(type \(type))")
        }
        func dump(_ v: NSView, _ depth: Int) {
            guard depth < 4 else { return }
            let colour = v.layer?.backgroundColor.map { NSColor(cgColor: $0)?.description ?? "?" } ?? "-"
            print(String(repeating: "  ", count: depth) + "\(type(of: v)) \(v.frame) hidden=\(v.isHidden) alpha=\(v.alphaValue) layerBg=\(colour)")
            v.subviews.forEach { dump($0, depth + 1) }
        }
        dump(web, 0)
    }

    /// What the page thinks: how wide its viewport is (it should be the
    /// window less the column when the left inset holds), and what sits at
    /// its own left edge, just inside the column.
    @objc private func measure() {
        let script = """
        JSON.stringify({
          inner: innerWidth, client: document.documentElement.clientWidth,
          innerH: innerHeight, scrollX: scrollX,
          atLeft: (document.elementFromPoint(4, 120) || {}).tagName || null
        })
        """
        web.evaluateJavaScript(script) { [weak self] result, _ in
            guard let self else { return }
            let window = Int(self.web.bounds.width)
            let line = "web view \(window) pt wide\ninsets L\(self.left ? Int(Self.column) : 0) T\(self.above ? Int(Self.bar) : 0)\nfill \(self.fill) within \(self.within)\n\(result as? String ?? "no page yet")"
            print(line.replacingOccurrences(of: "\n", with: " | "))
            self.readout.stringValue = line
        }
    }
}
