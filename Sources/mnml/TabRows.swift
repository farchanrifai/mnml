import Foundation

/// The same ordered group entries feed both the column and the top strip.
/// Build membership once per pass: looking up every group's members by
/// scanning all tabs made layout and drag updates grow with tabs × groups.
enum TabRowEntry: Identifiable {
    case tab(Tab)
    case group(TabGroup, [Tab])

    var id: String {
        switch self {
        case .tab(let tab): return "t" + tab.id.uuidString
        case .group(let group, _): return "g" + group.id.uuidString
        }
    }

    @MainActor static func entries(tabs: [Tab], groups: [TabGroup], pinned: Bool) -> [Self] {
        let known = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var members: [TabGroup.ID: [Tab]] = [:]
        for tab in tabs {
            if let id = tab.group { members[id, default: []].append(tab) }
        }
        var out: [Self] = []
        var seen = Set<TabGroup.ID>()
        for tab in tabs where tab.pin == nil {
            if let id = tab.group, let group = known[id] {
                guard group.pinned == pinned, seen.insert(id).inserted else { continue }
                out.append(.group(group, members[id] ?? []))
            } else if !pinned {
                out.append(.tab(tab))
            }
        }
        return out
    }
}
