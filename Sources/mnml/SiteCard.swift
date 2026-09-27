import AppKit
import Combine
import SecurityInterface
import SwiftUI

// The site card: what a double-click on the tab you are on shows under its address,
// in the column and in the bar across the top alike — whether the connection
// is private, and the few things that belong to the page (copy its address,
// print it, its zoom). Right-click › Site Information… opens the same. It
// goes as soon as you type, when the address is left, or when one of its
// lines is used. From #56, whose bar it came with; the bar itself stayed out,
// since Search has the column or the strip, never a second row over the page.

/// The card's own small window, under the tab's address. It never takes the
/// keys: the address stays in the tab being edited, the caret where it was,
/// and a click on the card is only a click.
@MainActor
enum SiteCardPanel {
    private static var panel: Panel?
    private static var resign: Any?

    static var isShown: Bool { panel != nil }

    // MARK: - when

    /// The field the address is being edited in. SwiftUI can make it and
    /// throw it away several times as the edit begins, so the card follows
    /// the browser's edit rather than any one field, and stands under the one
    /// with the caret.
    private static weak var anchor: NSView?
    private static var watching: [ObjectIdentifier: AnyCancellable] = [:]
    /// The address as the edit began with it.
    private static var original: String?

    static func follow(_ browser: Browser, anchor field: NSView) {
        anchor = field
        let key = ObjectIdentifier(browser)
        guard watching[key] == nil else { return }
        watching[key] = browser.$editingTab.combineLatest(browser.$tabDraft)
            .receive(on: DispatchQueue.main)
            .sink { [weak browser] editing, draft in
                MainActor.assumeIsolated {
                    guard let browser else { return }
                    guard let id = editing, !browser.renamingTab,
                          let tab = browser.tabs.first(where: { $0.id == id }), !tab.isBlank
                    else { original = nil; hide(); return }
                    if original == nil {
                        // The edit began: the card comes up under the field once it
                        // is in its window.
                        original = draft
                        place(tab, browser, tries: 0)
                    } else if draft != original {
                        // Typing somewhere else: the card was about the page you are on.
                        hide()
                    }
                }
            }
    }

