import SwiftUI

/// The only chrome there is. Titles, one of them in a grey pill, and the pill
/// slides from the tab you left to the tab you picked rather than blinking out
/// of one and into the other.
struct TabBar: View {
    /// The room kept at the start for the window's buttons: none to speak of
    /// in full screen, where macOS takes them away (idea 184).
    private var lights: CGFloat { browser.fullScreen ? 12 : Metrics.lights }

    @ObservedObject var browser: Browser

    @Namespace private var pill
    /// The neighbouring spaces' own grey, apart from this one's.
    @Namespace private var above
    @Namespace private var below

    /// Which tab is under the hand, where it started, and how far it has come.
    @State private var landing = false
    /// The plus only comes out when the pointer is in the row.
    @State private var nearby = false
    @State private var plussed = false
    /// The helm's width when it stands before the tabs rather than after them.
    private var leading: CGFloat { browser.prefs.navigationLeft ? Metrics.helm - 8 + Metrics.tabGap : 0 }
    /// How wide the doors at the far end are, extension buttons included.
    @State private var doors: CGFloat = 0
    /// A pinned square being dragged within its box: which, where it
    /// started, and how far it has come.
    @State private var dragging: Tab.ID?
    @State private var from = 0
    @State private var travel: CGFloat = 0

    /// Dragging in the row, as in the column (see SideBar): tabs, or a whole
    /// group by its chip, into and out of groups, across the line to pin.
    enum Held: Equatable {
        case tabs([Tab.ID], lead: Tab.ID)
        case group(TabGroup.ID)
    }
    @State private var held: Held?
    @State private var pointer: CGFloat = 0
    @State private var grab: CGFloat = 0
    @State private var placed: String?
    @State private var merging: Tab.ID?
    @State private var mergeCandidate: Tab.ID?
    @State private var pinDrop = false
    /// Where each thing in the row is, in the run's space.
    @State private var frames: [RowKey: CGRect] = [:]
    /// Where the pinned tabs' box ends, in the run's space.
    @State private var pinsEnd: CGFloat = 0

