import AppKit
import SwiftUI
import Foundation

// Tab groups, as Dia has them in its column: a named, coloured bundle of tabs
// that folds away, keeps the one you were on showing when it does, and can
// be pinned under the pinned squares.
//
// The row of tabs stays one list, in order — ⌘1–⌘9, ⌃Tab, sleeping and the
// session all go on counting it as before. A group is a mark on its tabs,
// and the list is kept in three blocks: the pinned squares, the pinned
// groups' tabs, then everything else, with each group's tabs side by side.
// `GroupOrder.settle` is the one place that says so; it runs after every
// change to the row.

struct TabGroup: Identifiable, Codable, Equatable {
    enum Icon: Codable, Equatable {
        /// A small stack of tabs, in the group's colour.
        case stack
        case emoji(String)
        /// The icon of a site, by host.
        case site(String)
    }

    let id: UUID
    var name: String
    /// One of `TabGroup.colours`.
    var colour: Int
    var icon: Icon = .stack
    /// Listed under the pinned squares, above the line.
    var pinned = false
    var open = true
    /// Folded, the tab still showing under the name: the one you were on
    /// when it was folded, until it is opened and folded again. Not saved —
    /// tabs come back from a session as new tabs.
    var peek: UUID?
    /// How many tabs it had when last settled. A group that had two or
    /// more and is down to one is no longer a group. Not saved.
    var size = 0

    private enum CodingKeys: String, CodingKey { case id, name, colour, icon, pinned, open }

    init(id: UUID = UUID(), name: String, colour: Int, icon: Icon = .stack, pinned: Bool = false, open: Bool = true) {
        self.id = id
        self.name = name
        self.colour = colour
        self.icon = icon
        self.pinned = pinned
        self.open = open
    }

    /// Dia's eight, in its order: none, green, blue, purple, amber, pink, red, rust.
    static let colourCount = 8
}

enum GroupOrder {
    /// A tab as the ordering sees it.
    struct Item: Equatable {
        let id: UUID
        let pinned: Bool
        var group: UUID?
    }

    /// The row put in order: pinned squares, then the pinned groups' tabs
    /// group by group, then the rest with each group's tabs together, where
    /// its first one was. Pinned squares belong to no group; a group with no
    /// tabs left is gone, and so is a peek at a tab that left it.
    static func settle(_ items: [Item], _ groups: [TabGroup]) -> (items: [Item], groups: [TabGroup]) {
        var known = Set(groups.map(\.id))
        var items = items.map { item -> Item in
            var item = item
            if item.pinned || !(item.group.map(known.contains) ?? true) { item.group = nil }
            return item
        }
        // Down to one tab from two or more: the group goes, and its last
        // tab stays where it is, on its own. One made with a single tab, to
        // be added to, keeps it.
        var counts: [UUID: Int] = [:]
        for item in items { if let group = item.group { counts[group, default: 0] += 1 } }
        for group in groups where counts[group.id] == 1 && group.size >= 2 {
            known.remove(group.id)
            for index in items.indices where items[index].group == group.id { items[index].group = nil }
        }
        let byID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        var members: [UUID: [Item]] = [:]
        var appearance: [UUID] = []
        for item in items {
            guard let group = item.group else { continue }
            if members[group] == nil { appearance.append(group) }
            members[group, default: []].append(item)
        }
        let pinnedGroups = appearance.filter { byID[$0]?.pinned == true }

        var out = items.filter(\.pinned)
        for group in pinnedGroups { out += members[group] ?? [] }
        var emitted = Set(pinnedGroups)
        for item in items where !item.pinned {
            guard let group = item.group else { out.append(item); continue }
            guard !emitted.contains(group) else { continue }
            emitted.insert(group)
            out += members[group] ?? []
        }

        let order = pinnedGroups + appearance.filter { byID[$0]?.pinned != true }
        let settled = order.compactMap { id -> TabGroup? in
            guard known.contains(id), var group = byID[id] else { return nil }
            group.size = members[id]?.count ?? 0
            if let peek = group.peek, !(members[id]?.contains { $0.id == peek } ?? false) { group.peek = nil }
            return group
        }
        return (out, settled)
    }
}

