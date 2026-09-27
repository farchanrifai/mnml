import AppKit
import SwiftUI

// Every command mnml has a key for, in one list: the menus draw from it, the
// key monitor dispatches from it, and Settings › Shortcuts changes it. What
// changes is kept as overrides on top of the defaults, so a browser nobody
// has customised behaves exactly as it always did.

/// A key and the modifiers held with it.
struct KeyCombo: Codable, Hashable {
    /// A lowercased character, or the name of a key that has none:
    /// left, right, up, down, tab, return, delete, escape, space, f1…f12.
    var key: String
    var command = false
    var shift = false
    var option = false
    var control = false

    init(_ key: String, command: Bool = true, shift: Bool = false, option: Bool = false, control: Bool = false) {
        (self.key, self.shift) = KeyCombo.canonical(key.lowercased(), shift: shift)
        self.command = command
        self.option = option
        self.control = control
    }

    /// The key an event pressed, read the way the keyboard's own layout
    /// names it with nothing held — so ⇧⌘] is "]" with shift, not "}".
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // The top row by where it sits: on AZERTY and many other layouts it
        // types &, é, "… so ⌘1 has to be the key, not the character.
        let named = KeyCombo.names[event.keyCode] ?? ContentView.digits[event.keyCode].map(String.init)
        guard let key = named ?? event.characters(byApplyingModifiers: [])?.lowercased() ?? event.charactersIgnoringModifiers?.lowercased(),
              !key.isEmpty
        else { return nil }
        self.init(key, command: flags.contains(.command), shift: flags.contains(.shift),
                  option: flags.contains(.option), control: flags.contains(.control))
    }

    /// ⌘+ is ⇧⌘= on some keyboards and a key of its own on others; both
    /// mean the same thing, so both are kept as "+" with nothing about ⇧.
    private static func canonical(_ key: String, shift: Bool) -> (String, Bool) {
        key == "=" || key == "+" ? ("+", false) : (key, shift)
    }

    private static let names: [UInt16: String] = [
        123: "left", 124: "right", 125: "down", 126: "up", 48: "tab", 36: "return", 76: "return",
        51: "delete", 117: "delete", 53: "escape", 49: "space",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8",
        101: "f9", 109: "f10", 103: "f11", 111: "f12",
    ]

    private static let symbols: [String: String] = [
        "left": "←", "right": "→", "up": "↑", "down": "↓", "tab": "⇥", "return": "↩",
        "delete": "⌫", "escape": "⎋", "space": "Space",
    ]

    /// As a menu shows it: ⌃⌥⇧⌘ then the key.
    var display: String {
        var text = ""
        if control { text += "⌃" }
        if option { text += "⌥" }
        if shift { text += "⇧" }
        if command { text += "⌘" }
        return text + (KeyCombo.symbols[key] ?? key.uppercased())
    }

    var isFunctionKey: Bool { key.count > 1 && key.hasPrefix("f") && Int(key.dropFirst()) != nil }

    /// A key alone, or with only ⇧, is typing — never a shortcut here.
    var isUsable: Bool { command || option || control || isFunctionKey }

    var swiftUI: KeyboardShortcut? {
        let equivalent: KeyEquivalent
        switch key {
        case "left": equivalent = .leftArrow
        case "right": equivalent = .rightArrow
        case "up": equivalent = .upArrow
        case "down": equivalent = .downArrow
        case "tab": equivalent = .tab
        case "return": equivalent = .return
        case "delete": equivalent = .delete
        case "escape": equivalent = .escape
        case "space": equivalent = .space
        default:
            if isFunctionKey, let n = Int(key.dropFirst()), let scalar = UnicodeScalar(NSF1FunctionKey + n - 1) {
                equivalent = KeyEquivalent(Character(scalar))
            } else if let character = key.first, key.count == 1 {
                equivalent = KeyEquivalent(character)
            } else {
                return nil
            }
        }
        var modifiers: EventModifiers = []
        if command { modifiers.insert(.command) }
        if shift { modifiers.insert(.shift) }
        if option { modifiers.insert(.option) }
        if control { modifiers.insert(.control) }
        return KeyboardShortcut(equivalent, modifiers: modifiers)
    }

    /// macOS's own, and the ones every text field relies on. Not ours to give away.
    static let reserved: Set<KeyCombo> = [
        KeyCombo("q"), KeyCombo("h"), KeyCombo("m"), KeyCombo("c"), KeyCombo("v"), KeyCombo("x"),
        KeyCombo("a"), KeyCombo("z"), KeyCombo("z", shift: true), KeyCombo("`"), KeyCombo("h", option: true),
    ]
}