    private static func place(_ tab: Tab, _ browser: Browser, tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            guard original != nil, browser.editingTab == tab.id, browser.tabDraft == original else { return }
            // The field with the caret in it is the one on screen; failing
            // that, the latest one made.
            let focused = (Links.window?.firstResponder as? NSTextView)?.delegate as? NSTextField
            guard let field = focused ?? anchor, field.window != nil else {
                if tries < 15 { place(tab, browser, tries: tries + 1) }
                return
            }
            show(for: tab, in: browser, under: field)
        }
    }

    /// Under `field`, the tab's address, in `browser`'s window.
    private static func show(for tab: Tab, in browser: Browser, under field: NSView) {
        guard let window = field.window else { return }
        hide()
        let card = SiteCard(browser: browser, tab: tab) {
            SiteCardPanel.hide()
            browser.cancelTabEdit()
        }
        let host = FirstClick(rootView: AnyView(card.fixedSize()))
        let size = host.fittingSize
        let glass = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        glass.material = .menu
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = MenuMetrics.corner
        glass.layer?.cornerCurve = .continuous
        glass.layer?.masksToBounds = true
        glass.layer?.borderWidth = 0.5
        glass.layer?.borderColor = MenuMetrics.edge.cgColor
        host.frame = glass.bounds
        host.autoresizingMask = [.width, .height]
        glass.addSubview(host)

        let panel = Panel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = glass
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = true
        // Under the address, lined up with the tab's own edge.
        let spot = window.convertToScreen(field.convert(field.bounds, to: nil))
        var origin = NSPoint(x: spot.minX - 12, y: spot.minY - 12 - size.height)
        if let screen = window.screen?.visibleFrame {
            origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
            origin.y = max(origin.y, screen.minY + 8)
        }
        panel.setFrameOrigin(origin)
        window.addChildWindow(panel, ordered: .above)
        // Its height follows the card: one step in on the connection is taller.
        host.onResize = { [weak panel] fitted in
            guard let panel, fitted.height > 0 else { return }
            var frame = panel.frame
            frame.origin.y += frame.height - fitted.height
            frame.size = fitted
            panel.setFrame(frame, display: true)
        }
        self.panel = panel
        resign = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SiteCardPanel.hide() }
        }
    }

    // MARK: - the submenu

    private static var sub: Panel? {
        didSet { SubmenuState.shared.open = sub != nil }
    }

    /// A submenu beside the card, level with `row` (its frame in the card,
    /// top-left based) — opened by hovering, as a menu's is.
    static func showSub(_ content: AnyView, beside row: CGRect) {
        guard let panel, let window = panel.parent else { return }
        hideSub()
        let host = FirstClick(rootView: AnyView(content.fixedSize()))
        let size = host.fittingSize
        let glass = frosted(size)
        host.frame = glass.bounds
        host.autoresizingMask = [.width, .height]
        glass.addSubview(host)
        let made = Panel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        made.contentView = glass
        made.isOpaque = false
        made.backgroundColor = .clear
        made.hasShadow = true
        made.hidesOnDeactivate = true
        // Its first line level with the row, as macOS lines a submenu up.
        let top = panel.frame.maxY - row.minY + MenuMetrics.pad
        var origin = NSPoint(x: panel.frame.maxX - 4, y: top - size.height)
        if let screen = window.screen?.visibleFrame {
            if origin.x + size.width > screen.maxX - 8 { origin.x = panel.frame.minX - size.width + 4 }
            origin.y = max(origin.y, screen.minY + 8)
        }
        made.setFrameOrigin(origin)
        window.addChildWindow(made, ordered: .above)
        sub = made
    }

    static func hideSub() {
        guard let sub else { return }
        sub.parent?.removeChildWindow(sub)
        sub.orderOut(nil)
        self.sub = nil
    }

    /// The menu's frosted ground, with its corners and edge.
    private static func frosted(_ size: NSSize) -> NSVisualEffectView {
        let glass = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        glass.material = .menu
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = MenuMetrics.corner
        glass.layer?.cornerCurve = .continuous
        glass.layer?.masksToBounds = true
        glass.layer?.borderWidth = 0.5
        glass.layer?.borderColor = MenuMetrics.edge.cgColor
        return glass
    }

    static func hide() {
        hideSub()
        if let resign { NotificationCenter.default.removeObserver(resign) }
        resign = nil
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        self.panel = nil
    }

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    /// Takes the first click even though its window never becomes key, and
    /// says when what it shows changes size.
    private final class FirstClick: NSHostingView<AnyView> {
        var onResize: ((NSSize) -> Void)?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func invalidateIntrinsicContentSize() {
            super.invalidateIntrinsicContentSize()
            let fitted = fittingSize
            DispatchQueue.main.async { [weak self] in self?.onResize?(fitted) }
        }
    }
}

/// Whether the card's submenu is out, so the row it came from stays lit
/// while the pointer is in it, as a menu's does.
@MainActor
final class SubmenuState: ObservableObject {
    static let shared = SubmenuState()
    @Published var open = false
}

/// The site the tab is on: how private the connection is, and the few things
/// that belong to this page rather than to the browser. The connection's line
/// goes a step further in, to what it means and the certificate behind it.
struct SiteCard: View {
    let browser: Browser
    @ObservedObject var tab: Tab
    let close: () -> Void

    /// Whether this Mac trusts the site's certificate. Unknown until it has
    /// been asked, off the main thread: asking can go to the network.
    @State private var certified: Bool?

    init(browser: Browser, tab: Tab, deeper: Bool = false, close: @escaping () -> Void) {
        self.browser = browser
        self.tab = tab
        self.close = close
    }

    var body: some View {
        front
            .padding(.vertical, MenuMetrics.pad)
            .frame(minWidth: 180)
            .fixedSize()
            .onAppear(perform: certify)
    }

