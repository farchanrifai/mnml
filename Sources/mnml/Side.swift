import SwiftUI

/// The tabs, down the left instead of across the top.
///
/// The same pieces as the strip — the grey that slides to the tab you picked,
/// the pinned squares, the cross that appears under the pointer — laid out the
/// other way. The traffic lights keep their corner; the column starts under
/// them and the page takes the whole height beside it.
struct SideBar: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences

    @Namespace private var pill

    /// What is being dragged in the list — tabs, or a whole group — how
    /// far, and where it would land (see GroupDrop).
    @State private var held: Held?
    /// Where the pointer is, and how far below the held row's top it took hold.
    @State private var pointer: CGFloat = 0
    @State private var pointerX: CGFloat = 0
    @State private var grab: CGFloat = 0
    /// What the list was last rearranged to, so each move is made once.
    @State private var placed: String?
    /// A tab held over the middle of another long enough to make a group of the two.
    @State private var merging: Tab.ID?
    @State private var mergeCandidate: Tab.ID?
    /// Tabs held up over the pinned squares, to be pinned when let go.
    @State private var pinDrop = false
    @State private var pinDropIndex = 0
    @State private var listDrop: GroupDrop.Place?
    @State private var listLanding: CGFloat?
    @State private var pageOrigin: CGPoint = .zero
    @State private var sideBottom: CGFloat = 0
    /// How far the list has scrolled up under the pins: its top, less the
    /// top of the space it scrolls in.
    @State private var listTop: CGFloat = 0
    @State private var listLeft: CGFloat = 0
    @State private var rowsTop: CGFloat = 0
    /// Where each row is, in the list's own space.
    @State private var frames: [RowKey: CGRect] = [:]
    /// How tall the list is, for the empty column below it to drag the window.
    @State private var listHeight: CGFloat = 0

    enum Held: Equatable {
        case tabs([Tab.ID], lead: Tab.ID)
        case group(TabGroup.ID)
    }
    @State private var landing = false
    /// The width the column had when the edge was picked up.
    @State private var grabbed: CGFloat?

    /// The neighbouring spaces' own grey, apart from this one's.
    @Namespace private var before
    @Namespace private var after

    private static let row: CGFloat = 32
    private static let gap: CGFloat = 3
    private static let pinGap: CGFloat = 6

    // The column's highlights: the ink, see-through, rather than a grey of
    // their own, so they lighten a group's colour as they do the column —
    // a flat grey all but vanished over a group, and in the dark.
    //
    // Over the Mac's material in light mode — a mid grey where a dark desktop
    // shows through — the ink all but vanished: there it is stronger. The
    // flat colours made for a white column (Palette.hover, .faint, .wash)
    // are solid, and over the material stood out as white blocks or went
    // unseen; in the column and the strip these stand in for them.
    static var liveFill: Color { fill(0.10, light: 0.14) }
    static var hoverFill: Color { fill(0.06, light: 0.07) }
    static var pinFill: Color { fill(0.07, light: 0.08) }
    static var pinHoverFill: Color { fill(0.10, light: 0.12) }
    static var pinLiveFill: Color { fill(0.15, light: 0.18) }
    /// Quiet text, as New tab's.
    static var faintText: Color { frosted ? Palette.ink.opacity(0.42) : Palette.faint }

    /// Whether the column and the strip wear the Mac's material (Settings ›
    /// Tabs), kept here by Preferences for the fills to ask.
    static var frosted = true

    private static func fill(_ ink: Double, light: Double) -> Color {
        guard frosted else { return Palette.ink.opacity(ink) }
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor.white.withAlphaComponent(ink)
                : NSColor.black.withAlphaComponent(light)
        })
    }
    /// The narrowest a pinned square gets before a row takes one fewer.
    private static let pinCell: CGFloat = 36

    /// The window's buttons' corner: gone in full screen, where macOS takes
    /// them away, and back, forward and reload move up to the edge (idea 184).
    private var lights: CGFloat { browser.fullScreen ? 0 : Metrics.sideLights }

    var body: some View {
        ZStack(alignment: .top) {
            // Not under the card for a new space: it isn't made of views that
            // would take the click first.
            // A double-click in the empty space below the tabs opens a new one
            // (upstream #167), as in Safari and Chrome.
            DragStrip(reserved: 0, below: browser.makingSpace ? .greatestFiniteMagnitude : rowsEnd,
                      onDoubleClick: { browser.newTab() })

            // The band the lights sit in is this mode's title bar: the window
            // is dragged by it and a double-click fills the screen with it,
            // everywhere but over the three doors, which take their own
            // clicks. The lights are the title bar's own and answer first.
            HStack(spacing: 0) {
                DragStrip()
                    .frame(width: 10 + browser.sideLightsRoom)
                Color.clear
                    .frame(width: Metrics.helm)
                    .allowsHitTesting(false)
                DragStrip()
            }
            .frame(height: Metrics.strip)

            VStack(alignment: .leading, spacing: 0) {
                // The traffic lights' corner, with back, forward and reload
                // sitting right of them — the same three doors as the top
                // bar, moved beside the lights since there's no far end of a
                // row to put them at in this mode.
                HStack(spacing: 0) {
                    Color.clear.frame(width: browser.sideLightsRoom)
                        // In full screen, AppKit's buttons, always
                        // there in the column, where a window's sit (see
                        // FullScreenLights).
                        .overlay(alignment: .leading) {
                            if browser.fullScreen {
                                TrafficLights()
                                    .padding(.leading, 20)
                            }
                        }
                    Helm(browser: browser)
                    Spacer(minLength: 0)
                }
                .frame(height: Metrics.strip)

                // The spaces side by side, as pages: two fingers sideways move
                // the one on screen and the next one together, the next one
                // coming in as this one goes, with nothing between them.
                pages

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            // Clear of the foot, which sits over the column's bottom edge.
            .padding(.bottom, SideBar.footHeight)

            VStack {
                Spacer()
                foot
            }
        }
        .frame(width: prefs.sideWidth)
        .frame(maxHeight: .infinity)
        .background {
            GeometryReader { box in
                Color.clear
                    .onAppear { sideBottom = box.frame(in: .global).maxY - SideBar.footHeight }
                    .onChange(of: box.frame(in: .global).maxY) { _, bottom in sideBottom = bottom - SideBar.footHeight }
            }
        }
        // Rows on their way to or from another space stay in the column.
        .clipped()
        .onAppear { SpaceSwipe.shared.start(for: browser) }
        .background {
            Group {
                if prefs.frostedSidebar {
                    Frosted(blending: browser.pageUnder ? Under.blending : .behindWindow)
                        .overlay { if landing { SideBar.hoverFill } }
                } else {
                    landing ? Palette.hover : Palette.ground
                }
            }
            .overlay { TintWash(browser: browser, prefs: prefs) }
        }
        // No line down the column's edge, as in Arc: the column's own ground
        // or material is edge enough.
        .overlay(alignment: .trailing) { edge }
        .onDrop(of: [.url, .text], isTargeted: $landing) { providers in
            browser.take(providers)
        }
        .animation(Motion.quick, value: landing)
        .animation(browser.prefs.slidesHighlight ? Motion.glide : nil, value: browser.activeID)
        .animation(Motion.glide, value: browser.editingTab)
        .animation(Motion.settle, value: browser.tabs.map(\.id))
        .animation(Motion.settle, value: browser.pinnedCount)
        // The last square made the first row changes nothing in the row's
        // order; only how many of each there are.
        .animation(Motion.settle, value: browser.listedPins.count)
    }

    /// The column's edge: pull it to make the column wider or narrower,
    /// double-click it to put it back. Nothing drawn: the pointer turning to
    /// the resize arrows is what says it can be taken.
    private var edge: some View {
        Color.clear
            // Across the edge, half over the page, so it can be found
            // without aiming for a line that isn't drawn.
            .frame(width: 14)
            .contentShape(Rectangle())
            .offset(x: 7)
            .onHover { over in
                if over { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if grabbed == nil { grabbed = prefs.sideWidth }
                        let wanted = (grabbed ?? prefs.sideWidth) + value.translation.width
                        prefs.sideWidth = min(Metrics.sideMax, max(Metrics.sideMin, wanted))
                    }
                    .onEnded { _ in grabbed = nil }
            )
            .modifier(OneClick(double: true) {
                withAnimation(Motion.settle) { prefs.sideWidth = Metrics.side }
            })
    }

    // MARK: - the spaces, as pages

    /// Where the space on screen sits among them: one past the last while
    /// the card for a new one is up.
    private var spaceAt: Int {
        browser.makingSpace ? browser.spaces.count : (browser.spaces.firstIndex { $0.id == browser.spaceID } ?? 0)
    }

    private var pages: some View {
        let width = prefs.sideWidth
        let swipe = browser.spaceSwipe
        let at = spaceAt
        return ZStack(alignment: .topLeading) {
            page(at, pill: pill)
                .offset(x: swipe)
            // Only while the fingers are bringing one in: the one they are
            // bringing, a page's width away.
            if swipe > 0, at > 0 {
                page(at - 1, pill: before)
                    .offset(x: swipe - width)
            }
            if swipe < 0, at < browser.spaces.count - 1 {
                page(at + 1, pill: after)
                    .offset(x: swipe + width)
            }
        }
        // The pages are the column's whole width, each with its own margin.
        .padding(.horizontal, -10)
        .frame(maxHeight: .infinity, alignment: .top)
        .offset(x: browser.rowShift)
        .opacity(browser.rowFade)
    }

    /// One space's page: the rows on screen, another space's rows as they
    /// were left, or past the last the card for a new one.
    @ViewBuilder
    private func page(_ index: Int, pill: Namespace.ID) -> some View {
        Group {
            if index == browser.spaces.count {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    NewSpaceCard(browser: browser)
                    Spacer(minLength: 0)
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity)
            } else if browser.spaces[index].id == browser.spaceID {
                VStack(alignment: .leading, spacing: 0) {
                    if !pinPreview.isEmpty {
                        pinned
                            .padding(.bottom, 12)
                    }
                    // A row too long for the window scrolls between the pins
                    // and the foot, rather than running under the lights at one
                    // end and the foot at the other. While it fits it stays a
                    // plain stack, and the space under it is still the
                    // window's to be dragged by. Inside the page: the swipe
                    // between spaces moves the page, scroll and all.
                    ViewThatFits(in: .vertical) {
                        rows
                        ScrollViewReader { proxy in
                            // The scroll view reaches into the margin on
                            // the right and the rows keep it inside, so the
                            // system's bar lands in the margin beside them
                            // rather than over the cross on the tab under the
                            // pointer. The column's edge lies over that margin
                            // and answers first, so the bar never fights the
                            // resize; the wheel and the trackpad still scroll.
                            ScrollView(.vertical) {
                                rows.padding(.trailing, 10)
                            }
                            .padding(.trailing, -10)
                            // The tab you go to is the tab you see — ⌘1–⌘9,
                            // ⇧⌘], a link opening beside the one on screen.
                            .onChange(of: browser.activeID) { _, id in
                                guard let id else { return }
                                withAnimation(Motion.glide) { proxy.scrollTo(id) }
                            }
                            .onAppear {
                                if let id = browser.activeID { proxy.scrollTo(id, anchor: .center) }
                            }
                        }
                    }
                    .background {
                        // Where the rows start, under the pins, however far
                        // they are scrolled (see `drag`).
                        GeometryReader { box in
                            Color.clear
                                .onAppear { rowsTop = box.frame(in: .global).minY }
                                .onChange(of: box.frame(in: .global).minY) { _, top in rowsTop = top }
                        }
                    }
                }
                .background {
                    // How tall the list is, for the empty column below it
                    // to drag the window by.
                    GeometryReader { box in
                        Color.clear
                            .onAppear {
                                listHeight = box.size.height
                                pageOrigin = box.frame(in: .global).origin
                            }
                            .onChange(of: box.size.height) { _, height in listHeight = height }
                            .onChange(of: box.frame(in: .global).origin) { _, origin in
                                pageOrigin = origin
                            }
                    }
                }
                // The source view may change between a square and a row.
                // Keep its gesture and preview on their common parent.
                .contentShape(Rectangle())
                .simultaneousGesture(
                    DragGesture(minimumDistance: 5, coordinateSpace: .global)
                        .onChanged { value in
                            guard let what = held ?? pick(at: value.startLocation) else { return }
                            drag(what, value)
                        }
                        .onEnded { _ in finishDrag() }
                )
                .overlay(alignment: .topLeading) {
                    ghost
                        .opacity(browser.splitDrag == nil ? 1 : 0)
                        .transaction { $0.animation = nil }
                }
            } else {
                preview(browser.parked[browser.spaces[index].id] ?? Parked(tabs: [], active: nil), pill: pill)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: prefs.sideWidth, alignment: .topLeading)
    }

    /// Another space's rows, drawn with the same pieces as this one's so the
    /// two read as one column while they pass — and nothing to press until
    /// it is the one on screen.
    private func preview(_ row: Parked, pill: Namespace.ID) -> some View {
        let pins = row.tabs.filter { $0.pin != nil && !($0.listed && prefs.showsPinRows) }
        let listed = prefs.showsPinRows ? row.tabs.filter { $0.pin != nil && $0.listed } : []
        let rest = row.tabs.filter { $0.pin == nil }
        let cells = pinCells(pins.count)
        return VStack(alignment: .leading, spacing: 0) {
            if !pins.isEmpty {
                VStack(spacing: 0) {
                    PinGrid(cells: cells) {
                        ForEach(Array(pins.enumerated()), id: \.element.id) { index, tab in
                            PinSquare(browser: browser, prefs: prefs, tab: tab, live: tab.id == row.active,
                                      pill: pill, width: cells[index].width, height: cells[index].height)
                        }
                    }
                    .padding(.horizontal, -4)
                }
                .padding(.bottom, 12)
            }
            newTab(at: .top)
            VStack(spacing: SideBar.gap) {
                ForEach(listed) { tab in
                    SideRow(browser: browser, prefs: prefs, tab: tab, live: tab.id == row.active,
                            pill: pill, close: {})
                }
                // Groups aren't drawn here, so the line goes over all the rest.
                if !pins.isEmpty || !listed.isEmpty {
                    KeepLine(clears: false) {}
                }
                ForEach(rest) { tab in
                    SideRow(browser: browser, prefs: prefs, tab: tab, live: tab.id == row.active, pill: pill, close: {})
                }
            }
            newTab(at: .bottom)
        }
        .allowsHitTesting(false)
    }

    /// Where the rows stop and the window's own drag area starts. Added up
    /// from what was drawn rather than measured: a measurement would arrive a
    /// frame late, and for one frame the whole column would drag the window.
    /// Where the list ends — measured, since groups fold and a line comes
    /// and goes — and the empty column below it starts.
    private var rowsEnd: CGFloat {
        Metrics.strip + listHeight + 8
    }

    // MARK: - the pinned squares

    private var pinnedTabs: [Tab] { browser.squarePins }

    /// One size and column count for the whole grid, including its last row.
    static func pinCells(_ count: Int, width: CGFloat) -> [CGRect] {
        guard count > 0 else { return [] }
        let room = max(20, width - 12)
        let gap = SideBar.pinGap
        let columns = min(4, max(1, Int((room + gap) / (SideBar.pinCell + gap))))
        let side = (room - CGFloat(columns - 1) * gap) / CGFloat(columns)
        return (0..<count).map { index in
            CGRect(x: CGFloat(index % columns) * (side + gap),
                   y: CGFloat(index / columns) * (side + gap), width: side, height: side)
        }
    }

    private func pinCells(_ count: Int) -> [CGRect] { Self.pinCells(count, width: prefs.sideWidth) }

    /// A drop slot follows the pointer without changing the saved pins.
    private var pinPreview: [Tab?] {
        if !pinDrop { return pinnedTabs.map { isHeld($0) ? nil : $0 } }
        var pins = pinnedTabs.filter { !isHeld($0) }.map(Optional.some)
        if pinDrop, case .tabs(let ids, _)? = held {
            pins.insert(contentsOf: Array(repeating: nil, count: ids.count), at: min(pinDropIndex, pins.count))
        }
        return pins
    }

    private var pinned: some View {
        let pins = pinPreview
        let cells = pinCells(pins.count)
        return PinGrid(cells: cells) {
            ForEach(pins.compactMap { $0 }) { tab in
                if let index = pins.firstIndex(where: { $0?.id == tab.id }) {
                    PinSquare(browser: browser, prefs: prefs, tab: tab,
                              live: tab.id == browser.activeID, pill: pill,
                              width: cells[index].width, height: cells[index].height)
                        .layoutValue(key: PinSlot.self, value: index)
                }
            }
            ForEach(pins.indices.filter { pins[$0] == nil }, id: \.self) { index in
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(SideBar.pinFill)
                    .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.ink.opacity(0.16), lineWidth: 1) }
                    .frame(width: cells[index].width, height: cells[index].height)
                    .layoutValue(key: PinSlot.self, value: index)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, -4)
        .animation(Motion.settle, value: pinDropIndex)
        .animation(Motion.settle, value: pins.count)
    }

    static func pinTarget(at point: CGPoint, count: Int, width: CGFloat) -> Int {
        let cells = pinCells(count + 1, width: width)
        return cells.indices.min {
            hypot(cells[$0].midX - point.x, cells[$0].midY - point.y)
                < hypot(cells[$1].midX - point.x, cells[$1].midY - point.y)
        } ?? 0
    }

    // MARK: - the rows

    /// A tab by itself, or a group with its tabs, in the order of the row.
    private typealias Entry = TabRowEntry

    /// Above the line (pinned groups) or below it (everything else).
    private func entries(pinned: Bool) -> [Entry] {
        Entry.entries(tabs: browser.tabs, groups: browser.groups, pinned: pinned)
    }

    /// A line under the pinned squares and pinned groups, when there are any.
    private var hasLine: Bool { browser.pinnedCount > 0 || browser.groups.contains(where: \.pinned) }

    private var list: some View {
        let pinnedGroups = entries(pinned: true)
        return VStack(alignment: .leading, spacing: 0) {
            if !browser.listedPins.isEmpty {
                VStack(spacing: SideBar.gap) {
                    ForEach(browser.listedPins) { tab in tabRow(tab) }
                }.padding(.bottom, 8)
            }
            if !pinnedGroups.isEmpty {
                VStack(spacing: SideBar.gap) {
                    ForEach(pinnedGroups) { entry in entryView(entry) }
                }
                .padding(.bottom, 8)
            }
            if hasLine {
                KeepLine(clears: browser.tabs.contains { $0.pin == nil && $0.group == nil && !$0.bench }) { browser.clearTabs() }
                    .report(.line).padding(.bottom, 8)
            }
            newTab(at: .top)
            VStack(spacing: SideBar.gap) {
                ForEach(entries(pinned: false)) { entry in entryView(entry) }
            }
            .padding(.top, prefs.showsNewTab && prefs.newTabs == .top ? SideBar.gap : 0)
            newTab(at: .bottom)
                .padding(.top, SideBar.gap)
        }
        .coordinateSpace(name: "column")
        .onPreferenceChange(RowFrames.self) { frames = $0; if !Bench.drawingColumn { Bench.rowFrames = $0 } }
        .background {
            // Where the list sits in the window, for the bench's drags.
            GeometryReader { box in
                Color.clear
                    .onAppear {
                        listTop = box.frame(in: .global).minY
                        listLeft = box.frame(in: .global).minX
                        if !Bench.drawingColumn { Bench.listOrigin = box.frame(in: .global).origin }
                    }
                    .onChange(of: box.frame(in: .global).origin) { _, origin in
                        listTop = origin.y
                        listLeft = origin.x
                        if !Bench.drawingColumn { Bench.listOrigin = origin }
                    }
            }
        }
        .animation(Motion.settle, value: browser.groups)
    }

    @ViewBuilder
    private func entryView(_ entry: Entry) -> some View {
        switch entry {
        case .tab(let tab):
            tabRow(tab)
        case .group(let group, let members):
            // Held, the group keeps its place in the list, unseen, while a
            // copy of it follows the hand (see `ghost`).
            GroupBlock(browser: browser, group: group, members: members, row: { tabRow($0) })
                // Room around a group whose tabs show, so two in a row don't
                // run together; folded to its name alone it is spaced like a tab.
                .padding(.vertical, group.open || members.contains { $0.id == group.peek } ? 8 : 0)
                .opacity(held == .group(group.id) ? 0 : 1)
        }
    }

    private func isHeld(_ tab: Tab) -> Bool { isHeld(tab.id) }

    private func isHeld(_ id: Tab.ID) -> Bool {
        if case .tabs(let ids, _)? = held { return ids.contains(id) }
        return false
    }

    /// A tab's line — or, for the two halves of a split, one line for both,
    /// drawn where the left one is.
    @ViewBuilder
    private func tabRow(_ tab: Tab) -> some View {
        if let split = browser.split(of: tab.id) {
            if split.left == tab.id { pairRow(split) }
        } else {
            singleRow(tab)
        }
    }

    /// The two halves of a split side by side in one line, each its own tab
    /// to click, close or right-click.
    private func pairRow(_ split: Split, ghost: Bool = false) -> some View {
        HStack(spacing: 0) {
            ForEach(Array([split.left, split.right].enumerated()), id: \.element) { index, id in
                if index == 1 {
                    Rectangle()
                        .fill(Palette.hairline)
                        .frame(width: 1, height: 14)
                }
                if let tab = browser.tab(id) {
                    SideRow(
                        browser: browser,
                        prefs: prefs,
                        tab: tab,
                        live: !ghost && id == browser.activeID,
                        pill: pill,
                        close: { browser.close(tab) }
                    )
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(!ghost && browser.shownSplit == split ? SideBar.hoverFill : .clear)
        )
        .report(.tab(split.left), when: !ghost)
        .id(split.left)
        .opacity(!ghost && isHeld(split.left) ? 0 : 1)
    }

    private func singleRow(_ tab: Tab) -> some View {
        let lifted = isHeld(tab)
        return SideRow(
            browser: browser,
            prefs: prefs,
            tab: tab,
            live: tab.id == browser.activeID,
            pill: pill,
            close: { browser.close(tab) }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Palette.ink.opacity(merging == tab.id ? 0.45 : 0), lineWidth: 1.5)
        )
        .report(.tab(tab.id))
        // For the list to scroll to, when it scrolls (see `page`).
        .id(tab.id)
        // Held, it keeps its place in the list, unseen — that place is what
        // is measured, and moves as the list rearranges — while a copy
        // follows the hand (see `ghost`). Drawing the row itself shifted
        // measured the shift too, and chasing it never ended.
        .opacity(lifted ? 0 : 1)
    }

    /// What a drag starting here picks up: the tab under it — with the other
    /// picked tabs, if it is one of them — or a group, by its name.
    private func pick(at point: CGPoint) -> Held? {
        let pins = pinnedTabs
        let cells = pinCells(pins.count)
        let inPins = CGPoint(x: point.x - pageOrigin.x + 4, y: point.y - pageOrigin.y)
        if let index = cells.firstIndex(where: { $0.contains(inPins) }) {
            return .tabs([pins[index].id], lead: pins[index].id)
        }
        let inList = CGPoint(x: point.x - listLeft, y: point.y - listTop)
        for (key, frame) in frames where frame.contains(inList) {
            switch key {
            case .tab(let id):
                // A split is picked up whole.
                if let split = browser.split(of: id) { return .tabs([split.left, split.right], lead: split.left) }
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

    // MARK: - dragging in the list

    /// The rows on screen, top to bottom, less whatever is being dragged.
    private func dropRows(without held: Held) -> [(row: GroupDrop.Row, key: RowKey)] {
        var out: [(GroupDrop.Row, RowKey)] = []
        func add(_ entry: Entry) {
            switch entry {
            case .tab(let tab):
                if case .tabs(let ids, _) = held, ids.contains(tab.id) { return }
                // A split's right half has no line of its own.
                if browser.split(of: tab.id)?.right == tab.id { return }
                out.append((.tab(tab.id, group: nil), .tab(tab.id)))
            case .group(let group, let members):
                if held == .group(group.id) { return }
                out.append((.header(group.id, open: group.open), .header(group.id)))
                for tab in members where group.open || tab.id == group.peek {
                    if case .tabs(let ids, _) = held, ids.contains(tab.id) { continue }
                    if browser.split(of: tab.id)?.right == tab.id { continue }
                    out.append((.tab(tab.id, group: group.id), .tab(tab.id)))
                }
            }
        }
        entries(pinned: true).forEach(add)
        if hasLine { out.append((.line, .line)) }
        entries(pinned: false).forEach(add)
        return out
    }

    /// The held row's key: its own, or its group's name.
    private func key(of held: Held) -> RowKey {
        switch held {
        case .tabs(_, let lead): return .tab(lead)
        case .group(let id): return .header(id)
        }
    }

    /// What is held, drawn where the hand is, over the list.
    @ViewBuilder
    private var ghost: some View {
        if let listLanding, !pinDrop {
            RoundedRectangle(cornerRadius: 1)
                .fill(Palette.ink.opacity(0.25))
                .frame(width: prefs.sideWidth - 20, height: 2)
                .offset(y: listTop - pageOrigin.y + listLanding - 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        switch held {
        case .tabs(let ids, let lead)?:
            if ids.count > 1, let split = browser.split(of: lead) {
                pairRow(split, ghost: true)
                    .background(Palette.ground.opacity(0.92), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
                    .offset(y: pointer - pageOrigin.y - grab)
                    .allowsHitTesting(false)
            } else if let tab = browser.tabs.first(where: { $0.id == lead }) {
                let side = pinCells(1)[0].width
                Group {
                    if pinDrop {
                        PinSquare(browser: browser, prefs: prefs, tab: tab, live: false, pill: pill, width: side, height: side)
                    } else {
                        SideRow(browser: browser, prefs: prefs, tab: tab, live: false, pill: pill, close: {})
                    }
                }
                    .frame(width: pinDrop ? side : prefs.sideWidth - 20, height: pinDrop ? side : SideBar.row)
                    .background(Palette.ground.opacity(0.92), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.ink.opacity(0.16), lineWidth: 1) }
                    .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
                    .animation(Motion.quick, value: pinDrop)
                    .offset(x: pinDrop ? pointerX - pageOrigin.x - side / 2 : 0,
                            y: pointer - pageOrigin.y - (pinDrop ? side / 2 : min(grab, SideBar.row)))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        case .group(let id)?:
            if let group = browser.group(id) {
                GroupBlock(browser: browser, group: group, members: browser.members(of: id), row: { tab in
                    SideRow(browser: browser, prefs: prefs, tab: tab, live: false, pill: pill, close: {})
                }, reports: false)
                .background(Palette.ground.opacity(0.92), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
                .offset(y: pointer - pageOrigin.y - grab)
                .allowsHitTesting(false)
            }
        case nil:
            EmptyView()
        }
    }

    /// Picked up and moved: the list rearranges around it as it goes,
    /// tabs into and out of groups on the way. Held over the middle of a
    /// tab on its own, it waits instead — a moment there makes a group of
    /// the two.
    private func drag(_ what: Held, _ value: DragGesture.Value) {
        if held == nil {
            held = what
            if case .tabs(_, let lead) = what, let index = pinnedTabs.firstIndex(where: { $0.id == lead }) {
                grab = value.startLocation.y - pageOrigin.y - pinCells(pinnedTabs.count)[index].minY
            } else {
                grab = value.startLocation.y - listTop - (frames[key(of: what)]?.minY ?? value.startLocation.y - listTop)
            }
        }
        guard let held else { return }
        pointer = value.location.y
        pointerX = value.location.x
        let y = value.location.y - listTop
        let left = pageOrigin.x - 10
        let right = left + prefs.sideWidth

        // Out past the column's edge, over the page: let go on one of its two
        // places and the tab opens beside the one on screen (Split.swift).
        if case .tabs(let ids, let lead) = held, ids.count == 1, browser.canSplit(lead) {
            let at = value.location
            if at.x > right + 8 || at.x < left - 8 {
                browser.dragSplit(lead, at: at)
                return
            }
            if browser.splitDrag != nil { browser.cancelSplitDrag() }
        }

        // Up past the top of the list, among the pinned squares: let go there
        // and the tabs are pinned.
        let pinning: Bool
        if case .tabs(let ids, _) = held {
            pinning = value.location.y >= max(0, pageOrigin.y - (pinnedTabs.isEmpty ? 24 : 0)) && value.location.y < rowsTop
                && value.location.x >= left + 6 && value.location.x < right
                && browser.tabs.filter { ids.contains($0.id) }.allSatisfy { !$0.shy }
        } else { pinning = false }
        if pinning != pinDrop {
            withAnimation(Motion.quick) { pinDrop = pinning }
            browser.feelDrag(firm: true)
        }
        if pinning {
            let remaining = pinnedTabs.filter { !isHeld($0) }
            let point = CGPoint(x: value.location.x - pageOrigin.x + 4, y: value.location.y - pageOrigin.y)
            let target = Self.pinTarget(at: point, count: remaining.count, width: prefs.sideWidth)
            if target != pinDropIndex { browser.feelDrag() }
            pinDropIndex = target
            merging = nil
            mergeCandidate = nil
            listDrop = nil
            listLanding = nil
            return
        }
        guard value.location.y >= rowsTop, value.location.y < sideBottom,
              value.location.x >= left, value.location.x < right else {
            listDrop = nil
            listLanding = nil
            merging = nil
            mergeCandidate = nil
            return
        }
        let rows = dropRows(without: held)
        let gap = rows.filter { (frames[$0.key]?.midY ?? .infinity) < y }.count
        let row = rows.map(\.row)
        listDrop = GroupDrop.tab(at: gap, in: row)
        let fromGrid = browser.tabs.contains { isHeld($0) && $0.pin != nil }
        if fromGrid {
            // Show the gap without unpinning (and syncing other windows)
            // until release. An empty regular list still has a first gap.
            switch listDrop {
            case .loose(before: .tab(let id))?: listLanding = frames[.tab(id)]?.minY
            case .loose(before: .group(let id))?: listLanding = frames[.header(id)]?.minY
            case .loose(before: nil)?: listLanding = rows.last.flatMap { frames[$0.key]?.maxY } ?? max(0, rowsTop - listTop)
            default: listLanding = gap < rows.count ? frames[rows[gap].key]?.minY : rows.last.flatMap { frames[$0.key]?.maxY }
            }
        } else { listLanding = nil }

        var over: Tab.ID?
        if case .tabs = held {
            for (row, key) in rows {
                guard case .tab(let id, nil) = row, browser.split(of: id) == nil, let frame = frames[key] else { continue }
                if y > frame.minY + frame.height * 0.28, y < frame.maxY - frame.height * 0.28 { over = id }
            }
        }
        if over != mergeCandidate {
            mergeCandidate = over
            merging = nil
            if let over {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if mergeCandidate == over, self.held != nil {
                    withAnimation(Motion.quick) { merging = over }
                    browser.feelDrag(firm: true)
                }
                }
            }
        }
        guard over == nil else { return }
        guard !fromGrid else { return }
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
        defer {
            withAnimation(Motion.settle) {
                held = nil
                pinDrop = false
                pinDropIndex = 0
                listDrop = nil
                listLanding = nil
                placed = nil
                merging = nil
                mergeCandidate = nil
            }
        }
        if browser.splitDrag != nil {
            browser.dropSplit()
            return
        }
        if case .tabs(let ids, let lead)? = held, ids.count == 1, !pinDrop, merging == nil,
           let tab = browser.tabs.first(where: { $0.id == lead }), browser.dragOut(tab) {
            return
        }
        if case .tabs(let ids, _)? = held, pinDrop {
            withAnimation(Motion.settle) {
                let remaining = pinnedTabs.filter { !ids.contains($0.id) }
                let before = remaining.indices.contains(pinDropIndex) ? remaining[pinDropIndex].id : nil
                browser.placePins(browser.tabs.filter { ids.contains($0.id) }, before: before)
            }
        } else if case .tabs(let ids, _)? = held {
            let moving = browser.tabs.filter { ids.contains($0.id) }
            if let listDrop, moving.contains(where: { $0.pin != nil }) {
                withAnimation(Motion.settle) {
                    moving.filter { $0.pin != nil }.forEach { browser.unpin($0) }
                    browser.place(moving, listDrop)
                    browser.writeSession(now: true)
                }
            }
        }
        if case .tabs(let ids, _)? = held, let merging, let target = browser.tabs.first(where: { $0.id == merging }) {
            withAnimation(Motion.settle) {
                browser.makeGroup(of: [target] + browser.tabs.filter { ids.contains($0.id) })
            }
        }
    }

    /// The space's list — pinned groups, the line, New tab, then its tabs
    /// and groups (see `list`) — which scrolls as one when it is too long.
    private var rows: some View { list }

    /// The foot's door and its margin beneath.
    private static let footHeight: CGFloat = 26 + 10

    /// The New tab button, where new tabs go (Settings › Tabs), or nowhere.
    @ViewBuilder
    private func newTab(at place: NewTabs) -> some View {
        if prefs.showsNewTab, prefs.newTabs == place { newTab }
    }

    private var newTab: some View {
        Quiet(icon: "plus", title: "New tab", height: SideBar.row) { browser.newTab() }
    }

    /// One small door at the bottom: the settings.
    private var foot: some View {
        HStack(spacing: 2) {
            SpaceDot(browser: browser)
            ExtensionSlot(edge: .trailing)
            Door(icon: "bookmark", help: "Bookmarks") { browser.bookmarksOpen.toggle() }
                .popover(isPresented: $browser.bookmarksOpen, arrowEdge: .trailing) {
                    BookmarksDropdown(browser: browser, bookmarks: browser.bookmarks)
                }
            // Only while a download is running, and a moment after.
            FetchDoor(browser: browser, fetches: browser.fetches)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

}

/// The pinned squares' grid, every cell laid out at once. A lazy grid makes
/// its cells only once the column is on screen, where the column's slide
/// can't take them along: folded with ⌘S and brought back, the squares stood
/// in place while the column came in beneath them. A dozen squares need no
/// laziness.
private struct PinSlot: LayoutValueKey { static let defaultValue = -1 }

private struct PinGrid: Layout {
    let cells: [CGRect]

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: cells.map(\.maxX).max() ?? 0, height: cells.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (fallback, subview) in subviews.enumerated() {
            let index = subview[PinSlot.self] < 0 ? fallback : subview[PinSlot.self]
            guard cells.indices.contains(index) else { continue }
            let cell = cells[index]
            subview.place(at: CGPoint(x: bounds.minX + cell.minX, y: bounds.minY + cell.minY),
                          proposal: ProposedViewSize(width: cell.width, height: cell.height))
        }
    }
}

/// A pinned tab in an evenly sized square, with a restrained glyph size.
private struct PinSquare: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var tab: Tab
    let live: Bool
    let pill: Namespace.ID
    var width: CGFloat = 36
    var height: CGFloat = 38

    @State private var hovering = false

    /// Everything drawn inside scales off the shorter edge — the one that
    /// stays put — so the glyph sits at its usual size, centred, rather than
    /// stretching to chase the width.
    private var scale: CGFloat { min(width, height, 38) }

    var body: some View {
        Group {
            if browser.editingPin == tab.id {
                PinField(browser: browser, tab: tab)
            } else if tab.loading {
                // Its page on the way, as a row's ring says (upstream).
                Ring(size: scale * 11 / 34)
            } else if prefs.glyph == .icons, let icon = tab.icon {
                Mark(icon: icon, letter: tab.pin ?? tab.monogram, size: scale * 16 / 34, dim: tab.asleep)
            } else {
                Text(tab.pin ?? tab.monogram)
                    .font(.system(size: scale * 12 / 34, weight: .medium))
                    .foregroundStyle((live ? Palette.ink : Palette.muted).opacity(tab.asleep ? 0.45 : 1))
            }
        }
        .frame(width: scale * 16 / 34, height: scale * 16 / 34)
        .frame(width: width, height: height)
        .background {
            if live {
                // Darker than the resting squares' grey by as much as a live
                // row is darker than the white it sits on (Drice: the live
                // pin barely showed among the others).
                RoundedRectangle(cornerRadius: scale * 9 / 34, style: .continuous)
                    .fill(SideBar.pinLiveFill)
                    .matchedGeometryEffect(id: "live", in: pill)
            } else {
                RoundedRectangle(cornerRadius: scale * 9 / 34, style: .continuous)
                    .fill(hovering ? SideBar.pinHoverFill : SideBar.pinFill)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: scale * 9 / 34, style: .continuous))
        .modifier(OneClick(double: live) {
            // Double-clicked after wandering off: home (PinnedHome.swift).
            if tab.strayed, NSApp.currentEvent?.clickCount == 2 { browser.goHome(tab); return }
            if live { browser.editLetter(tab) } else { browser.select(tab) }
        })
        // Put down, like ⌘W: close() is what knows a pin isn't removed.
        .overlay { MiddleClick { browser.close(tab) } }
        .onHover { hovering = $0 }
        .contextMenu { TabMenu(browser: browser, tab: tab, close: { browser.close(tab) }) }
        .help(tab.strayed ? "\(tab.label) — double-click to go back to the pinned page" : tab.label)
        .animation(Motion.quick, value: hovering)
        .transition(.scale(scale: 0.8).combined(with: .opacity))
    }
}

/// One tab, as a line in the column.
struct SideRow: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var tab: Tab
    let live: Bool
    let pill: Namespace.ID
    let close: () -> Void

    @State private var hovering = false
    @State private var shake: CGFloat = 0
    /// The row in the window, for its preview to open beside (TabPreview).
    @State private var spot: CGRect = .zero
    /// The pointer on the way home: the icon of a wandered-off pinned tab.
    @State private var homeHover = false

    private var editing: Bool { browser.editingTab == tab.id }
    /// Something laid over the end of the title: the cross, the ring, the speaker.
    private var marked: Bool { hovering || tab.loading || speaker }
    /// The speaker, which can be pressed to mute the tab, and so steps in
    /// beside the cross under the pointer rather than hiding beneath it.
    private var speaker: Bool { !tab.loading && (tab.noisy || tab.muted) }

    var body: some View {
        HStack(spacing: 8) {
            if editing {
                TabAddressField(browser: browser)
                    .frame(height: 17)
            } else {
                if tab.pin == nil, tab.strayed {
                    // In a pinned group and wandered off: the icon and a "/",
                    // which take it home, as in Dia (PinnedHome.swift).
                    // Under the pointer the icon turns into the way back, on
                    // a small plate, so it reads as a button.
                    HStack(spacing: 5) {
                        if homeHover {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Palette.ink)
                                .frame(width: 16, height: 16)
                        } else if prefs.glyph == .icons {
                            Mark(icon: tab.icon, letter: tab.monogram, size: 16)
                        }
                        Text("/")
                            .font(.system(size: 13, weight: .light))
                            .foregroundStyle(homeHover ? Palette.ink : Palette.muted)
                    }
                    .padding(.horizontal, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(homeHover ? SideBar.hoverFill : .clear)
                            .padding(.vertical, -3)
                    )
                    .padding(.horizontal, -3)
                    .contentShape(Rectangle())
                    .onTapGesture { browser.goHome(tab) }
                    .onHover { over in
                        homeHover = over
                        if over { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                    // Gone from under the pointer — a click took it home —
                    // the hand goes with it.
                    .onDisappear { if homeHover { homeHover = false; NSCursor.pop() } }
                    .animation(Motion.quick, value: homeHover)
                    .help("Back to Pinned URL")
                } else if prefs.glyph == .icons, !tab.isBlank {
                    Mark(icon: tab.icon, letter: tab.monogram, size: 16)
                }
                if tab.bench {
                    // A script's tab, not yours.
                    Image(systemName: "flask")
                        .font(.system(size: 9))
                        .foregroundStyle(colour.opacity(0.7))
                }
                if tab.shy {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 9))
                        .foregroundStyle(colour.opacity(0.7))
                }
                // The title has the rest of the row and fades out at its end,
                // as in Dia, rather than giving up room to a cross that isn't
                // there; the cross, the ring or the speaker is laid over the
                // end instead, and the fade starts before it while one shows.
                // Laid over room the row gives it, so a long title can't widen
                // the row.
                Color.clear
                    .frame(maxWidth: .infinity, minHeight: 17, maxHeight: 17)
                    .overlay(alignment: .leading) {
                        Text(tab.label)
                            .font(.system(size: 13.5, weight: live ? .medium : .regular))
                            .lineLimit(1)
                            .fixedSize()
                            .foregroundStyle(colour)
                    }
                    .clipped()
                    .mask {
                        HStack(spacing: 0) {
                            Rectangle()
                            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: 18)
                            Color.clear.frame(width: hovering && speaker ? 43 : (marked ? 20 : 0))
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .trailing) {
            if !editing {
                HStack(spacing: 8) {
                    if hovering && speaker { Speaker(tab: tab).transition(.opacity) }
                    ZStack {
                        if hovering {
                            Image(systemName: tab.pin != nil ? "minus" : "xmark")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(Palette.muted)
                                .frame(width: 15, height: 15)
                                .background(Palette.ink.opacity(0.07), in: Circle())
                                .transition(.opacity)
                        } else if tab.loading {
                            Ring().transition(.opacity)
                        } else if speaker {
                            Speaker(tab: tab).transition(.opacity)
                        }
                    }
                    .frame(width: 15, height: 15)
                    .overlay {
                        Color.clear
                            .frame(width: 30, height: 32)
                            .contentShape(Rectangle())
                            .onTapGesture { if hovering { close() } }
                            .allowsHitTesting(hovering)
                    }
                }
                .animation(Motion.quick, value: hovering)
                .animation(Motion.quick, value: tab.loading)
                .animation(Motion.quick, value: speaker)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, editing ? 10 : 7)
        .frame(height: 32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { ground }
        .modifier(Shake(travel: shake))
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .modifier(OneClick(double: false) {
            // ⌘-click picks tabs, ⇧-click a run of them, for the menu to act
            // on together; a plain click is the tab, and lets the pick go.
            TabPreview.shared.hide()
            let flags = NSEvent.modifierFlags
            if flags.contains(.command) { browser.toggleChosen(tab); return }
            if flags.contains(.shift) { browser.chooseRange(to: tab); return }
            browser.chosen = []
            // The address opens on a double-click, not a single one: a click
            // meant for a wandered-off tab's way home, missed by a little,
            // opened the address instead.
            if live {
                if NSApp.currentEvent?.clickCount == 2 { browser.beginTabEdit(tab) }
            } else {
                browser.select(tab)
            }
        })
        .overlay { MiddleClick(act: close) }
        .background {
            GeometryReader { box in
                Color.clear
                    .onAppear { spot = box.frame(in: .global) }
                    .onChange(of: box.frame(in: .global)) { _, frame in spot = frame }
            }
        }
        .onHover { over in
            hovering = over
            // Beside the column's edge with a gap, not the row's: the row
            // ends just inside it, and the card sat flush against it.
            var edge = spot
            edge.size.width = max(spot.width, prefs.sideWidth - spot.minX + 4)
            TabPreview.shared.hover(over, tab: tab, browser: browser, beside: edge)
        }
        .onDisappear { if hovering { TabPreview.shared.hide() } }
        .contextMenu { TabMenu(browser: browser, tab: tab, close: close) }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.glide, value: editing)
        .onChange(of: browser.refusals) { _, _ in
            guard editing, !Motion.reduced else { return }
            shake = 0
            withAnimation(.easeOut(duration: 0.5)) { shake = 1 }
        }
        .transition(.scale(scale: 0.94, anchor: .leading).combined(with: .opacity))
    }

    @ViewBuilder
    private var ground: some View {
        if live {
            ZStack(alignment: .leading) {
                Rectangle().fill(SideBar.liveFill)
                if prefs.showsReading {
                    GeometryReader { geo in
                        ReadingFill(reading: tab.reading, span: geo.size.width)
                    }
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
                .fill(SideBar.hoverFill)
        }
    }

    private var colour: Color {
        if live { return Palette.ink }
        return Palette.ink.opacity(hovering ? 0.9 : 0.78)
    }
}

/// A row that is an action rather than a page. Quiet until the pointer is on it.
struct Quiet: View {
    let icon: String
    let title: String
    var height: CGFloat = 28
    let act: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: act) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 15)
                Text(title)
                    .font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .foregroundStyle(hovering ? Palette.ink.opacity(0.7) : SideBar.faintText)
            .padding(.leading, 10)
            .frame(height: height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(hovering ? SideBar.hoverFill : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
    }
}

/// The line between what is kept and the tabs that come and go, as Arc
/// draws it over its Today tabs, with Clear at its end under the pointer:
/// the tabs below it closed, everything above it left as it was.
struct KeepLine: View {
    static let height: CGFloat = 18
    /// Whether there is anything under it to clear.
    let clears: Bool
    let act: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(Palette.hairline)
                .frame(height: 1)
            if clears && hovering {
                Button(action: act) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 8, weight: .semibold))
                        Text("Clear")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(Palette.muted)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close the tabs under the line. Pins and groups stay; ⇧⌘T brings a tab back.")
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: KeepLine.height)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
    }
}

/// The speaker at the end of a tab that plays sound, or that was muted and
/// so says it is: a press mutes the tab or lets it be heard again. Drawn as
/// it was before it could be pressed, with the cross's faint disc behind
/// it only while the pointer is on it.
struct Speaker: View {
    @ObservedObject var tab: Tab

    @State private var hovering = false

    var body: some View {
        Button(action: tab.toggleMute) {
            Image(systemName: tab.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 8))
                .foregroundStyle(Palette.muted)
                .frame(width: 15, height: 15)
                .background(Palette.ink.opacity(hovering ? 0.07 : 0), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tab.muted ? "Unmute Tab" : "Mute Tab")
        .animation(Motion.quick, value: hovering)
    }
}

/// A small square holding one symbol. Lit when what it opens is open.
struct Door: View {
    let icon: String
    var on = false
    var help = ""
    let act: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: act) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(on ? Palette.ink : (hovering ? Palette.ink.opacity(0.7) : Palette.muted))
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(on ? SideBar.liveFill : (hovering ? SideBar.hoverFill : .clear))
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityHidden(help.isEmpty)
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: on)
    }
}

/// A row's place in the column's list, reported for dragging (see SideBar).
enum RowKey: Hashable {
    case tab(UUID)
    case header(UUID)
    case line
}

struct RowFrames: PreferenceKey {
    static var defaultValue: [RowKey: CGRect] = [:]
    static func reduce(value: inout [RowKey: CGRect], nextValue: () -> [RowKey: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Where this row is, in the list's space.
    /// `when` false for a copy of a row — the one the hand carries — whose
    /// place is not the row's.
    func report(_ key: RowKey, when: Bool = true) -> some View {
        background(GeometryReader { box in
            Color.clear.preference(key: RowFrames.self, value: when ? [key: box.frame(in: .named("column"))] : [:])
        })
    }
}