/// Who gets a key that mnml and the page both want.
enum Conflict: String, Codable, CaseIterable, Identifiable {
    case mnmlFirst, websiteFirst, prompt
    var id: String { rawValue }
    var title: String {
        switch self {
        case .mnmlFirst: return "Use mnml First"
        case .websiteFirst: return "Use Website First"
        case .prompt: return "Prompt After Using on Website"
        }
    }
}

/// Something mnml does, and the key it does it on unless told otherwise.
struct Command: Identifiable {
    enum Section: String, CaseIterable {
        case app = "mnml", file = "File", edit = "Edit", view = "View", tabs = "Tabs", bookmarks = "Bookmarks", history = "History"
    }

    let id: String
    let title: String
    let detail: String
    let section: Section
    let defaultKey: KeyCombo?
    /// False means "not now": the key goes on to whoever else wants it.
    let run: @MainActor (Browser) -> Bool

    /// For commands that always do something.
    init(_ id: String, _ title: String, _ section: Section, _ key: KeyCombo?, _ detail: String,
         _ act: @escaping @MainActor (Browser) -> Void) {
        self.id = id
        self.title = title
        self.section = section
        self.defaultKey = key
        self.detail = detail
        self.run = { browser in act(browser); return true }
    }

    private init(id: String, title: String, section: Section, key: KeyCombo?, detail: String,
                 run: @escaping @MainActor (Browser) -> Bool) {
        self.id = id
        self.title = title
        self.section = section
        self.defaultKey = key
        self.detail = detail
        self.run = run
    }

    /// For commands that only sometimes have something to do.
    static func when(_ id: String, _ title: String, _ section: Section, _ key: KeyCombo?, _ detail: String,
                     _ run: @escaping @MainActor (Browser) -> Bool) -> Command {
        Command(id: id, title: title, section: section, key: key, detail: detail, run: run)
    }