    var body: some View {
        // A GeometryReader is only here to measure the width. Its content is
        // put in a stack of its own and told to fill it: left to itself a
        // reader pins whatever it holds to the top corner, which is the row
        // riding at the very top of the strip while the traffic lights centre
        // themselves halfway down it.
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // The empty half of the strip is what you grab to move the
                // window; the tabs keep the run they sit on.
                DragStrip(reserved: browser.lightsRoom + dot + (making ? min(540, room(in: geo.size.width)) : run(in: geo.size.width)) + Metrics.tabGap + Metrics.plusWidth, trailing: Metrics.helm + 26 + 24)
                // And the corner the lights sit in, which is title bar too —
                // the one stretch left to take hold of when tabs fill the row.
                DragStrip()
                    .frame(width: browser.lightsRoom)

                // In full screen AppKit's buttons slide in
                // while the pointer is at the menu bar (see FullScreenLights).
                if browser.fullScreen {
                    TrafficLights()
                        .padding(.leading, 20)
                        .opacity(browser.lightsOut ? 1 : 0)
                        .offset(x: browser.lightsOut ? 0 : -16)
                        .allowsHitTesting(browser.lightsOut)
                }


                HStack(spacing: Metrics.tabGap) {

                    // The tabs, in a run of their own. While they fit, it is
                    // exactly as wide as they are and nothing about the row
                    // changes. Past what the window holds at their narrowest
                    // it takes the room there is and scrolls inside its own
                    // edges — never under the lights, never over the doors —
                    // keeping the tab you are on in view.
                    // The spaces, one above the other: up or down over the bar
                    // and the next one's tabs come in as these go, with nothing
                    // between them (see SpaceSwipe). Past the last, a new one.
                    ZStack(alignment: .leading) {
                        if making {
                            NewSpaceCard(browser: browser, inline: true)
                                .fixedSize()
                                .offset(y: browser.spaceSwipe)
                        } else {
                            ScrollViewReader { reader in
                                ScrollView(.horizontal, showsIndicators: false) {
                                    row(in: geo.size.width)
                                }
                                .scrollDisabled(!overflowing(in: geo.size.width))
                                .frame(width: run(in: geo.size.width))
                                .onAppear { reveal(reader, in: geo.size.width) }
                                .onChange(of: overflowing(in: geo.size.width)) { _, _ in reveal(reader, in: geo.size.width) }
                                .onChange(of: browser.activeID) { _, _ in reveal(reader, in: geo.size.width, gliding: true) }
                            }
                                .offset(y: browser.spaceSwipe)
                        }
                        if browser.spaceSwipe > 0, spaceAt > 0 {
                            page(spaceAt - 1, in: geo.size.width, pill: above)
                                .offset(y: browser.spaceSwipe - Metrics.strip)
                        }
                        if browser.spaceSwipe < 0, spaceAt < browser.spaces.count - 1 {
                            page(spaceAt + 1, in: geo.size.width, pill: below)
                                .offset(y: browser.spaceSwipe + Metrics.strip)
                        }
                    }
                    .frame(width: making ? min(540, room(in: geo.size.width)) : run(in: geo.size.width), height: Metrics.strip, alignment: .leading)
                    // Only up and down: a neighbour's row may run wider than this one.
                    .mask(Rectangle().frame(width: 4000, height: Metrics.strip))

                    // The way to a new page, right after the tabs rather than
                    // at the end of their run, so it is there however far the
                    // run has scrolled. Out of sight until the pointer is up here.
                    Button { browser.newTab() } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Palette.muted)
                            .frame(width: 15, height: 15)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 6)
                            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(plussed ? SideBar.hoverFill : .clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .onHover { plussed = $0 }
                    // With the tabs, as the space changes (see SpaceSwipe.turnName).
                    .offset(x: browser.rowShift)
                    .opacity(nearby ? browser.rowFade : 0)
                    .scaleEffect(nearby ? 1 : 0.7, anchor: .leading)
                    .allowsHitTesting(nearby)
                    .animation(Motion.settle, value: nearby)

                    Spacer(minLength: 0)

                    // Back, forward, reload, and the bookmarks, at the far end
                    // of the row. The dropdown hangs from the last one.
                    HStack(spacing: Metrics.tabGap) {
                        // Only while a download is running, and a moment after.
                        FetchDoor(browser: browser, fetches: browser.fetches)
                        ExtensionSlot()
                        // ponytail: upstream's back/forward/reload before the tabs
                        // (navigationLeft) isn't wired into mnml's strip; always here.
                        Helm(browser: browser).padding(.trailing, 8)
                        Door(icon: "bookmark", help: "Bookmarks") { browser.bookmarksOpen.toggle() }
                            .popover(isPresented: $browser.bookmarksOpen, arrowEdge: .bottom) {
                                BookmarksDropdown(browser: browser, bookmarks: browser.bookmarks)
                            }
                    }
                    .background {
                        GeometryReader { box in
                            Color.clear
                                .onAppear { doors = box.size.width }
                                .onChange(of: box.size.width) { _, width in doors = width }
                        }
                    }
                }
                // The traffic lights are the system's. The row starts after
                // them and stays there — nothing here moves to get out of
                // their way, because nothing here was ever in it.
                .padding(.leading, browser.lightsRoom)
                .padding(.trailing, 12)
                .coordinateSpace(name: "strip")
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(height: Metrics.strip)
        .onHover { nearby = $0 }
        .onAppear { SpaceSwipe.shared.start(for: browser) }
        // A link dragged onto the row opens there.
        .onDrop(of: [.url, .text], isTargeted: $landing) { providers in
            browser.take(providers)
        }
        // The Mac's sidebar material, as the column has it (Frosted).
        .background {
            Group {
                if browser.prefs.frostedSidebar {
                    Group {
                        if browser.pageUnder { TopGlass() } else { Frosted(blending: .behindWindow) }
                    }
                    .overlay { if landing { SideBar.hoverFill } }
                } else {
                    landing ? Palette.hover : Color.clear
                }
            }
            .overlay { TintWash(browser: browser, prefs: browser.prefs) }
        }
        .animation(Motion.quick, value: landing)
        .animation(browser.prefs.slidesHighlight ? Motion.glide : nil, value: browser.activeID)
        // The row makes room for the field on the same spring as everything
        // else. Without this the widths changed between one frame and the next
        // and the tabs appeared to jump aside.
        .animation(Motion.glide, value: browser.editingTab)
        .animation(Motion.settle, value: browser.tabs.map(\.id))
        .animation(Motion.settle, value: browser.groups)
    }

    // MARK: - the row: pinned tabs, pinned groups, the line, the rest

    private enum Entry: Identifiable {
        case tab(Tab)
        case group(TabGroup, [Tab])
        var id: String {
            switch self {
            case .tab(let tab): return "t" + tab.id.uuidString
            case .group(let group, _): return "g" + group.id.uuidString
            }
        }
    }

    /// The pinned groups, or everything else: tabs and groups in the row's order.
    private func entries(pinned: Bool) -> [Entry] {
        var out: [Entry] = []
        var seen = Set<TabGroup.ID>()
        for tab in browser.tabs where tab.pin == nil {
            if let id = tab.group, let group = browser.group(id) {
                guard group.pinned == pinned, !seen.contains(id) else { continue }
                seen.insert(id)
                out.append(.group(group, browser.members(of: id)))
            } else if !pinned {
                out.append(.tab(tab))
            }
        }
        return out
    }

    /// A line after the pinned tabs and pinned groups, when there are any.
    private var hasLine: Bool { browser.pinnedCount > 0 || browser.groups.contains(where: \.pinned) }

    private func row(in strip: CGFloat) -> some View {
        let each = width(in: strip)
        return HStack(spacing: Metrics.tabGap) {
            pinBox(in: strip, each: each)
            HStack(spacing: Metrics.tabGap) {
                ForEach(entries(pinned: true)) { entry in entryView(entry, each: each, strip: strip) }
                if hasLine {
                    Rectangle()
                        .fill(Palette.hairline)
                        .frame(width: 1, height: 16)
                        .padding(.horizontal, 3)
                        .reportInStrip(.line)
                }
                ForEach(entries(pinned: false)) { entry in entryView(entry, each: each, strip: strip) }
            }
            // After the space's name as it slides, fading (see SpaceName).
            .scaleEffect(browser.rowScale)
            .offset(x: browser.rowShift)
            .opacity(browser.rowFade)
        }
        .frame(height: Metrics.strip)
        .coordinateSpace(name: "run")
        .onPreferenceChange(StripFrames.self) { frames = $0 }
        // One drag for the whole row, which stays put while tabs move in and
        // out of groups (see the column's list for why).
        .simultaneousGesture(
            DragGesture(minimumDistance: 5, coordinateSpace: .named("run"))
                .onChanged { value in
                    guard let what = held ?? pick(at: value.startLocation) else { return }
                    drag(what, value)
                }
                .onEnded { _ in finishDrag() }
        )
        .overlay(alignment: .leading) {
            ghost(each: each, strip: strip)
                .transaction { $0.animation = nil }
        }
    }

    /// The pinned tabs in one box, after the space's name when there are spaces.
    private func pinBox(in strip: CGFloat, each: CGFloat) -> some View {
        let pins = browser.tabs.filter { $0.pin != nil }
        return HStack(spacing: 2) {
            if browser.prefs.usesSpaces, browser.spaces.count > 1 {
                SpaceName(browser: browser)
            } else {
                SpaceDot(browser: browser)
            }
            HStack(spacing: 2) {
                ForEach(Array(pins.enumerated()), id: \.element.id) { index, tab in
                    let held = dragging == tab.id
                    pillView(tab, width: each, strip: strip)
                        .offset(x: held ? travel - CGFloat(index - from) * (Metrics.pinWidth + 2) : 0)
                        .transaction { if held { $0.animation = nil } }
                        .zIndex(held ? 1 : 0)
                        .shadow(color: .black.opacity(held ? 0.14 : 0), radius: 12, y: 4)
                        .gesture(reorder(tab: tab, index: index, step: Metrics.pinWidth + 2))
                        .id(tab.id)
                }
            }
            .scaleEffect(browser.rowScale)
            .offset(x: browser.rowShift)
            .opacity(browser.rowFade)
        }
        .padding(StripChip.pad)
        .background(Palette.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .background(GeometryReader { box in
            Color.clear
                .onAppear { pinsEnd = box.frame(in: .named("run")).maxX }
                .onChange(of: box.frame(in: .named("run")).maxX) { _, end in pinsEnd = end }
        })
    }

    private func pillView(_ tab: Tab, width: CGFloat, strip: CGFloat) -> some View {
        TabPill(
            browser: browser,
            prefs: browser.prefs,
            tab: tab,
            live: tab.id == browser.activeID,
            width: width,
            room: strip - browser.lightsRoom - 12,
            pill: pill,
            close: { browser.close(tab) }
        )
    }

    private func isHeld(_ tab: Tab) -> Bool {
        if case .tabs(let ids, _)? = held { return ids.contains(tab.id) }
        return false
    }

    private func loosePill(_ tab: Tab, each: CGFloat, strip: CGFloat) -> some View {
        pillView(tab, width: each, strip: strip)
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Palette.ink.opacity(merging == tab.id ? 0.45 : 0), lineWidth: 1.5)
            )
            .reportInStrip(.tab(tab.id))
            // Held, it keeps its place unseen while a copy follows the hand.
            .opacity(isHeld(tab) ? 0 : 1)
            .id(tab.id)
    }

    @ViewBuilder
    private func entryView(_ entry: Entry, each: CGFloat, strip: CGFloat) -> some View {
        switch entry {
        case .tab(let tab):
            loosePill(tab, each: each, strip: strip)
        case .group(let group, let members):
            StripGroup(browser: browser, group: group, members: members) { tab in
                loosePill(tab, each: each, strip: strip)
            }
            .opacity(held == .group(group.id) ? 0 : 1)
        }
    }

    /// What is held, drawn where the hand is.
    @ViewBuilder
    private func ghost(each: CGFloat, strip: CGFloat) -> some View {
        switch held {
        case .tabs(_, let lead)?:
            if let tab = browser.tabs.first(where: { $0.id == lead }) {
                TabPill(browser: browser, prefs: browser.prefs, tab: tab, live: false, width: each,
                        room: strip, pill: pill, close: {})
                    .background(Palette.ground.opacity(0.92), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
                    // Over the pinned tabs it shrinks towards one.
                    .scaleEffect(pinDrop ? 0.6 : 1, anchor: .leading)
                    .opacity(pinDrop ? 0.85 : 1)
                    .offset(x: pointer - grab)
                    .allowsHitTesting(false)
            }
        case .group(let id)?:
            if let group = browser.group(id) {
                StripGroup(browser: browser, group: group, members: browser.members(of: id), pill: { tab in
                    TabPill(browser: browser, prefs: browser.prefs, tab: tab, live: false, width: each,
                            room: strip, pill: pill, close: {})
                }, reports: false)
                .background(Palette.ground.opacity(0.92), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
                .offset(x: pointer - grab)
                .allowsHitTesting(false)
            }
        case nil:
            EmptyView()
        }
    }

    /// What a drag starting here picks up: the tab under it — with the other
    /// picked tabs, if it is one of them — or a group, by its chip.
    private func pick(at point: CGPoint) -> Held? {
        for (key, frame) in frames where frame.contains(point) {
            switch key {
            case .tab(let id):
                let ids = browser.chosen.contains(id) ? browser.chosenTabs.map(\.id) : [id]
                return .tabs(ids, lead: id)
            case .header(let id):
                return .group(id)
            case .line:
                continue
            }
        }
        return nil
    }

    /// The row as it is, left to right, less whatever is being dragged.
    private func dropRows(without held: Held) -> [(row: GroupDrop.Row, key: RowKey)] {
        var out: [(GroupDrop.Row, RowKey)] = []
        func add(_ entry: Entry) {
            switch entry {
            case .tab(let tab):
                if case .tabs(let ids, _) = held, ids.contains(tab.id) { return }
                out.append((.tab(tab.id, group: nil), .tab(tab.id)))
            case .group(let group, let members):
                if held == .group(group.id) { return }
                out.append((.header(group.id, open: group.open), .header(group.id)))
                for tab in members where group.open || tab.id == group.peek {
                    if case .tabs(let ids, _) = held, ids.contains(tab.id) { continue }
                    out.append((.tab(tab.id, group: group.id), .tab(tab.id)))
                }
            }
        }
        entries(pinned: true).forEach(add)
        if hasLine { out.append((.line, .line)) }
        entries(pinned: false).forEach(add)
        return out
    }

    private func key(of held: Held) -> RowKey {
        switch held {
        case .tabs(_, let lead): return .tab(lead)
        case .group(let id): return .header(id)
        }
    }

    /// As the column's drag, across instead of down: the row rearranges
    /// around what is held, tabs into and out of groups; held over the middle
    /// of a tab on its own it waits, and a moment there makes a group of the
    /// two; over the pinned tabs, let go and they are pinned.
    private func drag(_ what: Held, _ value: DragGesture.Value) {
        if held == nil {
            held = what
            grab = value.startLocation.x - (frames[key(of: what)]?.minX ?? value.startLocation.x)
        }
        guard let held else { return }
        pointer = value.location.x
        let x = value.location.x

        let pinning: Bool
        if case .tabs = held { pinning = x < (browser.pinnedCount > 0 ? pinsEnd : 0) } else { pinning = false }
        if pinning != pinDrop {
            withAnimation(Motion.quick) { pinDrop = pinning }
            browser.feelDrag(firm: true)
        }
        guard !pinning else { return }
        let rows = dropRows(without: held)

        var over: Tab.ID?
        if case .tabs = held {
            for (row, key) in rows {
                guard case .tab(let id, nil) = row, let frame = frames[key] else { continue }
                if x > frame.minX + frame.width * 0.28, x < frame.maxX - frame.width * 0.28 { over = id }
            }
        }
        if over != mergeCandidate {
            mergeCandidate = over
            merging = nil
            if let over {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard mergeCandidate == over, self.held != nil else { return }
                    withAnimation(Motion.quick) { merging = over }
                    browser.feelDrag(firm: true)
                }
            }
        }
        guard over == nil else { return }

        let gap = rows.filter { (frames[$0.key]?.midX ?? .infinity) < x }.count
        let row = rows.map(\.row)
        withAnimation(Motion.settle) {
            switch held {
            case .tabs(let ids, let lead):
                let place = GroupDrop.tab(at: gap, in: row)
                let mark = String(describing: place)
                guard mark != placed else { return }
                let first = placed == nil
                placed = mark
                let before = browser.tabs.first { $0.id == lead }?.group
                let order = browser.tabs.map(\.id)
                browser.place(browser.tabs.filter { ids.contains($0.id) }, place)
                let after = browser.tabs.first { $0.id == lead }?.group
                if before != after { browser.feelDrag(firm: true) }
                else if !first, browser.tabs.map(\.id) != order { browser.feelDrag() }
            case .group(let id):
                let landing = GroupDrop.group(at: gap, in: row)
                let mark = String(describing: landing)
                guard mark != placed else { return }
                let first = placed == nil
                placed = mark
                let wasPinned = browser.group(id)?.pinned
                let order = browser.tabs.map(\.id)
                browser.placeGroup(id, pinned: landing.pinned, before: landing.before)
                if browser.group(id)?.pinned != wasPinned { browser.feelDrag(firm: true) }
                else if !first, browser.tabs.map(\.id) != order { browser.feelDrag() }
            }
        }
    }

    private func finishDrag() {
        if case .tabs(let ids, _)? = held, pinDrop {
            withAnimation(Motion.settle) {
                for tab in browser.tabs where ids.contains(tab.id) { browser.pin(tab) }
            }
        }
        if case .tabs(let ids, _)? = held, let merging, let target = browser.tabs.first(where: { $0.id == merging }) {
            withAnimation(Motion.settle) {
                _ = browser.makeGroup(of: [target] + browser.tabs.filter { ids.contains($0.id) })
            }
        }
        withAnimation(Motion.settle) {
            held = nil
            pinDrop = false
            placed = nil
            merging = nil
            mergeCandidate = nil
        }
    }

    // MARK: - the spaces, one above the other

    private var making: Bool { browser.prefs.usesSpaces && browser.makingSpace }

    /// Where the space on screen sits among them: one past the last while
    /// the row for a new one is up.
    private var spaceAt: Int {
        browser.makingSpace ? browser.spaces.count : (browser.spaces.firstIndex { $0.id == browser.spaceID } ?? 0)
    }

    /// Another space's row, drawn with the same pills as this one's so the
    /// two read as one bar while they pass — nothing to press until it is
    /// the one on screen. Past the last, the row for a new space.
    @ViewBuilder
    private func page(_ index: Int, in strip: CGFloat, pill: Namespace.ID) -> some View {
        if index == browser.spaces.count {
            NewSpaceCard(browser: browser, inline: true)
                .fixedSize()
                .allowsHitTesting(false)
        } else {
            let space = browser.spaces[index]
            let row = space.id == browser.spaceID
                ? Parked(tabs: browser.tabs, active: browser.activeID)
                : browser.parked[space.id] ?? Parked(tabs: [], active: nil)
            let each = width(in: strip, pinned: row.tabs.filter { $0.pin != nil }.count, count: row.tabs.count)
            HStack(spacing: Metrics.tabGap) {
                ForEach(row.tabs) { tab in
                    TabPill(
                        browser: browser,
                        prefs: browser.prefs,
                        tab: tab,
                        live: tab.id == row.active,
                        width: each,
                        room: strip - browser.lightsRoom - 12,
                        pill: pill,
                        close: {}
                    )
                }
            }
            .frame(height: Metrics.strip)
            .allowsHitTesting(false)
        }
    }

    /// Pick a tab up and the others get out of its way as it passes them.
    private func reorder(tab: Tab, index: Int, step: CGFloat) -> some Gesture {
        // In the row's space, not the pill's — see the sidebar's grid for why.
        DragGesture(minimumDistance: 5, coordinateSpace: .named("strip"))
            .onChanged { value in
                if dragging != tab.id {
                    dragging = tab.id
                    from = index
                }
                travel = value.translation.width
                let moved = Int((travel / step).rounded())
                let target = min(max(0, from + moved), browser.tabs.count - 1)
                if target != index {
                    withAnimation(Motion.settle) { browser.move(tab, to: target) }
                    browser.feelDrag()
                }
            }
            .onEnded { _ in
                if tab.pin == nil { _ = browser.dragOut(tab) }
                withAnimation(Motion.settle) {
                    dragging = nil
                    travel = 0
                }
            }
    }

    /// Brings the tab you are on into view once the run scrolls: at once
    /// when the window first shows it, on the strip's spring when you pick
    /// another. A turn of the run loop later, so the run has been laid out.
    private func reveal(_ reader: ScrollViewProxy, in strip: CGFloat, gliding: Bool = false) {
        guard overflowing(in: strip), let id = browser.activeID else { return }
        DispatchQueue.main.async {
            if gliding {
                withAnimation(Motion.glide) { reader.scrollTo(id) }
            } else {
                reader.scrollTo(id)
            }
        }
    }

    /// How wide the run of tabs is: as wide as the tabs while they fit, as
    /// wide as the room there is once they don't.
    private func run(in strip: CGFloat) -> CGFloat {
        min(content(in: strip), room(in: strip))
    }

    private func overflowing(in strip: CGFloat) -> Bool {
        content(in: strip) > room(in: strip) + 0.5
    }

    /// Everything in the run at the width the tabs get — and the address
    /// field's width for a tab being edited, which grows to take it.
    private func content(in strip: CGFloat) -> CGFloat {
        let each = width(in: strip)
        var total = fixed + CGFloat(looseShown) * each
        if let id = browser.editingTab, let tab = browser.tabs.first(where: { $0.id == id }) {
            total += min(340, strip - browser.lightsRoom - 12) - (tab.pin != nil ? Metrics.pinWidth : each)
        }
        return total
    }

    /// The strip, less the lights, the helm when it leads, the plus, the
    /// doors at the far end and the air around them. The doors are measured;
    /// until they have been, the helm and the bookmarks stand in for them —
    /// unless the helm leads, when nothing at the far end may be a real zero.
    private func room(in strip: CGFloat) -> CGFloat {
        let far = doors > 0 ? doors : Metrics.helm + 26
        return max(0, strip - browser.lightsRoom - dot - 12 - Metrics.plusWidth - far - 3 * Metrics.tabGap)
    }

    /// The space's name is in the pinned box now (see SpaceName), not a dot
    /// of its own before the tabs.
    private var dot: CGFloat { 0 }

    /// Every loose tab is the same width, so the cross is always in the same
    /// place. Past a dozen or so they start giving ground; too narrow for a
    /// title they show their mark alone (Metrics.tabTitled), down to the
    /// mark and its air. Past that, the run scrolls. The pinned squares take
    /// their room off the top.
    private func width(in strip: CGFloat) -> CGFloat {
        let loose = CGFloat(looseShown)
        guard loose > 0 else { return Metrics.tabWidth }
        return max(Metrics.tabMinWidth, min(Metrics.tabWidth, (room(in: strip) - fixed) / loose))
    }

    /// The tabs in the row that aren't pinned and aren't folded away.
    private var looseShown: Int {
        browser.tabs.filter { tab in
            guard tab.pin == nil else { return false }
            guard let id = tab.group, let group = browser.group(id) else { return true }
            return group.open || group.peek == tab.id
        }.count
    }

    /// Everything in the row but the loose tabs themselves: the pinned
    /// box, the groups' chips and patches, the line, and the gaps.
    private var fixed: CGFloat {
        var total: CGFloat = 0
        var items = 0
        let pins = browser.pinnedCount
        total += CGFloat(pins) * Metrics.pinWidth + CGFloat(max(0, pins - 1)) * 2 + 2 * StripChip.pad
        total += (browser.prefs.usesSpaces && browser.spaces.count > 1 ? SpaceSwipe.shared.nameWidth + 16 : SpaceDot.width) + 2
        items += 1
        for entry in entries(pinned: true) + entries(pinned: false) {
            items += 1
            guard case .group(let group, let members) = entry else { continue }
            let shown = members.filter { group.open || $0.id == group.peek }.count
            total += StripChip.width(group, icons: browser.prefs.glyph == .icons) + 2 * StripChip.pad + CGFloat(shown) * StripChip.rule
        }
        if hasLine {
            total += 7
            items += 1
        }
        return total + CGFloat(max(0, items - 1)) * Metrics.tabGap
    }

    private func width(in strip: CGFloat, pinned pins: Int, count: Int) -> CGFloat {
        let pinned = CGFloat(pins)
        let loose = CGFloat(count) - pinned
        guard loose > 0 else { return Metrics.tabWidth }
        let spent = pinned * Metrics.pinWidth
            + CGFloat(max(0, count - 1)) * Metrics.tabGap
        return max(Metrics.tabMinWidth, min(Metrics.tabWidth, (room(in: strip) - spent) / loose))
    }
}

