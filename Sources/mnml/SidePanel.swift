import SwiftUI
import WebKit

// An extension's side panel (chrome.sidePanel), docked on the right beside
// the page, as in Chrome — in the chat's place (AskPanel.swift), one or the
// other. It belongs to the tab it was opened for: Claude for Chrome's acts on
// that tab, and its page names it (sidepanel.html?tabId=…). WebKit has no
// side panels; before this it opened as a tab of its own.

@available(macOS 15.4, *)
@MainActor
final class SidePanels: NSObject, WKUIDelegate {
    static let shared = SidePanels()

    /// Each tab's panel page, kept while the tab is open so it isn't loaded
    /// again every time you come back to it.
    private var pages: [Tab.ID: WKWebView] = [:]

    func page(for tab: Tab.ID) -> WKWebView? { pages[tab] }

    /// The extension's panel beside the tab, opened or brought back.
    func open(_ url: URL, context: WKWebExtensionContext, for tab: Tab, in browser: Browser) {
        let id = context.uniqueIdentifier
        if browser.docked[tab.id] != id || pages[tab.id]?.url?.path != url.path {
            pages[tab.id]?.removeFromSuperview()
            guard let configuration = context.webViewConfiguration else { return }
            let web = WKWebView(frame: .zero, configuration: configuration)
            web.uiDelegate = self
            web.load(URLRequest(url: url))
            pages[tab.id] = web
        }
        // One thing in the slot at a time: the chat steps aside.
        browser.chatting.remove(tab.id)
        browser.docked[tab.id] = id
        browser.rememberSession()
    }

    func close(_ tab: Tab.ID, in browser: Browser) {
        browser.docked[tab] = nil
        pages.removeValue(forKey: tab)?.removeFromSuperview()
    }

    // MARK: - the page asking

    /// window.close() from the panel: Claude's toggle closes its own.
    func webViewDidClose(_ webView: WKWebView) {
        guard let tab = pages.first(where: { $0.value === webView })?.key,
              let browser = Browsers.all.first(where: { $0.docked[tab] != nil }) else { return }
        close(tab, in: browser)
    }

    /// A link that asks for a new window becomes a tab, as from a popup.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url, (try? Extensions.mayOpen(url)) != nil {
            let tab = pages.first(where: { $0.value === webView })?.key
            let browser = tab.flatMap { id in Browsers.all.first { $0.docked[id] != nil } }
            (browser ?? Browsers.front)?.open(url, foreground: true)
        }
        return nil
    }
}

/// The docked panel: the extension's name and a close button, its page below.
@available(macOS 15.4, *)
struct ExtensionSidePanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    let tab: Tab
    let extensionID: String

    private var name: String {
        Extensions.shared.contexts[extensionID]?.webExtension.displayName ?? "Extension"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                Spacer()
                Door(icon: "xmark", help: "Close") { SidePanels.shared.close(tab.id, in: browser) }
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .frame(height: Metrics.strip)
            PanelPage(web: SidePanels.shared.page(for: tab.id))
        }
        .frame(width: prefs.askWidth)
        .frame(maxHeight: .infinity)
        .background {
            if prefs.frostedSidebar {
                Frosted(blending: browser.pageUnder ? Under.blending : .behindWindow)
            } else {
                Palette.ground
            }
        }
        .overlay(alignment: .leading) {
            Rectangle().fill(Palette.hairline).frame(width: 1)
                .overlay { WidthGrip { prefs.askWidth = min(640, max(280, prefs.askWidth - $0)) } }
        }
    }
}

/// The panel's web view, put in place and kept there.
private struct PanelPage: NSViewRepresentable {
    let web: WKWebView?

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ holder: NSView, context: Context) {
        guard let web else { return holder.subviews.forEach { $0.removeFromSuperview() } }
        guard web.superview !== holder else { return }
        holder.subviews.forEach { $0.removeFromSuperview() }
        web.frame = holder.bounds
        web.autoresizingMask = [.width, .height]
        holder.addSubview(web)
    }
}
