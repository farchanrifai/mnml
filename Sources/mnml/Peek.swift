import SwiftUI
import WebKit

extension Browser {
    func peek(_ url: URL, from origin: Tab) {
        guard peekTab == nil else { return }
        let page = Tab(shy: origin.shy, configuration: Web.configuration(shy: origin.shy, space: spaceID, store: origin.store))
        prepare(page)
        page.go(to: url)
        presentPeek(page, from: origin)
    }

    func presentPeek(_ page: Tab, from origin: Tab) {
        closeFind()
        checkingPeek = false
        peekClosing = false
        peekOrigin = origin.id
        withAnimation(Motion.peek) { peekTab = page }
    }

    /// All dismissal paths share the same draft protection, including switching Spaces.
    func closePeek(then: (() -> Void)? = nil) {
        guard let page = peekTab else { then?(); return }
        guard !checkingPeek, !peekClosing else { return }
        checkingPeek = true
        page.unsaved(conservative: true) { [weak self, weak page] unsaved in
            guard let self, let page, self.peekTab === page else { return }
            self.checkingPeek = false
            let dismiss = {
                guard self.peekTab === page else { return }
                self.closeFind()
                // The native container closes the panel and backdrop together.
                self.peekDismissal = { [weak self, weak page] in
                    guard let self, let page, self.peekTab === page else { return }
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        self.peekTab = nil
                        self.peekClosing = false
                        self.peekOrigin = nil
                    }
                    page.close()
                    if let web = self.active?.built { web.window?.makeFirstResponder(web) }
                    then?()
                }
                self.peekClosing = true
            }
            if unsaved {
                Ask.sure("Close Preview?", detail: "This preview contains unsent form entries.", confirm: "Close Preview", then: dismiss)
            } else { dismiss() }
        }
    }

    func finishPeekClose(_ page: Tab) {
        guard peekTab === page, peekClosing else { return }
        let done = peekDismissal
        peekDismissal = nil
        done?()
    }

    func keepPeek() {
        guard let page = peekTab, !peekClosing else { return }
        closeFind()
        checkingPeek = false
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { peekTab = nil }
        peekOrigin = nil
        insert(page, at: placeForNew())
        select(page)
    }

    func splitPeek() {
        guard let page = peekTab, !peekClosing, let origin = tab(peekOrigin) else { return }
        let side: SplitSide = split(of: origin.id)?.right == origin.id ? .left : .right
        closeFind()
        checkingPeek = false
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { peekTab = nil }
        peekOrigin = nil
        makeSplit(page, beside: origin, on: side)
    }
}

struct PeekLayer: View {
    @ObservedObject var browser: Browser

    var body: some View {
        GeometryReader { _ in
            if let page = browser.peekTab {
                PeekSurface(browser: browser, tab: page)
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(browser.peekTab != nil)
    }
}

struct PeekBackdrop: View {
    @ObservedObject var browser: Browser
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder private var material: some View {
        if reduceTransparency {
            Palette.ground.opacity(0.9)
        } else if BackdropBlur.possible {
            BackdropBlur(radius: 6).overlay(Palette.ground.opacity(0.08))
        } else {
            Frosted(material: .popover, blending: .withinWindow)
        }
    }

    var body: some View {
        material
            .overlay(Color.black.opacity(0.04))
            .contentShape(Rectangle())
            .onTapGesture { browser.closePeek() }
            .accessibilityLabel("Dismiss preview")
    }
}

struct PeekPanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    @State private var address = ""
    @FocusState private var addressFocused: Bool

    private var displayedAddress: String {
        guard let url = tab.address, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "" }
        parts.user = nil
        parts.password = nil
        return parts.string ?? ""
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            .padding(10)
            Divider()
            Page(tab: tab)
                .overlay(alignment: .topTrailing) {
                    if browser.finding { FindBar(browser: browser) }
                }
        }
        .background(Palette.ground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.hairline, lineWidth: 1))
        .onAppear {
            address = displayedAddress
            DispatchQueue.main.async { tab.built?.window?.makeFirstResponder(tab.built) }
        }
        .onChange(of: tab.address) { _, url in if !addressFocused { address = displayedAddress } }
        .onChange(of: browser.peekAddressFocus) { _, _ in addressFocused = true }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button { tab.back() } label: { Image(systemName: "chevron.left") }
                .disabled(!tab.canGoBack).help("Back").accessibilityLabel("Back")
            Button { tab.forward() } label: { Image(systemName: "chevron.right") }
                .disabled(!tab.canGoForward).help("Forward").accessibilityLabel("Forward")
            Button { tab.reload() } label: { Image(systemName: "arrow.clockwise") }
                .help("Reload").accessibilityLabel("Reload")
            TextField("Address", text: $address)
                .textFieldStyle(.roundedBorder)
                .focused($addressFocused)
                .onSubmit {
                    guard let url = browser.destination(for: address) else { return }
                    tab.go(to: url)
                    addressFocused = false
                    tab.built?.window?.makeFirstResponder(tab.built)
                }
                .accessibilityLabel("Preview address")
            Button { browser.keepPeek() } label: {
                Label("Open as Tab", systemImage: "arrow.up.right.square").labelStyle(.iconOnly)
            }.help("Open as Tab (⌘O)").accessibilityLabel("Open preview as tab")
            Button { browser.splitPeek() } label: {
                Label("Split", systemImage: "rectangle.split.2x1").labelStyle(.iconOnly)
            }.help("Split beside original page").accessibilityLabel("Split preview")
            Button { browser.closePeek() } label: { Image(systemName: "xmark") }
                .help("Close (Escape)").accessibilityLabel("Close preview")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Palette.ink)
    }
}

