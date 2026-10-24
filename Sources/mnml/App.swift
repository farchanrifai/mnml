import SwiftUI
import AppKit
import os

// A window, a row of titles, and a field. Typing an address gets you a page;
// there is nothing else to learn and nothing else to press.

@main
struct MnmlApp: App {
    @StateObject private var front = Front.shared
    /// Links from other apps, and the Dock icon.
    @NSApplicationDelegateAdaptor(Links.self) private var links

    /// What the menus act on: the window in front's browser.
    private var browser: Browser { front.browser ?? SceneSlot.shared.browser }

    init() {
        // Settings › General › Start with a fresh window: the files are cut
        // down before any window reads its row from them.
        if Store.settings.bool(forKey: Preferences.freshKey) {
            Session.startFresh(spaces: Spaces.read().map(\.id))
            Browsers.startFresh()
        }
    }

    var body: some Scene {
        // Where you left it, at the size you left it. SwiftUI saves a
        // window's frame under its id and puts it back before the window
        // first shows; set by hand once the window was up, it showed at the
        // default size first and then jumped (upstream #202). The id is the
        // name the frame has always been kept under. A test run keeps its own:
        // the name lives in the app's standard defaults, which every copy
        // shares, and a probe resized for a test once changed the size the
        // real window came back at. The other windows' frames are in
        // windows.json (see Windows.swift).
        Window("mnml", id: Browsers.sceneID) {
            SceneRoot(slot: SceneSlot.shared)
                .frame(minWidth: 640, minHeight: 420)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(after: .appInfo) {
                if Updater.feed != nil { UpdateMenuItem() }
            }
            CommandGroup(replacing: .newItem) {
                item("file.newWindow")
                item("file.newTab")
                item("file.newPrivateTab")
                item("file.reopen")
                    .disabled(browser.ghosts.isEmpty && Browsers.lastClosedAt == nil)
                Divider()
                item("file.openAddress")
                item("file.openPeek")
                    .disabled(browser.peekTab == nil)
                Divider()
                item("file.import")
                Divider()
                item("file.closeTab")
                item("file.closeWindow")
            }
            CommandGroup(replacing: .printItem) {
                Button("Share…") { browser.share() }
                    .disabled(browser.active?.isBlank ?? true)
                item("file.exportPDF")
                    .disabled(browser.active?.isBlank ?? true)
                item("file.print")
                    .disabled(browser.active?.isBlank ?? true)
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                item("edit.find")
                    .disabled(browser.active?.isBlank ?? true)
                item("edit.findNext")
                    .disabled(!browser.finding)
                item("edit.findPrevious")
                    .disabled(!browser.finding)
                Divider()
                // As in Safari: each follows the Mac until switched here
                // (see Substitutions.swift).
                Menu("Substitutions") {
                    Button("Show Substitutions") { Substitution.showPanel() }
                    Divider()
                    ForEach(Substitution.allCases, id: \.self) { kind in
                        Toggle(kind.title, isOn: Binding(
                            get: { browser.substitutes(kind) },
                            set: { _ in browser.toggleSubstitution(kind) }
                        ))
                    }
                }
            }
            CommandGroup(replacing: .toolbar) {
                Toggle("Show Tabs in Sidebar", isOn: Binding(
                    get: { browser.prefs.sidebar },
                    set: { _ in browser.toggleSidebar() }
                ))
                .keyboardShortcut(key("view.sidebar"))
                // Folded away, not moved (see Fold.swift) — the column, or the
                // strip across the top.
                Button(browser.prefs.sidebar
                       ? (browser.folded ? "Show Sidebar" : "Hide Sidebar")
                       : (browser.folded ? "Show Tab Bar" : "Hide Tab Bar")) { browser.run("view.fold") }
                    .keyboardShortcut(key("view.fold"))
                Picker("Tabs Wear", selection: Binding(
                    get: { browser.prefs.glyph },
                    set: { browser.prefs.glyph = $0 }
                )) {
                    ForEach(Glyph.allCases) { glyph in
                        Text(glyph.title).tag(glyph)
                    }
                }
                Divider()
                item("view.ask")
                item("view.askNew")
                item("view.reload")
                item("view.reloadOrigin")
                item("view.reader")
                item("view.float")
                Divider()
                item("view.hide")
                item("view.hidden")
                Divider()
                item("view.zoomIn")
                item("view.zoomOut")
                item("view.actualSize")
                Divider()
                // The Web Inspector, on the keys Chrome and Arc use (see Inspector.swift).
                item("view.inspector")
                item("view.console")
                item("view.inspect")
            }
            CommandMenu("Tabs") {
                item("tabs.back")
                    .disabled(browser.active?.canGoBack != true)
                item("tabs.forward")
                    .disabled(browser.active?.canGoForward != true)
                Divider()
                item("tabs.next")
                item("tabs.previous")
                item("tabs.search")
                Divider()
                if let tab = browser.active {
                    let rows = browser.prefs.showsPinRows
                    if tab.pin == nil {
                        item("tabs.pin")
                            .disabled(tab.isBlank)
                    } else {
                        item("tabs.letter")
                        item("tabs.unpin")
                    }
                }
                if browser.prefs.sidebar {
                    item("tabs.newInGroup")
                        .disabled(browser.active?.group == nil)
                    item("tabs.groupSelected")
                        .disabled(browser.active?.pin != nil && browser.chosen.isEmpty)
                    item("tabs.toggleGroup")
                        .disabled(browser.active?.group == nil)
                    Divider()
                }
                item("tabs.rename")
                    .disabled(browser.active == nil)
                item("tabs.duplicate")
                    .disabled(browser.active?.isBlank ?? true)
                item("tabs.copyAddress")
                    .disabled(browser.active?.isBlank ?? true)
                Button("Copy as Markdown Link") { browser.copyMarkdownLink() }
                    .disabled(browser.active?.isBlank ?? true)
                item("tabs.pasteAndGo")
                Divider()
                item("tabs.closeOthers")
                    .disabled(browser.tabs.count < 2)
                item("tabs.mute")
            }
            CommandMenu("Bookmarks") {
                item("bookmarks.add")
                    .disabled(browser.active?.isBlank ?? true)
                item("bookmarks.show")
                Toggle("Show Bookmarks Bar", isOn: Binding(
                    get: { browser.prefs.bookmarksBar },
                    set: { on in withAnimation(Motion.glide) { browser.prefs.bookmarksBar = on } }
                ))
                // The bookmarks themselves follow, put in by AppKit (see
                // BookmarkMenu in Bookmarks.swift).
            }
            CommandMenu("History") {
                Section("Recently Visited") {
                    ForEach(browser.recentlyVisited) { trace in
                        Button {
                            browser.open(trace.url, foreground: true)
                        } label: {
                            MenuLine(title: trace.title.isEmpty ? Address.withoutWWW(trace.address) : trace.title, url: trace.url)
                        }
                    }
                }
                if !browser.ghosts.isEmpty {
                    Section("Recently Closed") {
                        ForEach(browser.ghosts.reversed().prefix(10)) { ghost in
                            Button {
                                browser.reopen(ghost)
                            } label: {
                                MenuLine(title: ghost.label, url: ghost.url)
                            }
                        }
                    }
                }
                Divider()
                item("history.show")
                item("history.downloads")
                item("history.archive")
                item("history.restoreArchive")
                Divider()
                item("history.clearData")
                item("history.clear")
            }
            CommandGroup(after: .appSettings) {
                item("app.settings")
                item("app.welcome")
                item("app.passwords")
            }
            CommandGroup(replacing: .help) {
                Button("Send Feedback…") { Links.writeFeedback() }
            }
        }
    }