/// Back, forward, reload. They watch the live tab, not the window: whether
/// there is anywhere to go back to is the tab's to say, and it changes with
/// every page. Used here and, beside the traffic lights instead of at the
/// far end of the row, in the sidebar.
struct Helm: View {
    @ObservedObject var browser: Browser

    var body: some View {
        if let tab = browser.active {
            Wheel(browser: browser, tab: tab)
        } else {
            // Nowhere to go and nothing to reload: the doors stay in place,
            // greyed, so the row doesn't shift when a tab arrives.
            HStack(spacing: 4) {
                Door(icon: "chevron.left") {}
                Door(icon: "chevron.right") {}
                Door(icon: "arrow.clockwise") {}
            }
            .opacity(0.3)
            .allowsHitTesting(false)
        }
    }

    private struct Wheel: View {
        let browser: Browser
        @ObservedObject var tab: Tab

        var body: some View {
            let back = !tab.isBlank && tab.canGoBack
            let forward = !tab.isBlank && tab.canGoForward
            HStack(spacing: 4) {
                Door(icon: "chevron.left", help: "Back   ⌘[") { browser.back() }
                    .disabled(!back)
                    .opacity(back ? 1 : 0.3)
                Door(icon: "chevron.right", help: "Forward   ⌘]") { browser.forward() }
                    .disabled(!forward)
                    .opacity(forward ? 1 : 0.3)
                // Reload, or stop while it is still coming.
                Door(
                    icon: tab.loading ? "xmark" : "arrow.clockwise",
                    help: tab.loading ? "Stop   ⌘." : "Reload   ⌘R"
                ) {
                    if tab.loading { tab.stop() } else { browser.reload() }
                }
                .disabled(tab.isBlank)
                .opacity(tab.isBlank ? 0.3 : 1)
            }
            .animation(Motion.quick, value: back)
            .animation(Motion.quick, value: forward)
            .animation(Motion.quick, value: tab.loading)
        }
    }
}

