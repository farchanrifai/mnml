import XCTest
@testable import mnml

@MainActor
final class TabRowsPerformanceTests: XCTestCase {
    func testIndexedEntriesKeepGroupOrderMembersAndUnknownGroups() {
        let groups = (0..<80).map { index in
            TabGroup(name: "Group \(index)", colour: index % 8, pinned: index % 3 == 0, open: index % 2 == 0)
        }
        let tabs = (0..<500).map { index -> Tab in
            let tab = Tab()
            if index % 6 != 0 { tab.group = groups[index % groups.count].id }
            if index % 23 == 0 { tab.pin = "Pin" }
            return tab
        }
        tabs[1].group = UUID()

        for pinned in [false, true] {
            let indexed = TabRowEntry.entries(tabs: tabs, groups: groups, pinned: pinned)
            let original = reference(tabs: tabs, groups: groups, pinned: pinned)
            XCTAssertEqual(indexed.map(\.id), original.map(\.id))
            for (actual, expected) in zip(indexed, original) {
                switch (actual, expected) {
                case (.tab(let tab), .tab(let previous)):
                    XCTAssertTrue(tab === previous)
                case (.group(let group, let members), .group(let previous, let oldMembers)):
                    XCTAssertEqual(group, previous)
                    XCTAssertEqual(members.map(\.id), oldMembers.map(\.id))
                default: XCTFail("Changed the kind of a row")
                }
            }
        }
    }

    private func reference(tabs: [Tab], groups: [TabGroup], pinned: Bool) -> [TabRowEntry] {
        var out: [TabRowEntry] = []
        var seen = Set<TabGroup.ID>()
        for tab in tabs where tab.pin == nil {
            if let id = tab.group, let group = groups.first(where: { $0.id == id }) {
                guard group.pinned == pinned, seen.insert(id).inserted else { continue }
                out.append(.group(group, tabs.filter { $0.group == id }))
            } else if !pinned {
                out.append(.tab(tab))
            }
        }
        return out
    }
}