    /// A command as a menu item, on the key it has now (Settings › Shortcuts).
    private func item(_ id: String) -> some View {
        Button(id == "file.reopen" ? browser.reopenTitle : (Command.named(id)?.title ?? id)) { browser.run(id) }
            .keyboardShortcut(key(id))
    }

    private func key(_ id: String) -> KeyboardShortcut? {
        browser.shortcuts.key(for: id)?.swiftUI
    }
}

/// A page, as a line in a menu: its icon if one is known, and its name.
private struct MenuLine: View {
    let title: String
    let url: URL

    var body: some View {
        if let site = Favicons.site(url),
           let icon = Favicons.shared.cached(site) {
            Label {
                Text(title)
            } icon: {
                Image(nsImage: MenuLine.small(icon))
            }
        } else {
            Text(title)
        }
    }

    /// The cached icon is sixty-four points across; a menu wants sixteen.
    private static func small(_ icon: NSImage) -> NSImage {
        let copy = icon.copy() as! NSImage
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }
}

/// The base a sheet draws on, and the reason a panel is legible over a page
/// that has hidden its own cursor.
///
/// WebKit turns `cursor: none` into an AppKit cursor rect over the whole web
/// view. SwiftUI panels layered on top add no rect of their own, so when the
/// pointer crosses from the page into a sheet the invisible rect still wins,
/// and the sheet reads as empty air. This gives the sheet one arrow-sized
/// rect to win with, frontmost because its NSView sits above the web view
/// (a sheet is drawn by `.overlay { panels }` on `ContentView.body`).
private struct CursorGround: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { CursorGroundView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class CursorGroundView: NSView {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    // Re-arm the rect each time this view joins a window or changes size, so
    // AppKit notices it even if the pointer has not moved since the sheet
    // appeared. Without this the arrow only shows after a twitch.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
    }

    override func layout() {
        super.layout()
        window?.invalidateCursorRects(for: self)
    }
}

private final class WeakWindow {
    weak var window: NSWindow?
}

struct ContentView: View {
    @ObservedObject var browser: Browser

    /// Its window, held weakly: the window holds this view's state, and
    /// held strongly back, a window closed for good was never freed.
    @State private var held = WeakWindow()
    private var window: NSWindow? { held.window }
    @State private var resting: RestingLights?
    /// The page's own size, set apart from its card's (see `holdPage`):
    /// the card's final size, and which of its sides the page keeps to
    /// while the card moves; and the window's size, which it comes from.
    @State private var hold: CGSize?
    /// The tab whose chat beside the page is built and kept (see window_).
    @State private var chatKept: Tab.ID?
    @State private var pinTrailing = false
    @State private var windowSize: CGSize = .zero
    /// The column and the panel beside the page are built off the window,
    /// unseen, and only on the next frame slide in. Built and slid in one
    /// go, the slide's clock started while the view was still being made —
    /// the chat's first frame came a third of the way in.
    @State private var columnIn = true
    @State private var sideIn = true


    /// The window: room at the top, one stage for the page, and the row when
    /// there is one.
    @State private var immersionRevision = 0
    private var fullscreenTab: Tab? {
        _ = immersionRevision
        if let split = browser.shownSplit {
            return browser.tabs.first { split.has($0.id) && $0.immersed }
        }
        if browser.peekTab?.immersed == true { return browser.peekTab }
        return browser.active?.immersed == true ? browser.active : nil
    }
    @ViewBuilder private var fullscreenWatch: some View {
        if let peek = browser.peekTab {
            TabImmersionWatch(tab: peek) { immersionRevision += 1 }.id(peek.id)
        }
        if let split = browser.shownSplit {
            ForEach(browser.tabs.filter { split.has($0.id) }) { tab in
                TabImmersionWatch(tab: tab) { immersionRevision += 1 }.id(tab.id)
            }
        } else if let tab = browser.active {
            TabImmersionWatch(tab: tab) { immersionRevision += 1 }.id(tab.id)
        }
    }