private struct TabPill: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var tab: Tab
    let live: Bool
    let width: CGFloat
    /// How much of the strip there is, for the field that grows over it.
    let room: CGFloat
    let pill: Namespace.ID
    let close: () -> Void

    @State private var hovering = false
    @State private var shake: CGFloat = 0

    private var editing: Bool { browser.editingTab == tab.id }
    private var pinned: Bool { tab.pin != nil && !editing }
    /// Too narrow for a title: the site's mark alone, the title in the
    /// tooltip, and ⌘W or the menu to close it — a cross on something this
    /// small would be what a click to pick the tab lands on.
    private var compact: Bool { !editing && !pinned && width < Metrics.tabTitled }
    /// A speaker to press at the end of the pill: the page plays sound, or
    /// was muted. The ring, while the page is still coming, goes first.
    private var speaker: Bool { !editing && !tab.loading && (tab.noisy || tab.muted) }

    /// A pinned tab is a square, an edited one is a field, everything else is
    /// its share of what is left.
    private var span: CGFloat {
        if editing { return min(340, room) }
        return pinned ? Metrics.pinWidth : width
    }

    var body: some View {
        Group {
            if pinned {
                Group {
                    if browser.editingPin == tab.id {
                        PinField(browser: browser, tab: tab)
                    } else if tab.loading {
                        // Its page on the way, as a tab's ring says; the
                        // letter or icon comes back once it is there.
                        Ring(size: 11)
                    } else if prefs.glyph == .icons, let icon = tab.icon {
                        Mark(icon: icon, letter: tab.pin ?? "", size: 16, dim: tab.asleep)
                    } else {
                        Text(tab.pin ?? "")
                            .font(.system(size: 12, weight: .medium))
                            // A pin holding no page is still there and still
                            // yours; it just isn't costing anything.
                            .foregroundStyle(colour.opacity(tab.asleep ? 0.45 : 1))
                    }
                }
                .frame(width: 16, height: 16)
                .padding(.horizontal, 7)
                .padding(.vertical, 6)
                .frame(width: span)
            } else {
                loose
            }
        }
        .background { ground }
        .modifier(Shake(travel: shake))
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        // Never both at once.
        //
        // A view carrying a single tap *and* a double tap has to wait out the
        // system's double-click delay before it can conclude that a click was
        // single — and that delay is a preference, adjustable up to a second.
        // Which is exactly how long a tab took to come forward.
        //
        // So each tab carries one gesture. The pinned square you are already
        // on has nothing to do on a single click, so it takes the double one
        // and goes back to the page it was pinned at — or, there already,
        // edits its letter; everything else answers the first click at
        // once. Change Letter in the menu covers the rest.
        .modifier(OneClick(double: live && pinned) {
            // ⌘-click picks tabs, ⇧-click a run of them, for the menu to act
            // on together, as in the column.
            let flags = NSEvent.modifierFlags
            if !pinned, flags.contains(.command) { browser.toggleChosen(tab); return }
            if !pinned, flags.contains(.shift) { browser.chooseRange(to: tab); return }
            browser.chosen = []
            // A double-click on a pinned square that has wandered off takes
            // it home (PinnedHome.swift); on one that hasn't, edits its letter.
            if pinned, tab.strayed, NSApp.currentEvent?.clickCount == 2 {
                browser.goHome(tab)
            } else if live && pinned {
                browser.editLetter(tab)
            } else if live && !pinned {
                // On a double-click, as in the column.
                if NSApp.currentEvent?.clickCount == 2 { browser.beginTabEdit(tab) }
            } else {
                browser.select(tab)
            }
        })
        .overlay { MiddleClick(act: close) }
        .onHover { hovering = $0 }
        .contextMenu { TabMenu(browser: browser, tab: tab, close: close) }
        .help(pinned && tab.strayed ? "\(tab.label) — double-click to go back to the pinned page" : (pinned || compact ? tab.label : ""))
        .animation(Motion.quick, value: hovering)
        .animation(Motion.glide, value: editing)
        .animation(Motion.glide, value: tab.pin)
        .onChange(of: browser.refusals) { _, _ in
            guard editing else { return }
            shake = 0
            withAnimation(.easeOut(duration: 0.5)) { shake = 1 }
        }
        // Arriving and leaving from the strip rather than from nowhere.
        .transition(.scale(scale: 0.9, anchor: .leading).combined(with: .opacity))
    }

    @ViewBuilder
    private var loose: some View {
        if compact {
            ZStack {
                if tab.loading {
                    Ring()
                } else {
                    Mark(icon: prefs.glyph == .icons ? tab.icon : nil, letter: tab.monogram, size: 15, dim: tab.asleep)
                }
            }
            .frame(width: 16, height: 16)
            .padding(.vertical, 6)
            .frame(width: span)
        } else {
            titled
        }
    }

    private var titled: some View {
        HStack(spacing: 6) {
            if editing {
                TabAddressField(browser: browser)
                    .frame(height: 16)
            } else {
                if prefs.glyph == .icons, !tab.isBlank {
                    Mark(icon: tab.icon, letter: tab.monogram, size: 15)
                }
                if tab.bench {
                    // A script's tab, not yours.
                    Image(systemName: "flask")
                        .font(.system(size: 9))
                        .foregroundStyle(colour.opacity(0.7))
                }
                if tab.shy {
                    // Quiet, and only on the tabs that keep nothing.
                    Image(systemName: "eye.slash")
                        .font(.system(size: 9))
                        .foregroundStyle(colour.opacity(0.7))
                }
                Text(tab.label)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(colour)
            }

            Spacer(minLength: 2)

            // The speaker, which can be pressed, is at the end of the pill on
            // its own, and one place in under the pointer, beside the cross
            // and clear of its reach.
            HStack(spacing: 0) {
                if speaker {
                    Speaker(tab: tab)
                        .padding(.trailing, hovering ? 8 : 0)
                        .transition(.opacity)
                }

                // Pinned to the right-hand end of the pill, not trailing the title.
                // One slot doing two jobs: the cross when the pointer is here, the
                // ring while the page is still coming, never both.
                ZStack {
                    if hovering {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Palette.muted)
                            .frame(width: 15, height: 15)
                            .background(Palette.ink.opacity(0.07), in: Circle())
                            .transition(.opacity)
                    } else if tab.loading {
                        Ring().transition(.opacity)
                    }
                }
                .frame(width: editing || (speaker && !hovering) ? 0 : 15, height: 15)
                .opacity(editing ? 0 : 1)
                // The cross is 15 points across because that is how big it should
                // look. What you have to hit is the whole right-hand end of the
                // tab: an overlay is not laid out, so it can reach past its own
                // frame without moving anything that is.
                //
                // A view of AppKit's own takes the click there, while the
                // cross shows (see CloseClick).
                .overlay {
                    if !editing {
                        CloseClick(armed: hovering, act: close)
                            .frame(width: 30, height: 28)
                    }
                }
                .animation(Motion.quick, value: hovering)
                .animation(Motion.quick, value: tab.loading)
            }
        }
        .padding(.leading, 11)
        .padding(.trailing, editing ? 11 : 7)
        .padding(.vertical, 6)
        .frame(width: span, alignment: .leading)
        .animation(Motion.quick, value: speaker)
    }

    @ViewBuilder
    private var ground: some View {
        if live {
            // The grey fills from the left as you read down the page. It is
            // the one thing in the window that says how far in you are, and
            // it says it without adding anything to the window.
            ZStack(alignment: .leading) {
                // The ink, see-through, as in the column: a flat grey all but
                // vanished over a group's colour.
                Rectangle().fill(pinned ? SideBar.pinLiveFill : SideBar.liveFill)
                // Not on a pinned square, nor a tab down to its mark. Thirty
                // points of grey filling from the left behind a single letter
                // says nothing about anything — it needs the width of a title
                // to read as progress at all.
                if !pinned && !compact && prefs.showsReading {
                    ReadingFill(reading: tab.reading, span: span)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .matchedGeometryEffect(id: "live", in: pill)
        } else if browser.chosen.contains(tab.id) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(SideBar.liveFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Palette.ink.opacity(0.18), lineWidth: 1)
                )
        } else if hovering {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(pinned ? SideBar.pinHoverFill : SideBar.hoverFill)
        } else if pinned {
            // A letter with nothing behind it reads as debris. A pinned tab
            // keeps a faint ground of its own so the block of them reads as
            // one thing.
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(SideBar.pinFill)
        }
    }

    private var colour: Color {
        if live { return Palette.ink }
        return hovering ? Palette.ink.opacity(0.7) : Palette.muted
    }
}

