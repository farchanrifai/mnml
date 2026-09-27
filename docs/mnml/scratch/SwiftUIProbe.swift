// mnml's shape in SwiftUI — a window whose page sits under an overlaid
// column — with SwiftUI's own background extension (.backgroundExtensionEffect,
// macOS 26) rather than AppKit's NSBackgroundExtensionView nested inside it.
//
//   swiftc -parse-as-library docs/mnml/scratch/SwiftUIProbe.swift -o /tmp/sui && /tmp/sui [bands|<url>] [toggle]
//
// `toggle` hides and shows the column every 1.5 s. Every 0.5 s a line says
// where the extension's copy of the page is.

import SwiftUI
import WebKit

@main
struct SwiftUIProbe: App {
    @NSApplicationDelegateAdaptor(Delegate.self) private var delegate

    // As mnml's: a SwiftUI Window scene with its title bar hidden.
    var body: some Scene {
        Window("SwiftUI Probe", id: "probe") {
            Probe()
                .frame(minWidth: 640, minHeight: 420)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
    }
}

/// Only so an app run from the command line comes forward with its window.
final class Delegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ note: Notification) {
        setvbuf(stdout, nil, _IOLBF, 0)
        NSApp.setActivationPolicy(.regular)
    }
    func applicationDidFinishLaunching(_ note: Notification) {
        if Opts.all.contains("dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct Probe: View {
    @State private var column = true
    static let width: CGFloat = 220

    var body: some View {
        ZStack(alignment: .leading) {
            Page()
                .backgroundExtensionEffect()
                // The covered strip, as safe area the extension fills.
                .safeAreaPadding(.leading, column ? Self.width : 0)
                .ignoresSafeArea(edges: .top)
            if column {
                Rectangle()
                    .fill(.clear)
                    .background(.ultraThinMaterial)
                    .overlay(alignment: .topLeading) { Text("Column").padding(.top, 60).padding(.leading, 16) }
                    .frame(width: Self.width)
                    .transition(.move(edge: .leading))
            }
        }
        .ignoresSafeArea()
        .onAppear {
            if Opts.all.contains("toggle") {
                var n = 0
                Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
                    n += 1
                    guard n <= 4 else { return }
                    withAnimation { column.toggle() }
                }
            }
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in Report.now() }
        }
    }
}

struct Page: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        // `play`: video starts without a click, as mnml lets it.
        let config = WKWebViewConfiguration()
        if Opts.all.contains("play") { config.mediaTypesRequiringUserActionForPlayback = [] }
        let web = WKWebView(frame: .zero, configuration: config)
        Report.web = web
        // `stage`: as mnml has it — a container the web view is put into a
        // moment after SwiftUI has laid it out, sized to it on every layout.
        guard !Opts.all.contains("stage") else {
            let stage = Stage()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { stage.hold(web) }
            load(web)
            return stage
        }
        load(web)
        return web
    }

    private func load(_ web: WKWebView) {
        let args = Opts.all
        if args.contains("bands") {
            let colours = ["#f00", "#0f0", "#00f", "#ff0", "#0ff", "#f0f", "#fff", "#000", "#f80", "#08f"]
            web.loadHTMLString("<body style='margin:0'>" + colours.map { "<div style='height:200px;background:\($0)'></div>" }.joined() + "</body>", baseURL: nil)
            for step in 1...5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2 + Double(step)) { web.evaluateJavaScript("scrollTo(0, \(step * 200))") }
            }
        } else {
            web.load(URLRequest(url: URL(string: args.first { $0.hasPrefix("http") } ?? "https://www.youtube.com")!))
        }
    }
    func updateNSView(_ view: NSView, context: Context) {}
}

final class Stage: NSView {
    func hold(_ web: WKWebView) {
        wantsLayer = true
        addSubview(web)
        web.frame = bounds
    }
    override func layout() {
        super.layout()
        subviews.first?.frame = bounds
    }
}

enum Report {
    static weak var web: WKWebView?
    static var last = ""

    static func now() {
        guard let web, let root = web.window?.contentView?.layer else { return }
        var portals: [String] = []
        func find(_ l: CALayer) {
            if String(describing: type(of: l)) == "CAPortalLayer" {
                if !Opts.all.contains("noflip"), !l.isGeometryFlipped { l.isGeometryFlipped = true }
                portals.append("\(l.frame.integral) id=\(CATransform3DIsIdentity(l.transform))")
            }
            l.sublayers?.forEach(find)
        }
        find(root)
        let line = "page \(web.frame.integral) in window \(web.convert(web.bounds, to: nil).integral) | portals \(portals)"
        if line != last { print(line); last = line }
    }
}

enum Opts {
    static let all = CommandLine.arguments + (ProcessInfo.processInfo.environment["PROBE"] ?? "").split(separator: " ").map(String.init)
}