    private var window_: some View {
        ZStack(alignment: .topLeading) {
            fullscreenWatch
            // Black while a page has the screen, so the frame of our own window
            // that survives the transition is not a white band across the top.
            if fullscreenTab != nil { Color.black } else { WindowGround(browser: browser, prefs: browser.prefs) }

            // The page, a card lying on the window's material (WindowGround),
            // as in Dia and Arc: in from the column, the strip and the chat by
            // the card's gap, rounded, lifted by its shadow.
            //
            // When any of them comes or goes, the card glides on the chrome's
            // spring — its frame and its shadow, cheap to move on every frame
            // — while the page inside it is laid out once (`hold`). The page
            // itself resized on every frame juddered and flashed white at its
            // edge as WebKit caught up (docs/mnml/sidebar-slide.md).
            stage
                .overlay {
                    if let image = browser.spacePageImage {
                        GeometryReader { box in
                            Image(nsImage: image).resizable()
                                .frame(width: box.size.width, height: box.size.height)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: pageCorner, style: .continuous))
                        .opacity(browser.spacePageOpacity)
                        .allowsHitTesting(false)
                    }
                }
                .background { if pageInset > 0 { cardFace } }
                .padding(pageInset)
                .padding(.leading, chrome.width)
                .padding(.trailing, sideRoom)
                .padding(.top, chrome.height)

            // The column of tabs, in the way that has one. It takes the full
            // height, so the traffic lights sit in its own corner rather than
            // over the page.
            if sidebar {
                SideBar(browser: browser, prefs: browser.prefs)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .offset(x: columnIn ? 0 : -browser.prefs.sideWidth)
                    .transition(.asymmetric(insertion: .identity, removal: .move(edge: .leading)))
                    // Kept over the page as it comes and goes: a view on its
                    // way in or out of a ZStack is otherwise drawn at the back,
                    // under the window's ground, and the ground showed as a dark
                    // panel for the length of the slide.
                    .zIndex(2)
            }

            if !browser.prefs.sidebar, !browser.folded, fullscreenTab == nil {
                TabBar(browser: browser)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            // An extension's side panel, docked where the chat goes.
            if #available(macOS 15.4, *), let tab = browser.active, let id = browser.docked[tab.id] {
                ExtensionSidePanel(browser: browser, prefs: browser.prefs, tab: tab, extensionID: id)
                    .id(tab.id)
                    .modifier(SideCard(on: pageInset > 0))
                    .padding(.top, chrome.height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .offset(x: sideIn ? 0 : sideAway)
                    .transition(.asymmetric(insertion: .identity, removal: .offset(x: sideAway)))
                    .zIndex(2)
            }

            // The chat beside the page: built the first time, then kept out
            // of sight past the window's edge while closed, so ⌘E slides it
            // straight in. Built afresh each time, it held the slide back by
            // a tenth of a second.
            // ponytail: one kept panel, the active tab's; its updates run
            // while closed too.
            if let tab = browser.active, browser.askMode(for: tab) == .side,
               browser.askShowing || browser.chats[tab.id] != nil {
                let shown = browser.askShowing
                AskPanel(browser: browser, tab: tab, chat: browser.chat(for: tab), prefs: browser.prefs, mode: .side, shown: shown)
                    .id(tab.id)
                    .modifier(SideCard(on: pageInset > 0))
                    .padding(.top, chrome.height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    // By its own width: .move measured the full-width frame
                    // around it, so it came from a window's width away —
                    // late in, early out, the gap beside the page dark.
                    .offset(x: shown && sideIn ? 0 : sideAway)
                    .allowsHitTesting(shown)
                    .accessibilityHidden(!shown)
                    .onAppear { chatKept = tab.id }
                    .zIndex(2) // as the column, above
            }

            if browser.askShowing, let tab = browser.active, browser.askMode(for: tab) != .side {
                let mode = browser.askMode(for: tab)
                let panel = AskPanel(browser: browser, tab: tab, chat: browser.chat(for: tab), prefs: browser.prefs, mode: mode)
                    .id(tab.id)
                switch mode {
                case .side:
                    EmptyView()
                case .full:
                    // Over the page's room: the column and the strip stay.
                    panel
                        .card()
                        .padding(PageCard.gap)
                        .padding(.leading, chrome.width)
                        .padding(.top, chrome.height)
                        .transition(.opacity)
                        .zIndex(2)
                case .float:
                    // Over everything, the column too, kept in its corner.
                    GeometryReader { room in
                        AskFloat(browser: browser, tab: tab, chat: browser.chat(for: tab), prefs: browser.prefs, room: room.size)
                            .id(tab.id)
                    }
                    .transition(.scale(scale: 0.96, anchor: .bottomTrailing).combined(with: .opacity))
                    .zIndex(3)
                }
            }

            // The bookmarks bar, under the strip or beside the column's top.
            if barShown {
                BookmarksBar(browser: browser, bookmarks: browser.bookmarks)
                    .padding(.leading, chrome.width)
                    .padding(.top, band)
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        // One spring for everything that moves the card, with no overshoot:
        // a card swinging past its place would show past its page.
        .animation(Motion.chrome, value: browser.prefs.sidebar)
        .animation(Motion.chrome, value: barShown)
        .animation(Motion.chrome, value: browser.askShowing)
        .animation(Motion.chrome, value: browser.active.flatMap { browser.docked[$0.id] })
        .animation(Motion.reduced ? nil : .easeOut(duration: 0.12), value: fullscreenTab?.id)
        .background {
            GeometryReader { box in
                Color.clear
                    .onAppear { windowSize = box.size }
                    .onChange(of: box.size) { _, size in
                        windowSize = size
                        // The window's edge dragged: the page follows it live.
                        hold = nil
                    }
            }
        }
        .onChange(of: cardRoom) { old, new in holdPage(from: old, to: new) }
        .onAppear {
            columnIn = sidebar
            sideIn = browser.askRoom > 0
        }
        .onChange(of: sidebar) { _, on in arrive(on, .column) }
        .onChange(of: browser.askRoom > 0) { _, on in arrive(on, .side) }
    }

    /// How far off the window's edge the panel beside the page waits.
    private var sideAway: CGFloat { browser.prefs.askWidth + PageCard.gap * 2 }

    /// The page's room on the right: the panel's, once it is on its way in.
    private var sideRoom: CGFloat { sideIn ? browser.askRoom : 0 }

    /// Chrome asked for: built where it waits this frame, slid in from the
    /// next on the chrome's spring, the card making room with it. Going, it
    /// leaves at once (its removal slides it out); nothing is built for that.
    private func arrive(_ on: Bool, _ piece: Arriving) {
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { set(piece, false) }
        guard on else { return }
        // The screen up to speed before the slide starts.
        FullSpeed.hold(window, for: Motion.chromeSettle + 0.3)
        // The page laid out at the size it is about to have, while the
        // piece is built out of sight; the slide starts once WebKit has
        // drawn it so, and nothing about the page changes while it runs.
        var target = cardRoom
        if piece == .column { target.leading = browser.prefs.sideWidth } else { target.trailing = browser.askRoom }
        let size = cardSize(target)
        if !Motion.reduced, size.width > 0, size.height > 0 { settle(size, pinTrailing: piece == .column) }
        // The chat already built and waiting: it slides at once.
        if piece == .side, chatKept == browser.active?.id {
            withAnimation(Motion.chrome) { set(piece, true) }
            return
        }
        var gone = false
        let go = {
            guard !gone else { return }
            gone = true
            guard piece == .column ? sidebar : browser.askRoom > 0 else { return }
            withAnimation(Motion.chrome) { set(piece, true) }
        }
        DispatchQueue.main.async {
            guard let page = browser.active?.built, page.window != nil else { return go() }
            Drawn.after(page, go)
            // Never long: a page that is slow to draw slides as it is.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: go)
        }
    }

    private enum Arriving { case column, side }

    private func set(_ piece: Arriving, _ value: Bool) {
        if piece == .column { columnIn = value } else { sideIn = value }
    }

    /// What decides the card's size, besides the window's.
    private struct CardRoom: Equatable {
        var leading: CGFloat, trailing: CGFloat, top: CGFloat, inset: CGFloat
    }

    private var cardRoom: CardRoom {
        CardRoom(leading: chrome.width, trailing: sideRoom, top: chrome.height, inset: pageInset)
    }

    private func cardSize(_ room: CardRoom) -> CGSize {
        CGSize(width: max(0, windowSize.width - room.leading - room.trailing - room.inset * 2),
               height: max(0, windowSize.height - room.top - room.inset * 2))
    }

    /// The column, the strip or a panel coming or going: the page takes
    /// the card's final size at once and keeps to the card's side that
    /// stays put, while the side that moves glides in over it or out to
    /// show more of it — one layout, before anything moves (see `arrive`),
    /// never during or after. Laid out after the slide instead, the page
    /// held the window up for a tenth of a second at a time while WebKit
    /// drew it anew (90–200 ms frames after ⌘E in full screen).
    private func holdPage(from old: CardRoom, to new: CardRoom) {
        let size = cardSize(new)
        guard !Motion.reduced, old != new, size.width > 0, size.height > 0 else {
            hold = nil
            return
        }
        settle(size, pinTrailing: new.leading != old.leading && new.trailing == old.trailing)
        FullSpeed.hold(window, for: Motion.chromeSettle + 0.1)
    }

    private func settle(_ size: CGSize, pinTrailing trailing: Bool) {
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            pinTrailing = trailing
            hold = size
        }
    }

    @ViewBuilder
    private var stage: some View {
        if let pick = browser.splitPicking, let tab = browser.tab(pick.tab) {
            SplitPickStage(browser: browser, pick: pick) { pane(tab, corner: SplitStage<EmptyView>.corner) }
        } else if let split = browser.shownSplit {
            SplitStage(browser: browser, split: split) { pane($0, corner: SplitStage<EmptyView>.corner) }
                .overlay {
                    if browser.prefs.showsLinks { LinkBubble(status: browser.linkStatus) }
                }
        } else if let tab = browser.active {
            pane(tab, corner: pageCorner, hold: hold, pinTrailing: pinTrailing)
                .overlay {
                    if browser.prefs.showsLinks { LinkBubble(status: browser.linkStatus) }
                }
        } else {
            Palette.ground
        }
    }

    /// Splits already have this margin; a video taking the screen has none.
    private var pageInset: CGFloat {
        fullscreenTab == nil && browser.shownSplit == nil && browser.splitPicking == nil ? PageCard.gap : 0
    }

    private var pageCorner: CGFloat { pageInset > 0 ? PageCard.corner : 0 }

    /// Under the page: the card's face, which only its shadow shows past.
    private var cardFace: some View {
        RoundedRectangle(cornerRadius: pageCorner, style: .continuous)
            .fill(Palette.ground)
            .shadow(color: PageCard.shadow, radius: PageCard.shadowRadius, y: PageCard.shadowY)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// One page, with what floats over it: find, and the accounts a field
    /// offers.
    private func pane(_ tab: Tab, corner: CGFloat = 0, hold: CGSize? = nil, pinTrailing: Bool = false) -> some View {
        Page(tab: tab, corner: corner, hold: hold, pinTrailing: pinTrailing)
            .overlay(alignment: .topTrailing) {
                if browser.finding, tab.id == browser.pageTarget?.id {
                    FindBar(browser: browser)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .overlay(alignment: .topLeading) {
                if let asked = browser.suggesting, asked.tab == tab.id {
                    AccountList(browser: browser, asked: asked)
                        .transition(.opacity)
                }
            }
            .animation(Motion.quick, value: browser.suggesting)
    }

    /// What the column and the strip take from the page right now: animated
    /// as they come and go.
    private var chrome: CGSize {
        CGSize(width: sidebar && columnIn ? browser.prefs.sideWidth : 0, height: band + (barShown ? BookmarksBar.height : 0))
    }

    /// The bookmarks bar is up: asked for, there are bookmarks, and the tabs
    /// aren't folded away or under a video filling the screen.
    private var barShown: Bool {
        browser.prefs.bookmarksBar && !browser.bookmarks.isEmpty && !browser.folded
            && fullscreenTab == nil
    }

    /// Everything that rises from the bottom edge to say one thing.
    private var bars: some View {
        VStack(spacing: 8) {
            announcement
            if let ask = browser.asking {
                captureAsking(ask)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let offer = browser.offering {
                keepAsking(offer)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let ask = browser.shortcutAsk {
                shortcutAsking(ask)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            StoreOffer(browser: browser)
            if browser.veiling {
                hint("Click anything to hide it   ⌘Z undo   esc done")
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, 30)
        .animation(Motion.settle, value: browser.veiling)
        .animation(Motion.settle, value: browser.asking)
        .animation(Motion.settle, value: browser.offering)
        .animation(Motion.settle, value: browser.shortcutAsk)
    }

    /// The address field: raised over a page by ⌘L or ⌘K, and standing on its
    /// own whenever a tab has nowhere to be yet.
    @ViewBuilder
    private var field: some View {
        if browser.fieldShowing {
            let over = !(browser.active?.isBlank ?? true)
            Omnibox(browser: browser, over: over)
                // On a blank tab, centred on the page, which is all the tab
                // has. Raised over a page (⌘T, ⌘L, ⌘K), a bar over the whole
                // window, as Arc's is, column and all.
                .padding(.leading, sidebar && !over ? browser.prefs.sideWidth : 0)
                // A fade, not a grow: grown, the dimming behind the field came
                // in as a smaller box with hard edges before it filled the window.
                .transition(.opacity)
        }
    }

    /// The panels. All the same kind of thing, so they are built the same way.
    @ViewBuilder
    private var panels: some View {
        if browser.recalling {
            sheet { HistoryPanel(browser: browser) } close: { browser.recalling = false }
        }
        if browser.archiveShowing {
            sheet { ArchivePanel(browser: browser) } close: { browser.archiveShowing = false }
        }
        if browser.hoarding {
            sheet { DownloadsPanel(browser: browser, loot: browser.loot) }
                close: { browser.hoarding = false }
        }
        if browser.tuning {
            sheet { SettingsPanel(browser: browser, prefs: browser.prefs) }
                close: { browser.tuning = false }
        }
        if browser.bookmarking {
            sheet { BookmarksPanel(browser: browser, bookmarks: browser.bookmarks) }
                close: { browser.bookmarking = false }
        }
        if browser.welcoming {
            WelcomePanel(browser: browser, prefs: browser.prefs)
                .ignoresSafeArea()
        }
        if browser.managing {
            sheet { PasswordsPanel(browser: browser) } close: { browser.managing = false }
        }
        if browser.bringingIn != nil {
            sheet { ImportPanel(browser: browser) } close: { browser.bringingIn = nil }
        }
        // What's new, once after an update, and every version's notes
        // (see WhatsNew.swift).
        if browser.newsShowing, let release = WhatsNew.current {
            sheet {
                WhatsNewCard(release: release, prefs: browser.prefs, close: { browser.newsShowing = false }) {
                    browser.newsShowing = false
                    browser.notesShowing = true
                }
            } close: { browser.newsShowing = false }
        }
        if browser.notesShowing {
            sheet { ReleaseNotesPanel { browser.notesShowing = false } } close: { browser.notesShowing = false }
        }
        if browser.reviewing {
            // No dimming for this one: the whole point is to keep looking at
            // the page while the list offers to put things back on it.
            ZStack(alignment: .topTrailing) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { browser.reviewing = false }
                HiddenPanel(browser: browser)
                    .padding(.top, Metrics.strip + 8)
                    .padding(.trailing, 14)
                    .transition(.scale(scale: 0.97, anchor: .topTrailing).combined(with: .opacity))
            }
            .ignoresSafeArea()
            .transition(.opacity)
        }
    }

    /// The window held, dressed and named for the page in front (see
    /// WindowTitle.swift).
    private var windowSetup: some View {
        ZStack {
            WindowSetup(ready: setUp)
            if let tab = browser.active { WindowTitle(tab: tab, window: window).id(tab.id) }
        }
    }

    var body: some View {
        window_
            // The column folded away, and out again at the edge (see Fold.swift).
            .overlay(alignment: .leading) { Fold(browser: browser, prefs: browser.prefs) }
            .overlay(alignment: .bottom) { bars }
            .overlay {
                // Over the page only: the column, the strip and the bookmarks
                // bar stay as they are, uncovered and in reach.
                PeekLayer(browser: browser)
                    .padding(pageInset)
                    .padding(.leading, chrome.width)
                    .padding(.trailing, sideRoom)
                    .padding(.top, chrome.height)
                    // From the window's own top edge, as the page is:
                    // the title bar's band is page too.
                    .ignoresSafeArea()
            }
            .overlay {
                // A tab held out of the column over the page (Split.swift).
                SplitDropLayer(browser: browser)
                    .padding(pageInset)
                    .padding(.leading, chrome.width)
                    .padding(.trailing, sideRoom)
                    .padding(.top, chrome.height)
                    .ignoresSafeArea()
            }
            .overlay { field }
            .overlay { panels }
            .overlay { TabSwitcherOverlay(browser: browser, switcher: browser.tabSwitcher) }
            .overlay(alignment: .topTrailing) {
                if let job = browser.fileImport { ImportProgress(browser: browser, job: job) }
            }
            .overlay(alignment: .topTrailing) { AntigravitySessionToasts() }
            // The field comes on its spring, and goes quickly: once Return
            // is pressed the page is on its way, and the field is not what
            // there is to watch.
            .animation(browser.fieldShowing ? Motion.settle : Motion.quick, value: browser.fieldShowing)
            .background(windowSetup)
            .onChange(of: browser.prefs.sidebar) { _, _ in
                DispatchQueue.main.async { Lights.refresh(window); measureLights() }
            }
            .onChange(of: browser.prefs.sideWidth) { _, _ in
                DispatchQueue.main.async { Lights.refresh(window); measureLights() }
            }
            // Stepping away to another app: macOS draws its own resting
            // buttons, and on a light window they come out nearly white. Ours
            // go on in their place until the app comes back.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                browser.tabSwitcher.cancel()
                measureLights()
                resting?.isHidden = false
                // Only the window you were in, or every window's video would come.
                browser.appLeft()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
                if let window, (note.object as? NSWindow) === window { Browsers.becameKey(browser) }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
                if let window, (note.object as? NSWindow) === window { browser.tabSwitcher.cancel() }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { note in
                if let window, (note.object as? NSWindow) === window { browser.fullScreen = true }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { note in
                if let window, (note.object as? NSWindow) === window { browser.fullScreen = false }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                resting?.isHidden = true
                browser.appBack()
            }
            .onChange(of: browser.fieldShowing) { _, showing in
                if showing {
                    DispatchQueue.main.async { browser.askFocus() }
                } else {
                    handBack()
                }
            }
            .onChange(of: browser.activeID) { _, _ in handBack() }
            .animation(Motion.settle, value: browser.recalling)
            .animation(Motion.settle, value: browser.hoarding)
            .animation(Motion.settle, value: browser.tuning)
            .animation(Motion.settle, value: browser.welcoming)
            .animation(Motion.settle, value: browser.bookmarking)
            .animation(Motion.settle, value: browser.managing)
            .animation(Motion.settle, value: browser.newsShowing)
            .animation(Motion.settle, value: browser.notesShowing)
            .animation(Motion.settle, value: browser.bringingIn != nil)
            .animation(Motion.settle, value: browser.reviewing)
        .onAppear {
            watchKeys()
            PageView.unused = { [weak browser] event in
                guard let browser else { return false }
                guard let id = browser.keyRouter.takeBack(event) else { return false }
                browser.run(id)
                return true
            }
            browser.askFocus()
            // Addresses from other apps have somewhere to go from here on.
            Links.hand(to: browser)
            BookmarkMenu.shared.start(for: browser)
            Browsers.watchFrames()
        }
        .onDisappear { Self.unwatchKeys(for: browser) }
    }

    /// Give the keyboard back to the page once the field is done with it.
    ///
    /// Nothing did this before, so after typing an address the window's first
    /// responder was a text field that no longer existed: typing went nowhere
    /// until you clicked the page. It also mattered more than it looked —
    /// WebAuthn refuses to run on a document that isn't focused, and so do a
    /// number of paste and shortcut handlers pages install for themselves.
    func handBack() {
        DispatchQueue.main.async {
            // A field or panel can open before this queued handoff runs.
            guard !browser.fieldShowing, nothingOver else { return }
            guard let web = browser.pageTarget?.web, let window = web.window else { return }
            window.makeFirstResponder(web)
        }
    }

    // MARK: - the window

    /// A line that rises from the bottom, says one thing, and leaves.
    @ViewBuilder
    private var announcement: some View {
        if let text = browser.announcement {
            HStack(spacing: 8) {
                Text(text)
                    .foregroundStyle(Palette.ink)
                // A file just saved: the line shows it in the Finder.
                if browser.announcedFile != nil {
                    Text("Show in Finder")
                        .foregroundStyle(Palette.muted)
                }
            }
                .font(.system(size: 12))
                .contentShape(Capsule())
                .onTapGesture {
                    if let file = browser.announcedFile { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 9)
                .background(Palette.ground, in: Capsule())
                .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
                .shadow(color: .black.opacity(0.10), radius: 18, y: 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(Motion.settle, value: browser.announcement)
        }
    }

    /// A page asking to see or hear you. Named by the site, in its own words,
    /// with the answer remembered so it is asked once and not every call.
    private func captureAsking(_ ask: Browser.CaptureAsk) -> some View {
        let off = ask.wants == "notifications off"
        return HStack(spacing: 12) {
            Image(systemName: ask.wants.hasPrefix("notifications") ? (off ? "bell.slash" : "bell") : ask.wants == "location" ? "location" : ask.wants == "microphone" ? "mic" : "video")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.muted)
            Text(off ? "\(ask.host) wants to notify you, but notifications for mnml are off in System Settings"
                 : ask.wants == "notifications" ? "\(ask.host) wants to send you notifications"
                 : ask.wants == "location" ? "\(ask.host) wants to know your location" : "\(ask.host) wants to use your \(ask.wants)")
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.ink)
            Button { ask.once ? browser.allowCaptureOnce() : browser.allowCapture() } label: {
                Text(off ? "Open Settings" : ask.once ? "Allow once" : "Allow")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ground)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(Palette.ink, in: Capsule())
            }
            .buttonStyle(.plain)
            if ask.once, ask.keeps {
                Button { browser.allowCapture() } label: {
                    Text("Always allow")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.ink)
                }
                .buttonStyle(.plain)
            }
            Button { browser.denyCapture() } label: {
                Text(off ? "Not now" : "Don't allow")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 9)
        .background(Palette.ground, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 20, y: 6)
    }

    /// Offered once, answered once. The password is never shown back to you —
    /// there is nothing to be learned from reading your own password.
    private func keepAsking(_ offer: Browser.Offer) -> some View {
        let login = offer.login
        return HStack(spacing: 12) {
            Text(offer.changed
                 ? "Update the password for \(login.user) on \(login.host)?"
                 : (login.user.isEmpty
                    ? "Save this password for \(login.host)?"
                    : "Save the password for \(login.user) on \(login.host)?"))
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            Button(offer.changed ? "Update" : "Save") { browser.keepOffer() }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Palette.ground)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(Palette.ink, in: Capsule())
            Button("Not now") { browser.dropOffer() }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
            if !offer.changed {
                Button("Never here") { browser.neverOffer() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 9)
        .background(Palette.ground, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 20, y: 6)
    }


    /// A site used a key one of mnml's commands is on, and that command is
    /// set to ask: who gets the key from now on.
    private func shortcutAsking(_ ask: Browser.ShortcutAsk) -> some View {
        let command = Command.named(ask.id)
        let keys = browser.shortcuts.key(for: ask.id)?.display ?? ""
        return HStack(spacing: 12) {
            Text("\(ask.site ?? "This page") used \(keys). Use mnml's \(command?.title ?? "shortcut") instead?")
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            Button("Use mnml's") { browser.answerShortcutAsk(mnml: true) }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Palette.ground)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(Palette.ink, in: Capsule())
            Button("Keep for websites") { browser.answerShortcutAsk(mnml: false) }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
            Button { browser.shortcutAsk = nil } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Palette.muted)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 9)
        .background(Palette.ground, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 20, y: 6)
    }

    /// A dark pill, for the one mode this browser has. It stays up for as long
    /// as the mode does, which is how you know you are still in it.
    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(Palette.ground.opacity(0.92))
            .padding(.horizontal, 15)
            .padding(.vertical, 9)
            .background(Palette.ink.opacity(0.92), in: Capsule())
            .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
    }

    /// The same dimmed ground and spring for every panel that floats over a
    /// page, so they read as one kind of thing.
    @ViewBuilder
    private func sheet<Panel: View>(
        @ViewBuilder _ panel: () -> Panel,
        close: @escaping () -> Void
    ) -> some View {
        ZStack {
            // The floor owns the cursor; see CursorGround.
            CursorGround()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
            Color.black.opacity(0.10)
                .ignoresSafeArea()
                .onTapGesture(perform: close)
            panel()
                .transition(.scale(scale: 0.97).combined(with: .opacity))
        }
        .transition(.opacity)
    }

    /// True while the tabs are down the left, and not folded away (see Fold.swift).
    private var sidebar: Bool {
        browser.prefs.sidebar && !browser.folded && fullscreenTab == nil
    }

    /// The column has its own corner for the lights, so the page beside it
    /// starts at the very top; the strip needs a band.
    private var band: CGFloat {
        guard fullscreenTab == nil else { return 0 }
        // Folded, the strip is out of the window and the page has its height.
        return browser.prefs.sidebar || browser.folded ? 0 : Metrics.strip
    }

    /// Put the resting circles in the title bar, exactly over the buttons.
    private func measureLights() {
        guard let window,
              let close = window.standardWindowButton(.closeButton),
              let titlebar = close.superview
        else { return }

        let view = resting ?? RestingLights()
        if view.superview !== titlebar {
            view.frame = titlebar.bounds
            view.autoresizingMask = [.width, .height]
            titlebar.addSubview(view, positioned: .above, relativeTo: nil)
            resting = view
        }
        view.spots = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
            .map { $0.convert($0.bounds, to: titlebar) }
        view.isHidden = NSApp.isActive
    }

    /// The window, once there is one: held, dressed, and named for the page
    /// in front so its name doesn't wait for the next change.
    private func setUp(_ window: NSWindow) {
        held.window = window
        dress(window)
        if let tab = browser.active { WindowTitle.set(tab, in: window) }
    }

    private func dress(_ window: NSWindow) {
        browser.window = window
        // Off screen at once, while a link's small window keeps the browser's
        // windows away (see Browsers.keepAway).
        Browsers.putAway()
        window.tabbingMode = .disallowed
        // Light or dark is the app's to say (Settings › Appearance); the
        // window only has to be the ground colour that goes with it.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = Palette.NS.ground
        // The strip does the dragging, so the page underneath can't be grabbed
        // by accident while selecting text.
        window.isMovableByWindowBackground = false
        // Nor by its title bar, which the strip is all the way down: AppKit
        // would move the window on any drag there, a tab picked up to take
        // it elsewhere in the row included. DragStrip moves it instead. The
        // window stays movable, though — macOS's Window › Move & Resize, its
        // tiling and the tools that arrange windows ask for a movable one
        // (#286) — and is made unmovable only while the pointer is over the
        // strip (see DragStrip).
        window.isMovable = true
        FullScreenEsc.keep(window)
        FullScreenLights.keep(window, browser: browser)

        // The traffic lights set in from the corner and centred in the strip's
        // height, in both modes, without a toolbar's rounder corners — see
        // Lights.swift. The column's first row is the strip's height too, so
        // its three doors sit on the lights' line.
        Lights.keep(window, centreX: { _ in Lights.centre.x }) { measureLights() }
        DispatchQueue.main.async { measureLights() }

        // The traffic lights are drawn — measured, they paint themselves — but
        // the window shows white where they are. The content view fills the
        // whole window, title bar included, and its layer was compositing over
        // the title bar's own. AppKit's subview order said otherwise; Core
        // Animation is the one actually deciding, so it is told directly.
        DispatchQueue.main.async {
            guard let close = window.standardWindowButton(.closeButton),
                  let container = close.superview?.superview,
                  let content = window.contentView,
                  let frame = content.superview
            else { return }
            frame.addSubview(container, positioned: .above, relativeTo: content)
            container.wantsLayer = true
            container.layer?.zPosition = 10
        }
    }

    // MARK: - keys

    /// A web view takes first responder and keeps most of the keyboard, so the
    /// shortcuts are caught before the event ever reaches it. The menu carries
    /// the same commands for anyone looking for them, and never sees these
    /// keystrokes because this runs first.
    private func watchKeys() {
        let id = ObjectIdentifier(browser)
        guard Self.keyMonitors[id] == nil else { return }
        Self.keyMonitors[id] = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown]) { event in
            // A click on the tab switcher, in this window only (see
            // Browser.clickTabSwitcher), turned into the top-left coordinates
            // SwiftUI's frames are in.
            if event.type == .leftMouseDown {
                guard let window, event.window === window, let height = window.contentView?.bounds.height
                else { return event }
                let at = event.locationInWindow
                return browser.clickTabSwitcher(at: CGPoint(x: at.x, y: height - at.y)) ? nil : event
            }
            // Every window has a monitor, and every monitor hears every key:
            // each takes only its own window's, and the one in front takes
            // those of windows that aren't a browser's (a panel, the little
            // window).
            guard mine(event) else { return event }
            guard event.type == .keyDown else {
                if browser.tabSwitcher.active, !event.modifierFlags.contains(.control) {
                    browser.commitTabSwitch()
                }
                // ⌘ let go of ends a ⌘K walk, wherever it stopped.
                if !event.modifierFlags.contains(.command) { browser.landSummon() }
                return event
            }
            return take(event) ? nil : event
        }
        ContentView.keyHooks[id] = { event in take(event) ? nil : event }
    }

    /// Each window's monitor retains its view callbacks. Remove both routes
    /// when the window retires, so its browser and key handlers do too.
    static func unwatchKeys(for browser: Browser) {
        let id = ObjectIdentifier(browser)
        if let monitor = keyMonitors.removeValue(forKey: id) { NSEvent.removeMonitor(monitor) }
        keyHooks[id] = nil
    }

    /// Whether a key is this window's to act on.
    private func mine(_ event: NSEvent) -> Bool {
        if let window = event.window, Browsers.browser(for: window) != nil { return window === self.window }
        return Browsers.acting === browser
    }

    /// The same handling the key monitor gives an event, for the bench to
    /// put a key through the app's own path — each window's own.
    static var keyHooks: [ObjectIdentifier: (NSEvent) -> NSEvent?] = [:]
    private static var keyMonitors: [ObjectIdentifier: Any] = [:]

    /// The keys of the top row, by where they sit rather than what they type.
    static let digits: [UInt16: Int] = [
        18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9, 29: 0,
    ]

    private func take(_ event: NSEvent) -> Bool {
        // A question hanging from the window (Ask) answers its own keys. Esc
        // there is its Cancel: taken here, it closed the panel under it and
        // left the question up, with Return still on its first button.
        if event.window?.sheetParent != nil { return false }
        // A small window's keys are its own (see Little.swift).
        if let little = LittleWindow.owning(event.window) { return little.take(event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.shortcutCharacters

        if let popup = Browsers.browser(for: event.window), popup.extensionPopup != nil {
            guard event.shortcutCharacters == "w", flags == .command else { return false }
            popup.window?.performClose(nil)
            return true
        }
        // Settings › Shortcuts is waiting for a key: it's the recorder's.
        if browser.recordingShortcut { return false }

        // A key handed to the page first, sent back unused: mnml's after all.
        if let id = browser.keyRouter.takeBack(event) {
            browser.run(id)
            return true
        }

        // ⌘Return in this window's address field opens behind the page;
        // ⇧⌘Return opens in front. A page's Return stays with the page.
        if (event.keyCode == 36 || event.keyCode == 76),
           flags == .command || flags == [.command, .shift],
           browser.fieldShowing, browser.editingTab == nil,
           let window, event.window === window,
           let editor = window.firstResponder as? NSTextView,
           (editor.delegate as? NSTextField)?.delegate is AddressField.Coordinator {
            browser.submit(aside: true, front: flags.contains(.shift))
            return true
        }

        // ⌃Tab with the recently used switcher on (Settings › Tabs): tabs in
        // the order you last looked at them. Off, ⌃Tab walks the row below.
        if event.keyCode == 48, flags.contains(.control),
           flags.isDisjoint(with: [.command, .option]), NSApp.keyWindow === window {
            browser.closeFind()
        }
        if browser.prefs.mruSwitcher, event.keyCode == 48, flags.contains(.control),
           !flags.contains(.command), !flags.contains(.option) {
            guard canSwitchTabs else { return false }
            if !event.isARepeat, let current = browser.activeID {
                browser.tabSwitcher.step(
                    eligible: browser.tabs.filter { !$0.bench }.map(\.id),
                    current: current,
                    backwards: flags.contains(.shift)
                )
            }
            return true
        }

        if browser.tabSwitcher.active, flags.contains(.control),
           !flags.contains(.command), !flags.contains(.option) {
            let direction: TabSwitcher.Direction?
            switch event.keyCode {
            case 123: direction = .left
            case 124: direction = .right
            case 125: direction = .down
            case 126: direction = .up
            default: direction = nil
            }
            if let direction {
                browser.tabSwitcher.move(direction)
                return true
            }
        }

        if browser.tabSwitcher.active {
            browser.tabSwitcher.cancel()
            if event.keyCode == 53 { return true }
        }

        // Escape puts the page back. On a blank tab there is no page to put
        // back, so it belongs to whatever else wants it.
        if event.keyCode == 53 {
            if browser.archiveShowing { browser.archiveShowing = false; return true }
            if browser.editingTab != nil {
                browser.cancelTabEdit()
                return true
            }
            if !browser.chosen.isEmpty {
                browser.chosen = []
                return true
            }
            if browser.peekTab != nil, browser.editing {
                browser.dismiss()
                return true
            }
            if let peek = browser.peekTab {
                if let web = peek.built, web.fullscreenState != .notInFullscreen { return false }
                browser.closePeek()
                return true
            }
            if browser.splitPicking != nil {
                withAnimation(Motion.settle) { browser.splitPicking = nil }
                return true
            }
            if browser.makingSpace {
                browser.cancelSpaceCreation()
                withAnimation(Motion.glide) { browser.makingSpace = false }
                return true
            }
            if browser.closePanel() { return true }
            if browser.suggesting != nil {
                browser.dropChoice()
                return true
            }
            if browser.veiling {
                browser.toggleHiding()
                return true
            }
            if browser.reviewing {
                browser.reviewing = false
                return true
            }
            if browser.finding {
                browser.closeFind()
                return true
            }
            // One step at a time: the list first, then the field.
            if browser.picked != nil {
                browser.picked = nil
                return true
            }
            // A new tab never sent anywhere is itself what is open: Escape
            // takes it away, back to the tab you were on, which is the one
            // touched last. Chosen before closing, so close() doesn't wake a
            // neighbour on the way. Anything typed keeps it; so does being
            // the last tab, where closing it would close the window.
            if let blank = browser.active, blank.isBlank, browser.typed.isEmpty,
               let back = browser.tabs.filter({ $0.id != blank.id }).max(by: { $0.touched < $1.touched }) {
                browser.select(back)
                browser.close(blank)
                return true
            }
            guard browser.editing, browser.active?.isBlank == false else { return false }
            browser.dismiss()
            return true
        }

        // ⌘Return keeps a peek, as its other button does: Return or the
        // keypad's Enter, by the key rather than what it types, whatever Caps
        // Lock says. Not while typing in the peeked page — a comment box or
        // a mail there sends with the same keys — by the page's word or by
        // the caret being in something editable, in any frame.
        if event.keyCode == 36 || event.keyCode == 76,
           flags.intersection([.command, .shift, .option, .control]) == .command,
           let peek = browser.peekTab, !browser.fieldShowing, !peek.typing, peek.built?.inputContext == nil {
            browser.keepPeek()
            return true
        }

        // Tab is the page's: it moves between a form's fields and a page's
        // links, as in every browser. It used to walk the row of tabs, which
        // took it from anyone filling in a form. ⌃Tab walks the row and comes
        // round to the first again, ⌃⇧Tab the other way — the keys every
        // other browser uses for that.
        //
        // While an address is being typed, the list under the field is what
        // there is to move through, and Return takes whatever the walk landed on.
        if event.keyCode == 48, !flags.contains(.command), !flags.contains(.option) {
            if flags.contains(.control) {
                browser.step(flags.contains(.shift) ? -1 : 1)
                return true
            }
            if browser.editingTab != nil { return true }
            // "red" then Tab: Reddit, in the field (SiteSearch.swift).
            if browser.fieldShowing, !flags.contains(.shift), browser.lockSiteOffer() { return true }
            if browser.fieldShowing, !browser.offers.isEmpty {
                browser.walk(flags.contains(.shift) ? -1 : 1)
                return true
            }
            return false
        }

        // ⌃1–⌃9 go to that space, when there are spaces — by the key, as
        // ⌘1–⌘9 are below, so the top row works on every layout.
        if browser.prefs.usesSpaces, flags.contains(.control),
           flags.isDisjoint(with: [.command, .option, .shift]),
           let number = ContentView.digits[event.keyCode], number > 0 {
            browser.switchSpace(index: number - 1)
            return true
        }

        // A shortcut an extension registered — ⌥⇧D, ⌃⇧Y — before the rest,
        // but never one of mnml's own: Claude for Chrome's ⌘E is the chat's
        // here. Its key can be changed in Settings › Shortcuts › Extensions.
        if #available(macOS 15.4, *), !flags.intersection([.command, .option, .control]).isEmpty,
           KeyCombo(event: event).map({ browser.shortcuts.command(matching: $0) == nil }) ?? true,
           Extensions.shared.take(event) {
            return true
        }

        // ⌘← and ⌘→ go back and forward while nothing is being typed:
        // WebKit takes them to scroll sideways and never hands them back
        // (upstream #324).
        if flags == .command, event.keyCode == 123 || event.keyCode == 124,
           !(event.window?.firstResponder is NSTextView), browser.active?.typing != true,
           browser.active?.built?.inputContext == nil {
            event.keyCode == 123 ? browser.back() : browser.forward()
            return true
        }

        // Only while pointing. Everywhere else undo belongs to the page.
        if browser.veiling, key == "z", flags == .command {
            browser.undoHiding()
            return true
        }

        guard let combo = KeyCombo(event: event), combo.isUsable,
              let command = browser.shortcuts.command(matching: combo)
        else { return false }

        // Set to let websites have the key first: the page gets it, and
        // mnml acts only if the page sends it back unused.
        let conflict = browser.shortcuts.conflict(for: command.id)
        if KeyRoute.decide(conflict, pageHasFocus: pageHasFocus(event)) == .hand, let page = browser.pageTarget?.built {
            browser.keyRouter.hand(event, for: command.id, to: page, prompt: conflict == .prompt,
                                   site: browser.pageTarget?.address?.host()) { id, site in
                browser.shortcutAsk = Browser.ShortcutAsk(id: id, site: site)
            }
            return true
        }
        return command.run(browser)
    }

    /// The page is what the key is meant for: its view has the keyboard and
    /// nothing is open over it.
    private func pageHasFocus(_ event: NSEvent) -> Bool {
        guard let page = browser.pageTarget?.built, let window = event.window,
              window.firstResponder === page, !browser.fieldShowing
        else { return false }
        return browser.peekTab != nil || nothingOver
    }

    private var canSwitchTabs: Bool {
        guard let window, NSApp.keyWindow === window else {
            ContentView.log.notice("⌃Tab ignored: the browser window isn't key (\(NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "none", privacy: .public))")
            return false
        }
        if !nothingOver {
            ContentView.log.notice("⌃Tab ignored: something is over the page (\(overReasons, privacy: .public))")
        }
        return nothingOver
    }

    /// Why ⌃Tab is refused, when it is: read with
    /// `log show --predicate 'subsystem == "com.farchan.mnml"' --last 1h`.
    static let log = Logger(subsystem: "com.farchan.mnml", category: "Switcher")

    private var overReasons: String {
        let flags: [(Bool, String)] = [
            (browser.archiveShowing, "archive"), (browser.tuning, "tuning"), (browser.recalling, "recalling"), (browser.hoarding, "hoarding"),
            (browser.bookmarking, "bookmarking"), (browser.welcoming, "welcoming"), (browser.managing, "managing"),
            (browser.newsShowing, "newsShowing"), (browser.notesShowing, "notesShowing"), (browser.bringingIn != nil, "bringingIn"),
            (browser.reviewing, "reviewing"), (browser.finding, "finding"), (browser.bookmarksOpen, "bookmarksOpen"),
            (browser.veiling, "veiling"), (browser.summoning, "summoning"), (browser.editingTab != nil, "editingTab"),
            (browser.asking != nil, "asking"), (browser.offering != nil, "offering"), (browser.suggesting != nil, "suggesting"),
            (browser.shortcutAsk != nil, "shortcutAsk"),
        ]
        return flags.filter(\.0).map(\.1).joined(separator: ", ")
    }

    /// No panel, field, bar or mode is up over the page.
    private var nothingOver: Bool {
        !browser.archiveShowing && !browser.tuning && !browser.recalling && !browser.hoarding &&
            !browser.bookmarking && !browser.welcoming && !browser.managing &&
            !browser.newsShowing && !browser.notesShowing && browser.bringingIn == nil &&
            !browser.reviewing && !browser.finding && !browser.bookmarksOpen &&
            !browser.veiling && !browser.summoning && browser.editingTab == nil &&
            browser.asking == nil && browser.offering == nil && browser.suggesting == nil && browser.shortcutAsk == nil
    }
}

/// Esc nobody wanted — the page, the address field, a row being renamed —
/// ends at SwiftUI's hosting view as Cancel, and SwiftUI takes Cancel in a
/// full-screen window as leaving full screen: Safari's habit too, and not
/// what Esc is for in a browser. It gets there from the page through WebKit
/// and from a text field through AppKit, both past any responder put in its
/// way, and SwiftUI tells its window to leave without going through Cancel.
/// So the window's leaving refuses while the event being handled is Esc, or
/// for a moment after one: a heavy page (Google Sheets) answers WebKit late,
/// and by then the current event is a mouse move or a timer, not the key.
/// ⌃⌘F, the green button and the menu still leave, and a video's own full
/// screen is WebKit's window, not this one, which Esc still ends.
enum FullScreenEsc {
    private static var done = false
    private static var lastEsc = Date.distantPast

    static func keep(_ window: NSWindow) {
        guard !done else { return }
        let leave = NSSelectorFromString("exitFullScreenMode:")
        guard let cls = NSClassFromString("SwiftUI.AppKitWindow"),
              let method = class_getInstanceMethod(cls, leave) else { return }
        done = true
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            if event.keyCode == 53 { lastEsc = Date() }
            return event
        }
        typealias Leave = @convention(c) (NSWindow, Selector, Any?) -> Void
        let before = unsafeBitCast(method_getImplementation(method), to: Leave.self)
        let block: @convention(block) (NSWindow, Any?) -> Void = { window, sender in
            let event = NSApp.currentEvent
            if let event, [.keyDown, .keyUp].contains(event.type), event.keyCode == 53 { return }
            // Something asked for since the Esc — another key (⌃⌘F), a click
            // (the green button, the menu) — is let through.
            // ponytail: 1.5 s window; a page slower than that still slips out.
            let asked = event.map { [.keyDown, .leftMouseDown, .leftMouseUp].contains($0.type) } ?? false
            if !asked, Date().timeIntervalSince(lastEsc) < 1.5 { return }
            before(window, leave, sender)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }
}

/// SwiftUI's window, around whichever browser it holds now (see SceneSlot):
/// a fresh one, laid out afresh, when the old one went with its window.
struct SceneRoot: View {
    @ObservedObject var slot: SceneSlot

    var body: some View {
        ContentView(browser: slot.browser)
            .id(ObjectIdentifier(slot.browser))
            .onAppear { Browsers.restoreOnce() }
    }
}

/// A file being brought in, in the background (#380): its name, how far it
/// has got, and Cancel — in the corner, in the quiet grey of everything
/// else that floats over the page.
private struct ImportProgress: View {
    @ObservedObject var browser: Browser
    let job: Browser.FileImportJob

    private var fraction: CGFloat? {
        guard let total = job.total, total > 0 else { return nil }
        return min(1, CGFloat(job.completed) / CGFloat(total))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(job.filename)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(job.message)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
            bar
            footer
        }
        .padding(14)
        .frame(width: 250, alignment: .leading)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.08), radius: 16, y: 5)
        .padding(20)
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Importing \(job.filename), \(job.message)")
    }

    private var bar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.hairline)
                if let fraction {
                    Capsule().fill(Palette.ink.opacity(0.7)).frame(width: geo.size.width * fraction)
                }
            }
        }
        .frame(height: 3)
    }

    private var footer: some View {
        HStack {
            if let total = job.total, total > 0 {
                Text("\(job.completed.formatted()) of \(total.formatted())")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 0)
            Button { browser.cancelFileImport() } label: {
                Text(job.cancelling ? "Cancelling…" : "Cancel")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .background(Palette.ink.opacity(0.07), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(job.cancelling)
        }
    }
}

private struct TabImmersionWatch: View {
    let tab: Tab
    let changed: () -> Void
    @State private var previous: Bool?

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onReceive(tab.$immersed.removeDuplicates()) { value in
                let didChange = previous != nil && previous != value
                previous = value
                if didChange { changed() }
            }
    }
}