/// The address, inside its own tab.
///
/// A field of its own rather than SwiftUI's, for one reason: the system paints
/// selected text as a solid block of accent colour, which over a pale grey pill
/// this size is the loudest thing in the window. Here it is a tenth of the ink.
/// A tab picked up and carried along its row, the others making way as it
/// passes them — across the top or down the column alike.
///
/// The hand's travel is the tab's own: every move of the pointer redraws the
/// one tab being carried, not the whole column or bar around it (with the
/// neighbouring spaces drawn beside it, that was every row and every square
/// of three spaces, each frame, and the tab trailed behind the hand). The row
/// only redraws when the tab actually changes place.
struct Carried: ViewModifier {
    let index: Int
    let count: Int
    /// One place in the row: the tab's length and the gap after it.
    let step: CGFloat
    let vertical: Bool
    /// The row's coordinate space, not the tab's: a tab that has just moved
    /// keeps its bearings (see the sidebar's grid).
    let space: String
    var onDrop: ((CGPoint) -> Void)? = nil
    /// Let go outside the window: true when the tab was taken elsewhere —
    /// another window, or a new one (see Browser.dragOut).
    var outside: (() -> Bool)? = nil
    let move: (Int) -> Void

    @State private var held = false
    @State private var from = 0
    @State private var travel: CGFloat = 0

