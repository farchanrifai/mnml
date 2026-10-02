import SwiftUI

// Two tabs side by side, as in Dia. A tab pulled out of the column over the
// page offers two places to land, one each side; let go on one and the two
// share the window until one is closed or they are separated.
//
// The right page keeps the left page's identity. Pairing does not depend on
// sidebar adjacency: a pin keeps its position while sharing the content area.

enum SplitSide: Hashable {
    case left, right
}

struct Split: Equatable {
    let left: Tab.ID
    let right: Tab.ID

    static func pair(of id: UUID?, in members: [(id: UUID, partner: UUID?)]) -> Split? {
        guard let id, let member = members.first(where: { $0.id == id }) else { return nil }
        if let left = member.partner, left != id, members.contains(where: { $0.id == left && $0.partner == nil }) {
            return Split(left: left, right: id)
        }
        if member.partner == nil, let right = members.first(where: { $0.partner == id && $0.id != id }) {
            return Split(left: id, right: right.id)
        }
        return nil
    }

    func has(_ id: Tab.ID?) -> Bool { id == left || id == right }

    func other(_ id: Tab.ID) -> Tab.ID? {
        id == left ? right : id == right ? left : nil
    }
}

/// The tab on screen put to one side, the other waiting for a pick.
struct SplitPick: Equatable {
    let tab: Tab.ID
    /// The side the tab on screen went to.
    let side: SplitSide
}

/// A tab held out over the page: where the pointer is, in the window, and
/// which side it would land on if let go now.
struct SplitDrag: Equatable {
    let tab: Tab.ID
    var point: CGPoint
    var side: SplitSide?
}

extension Browser {
    func tab(_ id: Tab.ID?) -> Tab? {
        guard let id else { return nil }
        return tabs.first { $0.id == id }
    }

    /// The pair this tab belongs to, including nonadjacent pinned members.
    // ponytail: a scan of the row per call, fine for a few hundred tabs.
    func split(of id: Tab.ID?) -> Split? {
        Split.pair(of: id, in: tabs.map { ($0.id, $0.partner) })
    }

    /// The split on screen, if the tab you are on is half of one.
    var shownSplit: Split? { split(of: activeID) }

    /// Whether this tab, dragged over the page, can open beside the one on
    /// screen — or, the one on screen itself, take one side and leave the
    /// other for a tab to be picked — or, over a split, take one side's place.
    func canSplit(_ id: Tab.ID) -> Bool {
        guard prefs.sidebar, let here = active, !here.isBlank,
              !here.immersed, peekTab == nil, splitPicking == nil, shownSplit?.has(id) != true,
              tab(id) != nil
        else { return false }
        return true
    }

    /// The tab held at `point`, in the window, over the page.
    func dragSplit(_ id: Tab.ID, at point: CGPoint) {
        let page = pageFrame
        let local = CGPoint(x: point.x - page.minX, y: point.y - page.minY)
        let side = SplitZones.side(at: local, in: page.size, current: splitDrag?.side)
        if splitDrag == nil {
            // A picture of the page it would bring, for the hand to carry.
            splitPicture = nil
            tab(id)?.preview(width: 420) { [weak self] image in
                guard let self, splitDrag?.tab == id else { return }
                splitPicture = image
            }
        } else if side != splitDrag?.side {
            feelDrag(firm: side != nil)
        }
        splitDrag = SplitDrag(tab: id, point: point, side: side)
    }

    /// Back over the column: the page's places to land go away.
    func cancelSplitDrag() {
        splitDrag = nil
    }

    /// Let go over the page: beside the tab on screen, if over one of the
    /// two places, and nothing if not.
    func dropSplit() {
        guard let drag = splitDrag else { return }
        splitDrag = nil
        guard let side = drag.side, let tab = tab(drag.tab), let anchor = active else { return }
        if let split = shownSplit {
            // Over a split: in place of that side's tab, which goes back to
            // being a tab of its own.
            let out = side == .left ? split.left : split.right
            guard let keep = split.other(out).flatMap({ self.tab($0) }) else { return }
            makeSplit(tab, beside: keep, on: side)
        } else if tab === anchor {
            // The page on screen to one side, and a list of the others on
            // the other, to pick what goes beside it.
            splitPicking = SplitPick(tab: tab.id, side: side)
        } else {
            makeSplit(tab, beside: anchor, on: side)
        }
    }

