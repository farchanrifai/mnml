import AppKit
import SwiftUI
import WebKit

// The page under the column and the strip, as Safari 26 has it. Under the
// column, the page sits beside it and SwiftUI's background extension fills
// the column's strip from the page's edge (Bleed, in Stage.swift). Under the
// strip across the top, WebKit is told how much is covered: it starts the
// page below it and lets it scroll up beneath, where Liquid Glass (TopGlass)
// blurs it. See docs/mnml/page-under-chrome.md.
//
// Off unless asked for (Settings › Tabs). Off, or on a Mac whose WebKit
// can't be told, the page sits beside the chrome as it always has.

enum Under {
    private static let insetsSetter = NSSelectorFromString("setObscuredContentInsets:")
    private static let insetsGetter = NSSelectorFromString("obscuredContentInsets")
    private static let fill = NSSelectorFromString("_setUsesAutomaticContentInsetBackgroundFill:")

    /// This WebKit can keep a page clear of a covered strip: macOS 26 and
    /// on. Asked by name, so mnml builds with an SDK that doesn't know it.
    static let possible = WKWebView.instancesRespond(to: insetsSetter)
        && WKWebView.instancesRespond(to: insetsGetter)

    /// Tells a page how much of it is covered, and to fill that much with
    /// its own edge colours. Only when it changes: every new value lays the
    /// page out again.
    static func cover(_ web: WKWebView, _ insets: NSEdgeInsets) {
        guard possible, !same(covered(web), insets) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, NSEdgeInsets) -> Void
        unsafeBitCast(web.method(for: insetsSetter), to: Setter.self)(web, insetsSetter, insets)
        // WebKit's fill off: it paints the covered strip one flat colour
        // over the page scrolling up beneath, where the glass is meant to
        // blur the page itself.
        if web.responds(to: fill) {
            typealias Fill = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(web.method(for: fill), to: Fill.self)(web, fill, false)
        }
    }

    /// How much of a page is covered: none, unless it has been told.
    static func covered(_ page: NSView) -> NSEdgeInsets {
        guard possible, let web = page as? WKWebView else { return NSEdgeInsets() }
        typealias Getter = @convention(c) (AnyObject, Selector) -> NSEdgeInsets
        return unsafeBitCast(web.method(for: insetsGetter), to: Getter.self)(web, insetsGetter)
    }

    /// A page leaving for somewhere nothing covers it — the floating window.
    /// Says how much was covered, so the page can keep the width it had.
    @discardableResult
    static func clear(_ page: NSView) -> NSEdgeInsets {
        let was = covered(page)
        if let web = page as? WKWebView { cover(web, NSEdgeInsets()) }
        return was
    }

    /// Over the page, the chrome's material blurs the page; the desktop
    /// behind the window is what it blurs otherwise. For trying the two side
    /// by side, a test build can be told to keep the desktop:
    ///   defaults write com.farchan.mnml.test under.behindWindow -bool YES
    static var blending: NSVisualEffectView.BlendingMode {
        Store.settings.bool(forKey: "under.behindWindow") ? .behindWindow : .withinWindow
    }

    private static func same(_ a: NSEdgeInsets, _ b: NSEdgeInsets) -> Bool {
        a.top == b.top && a.left == b.left && a.bottom == b.bottom && a.right == b.right
    }
}

extension Browser {
    /// The page runs under the column and the strip right now. Only with
    /// the see-through material — under a flat colour there'd be nothing to
    /// see — and not for a split, whose pages sit on cards with a margin of
    /// their own and never meet the chrome's edge.
    var pageUnder: Bool {
        prefs.pageUnder && prefs.frostedSidebar && Under.possible
            && shownSplit == nil && splitPicking == nil
    }
}

/// The chrome across the top when the page runs beneath it: the page, blurred
/// as it scrolls under, and tinted with the window's ground so the page's
/// colour comes through rather than its detail.
///
/// Core Animation's backdrop layer, blurred, which is what the Mac's window
/// materials are made of. Those materials don't see a web view there (flat
/// grey), nor does SwiftUI's glass (the page left sharp behind the tabs'
/// titles), and AppKit's Liquid Glass does but only softens it. Private, so
/// asked for by name; where it isn't, Liquid Glass.
struct TopGlass: View {
    // ponytail: tuned by eye on Wikipedia and Google results; adjust by feel.
    static let radius: Double = 20
    static let tint: Double = 0.9

    var body: some View {
        if BackdropBlur.possible {
            BackdropBlur(radius: Self.radius).overlay(Palette.ground.opacity(Self.tint))
        } else if #available(macOS 26, *) {
            Glass(tint: Palette.NS.ground.withAlphaComponent(Self.tint))
        } else {
            Frosted(blending: Under.blending)
        }
    }
}

/// Whatever lies behind, blurred: Core Animation's backdrop layer, as the
/// Mac's window materials are made of, at a radius of our own. Private, so
/// asked for by name — check `possible` first.
struct BackdropBlur: NSViewRepresentable {
    let radius: Double

    static let possible = NSClassFromString("CABackdropLayer") is CALayer.Type
        && (NSClassFromString("CAFilter") as? NSObject.Type)?.responds(to: NSSelectorFromString("filterWithType:")) == true

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        guard let backdrop = (NSClassFromString("CABackdropLayer") as? CALayer.Type)?.init(),
              let filters = NSClassFromString("CAFilter") as? NSObject.Type,
              let blur = filters.perform(NSSelectorFromString("filterWithType:"), with: "gaussianBlur")?
                .takeUnretainedValue() as? NSObject
        else { return view }
        blur.setValue(radius, forKey: "inputRadius")
        // The page's own colours at the bar's edges, not a fade to clear.
        blur.setValue(true, forKey: "inputNormalizeEdges")
        backdrop.filters = [blur]
        backdrop.setValue(true, forKey: "windowServerAware")
        backdrop.frame = view.bounds
        backdrop.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(backdrop)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

@available(macOS 26, *)
private struct Glass: NSViewRepresentable {
    let tint: NSColor

    func makeNSView(context: Context) -> NSGlassEffectView {
        let glass = NSGlassEffectView()
        glass.cornerRadius = 0
        return glass
    }

    func updateNSView(_ glass: NSGlassEffectView, context: Context) {
        glass.tintColor = tint
    }
}