    func body(content: Content) -> some View {
        // What it has travelled, less the ground its new place has already
        // given it.
        let shift = held ? travel - CGFloat(index - from) * step : 0
        return content
            .offset(x: vertical ? 0 : shift, y: vertical ? shift : 0)
            // Under the hand exactly. Its place in the row springs when it
            // passes another tab, and the offset springs back the same way —
            // until the next move of the hand cuts the offset's spring short
            // and leaves the place's running: the tab jumped a whole slot and
            // drifted back each time it passed one. Only the others glide.
            .transaction { if held { $0.animation = nil } }
            .zIndex(held ? 1 : 0)
            .shadow(color: .black.opacity(held ? 0.14 : 0), radius: 12, y: 4)
            .gesture(
                DragGesture(minimumDistance: 5, coordinateSpace: .named(space))
                    .onChanged { value in
                        if !held {
                            held = true
                            from = index
                        }
                        travel = vertical ? value.translation.height : value.translation.width
                        let target = min(max(0, from + Int((travel / step).rounded())), count - 1)
                        if target != index {
                            withAnimation(Motion.settle) { move(target) }
                        }
                    }
                    .onEnded { value in
                        if outside?() != true { onDrop?(value.location) }
                        withAnimation(Motion.settle) {
                            held = false
                            travel = 0
                        }
                    }
            )
    }
}

struct TabAddressField: NSViewRepresentable {
    @ObservedObject var browser: Browser

    func makeCoordinator() -> Coordinator { Coordinator(browser: browser) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12.5)
        field.textColor = Palette.NS.ink
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.stringValue = browser.tabDraft
        context.coordinator.watch(field)
        // The site card stands under whichever field the address is in.
        SiteCardPanel.follow(browser, anchor: field)
        return field
    }

    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        coordinator.unwatch()
    }

    /// The width it is offered, never the address's own. Left to its own,
    /// the field was as wide as the whole address and the row cut it off:
    /// a field that never runs out of room never scrolls, so the caret went
    /// on out of sight with ← and →, and so did what was typed at the end.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: NSTextField, context: Context) -> CGSize? {
        let natural = field.intrinsicContentSize
        guard let width = proposal.width, width.isFinite else { return nil }
        return CGSize(width: max(0, width), height: proposal.height ?? natural.height)
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.browser = browser
        if !coordinator.typing, field.stringValue != browser.tabDraft {
            field.stringValue = browser.tabDraft
        }
        guard !coordinator.claimed else { return }
        coordinator.claimed = true
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            guard let editor = field.currentEditor() as? NSTextView else { return }
            editor.selectedTextAttributes = [
                .backgroundColor: NSColor(Palette.ink.opacity(0.11)),
                .foregroundColor: Palette.NS.ink,
            ]
            editor.selectAll(nil)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var browser: Browser
        var claimed = false
        var typing = false

        init(browser: Browser) { self.browser = browser }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            typing = true
            browser.tabDraft = field.stringValue
            typing = false
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy command: Selector
        ) -> Bool {
            switch command {
            case #selector(NSResponder.insertNewline(_:)):
                // Returning true keeps the field editing, which is what lets a
                // refused address stay on screen instead of being thrown away.
                browser.commitTabEdit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                browser.cancelTabEdit()
                return true
            default:
                return false
            }
        }

        /// Clicking anywhere else keeps what was typed, as Return does.
        func controlTextDidEndEditing(_ note: Notification) {
            let browser = browser
            DispatchQueue.main.async { browser.finishTabEdit() }
        }

        /// A press on something that takes no focus — the strip's empty
        /// stretch, the column below the rows — leaves the field focused and
        /// editing, so presses are watched for while it is there: one anywhere
        /// but in the field ends the edit the same way. The press itself goes
        /// on to what it was for.
        private var watcher: Any?

        @MainActor func watch(_ field: NSTextField) {
            guard watcher == nil else { return }
            watcher = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self, weak field] event in
                guard let self, let field, event.window === field.window,
                      !field.bounds.contains(field.convert(event.locationInWindow, from: nil))
                else { return event }
                let browser = self.browser
                DispatchQueue.main.async { browser.finishTabEdit() }
                return event
            }
        }

        @MainActor func unwatch() {
            if let watcher { NSEvent.removeMonitor(watcher) }
            watcher = nil
        }
    }
}