/// Animate the compositor's transform, keeping WebKit's viewport fixed.
private struct PeekSurface: NSViewRepresentable {
    @ObservedObject var browser: Browser
    let tab: Tab

    func makeNSView(context: Context) -> PeekSurfaceView {
        PeekSurfaceView(panel: PeekPanel(browser: browser, tab: tab))
    }

    func updateNSView(_ view: PeekSurfaceView, context: Context) {
        if browser.peekClosing { view.close { browser.finishPeekClose(tab) } }
    }
}

final class PeekSurfaceView: NSView {
    let host: NSHostingView<PeekPanel>
    let backdrop: NSHostingView<PeekBackdrop>
    private let panel = NSView()
    private var opened = false
    private var closing = false

    init(panel: PeekPanel) {
        host = NSHostingView(rootView: panel)
        backdrop = NSHostingView(rootView: PeekBackdrop(browser: panel.browser))
        super.init(frame: .zero)
        backdrop.safeAreaRegions = []
        wantsLayer = true
        host.wantsLayer = true
        self.panel.wantsLayer = true
        addSubview(backdrop)
        addSubview(self.panel)
        self.panel.addSubview(host)
        self.panel.layer?.shadowColor = NSColor.black.cgColor
        self.panel.layer?.shadowOpacity = 0.14
        self.panel.layer?.shadowRadius = 16
        self.panel.layer?.shadowOffset = CGSize(width: 0, height: -5)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        if backdrop.frame != bounds { backdrop.frame = bounds }
        let size = CGSize(width: max(0, min(bounds.width - 16, bounds.width * 0.88)),
                          height: max(0, min(bounds.height - 16, bounds.height * 0.86)))
        let frame = NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                           width: size.width, height: size.height)
        if panel.frame != frame {
            panel.frame = frame
            panel.layer?.shadowPath = CGPath(roundedRect: panel.bounds, cornerWidth: 10, cornerHeight: 10, transform: nil)
        }
        if host.frame != panel.bounds { host.frame = panel.bounds }
        guard !opened, window != nil, bounds.width > 0, bounds.height > 0 else { return }
        opened = true
        guard !Motion.reduced, let layer = panel.layer else { return }
        let pop = CABasicAnimation(keyPath: "sublayerTransform")
        pop.fromValue = NSValue(caTransform3D: smallTransform)
        pop.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        pop.duration = 0.18
        pop.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(pop, forKey: "peek.pop")
    }

    private var smallTransform: CATransform3D {
        var value = CATransform3DMakeTranslation(panel.bounds.midX, panel.bounds.midY, 0)
        value = CATransform3DScale(value, 0.96, 0.96, 1)
        return CATransform3DTranslate(value, -panel.bounds.midX, -panel.bounds.midY, 0)
    }

    func close(completion: @escaping () -> Void = {}) {
        guard !closing, let layer, let panelLayer = panel.layer else { return }
        closing = true
        let current = panelLayer.presentation()
        let shrink = CABasicAnimation(keyPath: "sublayerTransform")
        shrink.fromValue = NSValue(caTransform3D: current?.sublayerTransform ?? panelLayer.sublayerTransform)
        shrink.toValue = NSValue(caTransform3D: smallTransform)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.presentation()?.opacity ?? layer.opacity
        fade.toValue = 0.0
        let exit = CAAnimationGroup()
        exit.animations = [fade]
        exit.duration = Motion.reduced ? 0 : 0.14
        shrink.duration = exit.duration
        fade.duration = exit.duration
        exit.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { DispatchQueue.main.async { completion() } }
        let start = CACurrentMediaTime()
        exit.beginTime = layer.convertTime(start, from: nil)
        shrink.beginTime = panelLayer.convertTime(start, from: nil)
        shrink.timingFunction = exit.timingFunction
        layer.opacity = 0
        panelLayer.removeAnimation(forKey: "peek.pop")
        if !Motion.reduced {
            panelLayer.sublayerTransform = smallTransform
            panelLayer.add(shrink, forKey: "peek.shrink")
        }
        layer.add(exit, forKey: "peek.close")
        CATransaction.commit()
    }

}