    /// The host as a person says it, without the www. A page with no host —
    /// a file, about:blank — is named by what it is.
    static func site(_ url: URL) -> String {
        if let host = url.host(), !host.isEmpty {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        if url.isFileURL { return "File" }
        return url.scheme ?? url.absoluteString
    }

    // MARK: - the card, drawn as the system draws a menu

    private var front: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let url = tab.address {
                Header(title: SiteCard.site(url))
            }
            // Hovered, the connection opens beside the card, as a submenu
            // does; every other line puts it away.
            if let safety {
                Row(safety.title, submenu: true, hovered: { over, frame in
                    guard over else { return }
                    SiteCardPanel.showSub(AnyView(security(safety).padding(.vertical, MenuMetrics.pad)), beside: frame)
                }) {}
            }
            Row("Rename Tab…", hovered: { over, _ in if over { SiteCardPanel.hideSub() } }) {
                after { browser.beginTabRename(tab) }
            }
            Row("Copy Address", keys: "⇧⌘C", hovered: { over, _ in if over { SiteCardPanel.hideSub() } }) {
                after { browser.copyAddress() }
            }
            Separator()
            Row("Print…", keys: "⌘P", hovered: { over, _ in if over { SiteCardPanel.hideSub() } }) {
                after { browser.printPage() }
            }
            zoom
            if let host = tab.address?.host(), !host.isEmpty {
                Separator()
                Permission(title: "Notifications", choice: .notifications, host: host)
                Permission(title: "Camera", choice: .camera, host: host)
                Permission(title: "Microphone", choice: .microphone, host: host)
            }
        }
    }

    /// What the site may do without asking: the answers the bars at the
    /// bottom of the window keep (Browser.answerCapture, Notify), seen and
    /// changed in one place. Ask forgets the answer, so the site asks again.
    private struct Permission: View {
        enum Choice { case notifications, camera, microphone }
        let title: String
        let choice: Choice
        let host: String

        @State private var answer: Bool?

        var body: some View {
            HStack(spacing: 0) {
                Text(title)
                    .font(MenuMetrics.font)
                    .foregroundStyle(Color(nsColor: .labelColor))
                Spacer(minLength: 24)
                Menu {
                    Button("Ask") { set(nil) }
                    Button("Allow") { set(true) }
                    Button("Block") { set(false) }
                } label: {
                    Text(answer == nil ? "Ask" : answer == true ? "Allow" : "Block")
                        .font(MenuMetrics.font)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.leading, MenuMetrics.text)
            .padding(.trailing, MenuMetrics.inset + 4)
            .frame(height: MenuMetrics.row)
            .onAppear { answer = Self.read(choice, host) }
        }

        /// The camera and the microphone are each asked for alone or both at
        /// once (WKMediaCaptureType 0, 1, 2), and each question kept apart.
        private static func keys(_ choice: Choice, _ host: String) -> [String] {
            switch choice {
            case .notifications: return [Notify.key(host)]
            case .camera: return ["capture.\(host)|0", "capture.\(host)|2"]
            case .microphone: return ["capture.\(host)|1", "capture.\(host)|2"]
            }
        }

        private static func read(_ choice: Choice, _ host: String) -> Bool? {
            keys(choice, host).lazy.compactMap { Store.settings.object(forKey: $0) as? Bool }.first
        }

        private func set(_ value: Bool?) {
            answer = value
            let keys = Self.keys(choice, host)
            // An answer given to both at once is the other's too: kept as its
            // own before the two part ways.
            if keys.count > 1, let both = Store.settings.object(forKey: keys[1]) as? Bool {
                let other: Choice = choice == .camera ? .microphone : .camera
                let alone = Self.keys(other, host)[0]
                if Store.settings.object(forKey: alone) == nil { Store.settings.set(both, forKey: alone) }
            }
            if let value { Store.settings.set(value, forKey: keys[0]) } else { Store.settings.removeObject(forKey: keys[0]) }
            // The both-at-once answer holds only while the two agree.
            guard keys.count > 1 else { return }
            let other: Choice = choice == .camera ? .microphone : .camera
            let otherAlone = Store.settings.object(forKey: Self.keys(other, host)[0]) as? Bool
            if let value, otherAlone == value { Store.settings.set(value, forKey: keys[1]) } else { Store.settings.removeObject(forKey: keys[1]) }
        }
    }

    /// The page's size, remembered for the site (see Tab.rememberZoom), as a
    /// menu puts a control on one of its lines: the name, and the steps at
    /// its end. The number puts it back to 100%.
    private var zoom: some View {
        HStack(spacing: 0) {
            Text("Zoom")
                .font(MenuMetrics.font)
                .foregroundStyle(Color(nsColor: .labelColor))
            Spacer(minLength: 24)
            Step(symbol: "minus", help: "Zoom Out   ⌘-") { browser.zoom(by: 1 / 1.1) }
            Button { browser.resetZoom() } label: {
                Text("\(Int((tab.zoom * 100).rounded()))%")
                    .font(MenuMetrics.font)
                    .monospacedDigit()
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .frame(width: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Actual Size   ⌘0")
            Step(symbol: "plus", help: "Zoom In   ⌘+") { browser.zoom(by: 1.1) }
        }
        .padding(.leading, MenuMetrics.text)
        .padding(.trailing, MenuMetrics.inset + 4)
        .frame(height: MenuMetrics.row)
    }

    // MARK: - one step in

    private func security(_ safety: Safety) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(safety.title)
                .font(MenuMetrics.font)
                .foregroundStyle(Color(nsColor: .labelColor))
                .padding(.leading, MenuMetrics.text)
                .frame(height: MenuMetrics.row, alignment: .leading)
            Text(safety.detail)
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 230, alignment: .leading)
                .padding(.leading, MenuMetrics.text)
                .padding(.trailing, MenuMetrics.trailing)
                .padding(.bottom, 6)
            Separator()
            if let trust = safety.trust {
                Row(certified == false ? "Show Certificate (Not Valid)…" : "Show Certificate…") {
                    after { SiteCard.show(trust) }
                }
            }
        }
    }

    // MARK: - the connection

    /// What there is to say about the connection, from a page's own address
    /// and what WebKit knows of how it came.
    private struct Safety {
        let symbol: String
        let title: String
        let detail: String
        let tint: Color
        /// The certificate the page came with, for an https page.
        let trust: SecTrust?
    }

    /// Asked when the card opens: a page that pulls in something over plain
    /// http after that is not worth a card that changes under you.
    private var safety: Safety? {
        switch tab.address?.scheme {
        case "https":
            let trust = tab.built?.serverTrust
            // Only a certificate this Mac refused and you let through anyway
            // (see Dialogs.trust) gets this far untrusted.
            if certified == false {
                return Safety(
                    symbol: "lock.open", title: "Connection is not secure",
                    detail: "This site's certificate isn't trusted by this Mac. Someone could be reading what you send.",
                    tint: Palette.unsafe, trust: trust
                )
            }
            if tab.built?.hasOnlySecureContent == false {
                return Safety(
                    symbol: "lock.trianglebadge.exclamationmark", title: "Parts of this page are not secure",
                    detail: "The page came privately, but some of what it shows was fetched over plain http, where anyone on the network could read or change it.",
                    tint: Palette.unsafe, trust: trust
                )
            }
            return Safety(
                symbol: "lock", title: "Connection is secure",
                detail: "Your information (for example, passwords or credit card numbers) is private when it is sent to this site.",
                tint: Palette.safe, trust: trust
            )
        case "http":
            return Safety(
                symbol: "lock.open", title: "Connection is not secure",
                detail: "Don't enter passwords or credit card numbers here: anything sent to this site can be read on the way.",
                tint: Palette.unsafe, trust: nil
            )
        default:
            return nil
        }
    }

    /// Asks whether this Mac trusts the certificate, the way it would for
    /// any app. Off the main thread: the answer can need a revocation check.
    private func certify() {
        guard certified == nil, let trust = tab.built?.serverTrust else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = SecTrustEvaluateWithError(trust, nil)
            DispatchQueue.main.async { certified = ok }
        }
    }

    /// The system's own certificate sheet, over the window.
    private static func show(_ trust: SecTrust) {
        guard let window = Links.window else { return }
        SFCertificatePanel.shared().beginSheet(
            for: window, modalDelegate: nil, didEnd: nil, contextInfo: nil, trust: trust, showGroup: false
        )
    }

    /// The card goes first, then the thing is done: a print panel or a sheet
    /// coming up under a popover still on its way out lands behind it.
    private func after(_ act: @escaping () -> Void) {
        close()
        DispatchQueue.main.async(execute: act)
    }

    /// One line, as a menu item draws it: its title in the menu's font where
    /// a menu puts its text, a key equivalent at the end, the accent colour
    /// behind it and white letters under the pointer. A line that opens more
    /// ends in the submenu's chevron.
    private struct Row: View {
        let title: String
        var keys = ""
        var submenu = false
        /// Told when the pointer comes and goes, with the row's frame in the
        /// card (top-left based), for a submenu to line up with.
        var hovered: ((Bool, CGRect) -> Void)?
        let act: () -> Void

        @State private var hovering = false
        @State private var frame: CGRect = .zero
        @ObservedObject private var submenuState = SubmenuState.shared

        /// Under the pointer, or the row whose submenu is out.
        private var lit: Bool { hovering || (submenu && submenuState.open) }

        init(_ title: String, keys: String = "", submenu: Bool = false,
             hovered: ((Bool, CGRect) -> Void)? = nil, act: @escaping () -> Void) {
            self.title = title
            self.keys = keys
            self.submenu = submenu
            self.hovered = hovered
            self.act = act
        }

        var body: some View {
            HStack(spacing: 0) {
                Text(title)
                    .font(MenuMetrics.font)
                    .foregroundStyle(lit ? Color.white : Color(nsColor: .labelColor))
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: keys.isEmpty ? 24 : 26)
                if !keys.isEmpty {
                    Text(keys)
                        .font(MenuMetrics.font)
                        .foregroundStyle(lit ? Color.white : Color(nsColor: .secondaryLabelColor))
                        .fixedSize()
                }
                if submenu {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(lit ? Color.white : Color(nsColor: .secondaryLabelColor))
                }
            }
            .padding(.leading, MenuMetrics.text - MenuMetrics.inset)
            .padding(.trailing, MenuMetrics.trailing - MenuMetrics.inset)
            .frame(height: MenuMetrics.row)
            .background(
                RoundedRectangle(cornerRadius: MenuMetrics.highlight, style: .continuous)
                    .fill(lit ? MenuMetrics.selection : .clear)
            )
            .padding(.horizontal, MenuMetrics.inset)
            .contentShape(Rectangle())
            .onTapGesture(perform: act)
            .background {
                GeometryReader { box in
                    Color.clear
                        .onAppear { frame = box.frame(in: .global) }
                        .onChange(of: box.frame(in: .global)) { _, new in frame = new }
                }
            }
            .onHover { over in
                hovering = over
                hovered?(over, frame)
            }
        }
    }

    /// The site's name over the lines, as a menu's section header is drawn.
    private struct Header: View {
        let title: String

        var body: some View {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .lineLimit(1)
                .padding(.leading, MenuMetrics.text)
                .padding(.trailing, MenuMetrics.trailing)
                .frame(height: MenuMetrics.row, alignment: .leading)
        }
    }

    /// A menu's separator: a hairline in its own band.
    private struct Separator: View {
        var body: some View {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
                .padding(.horizontal, MenuMetrics.rule)
                .frame(height: MenuMetrics.separator)
        }
    }

    /// A step of the zoom: the symbol alone, on the accent colour under the
    /// pointer as a menu's line would be.
    private struct Step: View {
        let symbol: String
        let help: String
        let act: () -> Void

        @State private var hovering = false

        var body: some View {
            Button(action: act) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(hovering ? Color.white : Color(nsColor: .labelColor))
                    .frame(width: 22, height: 18)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(hovering ? MenuMetrics.selection : .clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(help)
        }
    }
}