/// Where a dragged row lands in the column. The rows are those on screen,
/// top to bottom, without the one being dragged; `at` is the gap it is let
/// go in — 0 above the first row, `rows.count` below the last.
enum GroupDrop {
    enum Row: Equatable {
        case tab(UUID, group: UUID?)
        case header(UUID, open: Bool)
        /// Between the pinned groups and everything else.
        case line
    }

    /// Before this tab, or before this group's first tab.
    enum Anchor: Equatable {
        case tab(UUID)
        case group(UUID)
    }

    enum Place: Equatable {
        /// In no group, before the anchor; nil is the end of the row.
        case loose(before: Anchor?)
        /// In the group, before its tab; nil is the group's end.
        case group(UUID, before: UUID?)
    }

    /// A tab let go in gap `at`.
    static func tab(at: Int, in rows: [Row]) -> Place {
        let at = min(max(0, at), rows.count)
        let previous = at > 0 ? rows[at - 1] : nil
        let next = at < rows.count ? rows[at] : nil
        // Just under a group's name, or among its tabs: in the group.
        if case .header(let group, _)? = previous {
            if case .tab(let id, let inside)? = next, inside == group { return .group(group, before: id) }
            return .group(group, before: nil)
        }
        if case .tab(_, let above?)? = previous, case .tab(let id, let below)? = next, below == above {
            return .group(above, before: id)
        }
        // Above the line there is only room inside pinned groups; a tab let
        // go anywhere else up there goes to the top of the rest.
        if let line = rows.firstIndex(of: .line), at <= line {
            return .loose(before: anchor(after: line, in: rows))
        }
        return .loose(before: anchor(from: at, in: rows))
    }

    /// Where a whole group goes when its name is let go in gap `at`, with
    /// its own name and tabs already out of `rows`.
    static func group(at: Int, in rows: [Row]) -> (pinned: Bool, before: Anchor?) {
        let at = min(max(0, at), rows.count)
        // No line on screen — nothing pinned — is no place to pin to.
        let line = rows.firstIndex(of: .line) ?? -1
        let pinned = at <= line
        // Inside another group is not a place for a group: before that group.
        var gap = at
        if gap > 0, gap < rows.count, case .tab(_, let inside?) = rows[gap],
           let start = rows.firstIndex(of: .header(inside, open: true)) ?? rows.firstIndex(of: .header(inside, open: false)) {
            gap = start
        }
        if pinned {
            // Among the pinned groups: before the next pinned name, or last among them.
            for row in rows[gap..<line] { if case .header(let id, _) = row { return (true, .group(id)) } }
            return (true, anchor(after: line, in: rows))
        }
        return (false, anchor(from: gap, in: rows))
    }

    /// The first thing at or after `index` that a tab can be put before.
    private static func anchor(from index: Int, in rows: [Row]) -> Anchor? {
        guard index < rows.count else { return nil }
        for row in rows[index...] {
            switch row {
            case .header(let id, _): return .group(id)
            case .tab(let id, let group): return group.map { .group($0) } ?? .tab(id)
            case .line: continue
            }
        }
        return nil
    }

    /// The first thing below the line.
    private static func anchor(after line: Int, in rows: [Row]) -> Anchor? {
        anchor(from: line + 1, in: rows)
    }
}

// MARK: - what can be done with a group

extension Browser {
    func group(_ id: TabGroup.ID) -> TabGroup? { groups.first { $0.id == id } }

    /// A group's tabs, in order.
    func members(of id: TabGroup.ID) -> [Tab] { tabs.filter { $0.group == id } }

