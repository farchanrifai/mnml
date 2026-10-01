import Foundation

/// Words in the command bar; inline addresses retain exact, opt-in commands.
@MainActor
enum AddressCommand: Equatable {
    case settings, newTab, newPrivateTab, newSpace, bookmarks, history, downloads, passwords, toggleSidebar
    case openArchive, archiveTab, restoreArchived, routingSettings, pinTab, unpinTab, splitTab, separateSplit, keepPeek, splitPeek
    case moveSpace(UUID, String), switchSpace(UUID, String)

    static let inlineCases: [AddressCommand] = [.settings, .newTab, .newPrivateTab, .newSpace, .bookmarks,
        .history, .downloads, .passwords, .toggleSidebar]
    static let allCases = inlineCases + [.openArchive, .archiveTab, .restoreArchived, .routingSettings, .pinTab, .unpinTab, .splitTab, .separateSplit, .keepPeek, .splitPeek]

    var aliases: [String] {
        switch self {
        case .settings: return ["settings", "preferences"]
        case .openArchive: return ["open archive", "archived tabs"]
        case .archiveTab: return ["archive tab", "archive current tab"]
        case .restoreArchived: return ["restore archived tab", "restore last archived tab"]
        case .routingSettings: return ["routing settings", "link routing", "air traffic control"]
        case .newTab: return ["new tab"]
        case .newPrivateTab: return ["new private tab", "private tab"]
        case .newSpace: return ["new space"]
        case .bookmarks: return ["bookmarks"]
        case .history: return ["history"]
        case .downloads: return ["downloads"]
        case .passwords: return ["passwords"]
        case .toggleSidebar: return ["toggle sidebar", "sidebar"]
        case .pinTab: return ["pin tab", "pin current tab"]
        case .unpinTab: return ["unpin tab", "unpin current tab"]
        case .splitTab: return ["split page", "split tab", "split current page"]
        case .separateSplit: return ["separate split", "unsplit", "close split"]
        case .keepPeek: return ["open peek as tab", "keep peek", "open preview as tab"]
        case .splitPeek: return ["split peek", "split preview"]
        case .moveSpace(_, let name): return ["move tab to \(name)", "move to \(name)"]
        case .switchSpace(_, let name): return ["switch to \(name)", "switch space \(name)"]
        }
    }

    nonisolated var identity: String {
        switch self {
        case .moveSpace(let id, _): return "move " + id.uuidString
        case .switchSpace(let id, _): return "switch " + id.uuidString
        default: return String(describing: self)
        }
    }

    var title: String {
        switch self {
        case .moveSpace(_, let name): return "Move Tab to \(name)"
        case .switchSpace(_, let name): return "Switch to \(name)"
        default: return aliases[0].localizedCapitalized
        }
    }

    var symbol: String {
        switch self {
        case .settings: return "gearshape"
        case .openArchive, .archiveTab: return "archivebox"
        case .restoreArchived: return "arrow.uturn.backward"
        case .routingSettings: return "arrow.triangle.branch"
        case .newTab: return "plus"
        case .newPrivateTab: return "hand.raised"
        case .newSpace, .switchSpace: return "square.stack"
        case .bookmarks: return "bookmark"
        case .history: return "clock"
        case .downloads: return "arrow.down.circle"
        case .passwords: return "key"
        case .toggleSidebar: return "sidebar.left"
        case .pinTab, .unpinTab: return "pin"
        case .splitTab, .splitPeek: return "rectangle.split.2x1"
        case .separateSplit: return "rectangle"
        case .keepPeek: return "arrow.up.right.square"
        case .moveSpace: return "arrow.right.square"
        }
    }

    var shortcutID: String? {
        switch self {
        case .settings: return "app.settings"
        case .openArchive: return "history.archive"
        case .archiveTab: return "tabs.archive"
        case .restoreArchived: return "history.restoreArchive"
        case .routingSettings: return "app.linkRouting"
        case .newTab: return "file.newTab"
        case .newPrivateTab: return "file.newPrivateTab"
        case .bookmarks: return "bookmarks.show"
        case .history: return "history.show"
        case .downloads: return "history.downloads"
        case .passwords: return "app.passwords"
        case .toggleSidebar: return "view.sidebar"
        case .pinTab: return "tabs.pin"
        case .unpinTab: return "tabs.unpin"
        case .splitTab: return "tabs.split"
        case .separateSplit: return "tabs.unsplit"
        case .keepPeek: return "file.openPeek"
        case .splitPeek: return "file.splitPeek"
        default: return nil
        }
    }

