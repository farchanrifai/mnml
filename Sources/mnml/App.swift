import SwiftUI
import AppKit
import os

// A window, a row of titles, and a field. Typing an address gets you a page;
// there is nothing else to learn and nothing else to press.

@main
struct MnmlApp: App {
    @StateObject private var browser = Browser()
    /// Links from other apps, and the Dock icon.
    @NSApplicationDelegateAdaptor(Links.self) private var links

    var body: some Scene {
        Window("mnml", id: "browser") {
            ContentView(browser: browser)
                .frame(minWidth: 640, minHeight: 420)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 780)
        .commands {
            // One window. Tabs are the only kind of "new" there is.
            CommandGroup(replacing: .newItem) {
                item("file.newTab")
                item("file.newPrivateTab")
                item("file.reopen")
                    .disabled(browser.ghosts.isEmpty)
                Divider()
                item("file.openAddress")
                item("file.openPeek")
                    .disabled(browser.peekTab == nil)
                Divider()
                item("file.closeTab")
            }
            CommandGroup(replacing: .printItem) {
                Button("Share…") { browser.share() }
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
                            MenuLine(title: trace.title.isEmpty ? trace.key : trace.title, url: trace.url)
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
                Divider()
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
        Button(Command.named(id)?.title ?? id) { browser.run(id) }
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
        if let host = url.host()?.lowercased(),
           let icon = Favicons.shared.cached(host) {
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

struct ContentView: View {
    @ObservedObject var browser: Browser

    @State private var keys: Any?
    @State private var window: NSWindow?
    @State private var resting: RestingLights?
    /// The room the page leaves for the column and the strip, set without
    /// animation (see `make(room:after:)`); nil only before the window is up.
    @State private var room: CGSize?
    @State private var roomTicket = 0
    /// The column or the chat panel sliding in or out, with the page laid
    /// out again on each of its frames: the page's mirrored edge (Bleed) is
    /// off meanwhile, or it showed inside the page along its left side.
    @State private var sliding = false
    @State private var slideTicket = 0


    /// The window: room at the top, one stage for the page, and the row when
    /// there is one.
    private var window_: some View {
        ZStack(alignment: .topLeading) {
            // Black while a page has the screen, so the frame of our own window
            // that survives the transition is not a white band across the top.
            (browser.active?.immersed == true ? Color.black : Palette.ground)

            // One stage, always. It starts beside the column and under the
            // strip, not behind them — a page sliding beneath floating chrome
            // is a browser showing off, and it costs a compositing pass.
            //
            // When the column or the strip comes or goes, the page slides with
            // it and is resized once, not on every frame of the slide: laid out
            // again thirty times a second, the page juddered along its right
            // edge and overshot the window with the spring (see `room`).
            //
            // Unless the page is to run under them, as in Safari (Under.swift):
            // then it is the window's size, still, and told how much of it
            // they cover instead.
            //
            // Beside them, its width follows the column on every frame of the
            // slide (column-slide), as the chat panel's does; the strip's
            // height is still resized once. ChatGPT's picture-over-the-page
            // slide was tried too (d249ef0): see docs/mnml/sidebar-slide.md.
            stage
                .padding(.leading, under ? 0 : chrome.width)
                // This tab's chat, beside the page (AskPanel.swift), followed
                // frame by frame like the column.
                .padding(.trailing, browser.askRoom)
                .padding(.top, beside.height)
                .offset(y: under ? 0 : chrome.height - roomed.height)

            // The column of tabs, in the way that has one. It takes the full
            // height, so the traffic lights sit in its own corner rather than
            // over the page.
            if sidebar {
                SideBar(browser: browser, prefs: browser.prefs)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .transition(.move(edge: .leading))
                    // Kept over the page as it comes and goes: a view on its
                    // way in or out of a ZStack is otherwise drawn at the back,
                    // under the window's ground, and the ground showed as a dark
                    // panel for the length of the slide.
                    .zIndex(2)
            }

            if !browser.prefs.sidebar, !browser.folded, browser.active?.immersed != true {
                TabBar(browser: browser)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if browser.askShowing, let tab = browser.active {
                let mode = browser.askMode(for: tab)
                let panel = AskPanel(browser: browser, tab: tab, chat: browser.chat(for: tab), prefs: browser.prefs, mode: mode)
                    .id(tab.id)
                switch mode {
                case .side:
                    panel
                        .padding(.top, chrome.height)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                        // By its own width: .move measured the full-width frame
                        // around it, so it came from a window's width away —
                        // late in, early out, the gap beside the page dark.
                        .transition(.offset(x: browser.prefs.askWidth))
                        .zIndex(2) // as the column, above
                case .full:
                    // Over the page's room: the column and the strip stay.
                    panel
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
        .animation(Motion.glide, value: browser.prefs.sidebar)
        .animation(.spring(response: 0.34, dampingFraction: 1), value: browser.askShowing)
        .animation(.easeOut(duration: 0.12), value: browser.active?.immersed)
        .onAppear { if room == nil { room = chrome } }
        .onChange(of: chrome) { old, new in make(room: new, after: old) }
    }

    @ViewBuilder
    private var stage: some View {
        if let pick = browser.splitPicking, let tab = browser.tab(pick.tab) {
            SplitPickStage(browser: browser, pick: pick) { pane(tab, corner: SplitStage<EmptyView>.corner, under: EdgeInsets()) }
        } else if let split = browser.shownSplit {
            SplitStage(browser: browser, split: split) { pane($0, corner: SplitStage<EmptyView>.corner, under: EdgeInsets()) }
                .overlay {
                    if browser.prefs.showsLinks { LinkBubble(status: browser.linkStatus) }
                }
        } else if let tab = browser.active {
            pane(tab, under: covered)
                .overlay {
                    if browser.prefs.showsLinks { LinkBubble(status: browser.linkStatus).padding(covered) }
                }
        } else {
            Palette.ground
        }
    }

    /// One page, with what floats over it: find, and the accounts a field
    /// offers — both clear of the chrome the page may run under.
    private func pane(_ tab: Tab, corner: CGFloat = 0, under: EdgeInsets) -> some View {
        Page(tab: tab, corner: corner, under: under, bleeds: !sliding)
            .overlay(alignment: .topTrailing) {
                if browser.finding, tab.id == browser.activeID {
                    FindBar(browser: browser)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .padding(.top, under.top)
                }
            }
            .overlay(alignment: .topLeading) {
                if let asked = browser.suggesting, asked.tab == tab.id {
                    AccountList(browser: browser, asked: asked)
                        .transition(.opacity)
                        .padding(.leading, under.leading)
                        .padding(.top, under.top)
                }
            }
            .animation(Motion.quick, value: browser.suggesting)
    }

    /// What the column and the strip take from the page right now: animated
    /// as they come and go.
    private var chrome: CGSize {
        CGSize(width: sidebar ? browser.prefs.sideWidth : 0, height: band + (barShown ? BookmarksBar.height : 0))
    }

    /// The bookmarks bar is up: asked for, there are bookmarks, and the tabs
    /// aren't folded away or under a video filling the screen.
    private var barShown: Bool {
        browser.prefs.bookmarksBar && !browser.bookmarks.isEmpty && !browser.folded
            && browser.active?.immersed != true
    }

    /// The room the page is laid out to leave them, which is not animated.
    private var roomed: CGSize { room ?? chrome }

    /// The page runs under the column and the strip (Under.swift).
    private var under: Bool { browser.pageUnder }

    /// The room the stage leaves beside the chrome: none, with the page
    /// running under it.
    private var beside: CGSize { under ? .zero : roomed }

    /// How much of the page the chrome covers, with the page under it. The
    /// room, not the chrome: it changes when the room does, once a slide,
    /// never on its frames — each change lays the page out again. So the
    /// column going away uncovers the page at once and it reflows as the
    /// column slides off it; the column arriving slides over the page as it
    /// is, which moves its content clear once the slide is over.
    private var covered: EdgeInsets {
        // The column's width as it animates, as beside it (column-slide):
        // the page lays out again on each frame of the slide, its mirrored
        // edge off meanwhile (`sliding`).
        under ? EdgeInsets(top: roomed.height, leading: chrome.width, bottom: 0, trailing: 0) : EdgeInsets()
    }

    /// Chrome going away gives the page its room at once, the page sliding
    /// out from under it at its new size. Chrome arriving slides over a page
    /// still at its old size, which gives up the room once the slide is over.
    /// A column being dragged wider or narrower is followed as it goes.
    /// (Beside the column, the page's width follows `chrome` instead; this
    /// room is its height, and what the page under the chrome is told.)
    private func make(room new: CGSize, after old: CGSize) {
        let now = roomed
        let arriving = (old.width == 0 && new.width > 0, old.height == 0 && new.height > 0)
        var at = now
        if !arriving.0 { at.width = new.width }
        if !arriving.1 { at.height = new.height }
        roomTicket += 1
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { room = at }
        guard arriving.0 || arriving.1 else { return }
        let ticket = roomTicket
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
            guard ticket == roomTicket else { return }
            withTransaction(still) { room = chrome }
        }
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

    var body: some View {
        window_
            // The column folded away, and out again at the edge (see Fold.swift).
            .overlay(alignment: .leading) { Fold(browser: browser, prefs: browser.prefs) }
            .overlay(alignment: .bottom) { bars }
            .overlay {
                // Over the page only: the column, the strip and the bookmarks
                // bar stay as they are, uncovered and in reach.
                PeekLayer(browser: browser)
                    .padding(.leading, chrome.width)
                    .padding(.top, chrome.height)
                    // From the window's own top edge, as the page is:
                    // the title bar's band is page too.
                    .ignoresSafeArea()
            }
            .overlay {
                // A tab held out of the column over the page (Split.swift).
                SplitDropLayer(browser: browser)
                    .padding(.leading, chrome.width)
                    .padding(.top, chrome.height)
                    .ignoresSafeArea()
            }
            .overlay { field }
            .overlay { panels }
            .overlay { TabSwitcherOverlay(browser: browser, switcher: browser.tabSwitcher) }
            // The field comes on its spring, and goes quickly: once Return
            // is pressed the page is on its way, and the field is not what
            // there is to watch.
            .animation(browser.fieldShowing ? Motion.settle : Motion.quick, value: browser.fieldShowing)
            .background(WindowSetup { window = $0; dress($0) })
            .onChange(of: browser.prefs.sidebar) { _, _ in
                DispatchQueue.main.async { measureLights() }
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
                if let window, (note.object as? NSWindow) === window { Browser.front = browser }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
                if let window, (note.object as? NSWindow) === window { browser.tabSwitcher.cancel() }
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
            .onChange(of: browser.askRoom) { _, _ in slide() }
            .onChange(of: chrome.width) { _, _ in slide() }
            .animation(Motion.settle, value: browser.recalling)
            .animation(Motion.settle, value: browser.hoarding)
            .animation(Motion.settle, value: browser.tuning)
            .animation(Motion.settle, value: browser.welcoming)
            .animation(Motion.settle, value: browser.bookmarking)
            .animation(Motion.settle, value: browser.managing)
            .animation(Motion.settle, value: browser.reviewing)
        .onAppear {
            watchKeys()
            PageView.unused = { [browser] event in
                guard let id = browser.keyRouter.takeBack(event) else { return false }
                browser.run(id)
                return true
            }
            browser.askFocus()
            // Addresses from other apps have somewhere to go from here on.
            Links.hand(to: browser)
            BookmarkMenu.shared.start(for: browser)
        }
    }

    /// The mirrored edge off for the length of a slide (see `sliding`).
    private func slide() {
        guard browser.pageUnder else { return }
        slideTicket += 1
        let ticket = slideTicket
        // On the slide's own spring: switching the copy off lays the page out
        // again, and done without one, the strip under the column jumped to
        // its end at once, ahead of the column gliding in.
        withAnimation(Motion.glide) { sliding = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            if ticket == slideTicket { sliding = false }
        }
    }

    /// Give the keyboard back to the page once the field is done with it.
    ///
    /// Nothing did this before, so after typing an address the window's first
    /// responder was a text field that no longer existed: typing went nowhere
    /// until you clicked the page. It also mattered more than it looked —
    /// WebAuthn refuses to run on a document that isn't focused, and so do a
    /// number of paste and shortcut handlers pages install for themselves.
    private func handBack() {
        guard !browser.fieldShowing, browser.editingTab == nil else { return }
        DispatchQueue.main.async {
            guard let web = browser.active?.web, let window = web.window else { return }
            window.makeFirstResponder(web)
        }
    }

    // MARK: - the window

    /// A line that rises from the bottom, says one thing, and leaves.
    @ViewBuilder
    private var announcement: some View {
        if let text = browser.announcement {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Palette.ink)
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
            Image(systemName: ask.wants.hasPrefix("notifications") ? (off ? "bell.slash" : "bell") : ask.wants == "microphone" ? "mic" : "video")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.muted)
            Text(off ? "\(ask.host) wants to notify you, but notifications for mnml are off in System Settings"
                 : ask.wants == "notifications" ? "\(ask.host) wants to send you notifications"
                 : "\(ask.host) wants to use your \(ask.wants)")
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.ink)
            Button { browser.allowCapture() } label: {
                Text(off ? "Open Settings" : "Allow")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ground)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(Palette.ink, in: Capsule())
            }
            .buttonStyle(.plain)
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
        browser.prefs.sidebar && !browser.folded && browser.active?.immersed != true
    }

    /// The column has its own corner for the lights, so the page beside it
    /// starts at the very top; the strip needs a band.
    private var band: CGFloat {
        guard browser.active?.immersed != true else { return 0 }
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

    private func dress(_ window: NSWindow) {
        Links.window = window
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
        // it elsewhere in the row included. DragStrip moves it instead.
        window.isMovable = false
        // Where you left it, at the size you left it. A test run keeps its
        // own: the name lives in the app's standard defaults, which every
        // copy shares, and a probe resized for a test once changed the size
        // the real window came back at.
        window.setFrameAutosaveName(Store.world.map { "search (\($0))" } ?? "search")
        FullScreenEsc.keep(window)
        FullScreenLights.keep(window, browser: browser)

        // The traffic lights set in from the corner and centred in the strip's
        // height, in both modes, without a toolbar's rounder corners — see
        // Lights.swift. The column's first row is the strip's height too, so
        // its three doors sit on the lights' line.
        Lights.keep(window) { measureLights() }
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
        guard keys == nil else { return }
        keys = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
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
        ContentView.keyHook = { event in take(event) ? nil : event }
    }

    /// The same handling the key monitor gives an event, for the bench to
    /// put a key through the app's own path.
    static var keyHook: ((NSEvent) -> NSEvent?)?

    /// The keys of the top row, by where they sit rather than what they type.
    static let digits: [UInt16: Int] = [
        18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9, 29: 0,
    ]

    private func take(_ event: NSEvent) -> Bool {
        // A small window's keys are its own (see Little.swift).
        if let little = LittleWindow.owning(event.window) { return little.take(event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        // Settings › Shortcuts is waiting for a key: it's the recorder's.
        if browser.recordingShortcut { return false }

        // A key handed to the page first, sent back unused: mnml's after all.
        if let id = browser.keyRouter.takeBack(event) {
            browser.run(id)
            return true
        }

        // ⌃Tab with the recently used switcher on (Settings › Tabs): tabs in
        // the order you last looked at them. Off, ⌃Tab walks the row below.
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
            if browser.editingTab != nil {
                browser.cancelTabEdit()
                return true
            }
            if !browser.chosen.isEmpty {
                browser.chosen = []
                return true
            }
            if browser.peekTab != nil {
                browser.closePeek()
                return true
            }
            if browser.splitPicking != nil {
                withAnimation(Motion.settle) { browser.splitPicking = nil }
                return true
            }
            if browser.makingSpace {
                withAnimation(Motion.glide) { browser.makingSpace = false }
                return true
            }
            if browser.tuning {
                browser.tuning = false
                return true
            }
            if browser.bookmarking {
                browser.bookmarking = false
                return true
            }
            if browser.managing {
                browser.managing = false
                return true
            }
            if browser.recalling {
                browser.recalling = false
                return true
            }
            if browser.hoarding {
                browser.hoarding = false
                return true
            }
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
            guard browser.editing, browser.active?.isBlank == false else { return false }
            browser.dismiss()
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

        // A shortcut an extension registered — ⌥⇧D, ⌃⇧Y — before ours, since
        // none of ours use those.
        if #available(macOS 15.4, *), !flags.intersection([.command, .option, .control]).isEmpty,
           Extensions.shared.take(event) {
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
        if KeyRoute.decide(conflict, pageHasFocus: pageHasFocus(event)) == .hand, let page = browser.active?.built {
            browser.keyRouter.hand(event, for: command.id, to: page, prompt: conflict == .prompt,
                                   site: browser.active?.address?.host()) { id, site in
                browser.shortcutAsk = Browser.ShortcutAsk(id: id, site: site)
            }
            return true
        }
        return command.run(browser)
    }

    /// The page is what the key is meant for: its view has the keyboard and
    /// nothing is open over it.
    private func pageHasFocus(_ event: NSEvent) -> Bool {
        guard let page = browser.active?.built, let window = event.window,
              window.firstResponder === page, !browser.fieldShowing, browser.peekTab == nil
        else { return false }
        return nothingOver
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
            (browser.tuning, "tuning"), (browser.recalling, "recalling"), (browser.hoarding, "hoarding"),
            (browser.bookmarking, "bookmarking"), (browser.welcoming, "welcoming"), (browser.managing, "managing"),
            (browser.reviewing, "reviewing"), (browser.finding, "finding"), (browser.bookmarksOpen, "bookmarksOpen"),
            (browser.veiling, "veiling"), (browser.summoning, "summoning"), (browser.editingTab != nil, "editingTab"),
            (browser.asking != nil, "asking"), (browser.offering != nil, "offering"), (browser.suggesting != nil, "suggesting"),
        ]
        return flags.filter(\.0).map(\.1).joined(separator: ", ")
    }

    /// No panel, field, bar or mode is up over the page.
    private var nothingOver: Bool {
        !browser.tuning && !browser.recalling && !browser.hoarding &&
            !browser.bookmarking && !browser.welcoming && !browser.managing &&
            !browser.reviewing && !browser.finding && !browser.bookmarksOpen &&
            !browser.veiling && !browser.summoning && browser.editingTab == nil &&
            browser.asking == nil && browser.offering == nil && browser.suggesting == nil
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
