import AppKit
import SwiftUI

// Tab groups across the top (see Groups.swift for what a group is, and
// GroupViews.swift for the column's): a chip with the group's icon and name
// on a patch of its colour, its tabs after it on the same patch — all of
// them open, the one kept showing folded, or none.

/// Where each thing in the row is, in the run's own space, for dragging
/// (see TabBar). The column's keys, in a key of the row's own.
struct StripFrames: PreferenceKey {
    static var defaultValue: [RowKey: CGRect] = [:]
    static func reduce(value: inout [RowKey: CGRect], nextValue: () -> [RowKey: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Where this is in the row of tabs.
    func reportInStrip(_ key: RowKey, _ on: Bool = true) -> some View {
        background(GeometryReader { box in
            Color.clear.preference(key: StripFrames.self, value: on ? [key: box.frame(in: .named("run"))] : [:])
        })
    }
}

/// How wide a group's chip is, worked out rather than measured, so the row
/// can share out its room before anything is drawn.
@MainActor
enum StripChip {
    static let font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
    static let maxName: CGFloat = 150

    static func width(_ group: TabGroup, icons: Bool) -> CGFloat {
        let name = min(maxName, ceil((group.name as NSString).size(withAttributes: [.font: font]).width))
        return 10 + (icons ? 15 + 6 : 0) + name + 10
    }

    /// The chip and the patch around it: its padding and, between the chip
    /// and each tab after it, a hairline.
    static let pad: CGFloat = 3
    static let rule: CGFloat = 5
}

/// A group across the top: its chip, and after it its tabs, on a patch of
/// its colour.
struct StripGroup<Pill: View>: View {
    @ObservedObject var browser: Browser
    let group: TabGroup
    let members: [Tab]
    let pill: (Tab) -> Pill
    /// Off for the copy drawn under the hand while the group is dragged.
    var reports = true

    @State private var hovering = false
    @State private var listing = false
    @State private var inList = false
    @State private var clicked = false
    @State private var spot: CGRect = .zero
    @State private var draft = ""
    @FocusState private var naming: Bool

    private var shown: [Tab] {
        if group.open { return members }
        return members.filter { $0.id == group.peek }
    }

    var body: some View {
        HStack(spacing: 0) {
            chip
            ForEach(shown) { tab in
                Rectangle()
                    .fill(group.tint.opacity(0.35))
                    .frame(width: 1, height: 14)
                    .padding(.horizontal, 2)
                pill(tab)
            }
        }
        .padding(StripChip.pad)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(group.tint.opacity(0.16))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(group.tint.opacity(0.24), lineWidth: 1)
                )
        )
        .animation(Motion.settle, value: group.open)
        .animation(Motion.settle, value: shown.map(\.id))
    }