    private func change(_ id: TabGroup.ID, _ edit: (inout TabGroup) -> Void) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        edit(&groups[index])
        rememberSession()
    }

    /// A new group of these tabs, where the first of them was, named for
    /// you to type over. Pinned squares stay out.
    @discardableResult
    func makeGroup(of picks: [Tab], fallbackName: String? = nil) -> TabGroup.ID? {
        let joining = tabs.filter { tab in tab.pin == nil && picks.contains { $0 === tab } }
        guard let first = joining.first else { return nil }
        let used = Set(groups.map(\.colour))
        let colour = (1..<TabGroup.colourCount).first { !used.contains($0) } ?? 1 + groups.count % (TabGroup.colourCount - 1)
        let group = TabGroup(name: "New Group", colour: colour)
        var row = tabs.filter { tab in !joining.contains { $0 === tab } }
        let at = tabs.prefix { $0 !== first }.filter { tab in !joining.contains { $0 === tab } }.count
        row.insert(contentsOf: joining, at: at)
        joining.forEach { $0.group = group.id }
        groups.append(group)
        arrange(row)
        self.chosen = []
        // Named by the Mac's model where there is one (GroupNamer); if it
        // has nothing to say, or there is none, the field to type a name.
        guard GroupNamer.available else {
            if let fallbackName { rename(group.id, to: fallbackName) }
            else { renamingGroup = group.id }
            return group.id
        }
        let pages = joining.map { (title: $0.label, site: $0.address?.host() ?? "") }
        namingGroups.insert(group.id)
        Task { @MainActor [weak self] in
            let label = await GroupNamer.name(for: pages)
            self?.namingGroups.remove(group.id)
            // Named some other way meanwhile — typed, or for its site — it keeps that.
            guard let self, self.group(group.id)?.name == "New Group", self.renamingGroup != group.id else { return }
            if let label {
                self.rename(group.id, to: label.name)
                // Its emoji too, unless an icon was chosen meanwhile.
                if let emoji = label.emoji, self.group(group.id)?.icon == .stack {
                    self.setIcon(group.id, .emoji(emoji))
                }
                self.namedGroups.insert(group.id)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.namedGroups.remove(group.id) }
            } else {
                if let fallbackName { self.rename(group.id, to: fallbackName) }
                else { self.renamingGroup = group.id }
            }
        }
        return group.id
    }

    /// Into the group, before `before` or at its end.
    func add(_ moving: [Tab], to id: TabGroup.ID, before: Tab.ID? = nil) {
        place(moving, .group(id, before: before))
    }

    /// Out of their groups, just after the group they were in.
    func ungroup(_ moving: [Tab]) {
        moving.forEach { $0.group = nil }
        settleGroups()
        rememberSession()
    }

    /// Where a dragged tab — or several — was let go (see GroupDrop).
    func place(_ moving: [Tab], _ place: GroupDrop.Place) {
        let moving = tabs.filter { tab in tab.pin == nil && moving.contains { $0 === tab } }
        guard !moving.isEmpty else { return }
        var row = tabs.filter { tab in !moving.contains { $0 === tab } }
        let target: TabGroup.ID?
        let at: Int
        switch place {
        case .group(let id, let before):
            target = id
            if let before, let index = row.firstIndex(where: { $0.id == before }) {
                at = index
            } else {
                at = (row.lastIndex { $0.group == id }).map { $0 + 1 } ?? row.count
            }
        case .loose(let before):
            target = nil
            switch before {
            case .tab(let id)?: at = row.firstIndex { $0.id == id } ?? row.count
            case .group(let id)?: at = row.firstIndex { $0.group == id } ?? row.count
            case nil: at = row.count
            }
        }
        row.insert(contentsOf: moving, at: at)
        moving.forEach { $0.group = target }
        arrange(row)
    }

    /// A whole group moved: pinned or not, before `before` or last.
    func placeGroup(_ id: TabGroup.ID, pinned: Bool, before: GroupDrop.Anchor?) {
        let moving = members(of: id)
        guard !moving.isEmpty else { return }
        var row = tabs.filter { $0.group != id }
        let at: Int
        switch before {
        case .tab(let tab)?: at = row.firstIndex { $0.id == tab } ?? row.count
        case .group(let other)?: at = row.firstIndex { $0.group == other } ?? row.count
        // Last: settling puts a pinned group after the other pinned ones.
        case nil: at = row.count
        }
        row.insert(contentsOf: moving, at: at)
        if let index = groups.firstIndex(where: { $0.id == id }) { groups[index].pinned = pinned }
        arrange(row)
    }

    /// Folded: the tab you are on stays showing if it is one of the
    /// group's, until the group is opened and folded again.
    func toggleOpen(_ id: TabGroup.ID) {
        let active = active.flatMap { $0.group == id ? $0.id : nil }
        change(id) { group in
            group.open.toggle()
            group.peek = group.open ? nil : active
        }
    }

    func rename(_ id: TabGroup.ID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        change(id) { $0.name = name.isEmpty ? $0.name : name }
    }

    func setColour(_ id: TabGroup.ID, _ colour: Int) { change(id) { $0.colour = colour } }
    func setIcon(_ id: TabGroup.ID, _ icon: TabGroup.Icon) { change(id) { $0.icon = icon } }
    func setPinned(_ id: TabGroup.ID, _ pinned: Bool) {
        change(id) { $0.pinned = pinned }
        settleHomes()
    }

    /// The tabs stay; the group goes.
    func separate(_ id: TabGroup.ID) {
        members(of: id).forEach { $0.group = nil }
        groups.removeAll { $0.id == id }
        rememberSession()
    }

    func closeGroup(_ id: TabGroup.ID) {
        for tab in members(of: id) { close(tab) }
    }

    /// The same pages again, as a group of their own right after this one.
    func duplicateGroup(_ id: TabGroup.ID) {
        guard let original = group(id) else { return }
        let pages = members(of: id).compactMap { $0.pending ?? $0.address }
        guard !pages.isEmpty else { return }
        var copy = TabGroup(name: original.name, colour: original.colour, icon: original.icon, pinned: original.pinned)
        copy.open = true
        let fresh = pages.map { open($0, foreground: false, atEnd: true) }
        fresh.forEach { $0.group = copy.id }
        groups.append(copy)
        var row = tabs.filter { tab in !fresh.contains { $0 === tab } }
        let at = (row.lastIndex { $0.group == id }).map { $0 + 1 } ?? row.count
        row.insert(contentsOf: fresh, at: at)
        arrange(row)
    }

    /// A blank tab at the group's end, and the group open to show it.
    func newTab(in id: TabGroup.ID) {
        newTab(bar: false)
        guard let tab = active, tab.pin == nil else { return }
        change(id) { $0.open = true; $0.peek = nil }
        add([tab], to: id)
    }

    func copyLinks(of id: TabGroup.ID) {
        let links = members(of: id).compactMap { ($0.pending ?? $0.address)?.absoluteString }
        guard !links.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(links.joined(separator: "\n"), forType: .string)
        announce(links.count == 1 ? "Link copied" : "\(links.count) links copied")
    }

    /// A bookmark folder named for the group, a bookmark for each tab.
    func saveAsBookmarks(_ id: TabGroup.ID) {
        guard let group = group(id) else { return }
        let pages = members(of: id).compactMap { tab -> Bookmark? in
            guard let url = tab.pending ?? tab.address, url.scheme?.hasPrefix("http") == true else { return nil }
            return .site(tab.title, url)
        }
        guard !pages.isEmpty else { return }
        bookmarks.insert(.folder(group.name, pages), into: nil)
        announce("Saved to Bookmarks as “\(group.name)”")
    }
}

