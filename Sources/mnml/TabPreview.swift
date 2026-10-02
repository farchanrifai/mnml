import SwiftUI

// A picture of a tab's page beside its row in the column, a moment after the
// pointer settles on it — as in Dia. Once one is up, the next row's comes at
// once, the way tooltips do. The picture is the ⌃Tab switcher's when it has
// one, a fresh snapshot otherwise; a tab with neither (restored, never
// opened) shows nothing rather than an empty card.

@MainActor
final class TabPreview {
    static let shared = TabPreview()
    private let panel = GroupListPanel()
    private var pending: DispatchWorkItem?
    private var shown: Tab.ID?
    /// The row the pointer is on, as last told.
    private var target: Tab.ID?
    private(set) var generation = UUID()
    private var hiddenAt = Date.distantPast

    static let width: CGFloat = 260

    func hover(_ over: Bool, tab: Tab, browser: Browser, beside spot: CGRect) {
        // Leaving a row can be told after arriving on the next: only the
        // row the pointer was last on puts its preview away.
        guard over else {
            if target == tab.id { hide() }
            return
        }
        pending?.cancel()
        pending = nil
        generation = UUID()
        let request = generation
        let address = tab.address
        target = tab.id
        guard tab.id != browser.activeID, !tab.isBlank, browser.editingTab == nil else {
            if shown != nil, let id = shown { panel.hide(id); shown = nil; hiddenAt = Date() }
            return
        }
        let warm = shown != nil || Date().timeIntervalSince(hiddenAt) < 0.4
        let work = DispatchWorkItem { [weak self, weak tab, weak browser] in
            guard let self, let tab, let browser,
                  self.accepts(request, tab: tab, address: address, browser: browser) else { return }
            let show = { (image: NSImage?) in
                guard let image,
                      self.accepts(request, tab: tab, address: address, browser: browser) else { return }
                self.panel.show(Card(tab: tab, image: image), for: tab.id, beside: spot)
                self.shown = tab.id
            }
            if let cached = browser.tabSwitcher.preview(for: tab.id, address: address) {
                show(cached)
            } else if tab.built != nil {
                // Live in the background: a snapshot would make its page draw
                // (see TabSwitcher.capturePreviews). No picture, no card.
                return
            } else {
                tab.preview(width: TabPreview.width, show)
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (warm ? 0.05 : 0.25), execute: work)
    }

    /// Check both before decoding and when it returns; A → B → A is a new request.
    func accepts(_ request: UUID, tab: Tab, address: URL?, browser: Browser) -> Bool {
        generation == request && target == tab.id && tab.address == address && !tab.isBlank
            && tab.id != browser.activeID && browser.editingTab == nil && !browser.shut
            && browser.tabs.contains { $0 === tab }
    }

    func hide() {
        generation = UUID()
        pending?.cancel()
        pending = nil
        target = nil
        guard let id = shown else { return }
        panel.hide(id)
        shown = nil
        hiddenAt = Date()
    }

    private struct Card: View {
        @ObservedObject var tab: Tab
        let image: NSImage

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: TabPreview.width, height: TabPreview.width * 0.62, alignment: .top)
                    .clipped()
                VStack(alignment: .leading, spacing: 2) {
                    Text(tab.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    if let host = tab.address?.host() {
                        Text(host.replacingOccurrences(of: "www.", with: ""))
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .frame(width: TabPreview.width, alignment: .leading)
            .background(Palette.ground)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        }
    }
}
