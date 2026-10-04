import AppKit
import SwiftUI

// The traffic lights, where a Mac app with a toolbar has them — set in from the
// corner and centred in the strip's height — without the toolbar.
//
// An empty toolbar is the public way to move them, and it was how this window
// did it. On macOS 26 a toolbar also rounds the window's corners almost twice
// as much: 31.5 points against 17.5 for a window without one, measured, and
// 17.5 is what Claude's window and the Finder have. So the window has no
// toolbar, and the three buttons are put where one would have put them, by
// hand — which is how Claude's own window does it. AppKit lays its title bar
// out again whenever it sees fit (a resize, full screen, the window becoming
// key), so every time it does, the buttons are put back.

@MainActor
final class Lights: NSObject {
    /// Where the close button's centre goes, from the window's top-left: where
    /// a unified toolbar put it, which Metrics.lights and sideLights are
    /// measured from.
    static let centre = CGPoint(x: 26, y: 26)

    private static var kept: [ObjectIdentifier: Lights] = [:]

    /// Starts looking after a window's lights, once. `moved` hears each time
    /// they have been put in place.
    static func keep(_ window: NSWindow, centreX: @escaping () -> CGFloat, moved: @escaping () -> Void) {
        guard kept[ObjectIdentifier(window)] == nil else { return }
        kept[ObjectIdentifier(window)] = Lights(window, centreX: centreX, moved: moved)
    }

    static func refresh(_ window: NSWindow?) {
        guard let window else { return }
        kept[ObjectIdentifier(window)]?.place()
    }

    /// A retired window no longer needs placement callbacks. In particular,
    /// `moved` belongs to its SwiftUI view and must not keep that view alive.
    static func forget(_ window: NSWindow) {
        guard let lights = kept.removeValue(forKey: ObjectIdentifier(window)) else { return }
        NotificationCenter.default.removeObserver(lights)
    }

    private weak var window: NSWindow?
    private let moved: () -> Void
    private let centreX: () -> CGFloat
    private var placing = false
    /// AppKit's own spacing between the three, read once from its first
    /// layout and kept. Read again on every pass, it was caught while AppKit
    /// was halfway through putting them back after a resize — one button
    /// moved, the next not yet — and the three closed up from 23 points apart
    /// to 13, on top of each other, a spacing each later pass then copied
    /// from the one before. Reproduced with ./bench resize, 23 Sep 2026.
    private let spacing: CGFloat

    private init(_ window: NSWindow, centreX: @escaping () -> CGFloat, moved: @escaping () -> Void) {
        self.window = window
        self.centreX = centreX
        self.moved = moved
        let row = [NSWindow.ButtonType.closeButton, .miniaturizeButton].compactMap { window.standardWindowButton($0) }
        let measured = row.count == 2 ? row[1].frame.minX - row[0].frame.minX : 0
        spacing = (16...32).contains(measured) ? measured : 20
        super.init()
        let centre = NotificationCenter.default
        for name in [
            NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.didExitFullScreenNotification, NSWindow.didChangeScreenNotification,
        ] {
            centre.addObserver(self, selector: #selector(place), name: name, object: window)
        }
        // The title bar's own views moving is the surest sign AppKit has just
        // laid them out again.
        let buttons = self.buttons
        if let bar = buttons.first?.superview, let container = bar.superview {
            for view in [container, bar] + buttons {
                view.postsFrameChangedNotifications = true
                centre.addObserver(self, selector: #selector(place), name: NSView.frameDidChangeNotification, object: view)
            }
        }
        place()
    }

    private var buttons: [NSButton] {
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window?.standardWindowButton($0) }
    }

    @objc private func place() {
        // Full screen keeps its title bar in a window of its own, laid out by
        // macOS; it is left to it.
        guard !placing, let window, !window.styleMask.contains(.fullScreen) else { return }
        let buttons = self.buttons
        guard buttons.count == 3, let bar = buttons[0].superview, let container = bar.superview else { return }
        placing = true
        defer { placing = false }

        // A title bar as tall as the strip, so the buttons can sit lower in it.
        let height = Metrics.strip
        var frame = container.frame
        if frame.height != height || frame.maxY != window.frame.height {
            frame.size.height = height
            frame.origin.y = window.frame.height - height
            container.frame = frame
        }
        // Only the row moves; the spacing is AppKit's, from its first layout.
        for (index, button) in buttons.enumerated() {
            let size = button.frame.size
            let origin = NSPoint(
                x: centreX() - size.width / 2 + CGFloat(index) * spacing,
                y: bar.bounds.height - Lights.centre.y - size.height / 2
            )
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
        }
        moved()
    }
}

/// Full screen, as Safari has it. macOS keeps a window's title bar in a
/// strip of its own at the top of the screen then, sliding it down when the
/// pointer reaches the menu bar — a grey bar with the traffic lights on it,
/// over the tabs. Here that strip is never seen: its contents are hidden and
/// it lets clicks through, and it is only watched, so that as it comes the
/// the app's native buttons (TrafficLights) slide into the tabs' row, which makes
/// room for them (Browser.lightsOut).
@MainActor
final class FullScreenLights: NSObject {
    private static var kept: [ObjectIdentifier: FullScreenLights] = [:]

