import SwiftUI

/// Everything there is to set. Pages down the left, one page at a time on
/// the right, each a short list of lines with a hairline between them —
/// nothing to scroll through, nothing to hunt for. The same white and
/// hairline as the rest of the app; the same pill for the page you are on
/// as for the tab you are on.
struct SettingsPanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences

    @ObservedObject private var updater = Updater.shared
    @ObservedObject private var shield = Shield.shared
    @State private var isDefault = Links.isDefault
    /// A site shortcut being written, kept out of Preferences until it's saved.
    @State private var draft: Keyword?
    @State private var page: Page = Page(rawValue: Store.settings.string(forKey: "settings.page") ?? "") ?? .general
    @State private var hovered: Page?

    enum Page: String, CaseIterable, Identifiable {
        case general, tabs, links, ai, shortcuts, extensions, passwords, downloads, privacy, about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: return "General"
            case .tabs: return "Tabs"
            case .links: return "Links"
            case .ai: return "AI"
            case .shortcuts: return "Shortcuts"
            case .extensions: return "Extensions"
            case .passwords: return "Passwords"
            case .downloads: return "Downloads"
            case .privacy: return "Privacy"
            case .about: return "About"
            }
        }
        var icon: String {
            switch self {
            case .general: return "macwindow"
            case .tabs: return "rectangle.split.3x1"
            case .links: return "arrow.triangle.branch"
            case .ai: return "sparkles"
            case .shortcuts: return "keyboard"
            case .extensions: return "puzzlepiece.extension"
            case .passwords: return "key"
            case .downloads: return "arrow.down.circle"
            case .privacy: return "hand.raised"
            case .about: return "info.circle"
            }
        }
    }

    private static let rail: CGFloat = 168
    /// Room for Shortcuts' list and the one you picked side by side; every
    /// page gets the same, so the panel doesn't change size under you.
    private static let width: CGFloat = 780
    private static let height: CGFloat = 500

    var body: some View {
        HStack(spacing: 0) {
            pages
            Rectangle().fill(Palette.hairline).frame(width: 1)
            content
        }
        .frame(width: SettingsPanel.width, height: SettingsPanel.height)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 34, y: 12)
        .onChange(of: page) { _, page in Store.settings.set(page.rawValue, forKey: "settings.page") }
        .onAppear { if browser.appearanceSpace != nil { page = .tabs } }
        .onChange(of: browser.appearanceSpace) { _, id in if id != nil { page = .tabs } }
        .onChange(of: browser.settingsPage) { _, value in page = value }
        .onChange(of: browser.spaces) { _, spaces in
            if let id = browser.appearanceSpace, !spaces.contains(where: { $0.id == id }) { browser.appearanceSpace = nil }
        }
    }

    // MARK: - the rail

    private var pages: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Settings")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 10)
                .padding(.top, 14)
                .padding(.bottom, 12)
            ForEach(Page.allCases) { item in
                PageRow(page: item, on: page == item, hovering: hovered == item) { page = item }
                    .onHover { inside in
                        if inside { hovered = item } else if hovered == item { hovered = nil }
                    }
            }
            Spacer(minLength: 0)
        }
        // One hovered row for the rail, cleared when the pointer leaves it: a
        // row's own hover, its exit missed, stayed lit beside the chosen one.
        .onHover { if !$0 { hovered = nil } }
        .padding(8)
        .frame(width: SettingsPanel.rail, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Palette.wash.opacity(0.45), in: Rectangle())
    }

    private struct PageRow: View {
        let page: Page
        let on: Bool
        let hovering: Bool
        let act: () -> Void

        var body: some View {
            Button(action: act) {
                HStack(spacing: 9) {
                    Image(systemName: page.icon)
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 16)
                    Text(page.title)
                        .font(.system(size: 13, weight: on ? .medium : .regular))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(on ? Palette.ink : (hovering ? Palette.ink.opacity(0.75) : Palette.muted))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(on ? Palette.ground : (hovering ? Palette.hover : .clear))
                        .shadow(color: .black.opacity(on ? 0.06 : 0), radius: 3, y: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            // No fade: sweeping down the rail left the row behind still
            // fading as the next lit, two or three lit at once.
        }
    }

    // MARK: - the page

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(page.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Spacer()
                Door(icon: "xmark", help: "Done   esc") { browser.tuning = false }
            }
            .padding(.bottom, 16)

            if page == .shortcuts {
                // Its list scrolls on its own; the page around it doesn't.
                ShortcutsPage(browser: browser, store: browser.shortcuts)
            } else {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    switch page {
                    case .general: general
                    case .links: LinkRoutesPage(browser: browser)
                    case .tabs:
                        tabs
                    case .shortcuts: ShortcutsPage(browser: browser, store: browser.shortcuts)
                    case .extensions: ExtensionsPage(browser: browser)
                    case .passwords: passwords
                    case .downloads: downloads
                    case .ai: AISettings(prefs: prefs)
                    case .privacy: privacy
                    case .about: about
                    }
                }
                .padding(.bottom, 4)
            }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - general

    private var general: some View {
        Card {
            Line(
                "Open links from other apps",
                isDefault ? "mnml is the default browser on this Mac" : "Mail, Slack and the rest still send links elsewhere"
            ) {
                if isDefault {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .frame(width: 24)
                } else {
                    Pill("Make default", filled: true) {
                        Links.becomeDefault { worked in
                            isDefault = Links.isDefault
                            browser.announce(worked && isDefault ? "Links now open here" : "macOS didn't change it")
                        }
                    }
                }
            }
            Rule()
            // Coming from another browser, now or any time later: the same
            // sheet as File › Bring Things Over… and the Welcome's.
            Line("Bring things over", "Bookmarks, history, passwords and extensions from another browser on this Mac, or from a file it exported") {
                Pill("Bring Things Over…") {
                    browser.tuning = false
                    browser.bringingIn = ""
                }
            }
            Rule()
            Line("Search with", searchDetail) {
                Picker("", selection: $prefs.engine) {
                    ForEach(Engine.allCases) { engine in
                        Text(engine.title).tag(engine)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            if prefs.engine == .custom {
                ZStack(alignment: .leading) {
                    if prefs.customEngine.isEmpty {
                        Text("https://example.com/search?q=%s")
                            .foregroundStyle(Palette.muted.opacity(0.8))
                    }
                    TextField("", text: $prefs.customEngine)
                        .textFieldStyle(.plain)
                        .foregroundStyle(Palette.ink)
                }
                .font(.system(size: 12.5))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Palette.wash, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .padding(.horizontal, 14)
                .padding(.bottom, 11)
            }
            Rule()
            Line("Site shortcuts", keywordDetail) {
                if draft == nil {
                    Pill("Add") { draft = Keyword() }
                } else {
                    HStack(spacing: 6) {
                        Pill("Cancel") { draft = nil }
                        Pill("Save", filled: true) { saveDraft() }
                            .disabled(draftProblem != nil)
                            .opacity(draftProblem == nil ? 1 : 0.4)
                    }
                }
            }
            if let current = draft {
                HStack(spacing: 8) {
                    TextField("yt", text: Binding(
                        get: { current.keyword },
                        set: { draft?.keyword = $0 }
                    ))
                    .textFieldStyle(.plain)
                    .frame(width: 50)
                    Text("→").foregroundStyle(Palette.muted)
                    TextField("https://www.youtube.com/results?search_query=%s", text: Binding(
                        get: { current.template },
                        set: { draft?.template = $0 }
                    ))
                    .textFieldStyle(.plain)
                    .onSubmit(saveDraft)
                }
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Palette.wash, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
            }
            ForEach(prefs.keywords) { entry in
                HStack(spacing: 8) {
                    Text(entry.keyword)
                        .frame(width: 50, alignment: .leading)
                    Text("→").foregroundStyle(Palette.muted)
                    Text(entry.template)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        prefs.keywords.removeAll { $0.id == entry.id }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Palette.faint)
                    }
                    .buttonStyle(.plain)
                }
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Palette.wash, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
            }
            Rule()
            Line("Appearance", "Light, dark, or whatever the Mac is doing — pages follow it too") {
                Segmented(options: Look.allCases.map { ($0, $0.title) }, selection: $prefs.look)
            }
            Rule()
            Line("Page zoom", "Where every site starts. ⌘+ and ⌘− are still remembered for each site.") {
                // The number itself takes it back to 100%.
                Steps(stops: Preferences.zooms, value: $prefs.pageZoom, home: 1) { "\(Int(($0 * 100).rounded()))%" }
            }
            Rule()
            Line("Correct spelling as you type", "macOS's autocorrect inside pages — the one that capitalises for you") {
                Switch(on: $prefs.autocorrect)
            }
            Rule()
            Line("Peek at links", "Shift-click previews a link. Links leaving a pinned site preview automatically; keep the page as a tab or split") {
                Switch(on: $prefs.peeksLinks)
            }
            Rule()
            Line("Open links from other apps in a small window", "To read and close, or keep with Open in mnml (⌘O)") {
                Switch(on: $prefs.littleLinks)
            }
            Rule()
            Line("Command bar actions", "Show matching browser actions alongside tabs, history, and search") {
                Switch(on: $prefs.commandActions)
            }
            Rule()
            Line("Address bar commands", "A word like \"settings\" or \"new tab\", typed alone in the address field, goes there instead of searching for it") {
                Switch(on: $prefs.addressCommands)
            }
            Rule()
            Line("Show where links go", "Point at a link and its address shows at the bottom of the page") {
                Switch(on: $prefs.showsLinks)
            }
            Rule()
            Line("Scroll with the middle button", "Click the wheel on a page, then move the mouse up or down to scroll, as on Windows. Click again to stop") {
                Switch(on: $prefs.autoScroll)
            }
            Rule()
            Line("Pages at 120 Hz", "Animations and scrolling in pages at up to 120 frames a second on a screen that can, instead of 60 as in Safari. Uses more battery. Open tabs follow when reloaded") {
                Switch(on: $prefs.fastPages)
            }
            Rule()
            Line("Hold a swipe to pick from history", "Swipe back or forward and keep your fingers down: the pages that way appear, and moving up or down picks one to go to") {
                Switch(on: $prefs.holdsHistory)
            }
            Rule()
            Line("Flick the floating video to a corner", "Two fingers on it send it to the corner or edge they point at, instead of pushing it along; a strong swipe at the side of the screen it is against tucks it in there, a sliver left to bring it back by. Dragging still puts it anywhere") {
                Switch(on: $prefs.floatFlicks)
            }
            Rule()
            Line("Videos wait for a click", "Videos don't start by themselves, even without sound; they play when you press play. Tabs already open follow once closed and opened again, or after they've slept") {
                Switch(on: $prefs.waitsForPlay)
            }
            Rule()
            Line("Float the video when you switch tabs", "A video playing on YouTube and the like comes out into its floating window when you go to another tab, and back when you return. ⇧⌘P still floats one by hand") {
                Switch(on: $prefs.floatsOnLeave)
            }
            Rule()
            Line("Float the video when you switch apps", "A video playing on the site you're on comes out into its floating window as another app comes to the front, and goes back into its tab when you return") {
                Switch(on: $prefs.floatsAway)
            }
            Rule()
            Line("Let a script drive mnml", "A local socket for testing. Its tabs open beside yours with a flask on them and never take over — see ./bench") {
                Switch(on: $prefs.bench)
            }
        }
    }

    /// Checked when it's saved, not as it's typed into the list: a shortcut
    /// only exists once its address is one it's safe to send words to.
    private var draftProblem: String? {
        guard let draft else { return nil }
        return Keyword.problem(word: draft.keyword, template: draft.template, among: prefs.keywords)
    }

    private var keywordDetail: String {
        guard let draft else {
            return "A word before your search goes straight to that site, whatever engine you've picked — \"yt cats\" to YouTube"
        }
        if draft.keyword.isEmpty, draft.template.isEmpty {
            return "A word, then the site's search address with %s where the words go"
        }
        return draftProblem ?? "\(draft.keyword.trimmingCharacters(in: .whitespacesAndNewlines)) will search \(draft.name)"
    }

    private func saveDraft() {
        guard let current = draft, draftProblem == nil else { return }
        prefs.keywords.append(Keyword(
            keyword: current.keyword.trimmingCharacters(in: .whitespacesAndNewlines),
            template: current.template.trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        draft = nil
    }

    private var searchDetail: String {
        guard prefs.engine == .custom else { return "Where words that aren't an address go" }
        guard Engine.accepts(prefs.customEngine) else {
            return "An http or https address with %s where the words go. Until then, Google"
        }
        return "Words go to \(prefs.engine.name(custom: prefs.customEngine))"
    }

    // MARK: - tabs

    private var tintAppearance: SpaceAppearance { browser.appearance(for: browser.appearanceSpace) }

    private var tintInherited: Bool {
        guard let id = browser.appearanceSpace else { return false }
        return browser.spaces.first(where: { $0.id == id })?.appearance == nil
    }

    private func tintBinding<Value>(_ key: WritableKeyPath<SpaceAppearance, Value>) -> Binding<Value> {
        Binding(get: { tintAppearance[keyPath: key] }, set: { value in
            browser.editAppearance(browser.appearanceSpace) { $0[keyPath: key] = value }
        })
    }

    private var tabs: some View {
        VStack(alignment: .leading, spacing: 18) {
        Card {
            Line("Tabs in a sidebar", "Down the left instead of across the top. Pull its edge to make it wider; double-click the edge to reset.") {
                Switch(on: Binding(
                    get: { prefs.sidebar },
                    set: { on in withAnimation(Motion.glide) { prefs.sidebar = on } }
                ))
            }
            if prefs.sidebar {
                Rule()
                Line("Hide the sidebar until the pointer reaches the edge", "The page takes the whole window; push against its left edge for the tabs. ⌘S keeps them out.") {
                    Switch(on: $prefs.sideHides)
                }
            }
            Rule()
            Line("New tabs open at", "The top of the list, under the pinned tabs, or the bottom. Across the top, the left or the right") {
                Segmented(options: NewTabs.allCases.map { ($0, $0.title) }, selection: $prefs.newTabs)
            }
            Rule()
            Line("Show the New tab button", "In the sidebar, where new tabs open. ⌘T makes one either way") {
                Switch(on: $prefs.showsNewTab)
            }
            Rule()
            Line("⌘T opens the command bar", "Type where to go over the page you're on, as in Arc: a tab is made when you press Return, and an open tab you name is switched to. Off, ⌘T opens a blank tab at once") {
                Switch(on: $prefs.commandBar)
            }
            Rule()
            Line("Tabs show", "Beside the title, and on a pinned square") {
                Segmented(options: Glyph.allCases.map { ($0, $0.title) }, selection: $prefs.glyph)
            }
            Rule()
            Line("Recently used tab switcher", "Control-Tab previews up to ten recent tabs. Use Tab or arrow keys while holding Control; release it to switch.") {
                Switch(on: $prefs.mruSwitcher)
                    .accessibilityRepresentation {
                        Toggle("Recently used tab switcher", isOn: $prefs.mruSwitcher)
                    }
            }
            Rule()
            Line("Group links you ⌘-click", "A link opened with ⌘-click goes in the background, in a new group with the page it came from — or into that page's group, if it has one. Groups show with tabs in a sidebar.") {
                Switch(on: $prefs.groupsLinks)
            }
            Rule()
            Line("Feel tabs as you drag them", "A tap of the trackpad as a tab passes another, a double one into or out of a group. Force Touch trackpads only.") {
                Switch(on: $prefs.dragHaptics)
            }
            Rule()
            Line("Show the bookmarks bar", "Your bookmarks in a row above the page, folders opening as menus. It folds away with the tabs") {
                Switch(on: $prefs.bookmarksBar)
            }
            Rule()
            Line("Show how far you've read", "The tab you're on fills with grey as you scroll down the page") {
                Switch(on: $prefs.showsReading)
            }
            Rule()
            Line("Slide the highlight between tabs", "The highlight glides to the tab you choose. Off, it moves at once") {
                Switch(on: $prefs.slidesHighlight)
            }
            Rule()
            Line("Mac window material", "The sidebar, or the bar across the top, in the Mac's own see-through material, as in Finder. Off, a flat colour") {
                Switch(on: $prefs.frostedSidebar)
            }
            Rule()
            Line("Appearance for") {
                Picker("Appearance for", selection: $browser.appearanceSpace) {
                    Text("Global").tag(UUID?.none)
                    ForEach(browser.spaces) { space in
                        Text(space.name).tag(Optional(space.id))
                    }
                }
                .labelsHidden()
                .frame(width: 160)
            }
            Rule()
            if let id = browser.appearanceSpace {
                Line("Use global appearance") {
                    Switch(on: Binding(get: { tintInherited }, set: { inherit in
                        browser.setAppearance(inherit ? nil : browser.globalAppearance, for: id)
                    }))
                }
                Rule()
            }
            Line("Tint", "A colour over the sidebar, or the bar across the top, with the material still showing through") {
                TintPicker(hex: tintBinding(\.light))
                    .disabled(tintInherited)
            }
            Rule()
            Line("Tint in dark mode") {
                TintPicker(hex: tintBinding(\.dark), offersSame: true)
                    .disabled(tintInherited)
            }
            Rule()
            if !tintAppearance.light.isEmpty || !["", Tint.same].contains(tintAppearance.dark) {
                Line("Tint strength") {
                    Slider(value: tintBinding(\.strength), in: Tint.strengths)
                        .disabled(tintInherited)
                        .frame(width: 160)
                }
                Rule()
            }
            // Only where WebKit can keep the page clear of the chrome: before
            // macOS 26 the switch would do nothing.
            if Under.possible {
                Line("Page under the sidebar", "The page runs on beneath the sidebar, or the bar across the top, its colours showing through the Mac window material as you scroll, as in Safari. Needs the material") {
                    Switch(on: $prefs.pageUnder)
                }
                Rule()
            }
            Line("Auto Archive", "Keep unused loose tabs in Archive. Pins, groups, splits, private pages and active work stay open.") {
                Switch(on: $prefs.archivesTabs)
            }
            if prefs.archivesTabs {
                Rule()
                Line("Archive after") {
                    Picker("Archive after", selection: $prefs.archivePeriod) {
                        ForEach(ArchivePeriod.allCases) { period in Text(period.title).tag(period) }
                    }.labelsHidden().pickerStyle(.menu).fixedSize()
                }
            }
            Rule()
            Line("Archived tabs", "Search and restore pages kept until you delete them.") {
                Pill("Open Archive") { browser.tuning = false; browser.archiveShowing = true }
            }
            Rule()
            Line("Sleep tabs you aren't using", "Automatically releases inactive pages. Open them again to reload. Sound, calls and unsent text stay awake. macOS may still reclaim pages under pressure.") {
                Switch(on: $prefs.sleepsTabs)
            }
            if prefs.sleepsTabs {
                Rule()
                Line("Tab memory", memoryProfileDetail) {
                    Picker("", selection: $prefs.tabMemoryProfile) {
                        ForEach(TabMemoryProfile.allCases) { profile in
                            Text(profile.title).tag(profile)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }
            Rule()
            Line("Load background tabs when you go to them", "A link opened behind the page, with ⌘-click or the middle button, or a batch of links from another app, waits until you go to its tab. ⇧⌘-click still takes you there at once.") {
                Switch(on: $prefs.lazyTabs)
            }
            Rule()
            Line("Search a site from the address field", "Type the start of a site's name, like red or yout, then Tab, and what you type next searches that site. Sites you visit that offer a search join the list.") {
                Switch(on: $prefs.searchesSites)
            }
            Rule()
            Line("Start with a fresh window", "Each time Search opens, your pinned tabs are there and last time's other tabs aren't.") {
                Switch(on: $prefs.startsFresh)
            }
            Rule()
            if prefs.sidebar {
                Line("Pinned rows", "Keep pinned pages as rows beneath the pinned squares") {
                    Switch(on: $prefs.listsPins)
                }
                Rule()
            }
            Line("Spaces", "Separate sets of tabs, signed in where the others are or starting afresh, switched with ⌃1–⌃9, two fingers sideways over the column, or the space's icon. Mission Control's own ⌃1–⌃9, if you turned them on, take those keys first.") {
                Switch(on: $prefs.usesSpaces)
            }
        }
        TabMemory(browser: browser)
        }
    }

    private var memoryProfileDetail: String {
        switch prefs.tabMemoryProfile {
        case .saver: "Sleep after 30 minutes (2 hours pinned), or beyond 10 recent unpinned tabs. Background pages over 2 GB sleep."
        case .balanced: "Sleep after 2 hours (6 hours pinned), or beyond 20 recent unpinned tabs. Background pages over 4 GB sleep."
        case .keepLonger: "Sleep after 8 hours (24 hours pinned), or beyond 40 recent unpinned tabs. Background pages over 6 GB sleep."
        }
    }

    // MARK: - passwords

    /// Says so when a password manager extension has taken the saving over.
    private var savingDetail: String {
        if #available(macOS 15.4, *), let name = Extensions.shared.passwordSavingTakenBy {
            return "\(name) does the saving — it asked mnml not to offer"
        }
        return "Asked once per site, never again for a site you refuse"
    }

    private var passwords: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card {
                Line("Your passwords", "In the macOS keychain, shown with Touch ID") {
                    Pill("Open…") {
                        browser.tuning = false
                        browser.managing = true
                    }
                }
                Rule()
                Line("Offer to save passwords", savingDetail) {
                    Switch(on: $prefs.savesPasswords)
                }
                Rule()
                Line("Fill in sign-ins", "Click a sign-in box and the accounts kept for the site hang from it") {
                    Switch(on: $prefs.fillsPasswords)
                }
                Rule()
                Line(
                    "Offer passkeys",
                    !prefs.passkeysPossible
                        ? "Needs an Apple entitlement this build doesn't have — off keeps sites to the password"
                        : Passkeys.access == .denied
                        ? "macOS was told no — System Settings › Privacy & Security › Passkeys Access for Web Browsers"
                        : "Touch ID or an iCloud passkey, on sites that offer one"
                ) {
                    Switch(on: $prefs.passkeys)
                }
                if LockKey.kept || LockKey.declined {
                    Rule()
                    Line("Unlock 1Password with Touch ID",
                         LockKey.kept ? "Its password is kept in this Mac's keychain and typed in after Touch ID"
                                      : "Turned down — it will be offered again the next time you unlock 1Password") {
                        Pill(LockKey.kept ? "Forget" : "Offer again") {
                            LockKey.forget()
                            LockKey.declined = false
                            browser.announce("1Password's password forgotten")
                        }
                    }
                }
                if !Vault.never.isEmpty {
                    Rule()
                    Line("Sites never asked", "\(Vault.never.count) sites told to stop offering") {
                        Pill("Forget") {
                            Vault.never = []
                            browser.announce("Every site can ask again")
                        }
                    }
                }
            }
            Card {
                Line("Bring yours in", "From another browser on this Mac — nothing leaves it") {
                    Pill("Import…") {
                        browser.tuning = false
                        browser.bringingIn = ""
                    }
                }
            }
        }
    }

    // MARK: - downloads

    private var downloads: some View {
        Card {
            Line("Save to", prefs.downloads.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                Pill("Change…") { chooseFolder() }
            }
            Rule()
            Line("Ask where to save each file") {
                Switch(on: $prefs.asksWhereToSave)
            }
            Rule()
            Line("Always show the downloads button", "Beside the other buttons, even with nothing downloading. Off, it shows only while a file comes in") {
                Switch(on: $prefs.alwaysShowsDownloads)
            }
        }
    }

    // MARK: - privacy

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card {
                Line("Block ads and trackers", shield.trouble ?? "Third parties whose only job is to watch") {
                    Switch(on: $prefs.shielded)
                }
                if let trouble = shield.trouble {
                    Rule()
                    Line(trouble, "Nothing is being blocked until this clears — try again, or restart mnml") {
                        Pill("Try again") { shield.compile() }
                    }
                }
                if let host = browser.hereHost, prefs.shielded, shield.trouble == nil {
                    Rule()
                    Line("Block on \(host)", "Turn off here if the site breaks — the page reloads") {
                        Switch(on: Binding(
                            get: { !Shield.shared.isPaused(on: host) },
                            set: { on in
                                Shield.shared.pause(host, !on)
                                browser.reload()
                            }
                        ))
                    }
                }
                Rule()
                Line("Prevent cross-site tracking", "As in Safari. Off, sites you rarely open keep their sign-ins, and trackers inside other sites can follow you across them again, as in Chrome. Private tabs keep it on") {
                    Switch(on: Binding(get: { !prefs.keepsSignIns }, set: { prefs.keepsSignIns = !$0 }))
                }
                Rule()
                Line("Camera, microphone, location and notifications", "What each site was allowed or refused") {
                    Pill("Forget choices") { browser.forgetCaptureChoices() }
                }
                Rule()
                Line("Let sites ask to send notifications", "A site asks on a card over its page, and only one you allow reaches your Mac's notifications. Private tabs are never asked") {
                    Switch(on: $prefs.siteNotifications)
                }
                NotificationSites()
            }
            Card {
                Line("History", "Every address you have been to") {
                    Pill("Clear") { browser.clearHistory() }
                }
                Rule()
                Line("Cookies and sign-ins", "Signs you out of every site") {
                    Pill("Sign out of everything") { browser.clearSites() }
                }
                Rule()
                Line("Cache", "Only what was fetched to draw pages") {
                    Pill("Clear") { browser.clearCache() }
                }
            }
        }
    }

    // MARK: - about

    private var about: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Logomark(stacked: true)
                    .fill(Palette.ink)
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text("mnml")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Text("by farchan, based on Search by Office Commun · version \(Updater.version)")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                }
            }
            .padding(.bottom, 2)

            Card {
                Line(versionTitle, versionDetail) { versionControl }
                Rule()
                Line("Install updates on its own", "Off, mnml still looks once a day and tells you, and installs only when you press Install") {
                    Switch(on: $prefs.installsUpdates)
                }
                Rule()
                Line("Found something wrong?", "Opens a GitHub issue with the version already in it") {
                    Pill("Send Feedback") { Links.writeFeedback() }
                }
                Rule()
                Line("What's new", "Every version's notes, newest first") {
                    Pill("What's New…") { browser.notesShowing = true }
                }
            }
        }
    }

    /// The version line follows the newer build from found to fetched to
    /// in place; with none, it is simply this one.
    private var versionTitle: String {
        switch updater.stage {
        case .none: return "Updates"
        case .fetching(let next): return "mnml \(next.version) is downloading…"
        case .ready(let next): return "mnml \(next.version) is ready"
        case .offered(let next), .waiting(let next): return "mnml \(next.version) is out"
        }
    }

    private var versionDetail: String {
        switch updater.stage {
        case .none:
            return updater.lastChecked.map { "Checked \($0.formatted(.relative(presentation: .named))) — every hour on its own" }
                ?? "Checked every hour on its own"
        case .fetching(let next):
            return next.notes ?? "Quietly, in the background — nothing you have set is touched"
        case .ready(let next):
            return next.notes ?? "It's there the next time you open mnml"
        case .offered(let next):
            return next.notes ?? "Open the disk image, the same as the first time"
        case .waiting(let next):
            return next.notes ?? "Checked and put in place when you press Install"
        }
    }

    @ViewBuilder
    private var versionControl: some View {
        switch updater.stage {
        case .none:
            Pill(updater.checking ? "Checking…" : "Check now") {
                updater.check { found in
                    if found == nil { browser.announce("This is the latest one") }
                }
            }
            .disabled(updater.checking)
        case .fetching:
            Ring(size: 12)
        case .ready:
            Pill("Relaunch now", filled: true) { updater.relaunch() }
        case .offered:
            Pill(updater.fetchingDisk ? "Downloading…" : "Download", filled: true) { updater.openDisk() }
                .disabled(updater.fetchingDisk)
        case .waiting:
            Pill("Install", filled: true) { updater.install() }
        }
    }

    // MARK: - doing

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = prefs.downloads
        panel.prompt = "Use this folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        prefs.downloads = url
    }

}