/// What a right-click on any tab offers, wherever the tab is drawn.
struct TabMenu: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    let close: () -> Void

    var body: some View {
        let rows = browser.prefs.showsPinRows
        if tab.pin == nil {
            Button("Pin") { browser.pin(tab) }
                .disabled(tab.isBlank || tab.shy)
            if rows {
                Button("Pin as Row") { browser.pin(tab, listed: true) }
                    .disabled(tab.isBlank || tab.shy)
            }
        } else {
            if rows {
                Button(tab.listed ? "Show as Square" : "Show as Row") { browser.setListed(tab, !tab.listed) }
            }
            // A row wears its title, not its letter; and a click on it is
            // the address, so the way home a square's double-click is
            // (Browser.goHome) is here instead, while it has wandered.
            if rows && tab.listed {
                Button("Back to Pinned Page") { browser.goHome(tab) }
                    .disabled(tab.home.map { Browser.samePage($0, tab.address) } ?? true)
            } else {
                Button("Change Letter") { browser.editLetter(tab) }
            }
            Button("Unpin") { browser.unpin(tab) }
        }
        // Tab groups, in the column and across the top (Groups.swift).
        if tab.pin == nil {
            let targets = browser.menuTargets(for: tab)
            Divider()
            Button(targets.count > 1 ? "New Group from \(targets.count) Tabs" : "New Group with Tab") {
                withAnimation(Motion.settle) { _ = browser.makeGroup(of: targets) }
            }
            if !browser.groups.isEmpty {
                Menu("Add to Group") {
                    ForEach(browser.groups) { group in
                        Button(group.name) { withAnimation(Motion.settle) { browser.add(targets, to: group.id) } }
                            .disabled(targets.allSatisfy { $0.group == group.id })
                    }
                }
            }
            if targets.contains(where: { $0.group != nil }) {
                Button("Remove from Group") { withAnimation(Motion.settle) { browser.ungroup(targets) } }
            }
        }
        if tab.home != nil {
            Divider()
            Menu("Edit Pinned Page") {
                Button("Replace Pinned URL with Current") { browser.makeHome(tab) }
                    .disabled(!tab.strayed)
                Button("Edit…") { browser.editHome(tab) }
            }
            Button("Back to Pinned URL") { browser.goHome(tab) }
                .disabled(!tab.strayed)
        }
        if browser.prefs.usesSpaces, !tab.bench,
           tab.address.flatMap({ Browser.extensionHost(of: $0) }) == nil {
            Menu("Move to Space") {
                ForEach(browser.spaces.filter { $0.id != browser.spaceID }) { space in
                    Button {
                        browser.move(tab, toSpace: space.id)
                    } label: {
                        Label(space.name, systemImage: space.symbol)
                    }
                }
                if browser.spaces.count > 1 { Divider() }
                Button("New Space…") {
                    browser.askForSpace { space in
                        browser.move(tab, toSpace: space.id) {
                            browser.switchSpace(to: space.id)
                        }
                    }
                }
            }
            .help("Pages moved to a Space with different sign-ins reopen there.")
        }
        if tab.pin == nil, !tab.bench {
            // Another window, or a new one (see Browser.moveToWindow).
            let others = Browsers.all.filter { $0 !== browser && $0.isOpen && $0.extensionPopup == nil }
            if others.isEmpty {
                Button("Move to New Window") { browser.moveToWindow(tab, nil) }
                    .disabled(browser.tabs.count < 2)
            } else {
                Menu("Move to Window") {
                    Button("New Window") { browser.moveToWindow(tab, nil) }
                        .disabled(browser.tabs.count < 2)
                    Divider()
                    ForEach(Array(others.enumerated()), id: \.offset) { _, other in
                        Button(other.windowName) { browser.moveToWindow(tab, other) }
                    }
                }
            }
        }
        Divider()
        Button("Rename") { browser.beginTabRename(tab) }
        Button("Duplicate") {
            browser.select(tab)
            browser.duplicate()
        }
        .disabled(tab.isBlank)
        // The card a click on the tab you are on shows under its address.
        Button("Site Information…") {
            if browser.activeID != tab.id { browser.select(tab) }
            browser.beginTabEdit(tab)
        }
        .disabled(tab.isBlank || tab.address == nil || tab.pin != nil)
        Button("Copy Address") {
            browser.select(tab)
            browser.copyAddress()
        }
        .disabled(tab.isBlank)
        Button("Copy as Markdown Link") {
            browser.select(tab)
            browser.copyMarkdownLink()
        }
        .disabled(tab.isBlank)
        Button(tab.muted ? "Unmute Tab" : "Mute Tab") { tab.toggleMute() }
        if browser.split(of: tab.id) != nil {
            Divider()
            Button("Separate Tabs") { withAnimation(Motion.settle) { browser.unsplit(tab.id) } }
        }
        // Its page let go of now, as it would be after half an hour unseen:
        // the row keeps its title and picture, and it loads again when gone
        // to. Not the tab on screen, nor one that has to stay awake (#310).
        Button("Put to Sleep") {
            browser.sleep(tab) { outcome in
                if outcome != "asleep" { browser.announce("Stays awake: \(outcome)") }
            }
        }
        .disabled(browser.awake(because: tab) != nil)
        Divider()
        Button("Close Tab", action: close)
        Button("Close Other Tabs") { browser.closeOthers(but: tab) }
            .disabled(browser.tabs.count < 2)
        let here = browser.tabs.firstIndex { $0.id == tab.id } ?? 0
        Button(browser.prefs.sidebar ? "Close Tabs Above" : "Close Tabs to the Left") {
            browser.closeTabs(beside: tab, after: false)
        }
        .disabled(tab.pin != nil || !browser.tabs[..<here].contains { $0.pin == nil })
        Button(browser.prefs.sidebar ? "Close Tabs Below" : "Close Tabs to the Right") {
            browser.closeTabs(beside: tab, after: true)
        }
        .disabled(tab.pin != nil || !browser.tabs.dropFirst(here + 1).contains { $0.pin == nil })
        // ⌘⇧T, and the History menu's Recently Closed, where few think to
        // look for it: here too, where tabs are closed.
        Button("Reopen Closed Tab") { browser.reopen() }
            .disabled(browser.ghosts.isEmpty)
    }
}

/// One gesture or the other, never the two together.
struct OneClick: ViewModifier {
    let double: Bool
    let act: () -> Void

    func body(content: Content) -> some View {
        if double {
            content.onTapGesture(count: 2, perform: act)
        } else {
            content.onTapGesture(perform: act)
        }
    }
}

