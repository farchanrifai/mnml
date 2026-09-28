import XCTest
@testable import mnml

final class GroupsTests: XCTestCase {
    private typealias Item = GroupOrder.Item
    private let g = UUID(), h = UUID(), p = UUID()
    private let ids = (0..<8).map { _ in UUID() }

    private func settle(_ items: [Item], _ groups: [TabGroup]) -> [UUID] {
        GroupOrder.settle(items, groups).items.map(\.id)
    }

    func testBlocksAndTogetherness() {
        let groups = [TabGroup(id: g, name: "G", colour: 1), TabGroup(id: p, name: "P", colour: 2, pinned: true)]
        let items = [
            Item(id: ids[0], pinned: false, group: nil),
            Item(id: ids[1], pinned: false, group: g),
            Item(id: ids[2], pinned: true, group: nil),
            Item(id: ids[3], pinned: false, group: nil),
            Item(id: ids[4], pinned: false, group: g),
            Item(id: ids[5], pinned: false, group: p),
        ]
        // Pinned square, pinned group, then the rest with G's tabs together where G began.
        XCTAssertEqual(settle(items, groups), [ids[2], ids[5], ids[0], ids[1], ids[4], ids[3]])
        let settled = GroupOrder.settle(items, groups).groups.map(\.id)
        XCTAssertEqual(settled, [p, g], "pinned groups first")
    }

    func testEmptyGroupsGoAndPinnedSquaresLeaveGroups() {
        var group = TabGroup(id: g, name: "G", colour: 1)
        group.peek = ids[1]
        let items = [Item(id: ids[0], pinned: true, group: g), Item(id: ids[1], pinned: false, group: h)]
        let out = GroupOrder.settle(items, [group])
        XCTAssertNil(out.items[0].group, "a pinned square belongs to no group")
        XCTAssertNil(out.items[1].group, "an unknown group is dropped")
        XCTAssertTrue(out.groups.isEmpty, "a group with no tabs is gone")
    }

    func testAGroupDownToOneTabGoes() {
        // Made with one tab, to be added to: kept.
        let one = GroupOrder.settle([Item(id: ids[0], pinned: false, group: g)], [TabGroup(id: g, name: "G", colour: 1)])
        XCTAssertEqual(one.groups.map(\.id), [g])
        XCTAssertEqual(one.groups[0].size, 1)
        // Two tabs, then one leaves: the group goes, the last tab stays, loose, in place.
        let two = GroupOrder.settle([Item(id: ids[0], pinned: false, group: g), Item(id: ids[1], pinned: false, group: g)],
                                    [TabGroup(id: g, name: "G", colour: 1)])
        XCTAssertEqual(two.groups[0].size, 2)
        let left = GroupOrder.settle([Item(id: ids[2], pinned: false, group: nil), Item(id: ids[1], pinned: false, group: g)], two.groups)
        XCTAssertTrue(left.groups.isEmpty)
        XCTAssertEqual(left.items.map(\.id), [ids[2], ids[1]])
        XCTAssertNil(left.items[1].group)
    }

    func testPeekClearedWhenItsTabLeaves() {
        var group = TabGroup(id: g, name: "G", colour: 1, open: false)
        group.peek = ids[0]
        let items = [Item(id: ids[0], pinned: false, group: nil), Item(id: ids[1], pinned: false, group: g)]
        XCTAssertNil(GroupOrder.settle(items, [group]).groups[0].peek)
        group.peek = ids[1]
        XCTAssertEqual(GroupOrder.settle(items, [group]).groups[0].peek, ids[1])
    }

    // Column: [pinned group P: header, a] line [loose b] [G header, c, d] [loose e]
    private var rows: [GroupDrop.Row] {
        [.header(p, open: true), .tab(ids[0], group: p), .line,
         .tab(ids[1], group: nil), .header(g, open: true), .tab(ids[2], group: g), .tab(ids[3], group: g),
         .tab(ids[4], group: nil)]
    }