// MARK: - several tabs at once

extension Browser {
    /// The tabs picked with ⌘- and ⇧-click, in row order.
    var chosenTabs: [Tab] { tabs.filter { chosen.contains($0.id) } }

    /// What a tab's menu acts on: every picked tab if it is one of them,
    /// otherwise just it.
    func menuTargets(for tab: Tab) -> [Tab] {
        chosen.contains(tab.id) && chosen.count > 1 ? chosenTabs : [tab]
    }

    /// ⌘-click: in or out of the picked set, which starts with the tab
    /// you are on.
    func toggleChosen(_ tab: Tab) {
        guard tab.pin == nil else { return }
        if chosen.isEmpty, let active, active.pin == nil { chosen.insert(active.id) }
        if chosen.contains(tab.id) { chosen.remove(tab.id) } else { chosen.insert(tab.id) }
    }

    /// ⇧-click: every tab from the one you are on to this one.
    func chooseRange(to tab: Tab) {
        guard tab.pin == nil, let end = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let start = tabs.firstIndex { $0.id == activeID && $0.pin == nil } ?? end
        chosen = Set(tabs[min(start, end)...max(start, end)].filter { $0.pin == nil }.map(\.id))
    }
}

// MARK: - feeling the drag

extension Browser {
    /// A tap of a Force Touch trackpad as a dragged tab passes another, and
    /// a double one as it goes into or out of a group, is about to make one,
    /// or a group crosses the line (Settings › Tabs).
    func feelDrag(firm: Bool = false) {
        guard prefs.dragHaptics else { return }
        // macOS has no strength to ask for, only three taps; this is its
        // strongest. Firm is the same tap twice, close together.
        let performer = NSHapticFeedbackManager.defaultPerformer
        performer.perform(.levelChange, performanceTime: .now)
        guard firm else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) {
            performer.perform(.levelChange, performanceTime: .now)
        }
    }
}