    func available(in browser: Browser) -> Bool {
        let tab = browser.active
        switch self {
        case .archiveTab: return tab.map { browser.archiveReason($0, manual: true) == nil } == true && browser.peekTab == nil
        case .restoreArchived: return !ArchiveStore.shared.entries.isEmpty
        case .newSpace: return browser.prefs.usesSpaces
        case .pinTab: return browser.peekTab == nil && tab?.isBlank == false && tab?.pin == nil && tab?.bench == false && tab?.shy == false
        case .unpinTab: return browser.peekTab == nil && tab?.pin != nil
        case .splitTab:
            return tab.map { browser.canSplit($0.id) } == true && browser.tabs.contains { $0.id != tab?.id && !$0.isBlank && !$0.bench }
        case .separateSplit: return browser.peekTab == nil && browser.shownSplit != nil
        case .keepPeek: return browser.peekTab != nil && !browser.peekClosing
        case .splitPeek: return browser.peekTab != nil && browser.tab(browser.peekOrigin) != nil && !browser.peekClosing
        case .switchSpace(let id, _): return browser.prefs.usesSpaces && id != browser.spaceID && browser.spaces.contains { $0.id == id }
        case .moveSpace(let id, _):
            return browser.prefs.usesSpaces && id != browser.spaceID && browser.spaces.contains { $0.id == id }
                && browser.peekTab == nil && tab?.isBlank == false && tab?.bench == false
                && tab?.address.flatMap { Browser.extensionHost(of: $0) } == nil
        default: return true
        }
    }

    func run(on browser: Browser) {
        guard available(in: browser) else { return }
        switch self {
        case .openArchive: browser.archiveShowing = true
        case .archiveTab: if let tab = browser.active { browser.archive(tab, manual: true) }
        case .restoreArchived: if let entry = ArchiveStore.shared.entries.max(by: { $0.archived < $1.archived }) { browser.restoreArchive(entry) }
        case .settings: browser.tuning = true
        case .routingSettings:
            browser.appearanceSpace = nil
            browser.settingsPage = .links
            browser.tuning = true
        case .newTab: browser.newTab(bar: false)
        case .newPrivateTab: browser.newShyTab()
        case .newSpace: browser.makingSpace = true
        case .bookmarks: browser.bookmarking = true
        case .history: browser.recalling = true
        case .downloads: browser.hoarding = true
        case .passwords: browser.managing = true
        case .toggleSidebar: browser.toggleSidebar()
        case .pinTab: if let tab = browser.active { browser.pin(tab) }
        case .unpinTab: if let tab = browser.active { browser.unpin(tab) }
        case .splitTab: if let tab = browser.active { browser.splitPicking = SplitPick(tab: tab.id, side: .left) }
        case .separateSplit: if let id = browser.activeID { browser.unsplit(id) }
        case .keepPeek: browser.keepPeek()
        case .splitPeek: browser.splitPeek()
        case .moveSpace(let id, _): if let tab = browser.active { browser.move(tab, toSpace: id) }
        case .switchSpace(let id, _): browser.switchSpace(to: id)
        }
    }

    static func matching(_ typed: String, in browser: Browser) -> AddressCommand? {
        let needle = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return inlineCases.first { $0.available(in: browser) && $0.aliases.contains(needle) }
    }

    static func suggestions(for typed: String, in browser: Browser) -> [Suggestion] {
        let spaces = browser.spaces.filter { $0.id != browser.spaceID }
        let commands = allCases + spaces.flatMap { [AddressCommand.switchSpace($0.id, $0.name), .moveSpace($0.id, $0.name)] }
        return commands.filter { $0.available(in: browser) && $0.aliases.contains { CommandRank.match(typed, text: $0) != nil } }
            .map(Suggestion.command)
    }
}

/// Stable ranking shared by actions and destinations; search stays available.
enum CommandRank {
    static func match(_ typed: String, text: String) -> Int? {
        let needle = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hay = text.lowercased()
        guard !needle.isEmpty else { return nil }
        if hay == needle { return 0 }
        if hay.hasPrefix(needle) { return 1 }
        return needle.split(whereSeparator: { $0.isWhitespace }).allSatisfy { hay.contains($0) } ? 2 : nil
    }

    @MainActor static func sorted(_ list: [Suggestion], for typed: String) -> [Suggestion] {
        let url = Address.url(from: typed)
        func score(_ offer: Suggestion) -> Int {
            if offer.kind == .search { return 10 }
            if let url, offer.url == url, !offer.kind.isCommand { return -1 }
            if case .command(let action) = offer.kind {
                return action.aliases.compactMap { match(typed, text: $0) }.min() ?? 3
            }
            return [offer.key, offer.title].compactMap { match(typed, text: $0) }.min() ?? 3
        }
        return list.enumerated().sorted { a, b in
            let lhs = score(a.element), rhs = score(b.element)
            if lhs != rhs { return lhs < rhs }
            if lhs == 0, a.element.kind.isCommand != b.element.kind.isCommand { return a.element.kind.isCommand }
            return a.offset < b.offset
        }.map(\.element)
    }
}