    static func keep(_ window: NSWindow, browser: Browser) {
        let key = ObjectIdentifier(window)
        guard kept[key] == nil else { return }
        kept[key] = FullScreenLights(window, browser: browser)
    }

    static func forget(_ window: NSWindow) {
        guard let lights = kept.removeValue(forKey: ObjectIdentifier(window)) else { return }
        NotificationCenter.default.removeObserver(lights)
        lights.hide(false)
    }

    private weak var window: NSWindow?
    private weak var browser: Browser?
    private weak var container: NSView?
    /// macOS's title bar in full screen, found as full screen begins.
    private weak var bar: NSView?

    private init(_ window: NSWindow, browser: Browser) {
        self.window = window
        self.browser = browser
        super.init()
        let centre = NotificationCenter.default
        centre.addObserver(self, selector: #selector(entered), name: NSWindow.didEnterFullScreenNotification, object: window)
        centre.addObserver(self, selector: #selector(leaving), name: NSWindow.willExitFullScreenNotification, object: window)
    }

    @objc private func entered() {
        bar = window?.standardWindowButton(.closeButton)?.superview
        guard let bar, let holder = bar.superview else { return }
        browser?.fullScreen = true
        hide(true)
        container = holder
        holder.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(moved), name: NSView.frameDidChangeNotification, object: holder)
        moved()
    }

    @objc private func leaving() {
        if let container {
            NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: container)
        }
        hide(false)
        container = nil
        withAnimation(Motion.settle) {
            browser?.lightsOut = false
            browser?.fullScreen = false
        }
    }

    /// Everything in the strip, not just the bar — beside it is the
    /// decoration that draws an edge and a shadow over the tabs — and the
    /// strip itself: unseen, shadowless, and clicks going through it. Hidden,
    /// it is still laid out and still moves, which is all that is read.
    private func hide(_ off: Bool) {
        guard let strip = bar?.window, strip !== window else { return }
        bar?.isHidden = off
        strip.contentView?.isHidden = off
        strip.alphaValue = off ? 0 : 1
        strip.ignoresMouseEvents = off
        strip.hasShadow = !off
        strip.invalidateShadow()
    }

    /// The hidden strip moves down with the menu bar and back up: the lights
    /// are out while any of it would show. macOS gives the strip its shadow
    /// back as it slides it down; that goes again, every time.
    @objc private func moved() {
        guard let container else { return }
        hide(true)
        let out = container.frame.maxY > 4
        guard out != browser?.lightsOut else { return }
        withAnimation(Motion.settle) { browser?.lightsOut = out }
    }
}

/// AppKit's standard buttons in the full-screen row. The system supplies
/// their appearance, hover treatment and accessibility labels.
struct TrafficLights: NSViewRepresentable {
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        CGSize(width: 54, height: 14)
    }

    func makeNSView(context: Context) -> NSView {
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 54, height: 14))
        for (index, kind) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let button = NSWindow.standardWindowButton(kind, for: [.titled, .resizable, .fullScreen]) else { continue }
            button.setFrameOrigin(NSPoint(x: CGFloat(index) * 20, y: 0))
            button.action = [#selector(NSWindow.performClose(_:)), #selector(NSWindow.miniaturize(_:)), #selector(NSWindow.toggleFullScreen(_:))][index]
            button.isEnabled = kind != .miniaturizeButton
            row.addSubview(button)
        }
        return row
    }

    func updateNSView(_ row: NSView, context: Context) {
        for button in row.subviews.compactMap({ $0 as? NSButton }) {
            button.target = Links.window
        }
    }
}