    func testTabDrops() {
        XCTAssertEqual(GroupDrop.tab(at: 5, in: rows), .group(g, before: ids[2]), "just under a name")
        XCTAssertEqual(GroupDrop.tab(at: 6, in: rows), .group(g, before: ids[3]), "between a group's tabs")
        XCTAssertEqual(GroupDrop.tab(at: 7, in: rows), .loose(before: .tab(ids[4])), "after a group's last tab is out of it")
        XCTAssertEqual(GroupDrop.tab(at: 4, in: rows), .loose(before: .group(g)), "just above a name is before the group")
        XCTAssertEqual(GroupDrop.tab(at: 8, in: rows), .loose(before: nil), "the end")
        XCTAssertEqual(GroupDrop.tab(at: 1, in: rows), .group(p, before: ids[0]), "into a pinned group")
        XCTAssertEqual(GroupDrop.tab(at: 0, in: rows), .loose(before: .tab(ids[1])), "above the line, outside a group: top of the rest")
        let folded: [GroupDrop.Row] = [.line, .header(g, open: false), .tab(ids[4], group: nil)]
        XCTAssertEqual(GroupDrop.tab(at: 2, in: folded), .group(g, before: nil), "under a folded group's name: its end")
    }

    func testGroupDrops() {
        // Group G dragged: its own rows are out.
        let without: [GroupDrop.Row] = [.header(p, open: true), .tab(ids[0], group: p), .line,
                                         .tab(ids[1], group: nil), .tab(ids[4], group: nil)]
        XCTAssertEqual(GroupDrop.group(at: 0, in: without).pinned, true)
        XCTAssertEqual(GroupDrop.group(at: 0, in: without).before, .group(p), "before the first pinned group")
        XCTAssertEqual(GroupDrop.group(at: 2, in: without).pinned, true, "right above the line is still pinned")
        XCTAssertEqual(GroupDrop.group(at: 3, in: without).pinned, false)
        XCTAssertEqual(GroupDrop.group(at: 4, in: without).before, .tab(ids[4]))
        XCTAssertNil(GroupDrop.group(at: 5, in: without).before)
        // Nothing pinned, no line: the top is just the top.
        let flat: [GroupDrop.Row] = [.tab(ids[1], group: nil), .tab(ids[4], group: nil)]
        XCTAssertEqual(GroupDrop.group(at: 0, in: flat).pinned, false)
        XCTAssertEqual(GroupDrop.group(at: 0, in: flat).before, .tab(ids[1]))
        // Let go inside another group: before that group.
        XCTAssertEqual(GroupDrop.group(at: 1, in: without).before, .group(p))
    }

    func testSessionsWithAndWithoutGroups() throws {
        let old = #"{"tabs":[{"url":"https://a.com","title":"A"}],"active":0}"#
        let shape = try JSONDecoder().decode(Session.Shape.self, from: Data(old.utf8))
        XCTAssertNil(shape.groups)
        XCTAssertNil(shape.tabs[0].group)

        var group = TabGroup(id: g, name: "Work", colour: 3, icon: .emoji("💼"), pinned: true, open: false)
        group.peek = ids[0]
        let now = Session.Shape(tabs: [.init(url: "https://a.com", title: "A", pin: nil, group: g)], active: 0, groups: [group])
        let back = try JSONDecoder().decode(Session.Shape.self, from: JSONEncoder().encode(now))
        XCTAssertEqual(back.tabs[0].group, g)
        XCTAssertEqual(back.groups?.first?.name, "Work")
        XCTAssertEqual(back.groups?.first?.icon, .emoji("💼"))
        XCTAssertEqual(back.groups?.first?.pinned, true)
        XCTAssertEqual(back.groups?.first?.open, false)
        XCTAssertNil(back.groups?.first?.peek, "the peek isn't saved")
    }

    func testExtraWindowKeepsMnmlSessionFields() throws {
        let chat = UUID(), pin = UUID()
        let entry = Session.Entry(url: "https://a.com", title: "A", pin: "A", group: g,
                                  name: "Named", split: true, home: "https://a.com",
                                  chat: chat, asking: true, pinID: pin)
        var window = WindowRecord()
        window.rows[Space.firstID.uuidString] = Session.Shape(tabs: [entry], active: 0)
        let restored = try JSONDecoder().decode(WindowRecord.self, from: JSONEncoder().encode(window))
        let tab = try XCTUnwrap(restored.rows[Space.firstID.uuidString]?.tabs.first)
        XCTAssertEqual(tab.group, g)
        XCTAssertEqual(tab.split, true)
        XCTAssertEqual(tab.chat, chat)
        XCTAssertEqual(tab.asking, true)
        XCTAssertEqual(tab.pinID, pin)
    }
}