/// A row of choices in a grey track, one of them lifted out in white. The
/// white slides to the one you pick rather than appearing there.
struct Segmented<Option: Hashable>: View {
    let options: [(Option, String)]
    @Binding var selection: Option
    /// True when the control has the whole width to itself, so the choices
    /// share it evenly instead of each taking only what its word needs.
    var wide = false

    @Namespace private var slide

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { option, title in
                Text(title)
                    .font(.system(size: 11.5, weight: option == selection ? .medium : .regular))
                    .foregroundStyle(option == selection ? Palette.ink : Palette.muted)
                    .lineLimit(1)
                    .fixedSize(horizontal: !wide, vertical: false)
                    .frame(maxWidth: wide ? .infinity : nil)
                    .padding(.horizontal, wide ? 4 : 10)
                    .padding(.vertical, 5)
                    .background {
                        if option == selection {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Palette.ground)
                                .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                                .matchedGeometryEffect(id: "chosen", in: slide)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .onTapGesture {
                        withAnimation(Motion.settle) { selection = option }
                    }
            }
        }
        .padding(2)
        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .animation(Motion.settle, value: selection)
    }
}

/// On or off, in ink rather than in blue.
struct Switch: View {
    @Binding var on: Bool

    var body: some View {
        Capsule()
            .fill(on ? Palette.ink : Palette.faint)
            .frame(width: 30, height: 18)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle()
                    .fill(Palette.ground)
                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                    .padding(2)
            }
            .contentShape(Capsule())
            .onTapGesture { withAnimation(Motion.settle) { on.toggle() } }
            .animation(Motion.settle, value: on)
    }
}