    static func named(_ id: String) -> Command? { byID[id] }
    private static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static let all: [Command] = {
        var list: [Command] = [
            Command("app.settings", "Settings…", .app, KeyCombo(","), "Opens Settings, or closes it.") { $0.tuning.toggle() },
            Command("app.passwords", "Passwords…", .app, KeyCombo("l", option: true), "Your saved passwords, shown with Touch ID.") { $0.managing = true },
            Command("app.welcome", "Welcome…", .app, nil, "The first-launch walk-through again.") { $0.welcoming = true },

            Command("file.newTab", "New Tab", .file, KeyCombo("t"), "Opens a blank tab.") { $0.newTab() },
            Command("file.newPrivateTab", "New Private Tab", .file, KeyCombo("n", shift: true), "A tab that keeps no history and no cookies once closed.") { $0.newShyTab() },
            Command("file.reopen", "Reopen Closed Tab", .file, KeyCombo("t", shift: true), "Brings back the tab you closed last.") { $0.reopen() },
            Command("file.openAddress", "Open Address…", .file, KeyCombo("l"), "Puts the address field up to type where to go.") { $0.edit() },
            .when("file.openPeek", "Open Peek as Tab", .file, KeyCombo("o"), "Keeps the peek as a regular tab.") { browser in
                guard browser.peekTab != nil else { return false }
                browser.keepPeek()
                return true
            },
            Command("file.closeTab", "Close Tab", .file, KeyCombo("w"), "Closes the tab you're on.") { browser in
                if let tab = browser.active { browser.close(tab) }
            },
            Command("file.print", "Print…", .file, KeyCombo("p"), "Prints the page.") { $0.printPage() },

            Command("edit.find", "Find on Page…", .edit, KeyCombo("f"), "Looks for words on the page.") { $0.openFind() },
            Command("edit.findNext", "Find Next", .edit, KeyCombo("g"), "The next match of what you're looking for.") { $0.look(forward: true) },
            Command("edit.findPrevious", "Find Previous", .edit, KeyCombo("g", shift: true), "The match before this one.") { $0.look(forward: false) },

            Command("view.sidebar", "Show Tabs in Sidebar", .view, KeyCombo("s", shift: true), "Tabs down the left, or across the top.") { $0.toggleSidebar() },
            Command("view.fold", "Hide Sidebar or Tab Bar", .view, KeyCombo("s"), "Folds the column of tabs, or the strip across the top, away so the page has the whole window; the edge brings it back.") { $0.toggleFold() },
            Command("view.inspector", "Web Inspector", .view, KeyCombo("i", option: true), "The page's code, styles and network, beside it.") { $0.toggleInspector() },
            Command("view.console", "JavaScript Console", .view, KeyCombo("j", option: true), "The Web Inspector, open at its console.") { $0.showConsole() },
            Command("view.inspect", "Inspect Element", .view, KeyCombo("c", option: true), "Point at something on the page to see it in the Web Inspector.") { $0.inspectElement() },
            Command("view.askNew", "New AI Chat", .view, KeyCombo("e", shift: true), "A chat in a new tab of its own, about no page until you add one with @.") { $0.newChatTab() },
            Command("view.ask", "Ask About This Tab", .view, KeyCombo("e"), "A chat beside the page about what's on it, this tab's own.") { $0.toggleAsk() },
            Command("view.reload", "Reload Page", .view, KeyCombo("r"), "Loads the page again.") { $0.reload() },
            Command("view.reloadOrigin", "Reload Page From Origin", .view, KeyCombo("r", option: true), "Loads the page again, nothing from the cache, as Safari's ⌥⌘R.") { $0.reload(fromOrigin: true) },
            Command("view.reader", "Reading Mode", .view, KeyCombo("r", shift: true), "Just the article, set for reading.") { $0.toggleReader() },
            Command("view.float", "Float Video", .view, KeyCombo("p", shift: true), "The video on this page in a window of its own, above everything.") { $0.toggleFloat() },
            Command("view.hide", "Hide Elements…", .view, KeyCombo("h", shift: true), "Click anything on the page to hide it, on this site from then on.") { $0.toggleHiding() },
            Command("view.hidden", "Hidden on This Site…", .view, KeyCombo("u", shift: true), "What you've hidden here, to put back.") { $0.reviewing.toggle() },
            Command("view.zoomIn", "Zoom In", .view, KeyCombo("+"), "Makes the page bigger.") { $0.zoom(by: 1.1) },
            Command("view.zoomOut", "Zoom Out", .view, KeyCombo("-"), "Makes the page smaller.") { $0.zoom(by: 1 / 1.1) },
            Command("view.actualSize", "Actual Size", .view, KeyCombo("0"), "The page at its own size.") { $0.resetZoom() },

            Command("tabs.back", "Back", .tabs, KeyCombo("["), "The page before this one.") { $0.back() },
            Command("tabs.forward", "Forward", .tabs, KeyCombo("]"), "The page after this one.") { $0.forward() },
            // Not while typing: there ⌘← and ⌘→ move the caret, in a page's
            // fields and the browser's own alike.
            .when("tabs.backArrow", "Back (Arrow)", .tabs, KeyCombo("left"), "Back, for hands that never learned the brackets.") { browser in
                guard !browser.editingText else { return false }
                browser.back()
                return true
            },
            .when("tabs.forwardArrow", "Forward (Arrow)", .tabs, KeyCombo("right"), "Forward, for hands that never learned the brackets.") { browser in
                guard !browser.editingText else { return false }
                browser.forward()
                return true
            },
            Command("tabs.next", "Next Tab", .tabs, KeyCombo("]", shift: true), "The tab to the right, round to the first.") { $0.step(1) },
            Command("tabs.previous", "Previous Tab", .tabs, KeyCombo("[", shift: true), "The tab to the left, round to the last.") { $0.step(-1) },
            Command("tabs.search", "Search Tabs…", .tabs, KeyCombo("k"), "Finds an open tab by name. Held down, each press steps down the list; letting go of ⌘ goes there.") { browser in
                if browser.editing, !browser.offers.isEmpty { browser.stepSummon() } else { browser.summon() }
            },
            .when("tabs.pin", "Pin Tab", .tabs, nil, "Keeps the tab at the front of the row, as a letter or its icon.") { browser in
                guard let tab = browser.active, tab.pin == nil, !tab.isBlank else { return false }
                browser.pin(tab)
                return true
            },
            .when("tabs.unpin", "Unpin Tab", .tabs, nil, "Puts a pinned tab back in the row.") { browser in
                guard let tab = browser.active, tab.pin != nil else { return false }
                browser.unpin(tab)
                return true
            },
            .when("tabs.letter", "Change Letter", .tabs, nil, "The letter a pinned tab shows.") { browser in
                guard let tab = browser.active, tab.pin != nil else { return false }
                browser.editLetter(tab)
                return true
            },
            .when("tabs.newInGroup", "New Tab in Group", .tabs, KeyCombo("t", option: true), "A blank tab at the end of the group the tab you're on is in.") { browser in
                guard let group = browser.active?.group else { return false }
                browser.newTab(in: group)
                return true
            },
            .when("tabs.groupSelected", "New Group from Tabs", .tabs, nil, "A group of the tabs picked with ⌘-click, or of the tab you're on.") { browser in
                let tabs = browser.chosen.isEmpty ? browser.active.map { [$0] } ?? [] : browser.chosenTabs
                return browser.makeGroup(of: tabs) != nil
            },
            .when("tabs.toggleGroup", "Collapse or Expand Group", .tabs, nil, "Folds the group the tab you're on is in, keeping that tab showing, or opens it.") { browser in
                guard let group = browser.active?.group else { return false }
                browser.toggleOpen(group)
                return true
            },
            .when("tabs.rename", "Rename Tab", .tabs, nil, "Gives the tab a name of your own, kept whatever page it shows.") { browser in
                guard let tab = browser.active else { return false }
                browser.beginTabRename(tab)
                return true
            },
            Command("tabs.duplicate", "Duplicate Tab", .tabs, KeyCombo("d"), "The same page again, in a tab beside this one.") { $0.duplicate() },
            Command("tabs.copyAddress", "Copy Address", .tabs, KeyCombo("c", shift: true), "The page's address, on the clipboard.") { $0.copyAddress() },
            Command("tabs.pasteAndGo", "Paste and Go", .tabs, KeyCombo("v", shift: true), "Goes to the address, or searches for the words, on the clipboard, in a new tab. While typing, pastes without formatting instead.") { browser in
                // In a text field this key is paste without formatting — a
                // Google Doc, a form, the address field. A web view has an
                // input context only while the caret is in something editable.
                let window = NSApp.keyWindow
                if browser.active?.typing == true || browser.active?.built?.inputContext != nil
                    || browser.editing || window?.firstResponder is NSTextView {
                    _ = window?.firstResponder?.tryToPerform(#selector(NSTextView.pasteAsPlainText(_:)), with: nil)
                } else {
                    browser.pasteAndGo()
                }
            },
            Command("tabs.closeOthers", "Close Other Tabs", .tabs, nil, "Closes every tab but this one.") { browser in
                if let tab = browser.active { browser.closeOthers(but: tab) }
            },
            Command("tabs.mute", "Stop Sound in Tab", .tabs, KeyCombo("m", shift: true), "Pauses whatever is playing in this tab.") { $0.pauseMedia() },
        ]
        for n in 1...8 {
            list.append(Command("tabs.select\(n)", "Select Tab \(n)", .tabs, KeyCombo("\(n)"), "Goes to tab \(n) in the row.") { $0.select(index: n - 1) })
        }
        list.append(Command("tabs.selectLast", "Select Last Tab", .tabs, KeyCombo("9"), "Goes to the last tab in the row, however many there are.") { browser in
            browser.select(index: browser.tabs.count - 1)
        })
        list += [
            Command("bookmarks.add", "Add This Page", .bookmarks, KeyCombo("b", shift: true), "Bookmarks the page you're on.") { $0.bookmarkCurrent() },
            Command("bookmarks.show", "Show Bookmarks…", .bookmarks, nil, "All your bookmarks, to open or tidy.") { $0.bookmarking = true },
            Command("history.show", "Show History…", .history, KeyCombo("y"), "Everywhere you've been, searchable.") { $0.recalling.toggle() },
            Command("history.downloads", "Downloads…", .history, KeyCombo("j", shift: true), "What you've downloaded.") { $0.hoarding.toggle() },
            Command("history.clearData", "Clear Browsing Data…", .history, KeyCombo("delete", shift: true), "History, cookies and the cache, each on its own.") { $0.recallMode = .clearing },
            Command("history.clear", "Clear History", .history, nil, "Forgets everywhere you've been.") { $0.clearHistory() },
        ]
        return list
    }()
}

/// What you've changed, on top of the defaults. Kept as overrides only, so
/// a new default in a later version reaches everyone who didn't change it.
@MainActor
final class ShortcutStore: ObservableObject {
    private struct Override: Codable, Equatable { var key: KeyCombo? }

