// Do a page's notifications reach macOS from a WKWebView app? WebKit's
// built-in notifications (a feature flag, off by default) post them through
// the app's own UNUserNotificationCenter; the page's permission request comes
// to a private UI delegate method.
//
// Needs to run as an app (notifications belong to a bundle): see
// docs/mnml/scratch — built into NotifyProbe.app and opened with `open`.

import AppKit
import WebKit
import UserNotifications

@main
struct NotifyProbe {
    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let probe = Probe()
        app.delegate = probe
        app.run()
    }
}

final class Probe: NSObject, NSApplicationDelegate, WKUIDelegate, UNUserNotificationCenterDelegate {
    var window: NSWindow!
    var web: WKWebView!

    func applicationDidFinishLaunching(_ note: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { ok, error in
            log("mac authorisation \(ok) \(error.map { "\($0)" } ?? "")")
        }

        let config = WKWebViewConfiguration()
        let features = WKPreferences.perform(NSSelectorFromString("_features"))?.takeUnretainedValue() as? [NSObject] ?? []
        if let builtIn = features.first(where: { $0.value(forKey: "key") as? String == "BuiltInNotificationsEnabled" }) {
            let set = NSSelectorFromString("_setEnabled:forFeature:")
            typealias Setter = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
            unsafeBitCast(config.preferences.method(for: set), to: Setter.self)(config.preferences, set, true, builtIn)
            log("built-in notifications on")
        }
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 700, height: 400), configuration: config)
        web.uiDelegate = self
        window = NSWindow(contentRect: web.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = web
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let page = """
        <body style="font:16px system-ui;padding:20px"><div id=out>…</div><script>
        const say = t => { document.getElementById('out').textContent += ' | ' + t; webkit.messageHandlers.log?.postMessage(t) };
        say('permission before: ' + Notification.permission);
        Notification.requestPermission().then(p => {
          say('permission after: ' + p);
          if (p === 'granted') {
            const n = new Notification('mnml notification test', { body: 'From a page, through WebKit' });
            n.onshow = () => say('shown'); n.onerror = () => say('error'); n.onclick = () => say('clicked');
          }
        });
        </script></body>
        """
        let bridge = Bridge()
        web.configuration.userContentController.add(bridge, name: "log")
        web.loadHTMLString(page, baseURL: URL(string: "https://example.com/")!)

        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            center.getDeliveredNotifications { list in
                log("delivered: \(list.map { $0.request.content.title })")
            }
        }
    }

    @objc(_webView:requestNotificationPermissionForSecurityOrigin:decisionHandler:)
    func webView(_ webView: WKWebView, requestNotificationPermissionFor origin: WKSecurityOrigin, decisionHandler: @escaping (Bool) -> Void) {
        log("page asked: \(origin.host)")
        decisionHandler(true)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        log("will present: \(notification.request.content.title)")
        return [.banner, .sound]
    }
}

final class Bridge: NSObject, WKScriptMessageHandler {
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) { log("page: \(message.body)") }
}

func log(_ s: String) {
    print(s)
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("notifyprobe.log")
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write((s + "\n").data(using: .utf8)!); try? h.close() }
    else { try? (s + "\n").write(to: url, atomically: true, encoding: .utf8) }
}