private struct UpdateMenuItem: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        switch updater.stage {
        case .none:
            Button(updater.checking ? "Checking for Updates…" : "Check for Updates…") { updater.checkByHand() }
                .disabled(updater.checking)
        case .waiting:
            Button("Install Update") { updater.install() }
        case .fetching:
            Button("Downloading Update…") {}
                .disabled(true)
        case .ready:
            Button("Restart to Update") { updater.relaunch() }
        case .offered:
            Button(updater.fetchingDisk ? "Downloading Update…" : "Download Update…") { updater.openDisk() }
                .disabled(updater.fetchingDisk)
        }
    }
}

/// A panel beside the page — the chat, an extension's — as a card of its
/// own when the page is one: the gap above, below and at the window's
/// edge, the page's own margin on the other side (see Browser.askRoom).
private struct SideCard: ViewModifier {
    let on: Bool

    func body(content: Content) -> some View {
        if on {
            content.card().padding([.top, .bottom, .trailing], PageCard.gap)
        } else {
            content
        }
    }
}

/// The screen at full speed for the length of a slide. ProMotion lets a
/// screen idle at a low refresh rate while nothing on it moves, and in full
/// screen, where the window goes almost straight to the display, the
/// chrome's first frames came at that rate and stuttered — never while the
/// screen was being recorded, which keeps it compositing at a steady rate.
/// A display link asking for 120 frames a second holds it there; it lets go
/// on its own once the slide is over.
@MainActor
final class FullSpeed: NSObject {
    private static var held: [ObjectIdentifier: FullSpeed] = [:]
    private var link: CADisplayLink?
    private var until = Date.distantPast

    static func hold(_ window: NSWindow?, for seconds: TimeInterval) {
        guard let window, !Motion.reduced else { return }
        let key = ObjectIdentifier(window)
        let speed = held[key] ?? FullSpeed()
        held[key] = speed
        speed.until = max(speed.until, Date().addingTimeInterval(seconds))
        guard speed.link == nil else { return }
        let link = window.displayLink(target: speed, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        speed.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard Date() >= until else { return }
        link.invalidate()
        self.link = nil
        Self.held = Self.held.filter { $0.value !== self }
    }
}