/// A menu's measurements, as macOS lays out an NSMenu (measured from one:
/// NSMenu.size with the same items), so the card sits beside the tab's
/// right-click menu as one of its own.
enum MenuMetrics {
    static let font = Font(NSFont.menuFont(ofSize: 0))
    /// One item.
    static let row: CGFloat = 24
    /// A separator's band.
    static let separator: CGFloat = 11
    /// Above the first item and under the last.
    static let pad: CGFloat = 5
    /// Where the highlight starts, from the menu's edge.
    static let inset: CGFloat = 5
    /// Where an item's text starts, from the menu's edge: a context menu
    /// without a checkmark column, as the tab's right-click is.
    static let text: CGFloat = 17
    /// From the end of the text, or of its key equivalent, to the menu's edge.
    static let trailing: CGFloat = 17
    /// A separator's line, in from either edge.
    static let rule: CGFloat = 16
    static let highlight: CGFloat = 6
    static let corner: CGFloat = 12
    /// The line under the pointer: the accent colour as a menu shows it over
    /// its glass, lighter than the accent itself (111, 162, 249 for blue).
    static let selection = Color(nsColor: NSColor(name: nil) { appearance in
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? accent.blended(withFraction: 0.15, of: .black) ?? accent
            : accent.blended(withFraction: 0.42, of: .white) ?? accent
    })
    /// The panel's hairline edge.
    static let edge = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.18) : NSColor.black.withAlphaComponent(0.26)
    }
}