    /// The tab picked for the waiting half.
    func pickSplit(_ other: Tab) {
        guard let pick = splitPicking, let tab = tab(pick.tab) else { return }
        splitPicking = nil
        makeSplit(other, beside: tab, on: pick.side == .left ? .right : .left)
    }

    /// `tab` put next to `anchor` in the row, in its group, and the two made
    /// one split, the new one in front.
    func makeSplit(_ tab: Tab, beside anchor: Tab, on side: SplitSide) {
        guard tab !== anchor, tabs.contains(where: { $0 === anchor }) else { return }
        unsplit(tab.id)
        unsplit(anchor.id)
        var row = tabs.filter { $0 !== tab }
        guard let at = row.firstIndex(where: { $0 === anchor }) else { return }
        if tab.pin == nil { tab.group = anchor.pin == nil ? anchor.group : nil }
        row.insert(tab, at: tab.pin == nil && anchor.pin == nil ? (side == .left ? at : at + 1) : row.count)
        let (left, right) = side == .left ? (tab, anchor) : (anchor, tab)
        left.partner = nil
        right.partner = left.id
        arrange(row)
        objectWillChange.send()
        select(tab)
    }

    /// The two halves go back to being two tabs, next to each other.
    func unsplit(_ id: Tab.ID) {
        guard let split = split(of: id) else { tab(id)?.partner = nil; return }
        if split.has(activeID) { touchShownTabs(activeID) }
        tab(split.right)?.partner = nil
        objectWillChange.send()
        rememberSession()
    }

    /// A click in the half not in front brings it to the front.
    func focusPane(_ tab: Tab) {
        guard tab.id != activeID, shownSplit?.has(tab.id) == true else { return }
        select(tab)
    }
}

/// The two places a dragged tab can land, measured off the page they sit
/// over. Sized from Dia's: each about a fifth of the page wide and half its
/// height, a little in from the edge — and, the one under the pointer, a
/// little larger and further in.
enum SplitZones {
    static func rect(_ side: SplitSide, in page: CGSize, hot: Bool) -> CGRect {
        let width = min(340, max(150, page.width * 0.195))
        let height = min(580, max(220, page.height * 0.5))
        let inset = page.width * 0.024
        let rest = CGRect(
            x: side == .left ? inset : page.width - inset - width,
            y: (page.height - height) / 2,
            width: width, height: height
        )
        guard hot else { return rest }
        return rest
            .insetBy(dx: -width * 0.075, dy: -height * 0.07)
            .offsetBy(dx: (side == .left ? 1 : -1) * page.width * 0.03, dy: 0)
    }

    /// The place under `point`. The one already lit is measured at its
    /// larger size, so its edge doesn't flicker under a still pointer.
    static func side(at point: CGPoint, in page: CGSize, current: SplitSide?) -> SplitSide? {
        for side in [SplitSide.left, .right] where rect(side, in: page, hot: side == current).contains(point) {
            return side
        }
        return nil
    }
}

/// Over the page while a tab is held out of the column: the two places,
/// and the page it would bring, following the pointer until it is over one
/// of them and then settling into it.
struct SplitDropLayer: View {
    @ObservedObject var browser: Browser

    var body: some View {
        GeometryReader { box in
            let frame = box.frame(in: .global)
            ZStack(alignment: .topLeading) {
                if let drag = browser.splitDrag {
                    zone(.left, drag: drag, in: frame.size)
                    zone(.right, drag: drag, in: frame.size)
                    carried(drag, in: frame)
                }
            }
            .frame(width: frame.width, height: frame.height, alignment: .topLeading)
            .onAppear { browser.pageFrame = frame }
            .onChange(of: frame) { _, frame in browser.pageFrame = frame }
        }
        .allowsHitTesting(false)
        .animation(Motion.settle, value: browser.splitDrag?.side)
        // In on a spring; out quickly, the moment the tab is let go, as the
        // two pages are already there underneath.
        .animation(Motion.reduced ? nil : (browser.splitDrag == nil ? .easeOut(duration: 0.12) : Motion.settle), value: browser.splitDrag == nil)
    }