/// A value moved one stop at a time: − and + either side of it, in the same
/// outlined capsule as a pill. Pressing the value itself takes it home.
struct Steps: View {
    let stops: [Double]
    @Binding var value: Double
    let home: Double
    let label: (Double) -> String

    /// The nearest stop either way — a value between stops, from before
    /// there were stops, still moves to a round one.
    private var below: Double? { stops.last { $0 < value - 0.001 } }
    private var above: Double? { stops.first { $0 > value + 0.001 } }

    var body: some View {
        HStack(spacing: 0) {
            Step(icon: "minus", to: below) { value = $0 }
            Button { value = home } label: {
                Text(label(value))
                    .font(.system(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(Palette.ink)
                    .frame(minWidth: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back to \(label(home))")
            Step(icon: "plus", to: above) { value = $0 }
        }
        .padding(.horizontal, 2)
        .frame(height: 24)
        .background(Palette.ground, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
    }

    private struct Step: View {
        let icon: String
        let to: Double?
        let act: (Double) -> Void
        @State private var hovering = false

        var body: some View {
            Button { if let to { act(to) } } label: {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(to == nil ? Palette.faint : Palette.ink)
                    .frame(width: 20, height: 20)
                    .background(hovering && to != nil ? Palette.hover : .clear, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(to == nil)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
        }
    }
}

/// A small capsule that does one thing. Outlined by default; filled in ink
/// when it is the thing you came here to press.
struct Pill: View {
    let title: String
    var filled = false
    var tint: Color = Palette.ink
    let action: () -> Void

    @State private var hovering = false

    init(_ title: String, filled: Bool = false, tint: Color = Palette.ink, action: @escaping () -> Void) {
        self.title = title
        self.filled = filled
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(filled ? Palette.ground : tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(filled ? Palette.ink : (hovering ? Palette.hover : Palette.ground), in: Capsule())
                .overlay(Capsule().strokeBorder(filled ? .clear : Palette.hairline, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
    }
}

/// The awake tabs, heaviest first, each with what its page holds and a way
/// to put it to sleep — Chrome's Task Manager, for the tabs (Memory.swift).
struct TabMemory: View {
    @ObservedObject var browser: Browser

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            let rows = (browser.tabs + browser.parkedTabs)
                .filter { !$0.asleep }
                .compactMap { tab in tab.footprint.map { (tab, $0) } }
                .sorted { $0.1 > $1.1 }
                .prefix(10)
            Card {
                Line("Memory", rows.isEmpty ? "No page is open" : "The awake tabs, heaviest first. Tabs that share a page's process each show all of it.") {
                    EmptyView()
                }
                ForEach(Array(rows), id: \.0.id) { tab, size in
                    Rule()
                    Line(tab.label, Browser.gigabytes(size)) {
                        if let why = browser.awake(because: tab) {
                            Text(why).font(.system(size: 11.5)).foregroundStyle(Palette.muted)
                        } else {
                            Pill("Sleep") { browser.sleep(tab) }
                        }
                    }
                }
            }
        }
    }
}

/// Settings › AI: the chosen provider key the chat beside a page uses (Ask.swift),
/// which model, where the chat shows, and the chats kept.
private struct AISettings: View {
    @ObservedObject var prefs: Preferences
    @State private var key: String?
    @State private var keyLoaded = false
    @State private var typed = ""
    @State private var customModel = ""
    @State private var changing = false
    @State private var kept = Chat.history().count

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card {
                Line("Provider", "Ask sends the page and attachments directly to this provider. Groq and Gemini have limited free tiers; OpenAI and Anthropic may charge.") {
                    Picker("", selection: $prefs.askProvider) {
                        ForEach(AIProvider.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                Rule()
                Line("\(prefs.askProvider.title) key", "Stored in this Mac's Keychain") {
                    if !keyLoaded {
                        ProgressView().controlSize(.small)
                    } else if let key, !changing {
                        HStack(spacing: 6) {
                            Text("••••\(key.suffix(4))").font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.muted)
                            Pill("Change") { changing = true }
                            Pill("Remove") {
                                let provider = prefs.askProvider
                                Task {
                                    await AIKey.keepAsync("", for: provider)
                                    let saved = await AIKey.readAsync(provider)
                                    if prefs.askProvider == provider { self.key = saved }
                                }
                            }
                        }
                    } else {
                        Link("Get a key", destination: prefs.askProvider.keyURL)
                            .font(.system(size: 12))
                    }
                }
                if keyLoaded && (key == nil || changing) {
                    HStack(spacing: 6) {
                        SecureField("Paste the key", text: $typed)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(Palette.wash, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .onSubmit(save)
                        Pill("Save", filled: true, action: save)
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 11)
                }
                Rule()
                Line("Model", "Custom IDs start as text-only; curated models have verified attachment support") {
                    Picker("", selection: $prefs.askModel) {
                        ForEach(prefs.askProvider.models) { choice in Text(choice.title).tag(choice.id) }
                        if !prefs.askProvider.models.contains(where: { $0.id == prefs.askModel }) {
                            Text("Custom: \(prefs.askModel)").tag(prefs.askModel)
                        }
                    }
                    .labelsHidden().fixedSize()
                    .onChange(of: prefs.askModel) { _, model in
                        customModel = prefs.askProvider.models.contains(where: { $0.id == model }) ? "" : model
                    }
                }
                HStack(spacing: 6) {
                    TextField("Custom model ID", text: $customModel)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .padding(7)
                        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 9))
                        .onSubmit(saveModel)
                    Pill("Use Model", action: saveModel)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 11)
                Rule()
                Line("Chat shows", "⌘E on a page. ⇧⌘E opens a chat in a new tab of its own") {
                    Segmented(options: AskMode.allCases.map { ($0, $0.title) }, selection: $prefs.askMode)
                }
            }
            Card {
                Line("Past chats", kept == 0 ? "None kept yet" : "\(kept) kept on this Mac") {
                    Pill("Delete All…") {
                        let alert = NSAlert()
                        alert.messageText = "Delete all past chats?"
                        alert.informativeText = "They can't be brought back. Chats open on tabs stay until you close them."
                        alert.addButton(withTitle: "Delete All")
                        alert.addButton(withTitle: "Cancel")
                        guard alert.runModal() == .alertFirstButtonReturn else { return }
                        Chat.forgetAll()
                        kept = 0
                    }
                    .disabled(kept == 0)
                }
            }
        }
        .task(id: prefs.askProvider) {
            keyLoaded = false
            key = nil
            changing = false
            typed = ""
            customModel = prefs.askProvider.models.contains(where: { $0.id == prefs.askModel }) ? "" : prefs.askModel
            let provider = prefs.askProvider
            let saved = await AIKey.readAsync(provider)
            if !Task.isCancelled {
                key = saved
                keyLoaded = true
            }
        }
    }

    private func save() {
        guard !typed.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let value = typed
        let provider = prefs.askProvider
        Task {
            await AIKey.keepAsync(value, for: provider)
            let saved = await AIKey.readAsync(provider)
            guard prefs.askProvider == provider else { return }
            key = saved
            if saved != nil {
                typed = ""
                changing = false
            }
        }
    }

    private func saveModel() {
        let id = customModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        prefs.askModel = id
    }
}

/// The tint's swatches, none first, and the Mac's colour picker for any other.
struct TintPicker: View {
    @Binding var hex: String
    /// The dark mode's row: first, following the light tint.
    var offersSame = false

    var body: some View {
        HStack(spacing: 7) {
            if offersSame {
                Button { hex = Tint.same } label: {
                    Text("Same")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.ink)
                        .padding(.horizontal, 7)
                        .frame(height: 22)
                        .overlay { Capsule().strokeBorder(hex == Tint.same ? Palette.ink : Palette.muted, lineWidth: hex == Tint.same ? 1.5 : 1) }
                }
                .buttonStyle(.plain)
                .help("As in light mode")
            }
            ForEach(Tint.presets, id: \.self) { preset in
                Button { hex = preset } label: { swatch(preset) }
                    .buttonStyle(.plain)
                    .help(preset.isEmpty ? "No tint" : "#\(preset)")
            }
            // A colour of your own; chosen, it is the one ringed.
            ColorPicker("", selection: Binding(
                get: { Tint.color(hex) ?? .gray },
                set: { hex = Tint.hex($0) }
            ), supportsOpacity: false)
            .labelsHidden()
            .overlay { if !hex.isEmpty && hex != Tint.same && !Tint.presets.contains(hex) { ring } }
        }
    }

    private func swatch(_ preset: String) -> some View {
        ZStack {
            if let color = Tint.color(preset) {
                Circle().fill(color)
            } else {
                Circle().strokeBorder(Palette.muted, lineWidth: 1)
                Rectangle().fill(Palette.muted).frame(width: 1, height: 14).rotationEffect(.degrees(45))
            }
        }
        .frame(width: 16, height: 16)
        .padding(3)
        .overlay { if hex == preset { ring } }
    }

    private var ring: some View {
        Circle().strokeBorder(Palette.ink, lineWidth: 1.5)
    }
}

/// Settings › Privacy: the sites allowed to send notifications, each with a
/// way to take it back.
private struct NotificationSites: View {
    @ObservedObject private var notifications = SiteNotifications.shared

    var body: some View {
        let sites = SiteNotifications.allowed
        if !sites.isEmpty {
            ForEach(sites, id: \.self) { site in
                Rule()
                Line(URL(string: site).map(SiteCard.site) ?? site, "Can send notifications") {
                    Pill("Remove") { SiteNotifications.forget(site) }
                }
            }
        }
    }
}