    private var chip: some View {
        HStack(spacing: 6) {
            if browser.prefs.glyph == .icons { GroupIcon(group: group) }
            if browser.renamingGroup == group.id {
                TextField("Group name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, weight: .semibold))
                    .frame(width: 110)
                    .focused($naming)
                    .onSubmit { finishNaming() }
                    .onExitCommand { browser.renamingGroup = nil }
                    .onAppear {
                        draft = group.name
                        DispatchQueue.main.async { naming = true }
                    }
                    .onChange(of: naming) { _, focused in if !focused { finishNaming() } }
            } else {
                Text(group.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: StripChip.maxName, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                    // In ink: the chip's patch carries the colour.
                    .foregroundStyle(Palette.ink)
                    .modifier(NameGlow(naming: browser.namingGroups.contains(group.id),
                                       arrived: browser.namedGroups.contains(group.id)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(hovering ? group.tint.opacity(0.14) : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        // A click folds or opens it, as in the column.
        .onTapGesture {
            clicked = true
            listing = false
            withAnimation(Motion.settle) { browser.toggleOpen(group.id) }
        }
        .onHover { over in
            hovering = over
            if !over { clicked = false }
            peekList(over)
        }
        .reportInStrip(.header(group.id), reports)
        .background {
            GeometryReader { box in
                Color.clear
                    .onAppear { spot = box.frame(in: .global) }
                    .onChange(of: box.frame(in: .global)) { _, frame in spot = frame }
            }
        }
        .contextMenu { GroupMenu(browser: browser, group: group) }
        .help(group.name)
        .animation(Motion.quick, value: hovering)
        .onChange(of: listing) { _, showing in
            guard reports else { return }
            if showing {
                GroupListPanel.shared.show(
                    GroupList(browser: browser, groupID: group.id) { inside in
                        inList = inside
                        if !inside { peekList(false) }
                    } done: {
                        listing = false
                    },
                    for: group.id, beside: spot, below: true
                )
            } else {
                GroupListPanel.shared.hide(group.id)
            }
        }
        .onDisappear { GroupListPanel.shared.hide(group.id) }
    }

    /// The list of a folded group's tabs, a moment after the pointer arrives
    /// on its chip, gone a moment after it leaves both.
    private func peekList(_ over: Bool) {
        guard !group.open, browser.renamingGroup != group.id else { listing = false; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + (over ? 0.35 : 0.3)) {
            if over, hovering, !clicked, !group.open { listing = true }
            if !over, !hovering, !inList { listing = false }
        }
    }

    private func finishNaming() {
        guard browser.renamingGroup == group.id else { return }
        browser.rename(group.id, to: draft)
        browser.renamingGroup = nil
    }
}

/// The space on screen, by name, at the start of the bar's pinned box, in
/// place of the column's icon: a click for the spaces' menu, as the icon
/// gives. Two fingers sideways on it go from space to space, as in Dia: the
/// name slides and the next or last comes in beside it, and past far enough
/// the row becomes that space's (see SpaceSwipe.nameSpot). Under the pointer,
/// or while it moves, a dot for each space says which this is.
struct SpaceName: View {
    @ObservedObject var browser: Browser
    @State private var hovering = false

    private var here: Int {
        browser.makingSpace ? browser.spaces.count : (browser.spaces.firstIndex { $0.id == browser.spaceID } ?? 0)
    }

    private var dots: Bool { hovering || browser.nameSwipe != 0 }

    var body: some View {
        let width = SpaceSwipe.shared.nameWidth
        Button { SpaceMenu.show(for: browser) } label: {
            VStack(spacing: 2) {
                // Every space's name in a strip of its own, each keeping its
                // place: the one on screen at nought, the others a name's
                // width along. Changing space moves which is at nought and
                // takes the swipe back to nought in the same change, so the
                // name that slid in stays exactly where it is.
                ZStack {
                    ForEach(Array(browser.spaces.enumerated()), id: \.element.id) { index, space in
                        let at = CGFloat(index - here) * width + browser.nameSwipe
                        let near = 1 - min(1, abs(at) / max(1, width))
                        if abs(at) < width * 1.5 {
                            label(space.name, lit: index == here)
                                .offset(x: at)
                                .opacity(0.1 + near * 0.9)
                        }
                    }
                    if browser.makingSpace { label("New Space", lit: true) }
                }
                .frame(width: width)
                .clipped()
                // Moved by the fingers and the glide at the end, never by the
                // change of space itself: that change only moves which name is
                // at nought, and the swipe back to nought with it.
                .animation(nil, value: browser.spaceID)
                if dots {
                    HStack(spacing: 3) {
                        ForEach(0..<browser.spaces.count, id: \.self) { index in
                            Circle()
                                .fill(Palette.ink.opacity(index == here ? 0.75 : 0.25))
                                .frame(width: 3, height: 3)
                        }
                    }
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? SideBar.hoverFill : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $browser.spaceAppearanceOpen, arrowEdge: .bottom) {
            SpaceAppearancePanel(browser: browser, prefs: browser.prefs)
        }
        .onHover { hovering = $0 }
        .help("\(browser.space.name) — ⌃1–⌃9, or two fingers sideways here, to switch")
        .animation(Motion.quick, value: dots)
        .animation(Motion.quick, value: hovering)
        .background(GeometryReader { box in
            Color.clear
                .onAppear { SpaceSwipe.shared.nameSpot = box.frame(in: .global) }
                .onChange(of: box.frame(in: .global)) { _, frame in SpaceSwipe.shared.nameSpot = frame }
        })
        // Not cleared on the way out: the row is made again for each space,
        // and the name going went after the new one had said where it is,
        // leaving the swipe nowhere to start. Only read while there are
        // spaces and a bar (see SpaceSwipe.takes).
        .onAppear { measure() }
        .onChange(of: browser.spaces) { _, _ in measure() }
    }

    private func label(_ text: String, lit: Bool) -> some View {
        Text(text)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(hovering && lit ? Palette.ink : Palette.muted)
            .lineLimit(1)
            .fixedSize()
    }

    /// One width for every name, the widest: the box doesn't jump from space
    /// to space, and a name slides exactly its box's width.
    private func measure() {
        let font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        let names = browser.spaces.map(\.name) + ["New Space"]
        let widest = names.map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) }.max() ?? 60
        SpaceSwipe.shared.nameWidth = min(140, widest)
    }
}