    private let defaults: UserDefaults
    @Published private var keys: [String: Override]
    @Published private var conflicts: [String: Conflict]

    init(defaults: UserDefaults = Store.settings) {
        self.defaults = defaults
        let decoder = JSONDecoder()
        keys = defaults.data(forKey: "shortcuts.keys").flatMap { try? decoder.decode([String: Override].self, from: $0) } ?? [:]
        conflicts = defaults.data(forKey: "shortcuts.conflict").flatMap { try? decoder.decode([String: Conflict].self, from: $0) } ?? [:]
    }

    private func save() {
        let encoder = JSONEncoder()
        defaults.set(try? encoder.encode(keys), forKey: "shortcuts.keys")
        defaults.set(try? encoder.encode(conflicts), forKey: "shortcuts.conflict")
    }

    func key(for id: String) -> KeyCombo? {
        if let override = keys[id] { return override.key }
        return Command.named(id)?.defaultKey
    }

    /// Turned off on purpose — not merely a command that never had a key.
    func isDisabled(_ id: String) -> Bool { keys[id] != nil && keys[id]?.key == nil }

    func conflict(for id: String) -> Conflict { conflicts[id] ?? .mnmlFirst }

    func isModified(_ id: String) -> Bool { keys[id] != nil || conflicts[id] != nil }

