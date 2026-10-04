import SwiftUI

/// Resolve ownership from the live tab rows, so moving a chat to a new tab,
/// space or window never leaves a session pointing at its former home.
@MainActor
enum AntigravitySessionUI {
    private static var tabs: [UUID: Tab.ID] = [:]

    static func bind(chat: UUID, to tab: Tab.ID) {
        let live = Set(AntigravitySessions.shared.sessions.map(\.id))
        tabs = tabs.filter { live.contains($0.key) || $0.key == chat }
        tabs[chat] = tab
    }

    @MainActor
    struct Owner {
        let browser: Browser
        let tab: Tab
        let space: Space
        let chat: Chat

        var title: String { tab.isBlank ? chat.title : tab.label }
    }

    static func owner(of chat: UUID) -> Owner? {
        let owns: (Browser, Tab) -> Bool = { browser, tab in
            browser.chats[tab.id]?.sessionID == chat && (tabs[chat] == nil || tabs[chat] == tab.id)
        }
        for browser in Browsers.all {
            if let tab = browser.tabs.first(where: { owns(browser, $0) }),
               let conversation = browser.chats[tab.id] {
                return Owner(browser: browser, tab: tab, space: browser.space, chat: conversation)
            }
            for (spaceID, row) in browser.parked {
                guard let space = browser.spaces.first(where: { $0.id == spaceID }),
                      let tab = row.tabs.first(where: { owns(browser, $0) }),
                      let conversation = browser.chats[tab.id] else { continue }
                return Owner(browser: browser, tab: tab, space: space, chat: conversation)
            }
        }
        return nil
    }

    /// Used by the toast and the test bench: the exact owning tab is selected,
    /// its space is restored, and its chat is opened with the composer focused.
    @discardableResult
    static func go(to chat: UUID) -> Bool {
        guard let owner = owner(of: chat) else { return false }
        AntigravitySessions.shared.keepLive(chat)
        let browser = owner.browser
        if browser.peekTab != nil {
            browser.closePeek { go(to: chat) }
            return true
        }
        browser.clearSpaceTransition()
        browser.switchSpace(to: owner.space.id, animated: false)
        browser.select(owner.tab, floatPrevious: false)
        browser.dismiss()
        browser.editing = false
        while browser.closePanel() { }
        if #available(macOS 15.4, *), browser.docked[owner.tab.id] != nil {
            SidePanels.shared.close(owner.tab.id, in: browser)
        }
        browser.askTyping = true
        browser.chatting.insert(owner.tab.id)
        browser.askFocusTick += 1
        browser.rememberSession()
        Browsers.show(browser)
        return true
    }

    static func memory(_ bytes: UInt64?) -> String {
        guard let bytes else { return "RAM unavailable" }
        return "~\(Int((Double(bytes) / 1_048_576).rounded())) MB RAM"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds))
        return whole >= 60 ? "\(whole / 60)m \(whole % 60)s" : "\(whole)s"
    }

    static func detail(_ session: AntigravitySessions.Snapshot) -> String {
        "Antigravity · Live · \(memory(session.rssBytes)) · " +
        (session.busy ? "Answering" : "\(duration(session.idle)) idle")
    }
}

/// This observes the app's sessions rather than the displayed tab's chat. Each
/// browser window can therefore show a warning from a different mnml space.
struct AntigravitySessionToasts: View {
    @ObservedObject private var sessions = AntigravitySessions.shared

    private var warnings: [AntigravitySessions.Snapshot] {
        sessions.sessions.filter { $0.remaining != nil }
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            ForEach(warnings) { session in
                AntigravitySessionToast(session: session)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(14)
        .animation(Motion.quick, value: warnings.map(\.id))
    }
}

private struct AntigravitySessionToast: View {
    let session: AntigravitySessions.Snapshot

    private var owner: AntigravitySessionUI.Owner? { AntigravitySessionUI.owner(of: session.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("AI session active — \(owner?.title ?? "Chat")")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .lineLimit(2)
            VStack(alignment: .leading, spacing: 3) {
                Text("Space: \(owner?.space.name ?? "Unknown") · \(AntigravitySessionUI.memory(session.rssBytes))")
                Text("Idle \(AntigravitySessionUI.duration(session.idle)) · Ending in \(session.remaining ?? 0)s")
                    .monospacedDigit()
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Palette.muted)
            HStack(spacing: 8) {
                Button("Go to Tab") { AntigravitySessionUI.go(to: session.id) }
                    .disabled(owner == nil)
                Button("Keep Live") { AntigravitySessions.shared.keepLive(session.id) }
                Button("Kill Process") { AntigravitySessions.shared.kill(session.id) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(13)
        .frame(width: 344, alignment: .leading)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.14), radius: 20, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Active Antigravity session")
    }
}

/// A live process is visible before its idle warning appears. The native menu
/// also provides the same resource controls while a conversation is on screen.
struct AntigravityLiveIndicator: View {
    let chat: UUID
    @ObservedObject private var sessions = AntigravitySessions.shared

    var body: some View {
        if let session = sessions.session(for: chat) {
            Menu {
                Text(AntigravitySessionUI.detail(session))
                Button("Keep Live") { sessions.keepLive(chat) }
                Button("Kill Process") { sessions.kill(chat) }
            } label: {
                HStack(spacing: 4) {
                    Circle().fill(Color.green).frame(width: 5, height: 5)
                    Text("Live").font(.system(size: 10.5, weight: .medium))
                }
                .foregroundStyle(Palette.muted)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(AntigravitySessionUI.detail(session))
            .accessibilityLabel(AntigravitySessionUI.detail(session))
        }
    }
}