    private static let corner: CGFloat = 14

    private func zone(_ side: SplitSide, drag: SplitDrag, in page: CGSize) -> some View {
        let hot = drag.side == side
        let rect = SplitZones.rect(side, in: page, hot: hot)
        let shape = RoundedRectangle(cornerRadius: SplitDropLayer.corner, style: .continuous)
        return ZStack {
            shape.fill(Palette.ground)
            if hot {
                shape.fill(Palette.ink.opacity(0.05))
                shape.strokeBorder(Palette.ink.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            } else {
                shape.strokeBorder(Palette.hairline, lineWidth: 1)
            }
            VStack(spacing: 8) {
                if !hot {
                    Image(systemName: side == .left ? "rectangle.lefthalf.inset.filled" : "rectangle.righthalf.inset.filled")
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.muted)
                        .transition(.opacity)
                }
                Text(browser.shownSplit == nil
                     ? (side == .left ? "Add left split" : "Add right split")
                     : (side == .left ? "Replace left" : "Replace right"))
                    .font(.system(size: 12, weight: hot ? .medium : .regular))
                    .foregroundStyle(hot ? Palette.ink : Palette.muted)
            }
            // Under the page it carries, once it is lit.
            .offset(y: hot ? SplitDropLayer.held(in: rect, page: page).height / 2 + 4 : 0)
        }
        .frame(width: rect.width, height: rect.height)
        .shadow(color: .black.opacity(hot ? 0.16 : 0.10), radius: 18, y: 6)
        .position(x: rect.midX, y: rect.midY)
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.94)),
            removal: .opacity
        ))
    }

    /// The carried page's size once it has settled into a place.
    private static func held(in rect: CGRect, page: CGSize) -> CGSize {
        let width = rect.width * 0.64
        return CGSize(width: width, height: width * page.height / max(page.width, 1))
    }

    /// The page the tab would bring: by the pointer, a little to its right,
    /// as Dia carries it, and in the middle of a place once over one.
    private func carried(_ drag: SplitDrag, in frame: CGRect) -> some View {
        let page = frame.size
        let size: CGSize
        let centre: CGPoint
        if let side = drag.side {
            let rect = SplitZones.rect(side, in: page, hot: true)
            size = SplitDropLayer.held(in: rect, page: page)
            centre = CGPoint(x: rect.midX, y: rect.midY - 12)
        } else {
            let width: CGFloat = 170
            size = CGSize(width: width, height: width * page.height / max(page.width, 1))
            centre = CGPoint(x: drag.point.x - frame.minX + width * 0.25, y: drag.point.y - frame.minY)
        }
        return picture(of: browser.tab(drag.tab))
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
            .position(centre)
            .transition(.opacity)
    }

    @ViewBuilder
    private func picture(of tab: Tab?) -> some View {
        if let image = browser.splitPicture {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            // Nothing drawn yet — a tab never opened since launch: its icon.
            ZStack {
                Palette.ground
                if let tab { Mark(icon: tab.icon, letter: tab.monogram, size: 20) }
            }
        }
    }
}

/// The two pages of a split, each on its own card, the one in front
/// outlined.
struct SplitStage<Pane: View>: View {
    @ObservedObject var browser: Browser
    let split: Split
    let pane: (Tab) -> Pane

    static var corner: CGFloat { 10 }

    var body: some View {
        HStack(spacing: 6) {
            ForEach([split.left, split.right], id: \.self) { id in
                if let tab = browser.tab(id) {
                    let front = id == browser.activeID
                    let shape = RoundedRectangle(cornerRadius: SplitStage.corner, style: .continuous)
                    pane(tab)
                        .clipShape(shape)
                        .overlay(
                            shape.strokeBorder(front ? Palette.ink.opacity(0.35) : Palette.hairline, lineWidth: front ? 1.5 : 1)
                                .allowsHitTesting(false)
                        )
                }
            }
        }
        .padding(6)
        .background(Palette.ground)
        .animation(Motion.quick, value: browser.activeID)
    }
}