/// A click on a tab's cross closes it — taken by a real view laid over the
/// cross rather than by a SwiftUI tap. Out over the page, in the strip folded
/// away with ⌘S, the tap never came: the cross showed under the pointer and
/// clicking it did nothing (Drice). A view of AppKit's own is handed the
/// press by AppKit itself, as the middle button's is (MiddleClick), and it
/// answers only while the cross is there to be pressed, only to the left
/// button; to anything else it isn't there, and the tab goes on as before.
struct CloseClick: NSViewRepresentable {
    let armed: Bool
    let act: () -> Void

    func makeNSView(context: Context) -> NSView { Cross() }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? Cross)?.armed = armed
        (view as? Cross)?.act = act
    }

    private final class Cross: NSView {
        var armed = false
        var act: () -> Void = {}
        private var pressed = false

        /// Never the window's to drag from: the press is the cross's.
        override var mouseDownCanMoveWindow: Bool { false }

        /// Asked about every event over the cross, the pointer moving included;
        /// only a left press, while the cross shows, is this view's.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard armed, let event = NSApp.currentEvent,
                  event.type == .leftMouseDown, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
            else { return nil }
            return super.hitTest(point)
        }

        override func mouseDown(with event: NSEvent) {
            pressed = true
        }

        /// On the release, and only if it is still over the cross: a press
        /// taken back by moving off before letting go closes nothing.
        override func mouseUp(with event: NSEvent) {
            guard pressed else { return }
            pressed = false
            if bounds.contains(convert(event.locationInWindow, from: nil)) { act() }
        }
    }
}

/// The middle button on a tab closes it, as it does in every other browser.
///
/// SwiftUI has no gesture for that button, so this is a real view laid over
/// the tab — and a real view is asked first (see DragStrip). It says yes for
/// the middle button and nothing else: to a left click, a drag or a right
/// click it isn't there, and the tab's own gestures and menu go on as before.
struct MiddleClick: NSViewRepresentable {
    let act: () -> Void

    func makeNSView(context: Context) -> NSView { Catch() }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? Catch)?.act = act
    }

    private final class Catch: NSView {
        var act: () -> Void = {}
        private var pressed = false

        /// Asked about every event that lands on the tab, the pointer moving
        /// over it included; the one being delivered is the one to judge by.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent,
                  event.type == .otherMouseDown || event.type == .otherMouseUp,
                  event.buttonNumber == 2
            else { return nil }
            return super.hitTest(point)
        }

        override func otherMouseDown(with event: NSEvent) {
            pressed = true
        }

        /// On the release, not the press, and only if it is still over the
        /// tab: a middle button pressed by mistake can be taken back the way
        /// a click on the cross can, by moving off before letting go.
        override func otherMouseUp(with event: NSEvent) {
            guard pressed else { return }
            pressed = false
            if bounds.contains(convert(event.locationInWindow, from: nil)) { act() }
        }
    }
}

/// An almost-closed ring, turning — the same one the canvas app uses, small
/// enough to sit inside a tab without becoming the loudest thing in it.
///
/// Turned by Core Animation rather than SwiftUI. A SwiftUI animation that
/// never ends has the whole window's view tree laid out and redrawn every
/// frame for as long as it runs — a fifth of a core, all the while a page
/// in some tab behind was still loading. A layer's own animation is played
/// by the render server and costs this process nothing.
struct Ring: NSViewRepresentable {
    var size: CGFloat = 10

    func makeNSView(context: Context) -> RingView { RingView() }
    func updateNSView(_ view: RingView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RingView, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }

    final class RingView: NSView {
        private let ring = CAShapeLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            ring.fillColor = nil
            ring.lineWidth = 1.4
            ring.lineCap = .round
            ring.strokeEnd = 0.78
            // Nothing but the turn moves: a new size or colour is there at
            // once, not eased into by Core Animation's own quarter second.
            ring.actions = ["bounds": NSNull(), "position": NSNull(), "path": NSNull(), "strokeColor": NSNull()]
            layer?.addSublayer(ring)
        }

        required init?(coder: NSCoder) { nil }

        /// Seen, never pressed: it sits in a tab, over the × while the page
        /// loads and in the middle of a tab down to its mark, and a real view
        /// would take the click meant for either.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            let inset = ring.lineWidth / 2
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            ring.frame = bounds
            ring.path = CGPath(ellipseIn: bounds.insetBy(dx: inset, dy: inset), transform: nil)
            CATransaction.commit()
        }

        /// The colour is resolved against the window's appearance, so it is
        /// set again whenever that changes.
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            effectiveAppearance.performAsCurrentDrawingAppearance {
                ring.strokeColor = Palette.NS.muted.withAlphaComponent(0.7).cgColor
            }
        }

        /// Turning only while it is in a window: a layer animation is dropped
        /// when the view leaves one, so it is added each time it arrives.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            viewDidChangeEffectiveAppearance()
            ring.removeAnimation(forKey: "turn")
            guard window != nil else { return }
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            // Clockwise, as the SwiftUI one turned: a layer's positive angle
            // is anticlockwise in a view that isn't flipped.
            turn.fromValue = 0
            turn.toValue = -2 * Double.pi
            turn.duration = 0.85
            turn.repeatCount = .infinity
            ring.add(turn, forKey: "turn")
        }
    }
}


/// The letter of a pinned tab, typed in the square itself.
///
/// A field of its own rather than SwiftUI's, for the same reason as the address
/// in a tab: the system paints selected text as a solid block of accent colour,
/// and over a thirty-point grey square that is the loudest thing on screen.
struct PinField: NSViewRepresentable {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab

    func makeCoordinator() -> Coordinator { Coordinator(browser: browser, tab: tab) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.alignment = .center
        field.font = .systemFont(ofSize: 12, weight: .medium)
        field.textColor = Palette.NS.ink
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.stringValue = tab.pin ?? ""
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.browser = browser
        coordinator.tab = tab
        if !coordinator.typing, field.stringValue != tab.pin ?? "" {
            field.stringValue = tab.pin ?? ""
        }
        guard !coordinator.claimed else { return }
        coordinator.claimed = true
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            guard let editor = field.currentEditor() as? NSTextView else { return }
            editor.selectedTextAttributes = [
                .backgroundColor: NSColor(Palette.ink.opacity(0.12)),
                .foregroundColor: Palette.NS.ink,
            ]
            // The guessed letter arrives selected, so one keystroke replaces it
            // and doing nothing keeps it.
            editor.selectAll(nil)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var browser: Browser
        var tab: Tab
        var claimed = false
        var typing = false

        init(browser: Browser, tab: Tab) {
            self.browser = browser
            self.tab = tab
        }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            typing = true
            browser.letter(field.stringValue, for: tab)
            // One character only, and shown as it will be worn.
            field.stringValue = tab.pin ?? ""
            typing = false
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy command: Selector
        ) -> Bool {
            switch command {
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.cancelOperation(_:)),
                 #selector(NSResponder.insertTab(_:)):
                browser.endPinEdit()
                return true
            default:
                return false
            }
        }

        func controlTextDidEndEditing(_ note: Notification) {
            let browser = browser
            DispatchQueue.main.async { browser.endPinEdit() }
        }
    }
}