    var anyModified: Bool { !keys.isEmpty || !conflicts.isEmpty }

    func command(matching combo: KeyCombo) -> Command? {
        Command.all.first { key(for: $0.id) == combo }
    }

    /// The command already on `combo`, other than `id`.
    func owner(of combo: KeyCombo, except id: String) -> Command? {
        Command.all.first { $0.id != id && key(for: $0.id) == combo }
    }

    /// `combo` for `id`, taken from whichever command had it.
    func assign(_ combo: KeyCombo, to id: String) {
        if let other = owner(of: combo, except: id) { store(nil, for: other.id) }
        store(combo, for: id)
        save()
    }

    func disable(_ id: String) {
        store(nil, for: id)
        save()
    }

    func setConflict(_ conflict: Conflict, for id: String) {
        conflicts[id] = conflict == .mnmlFirst ? nil : conflict
        save()
    }

    func setAllConflicts(_ conflict: Conflict) {
        conflicts = conflict == .mnmlFirst ? [:] : Dictionary(uniqueKeysWithValues: Command.all.map { ($0.id, conflict) })
        save()
    }

    /// Key and conflict setting both back to how they came.
    func reset(_ id: String) {
        keys[id] = nil
        conflicts[id] = nil
        save()
    }

    func resetAll() {
        keys = [:]
        conflicts = [:]
        save()
    }

    /// Only a difference from the default is kept.
    private func store(_ combo: KeyCombo?, for id: String) {
        let fallback = Command.named(id)?.defaultKey
        keys[id] = combo == fallback ? nil : Override(key: combo)
    }
}

/// Which of mnml and the page a shortcut goes to first.
enum KeyRoute: Equatable {
    /// mnml acts, the page never sees the key.
    case run
    /// The page gets it; mnml acts only if the page sends it back unused.
    case hand
}

extension KeyRoute {
    static func decide(_ conflict: Conflict, pageHasFocus: Bool) -> KeyRoute {
        pageHasFocus && conflict != .mnmlFirst ? .hand : .run
    }
}

/// A key handed to the page for it to use first, remembered until the page
/// either sends it back — then mnml acts on it — or keeps it.
@MainActor
final class KeyRouter {
    private var handed: (event: NSEvent, id: String)?
    /// Asked about once per launch, answered or not.
    private var asked: Set<String> = []

    /// Give the key to the page. WebKit answers a key the page didn't use by
    /// sending the same event back through the app, which `takeBack` catches.
    func hand(_ event: NSEvent, for id: String, to page: PageView, prompt: Bool, site: String?, ask: @escaping (String, String?) -> Void) {
        handed = (event, id)
        if event.modifierFlags.contains(.command) {
            _ = page.performKeyEquivalent(with: event)
        } else {
            page.keyDown(with: event)
        }
        // Not back by now: the page kept it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, let still = self.handed, PageView.same(still.event, event) else { return }
            self.handed = nil
            if prompt, !self.asked.contains(id) {
                self.asked.insert(id)
                ask(id, site)
            }
        }
    }

    /// The key the page just sent back unused: the command it was handed
    /// for, once.
    func takeBack(_ event: NSEvent) -> String? {
        guard let handed, PageView.same(handed.event, event) else { return nil }
        self.handed = nil
        return handed.id
    }
}

extension Browser {
    /// Text being typed into — a page's field, or one of the browser's own —
    /// where keys like ⌘← move the caret instead of the page. The page's own
    /// word on typing misses a click straight into a frame, and never reaches
    /// into another site's (an embedded comment box); the web view has an
    /// input context only while the caret is in something editable, in any
    /// frame (upstream #293).
    var editingText: Bool {
        active?.typing == true || active?.built?.inputContext != nil
            || NSApp.keyWindow?.firstResponder is NSTextView
    }
}