/// The page on screen on one side, and on the other the tabs there are to
/// put beside it.
struct SplitPickStage<Pane: View>: View {
    @ObservedObject var browser: Browser
    let pick: SplitPick
    let pane: () -> Pane

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SplitStage<EmptyView>.corner, style: .continuous)
        HStack(spacing: 6) {
            if pick.side == .right { picker(shape) }
            pane()
                .clipShape(shape)
                .overlay(shape.strokeBorder(Palette.ink.opacity(0.35), lineWidth: 1.5).allowsHitTesting(false))
            if pick.side == .left { picker(shape) }
        }
        .padding(6)
        .background(Palette.ground)
    }

    private func picker(_ shape: RoundedRectangle) -> some View {
        SplitPicker(browser: browser, except: pick.tab)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Palette.hairline, lineWidth: 1).allowsHitTesting(false))
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }
}

/// Every other tab, most recently used first, as cards with a picture of
/// the page — to pick the one that opens in the waiting half.
struct SplitPicker: View {
    @ObservedObject var browser: Browser
    let except: Tab.ID

    @State private var hunt = ""
    @FocusState private var focused: Bool

    private var choices: [Tab] {
        let needle = hunt.trimmingCharacters(in: .whitespaces).lowercased()
        return browser.tabs
            .filter { tab in
                guard tab.id != except, !tab.bench, !tab.isBlank else { return false }
                guard !needle.isEmpty else { return true }
                return tab.label.lowercased().contains(needle)
                    || (tab.address?.absoluteString.lowercased().contains(needle) ?? false)
            }
            .sorted { $0.touched > $1.touched }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a tab to open beside it")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.ink)
                .padding(.leading, 2)
            Hunt(text: $hunt, prompt: "Search tabs", focus: $focused)
                .onSubmit { if let first = choices.first { browser.pickSplit(first) } }
            if choices.isEmpty {
                Nothing(hunt.isEmpty ? "No other tabs to open here" : "No tab matches")
            } else {
                ScrollView(.vertical) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 14) {
                        ForEach(choices) { tab in
                            Card(browser: browser, tab: tab) { browser.pickSplit(tab) }
                        }
                    }
                    .padding(2)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.ground)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    /// A tab as a picture of its page and its name under it. A tab not
    /// opened since launch has no picture to show, and shows its icon.
    private struct Card: View {
        let browser: Browser
        @ObservedObject var tab: Tab
        let act: () -> Void
        @State private var hovering = false
        @State private var image: NSImage?

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
            Button(action: act) {
                VStack(alignment: .leading, spacing: 7) {
                    // Every card the same shape, whatever the picture's.
                    Color.clear
                        .aspectRatio(16 / 10, contentMode: .fit)
                        .overlay {
                            ZStack {
                                Palette.wash
                                if let image {
                                    PagePicture(image: image)
                                } else {
                                    Mark(icon: tab.icon, letter: tab.monogram, size: 22)
                                }
                            }
                        }
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(hovering ? Palette.ink.opacity(0.35) : Palette.hairline, lineWidth: hovering ? 1.5 : 1))
                    HStack(spacing: 6) {
                        Mark(icon: tab.icon, letter: tab.monogram, size: 13)
                        Text(tab.label)
                            .font(.system(size: 12))
                            .foregroundStyle(hovering ? Palette.ink : Palette.ink.opacity(0.8))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 2)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(tab.label) in split view")
            .scaleEffect(hovering ? 1.02 : 1)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
            .onAppear(perform: picture)
        }

        /// The switcher's picture when it has one of this page; otherwise
        /// one taken now, from the page or from what it slept with.
        private func picture() {
            if let kept = browser.tabSwitcher.preview(for: tab.id, address: tab.address) {
                image = kept
                return
            }
            tab.preview(width: 320) { image = $0 }
        }
    }
}
