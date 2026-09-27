import WebKit
import UserNotifications

// A page's notifications, through the Mac's own. WebKit, in an app of its
// own that isn't Safari, answers every page that asks with a quiet "denied"
// and never asks the app — its built-in notifications, a switch away, did the
// same in a probe. So mnml stands in for the page's Notification: asked, it
// puts the question to you the way the camera does (Browser.askNotifications),
// remembers the answer per site, and shows what the page sends in the Mac's
// Notification Centre. Clicking one brings its tab forward and tells the page.
//
// While the tab is open only: a closed tab has nothing left to send, and the
// push that wakes a closed site is Safari's alone. A tab allowed to notify
// isn't put to sleep for that reason (Sleep.swift).
//
// The page's side (`page`) stands in for window.Notification, the service
// worker's showNotification from the page, and the Permissions API's answer;
// it reaches mnml through a bridge in mnml's own world (`bridge`), as
// passkeys do, so nothing of mnml's is left in the page for a site to find.
final class Notify: NSObject, WKScriptMessageHandlerWithReply, UNUserNotificationCenterDelegate {
    @MainActor static let shared = Notify()

    static let name = "mnmlNotify"
    static let asked = "mnml-notify-ask"
    static let answered = "mnml-notify-answer"
    /// A click or a close from the Mac, told to the page that showed it.
    static let heard = "mnml-notify-heard"

    /// Where a site's answer is kept: beside the camera's, so Settings'
    /// forgetting of those forgets this too.
    static func key(_ host: String) -> String { "capture.notify:" + host }

    /// Every site's answer, for the page's side to know without asking.
    @MainActor static var answers: [String: Bool] {
        var found: [String: Bool] = [:]
        for (key, value) in Store.settings.dictionaryRepresentation() where key.hasPrefix("capture.notify:") {
            if let yes = value as? Bool { found[String(key.dropFirst("capture.notify:".count))] = yes }
        }
        return found
    }

    /// mnml's own page in System Settings › Notifications.
    static var settings: URL? {
        URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")")
    }

    @MainActor static func allowed(_ host: String) -> Bool {
        Store.settings.object(forKey: key(host)) as? Bool == true
    }

    /// Each notification shown, and the page it came from, for a click to
    /// find its way back.
    @MainActor private var shown: [String: (page: String, web: Weak)] = [:]

    final class Weak {
        weak var web: WKWebView?
        init(_ web: WKWebView) { self.web = web }
    }

    @MainActor override init() {
        super.init()
        // Here from launch, so a click on one left from before still lands.
        UNUserNotificationCenter.current().delegate = self
    }

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        MainActor.assumeIsolated {
            guard let body = message.body as? [String: Any], let kind = body["kind"] as? String,
                  let web = message.webView
            else { return replyHandler(nil, "Not a request") }
            let host = message.frameInfo.securityOrigin.host
            switch kind {
            case "permission":
                ask(host, from: web) { replyHandler($0, nil) }
            case "show":
                show(body, host: host, from: web) { replyHandler($0, nil) }
            case "close":
                if let id = identifier(body, host: host) {
                    UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
                    shown[id] = nil
                }
                replyHandler(true, nil)
            default:
                replyHandler(nil, "Unknown")
            }
        }
    }

    /// The site's answer, asked for once: yours, then the Mac's for mnml as a
    /// whole. Refused by the Mac, the site isn't remembered as allowed, so it
    /// can ask again once the Mac allows mnml.
    @MainActor private func ask(_ host: String, from web: WKWebView, answer: @escaping (String) -> Void) {
        if let saved = Store.settings.object(forKey: Self.key(host)) as? Bool {
            return answer(saved ? "granted" : "denied")
        }
        guard !host.isEmpty, let browser = Browser.front, browser.tab(for: web) != nil else { return answer("default") }
        // Off for mnml in System Settings, the Mac neither asks nor says why:
        // the bar says so instead, with the way there, and the site isn't
        // asked what it can't be given.
        Task { @MainActor in
            let mac = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            if mac == .denied {
                browser.askNotificationsOff(host: host)
                return answer("default")
            }
            self.askSite(host, browser: browser, answer: answer)
        }
    }

    @MainActor private func askSite(_ host: String, browser: Browser, answer: @escaping (String) -> Void) {
        browser.askNotifications(host: host) { yes in
            guard let yes else { return answer("default") }
            guard yes else { return answer("denied") }
            Task { @MainActor in
                let mac = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
                if !mac {
                    Store.settings.removeObject(forKey: Self.key(host))
                    browser.announce("Turn on notifications for mnml in System Settings › Notifications")
                }
                answer(mac ? "granted" : "default")
            }
        }
    }

    /// The Mac's name for one: the page's own, or its tag — a second with the
    /// same tag takes the first's place, as on the web.
    @MainActor private func identifier(_ body: [String: Any], host: String) -> String? {
        if let tag = body["tag"] as? String, !tag.isEmpty { return "notify|\(host)|\(tag)" }
        return (body["id"] as? String).map { "notify|\(host)|\($0)" }
    }

    @MainActor private func show(_ body: [String: Any], host: String, from web: WKWebView, done: @escaping (Bool) -> Void) {
        guard Self.allowed(host), let id = identifier(body, host: host), let page = body["id"] as? String else { return done(false) }
        let content = UNMutableNotificationContent()
        content.title = body["title"] as? String ?? ""
        content.body = body["body"] as? String ?? ""
        content.subtitle = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        content.threadIdentifier = host
        content.sound = body["silent"] as? Bool == true ? nil : .default
        shown[id] = (page, Weak(web))
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
            DispatchQueue.main.async { done(error == nil) }
        }
    }

    /// Shown even with mnml in front, as a page's own would be in Safari.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        done([.banner, .list, .sound])
    }

    /// A click: its tab forward, and the page told, which may do more (a chat
    /// opening the conversation). The extensions' own go nowhere of their own.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler done: @escaping () -> Void
    ) {
        let id = response.notification.request.identifier
        let clicked = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                defer { done() }
                guard let entry = Notify.shared.shown[id], let web = entry.web.web else { return }
                if clicked, let browser = Browser.front, let tab = browser.tab(for: web) {
                    browser.select(tab)
                    NSApp.activate(ignoringOtherApps: true)
                    web.window?.makeKeyAndOrderFront(nil)
                }
                Notify.shared.shown[id] = nil
                let detail = "{\"id\":\"\(entry.page)\",\"type\":\"\(clicked ? "click" : "close")\"}"
                web.evaluateJavaScript(
                    "window.dispatchEvent(new CustomEvent('\(Notify.heard)', { detail: \(Notify.quoted(detail)) }))",
                    in: nil, in: Web.world
                )
            }
        }
    }

    private static func quoted(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }

    /// The page's side, with every site's answer written in so Notification.
    /// permission is right before the page's first line runs.
    @MainActor static var page: String {
        let known = (try? JSONSerialization.data(withJSONObject: answers)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return """
        (function () {
          if (window.__mnmlNotify) return;
          window.__mnmlNotify = true;
          var answers = \(known);
          var host = location.hostname;
          var state = host in answers ? (answers[host] ? 'granted' : 'denied') : 'default';
          var live = {}, count = 0;
          function ask(message) {
            return new Promise(function (resolve) {
              var token = Math.random().toString(36).slice(2) + Date.now();
              message.token = token;
              function heard(event) {
                var reply;
                try { reply = JSON.parse(event.detail); } catch (e) { return; }
                if (!reply || reply.token !== token) return;
                window.removeEventListener('\(answered)', heard);
                resolve(reply.reply);
              }
              window.addEventListener('\(answered)', heard);
              window.dispatchEvent(new CustomEvent('\(asked)', { detail: JSON.stringify(message) }));
            });
          }
          function fire(target, type) {
            var event = new Event(type);
            var handler = target['on' + type];
            if (typeof handler === 'function') {
              try { handler.call(target, event); } catch (e) { setTimeout(function () { throw e; }); }
            }
            target.dispatchEvent(event);
          }
          class Notification extends EventTarget {
            constructor(title, options) {
              super();
              if (arguments.length === 0) throw new TypeError("Failed to construct 'Notification': 1 argument required, but only 0 present.");
              options = options || {};
              this.title = String(title);
              this.body = options.body ? String(options.body) : '';
              this.tag = options.tag ? String(options.tag) : '';
              this.icon = options.icon ? String(options.icon) : '';
              this.data = options.data === undefined ? null : options.data;
              this.silent = !!options.silent;
              this.requireInteraction = !!options.requireInteraction;
              this.dir = options.dir || 'auto';
              this.lang = options.lang || '';
              this.badge = ''; this.image = '';
              this.onclick = null; this.onshow = null; this.onclose = null; this.onerror = null;
              var self = this, id = 'n' + (++count) + '-' + Date.now();
              Object.defineProperty(this, '__id', { value: id });
              if (state !== 'granted') { setTimeout(function () { fire(self, 'error'); }); return; }
              live[id] = this;
              ask({ kind: 'show', id: id, tag: this.tag, title: this.title, body: this.body, silent: this.silent })
                .then(function (ok) {
                  if (ok) { fire(self, 'show'); } else { delete live[id]; fire(self, 'error'); }
                });
            }
            close() {
              if (!live[this.__id]) return;
              delete live[this.__id];
              ask({ kind: 'close', id: this.__id, tag: this.tag });
              fire(this, 'close');
            }
            static get permission() { return state; }
            static get maxActions() { return 0; }
            static requestPermission(callback) {
              var answer = state !== 'default' ? Promise.resolve(state)
                : ask({ kind: 'permission' }).then(function (reply) { state = reply || 'default'; return state; });
              if (typeof callback === 'function') answer.then(callback);
              return answer;
            }
          }
          Object.defineProperty(window, 'Notification', { value: Notification, writable: true, configurable: true });
          window.addEventListener('\(heard)', function (event) {
            var told;
            try { told = JSON.parse(event.detail); } catch (e) { return; }
            var shown = told && live[told.id];
            if (!shown) return;
            delete live[told.id];
            fire(shown, told.type === 'click' ? 'click' : 'close');
          });
          if (window.ServiceWorkerRegistration) {
            ServiceWorkerRegistration.prototype.showNotification = function (title, options) {
              if (state !== 'granted') return Promise.reject(new TypeError('No permission to show notifications'));
              new Notification(title, options);
              return Promise.resolve();
            };
            ServiceWorkerRegistration.prototype.getNotifications = function () { return Promise.resolve([]); };
          }
          if (navigator.permissions && navigator.permissions.query) {
            var query = navigator.permissions.query.bind(navigator.permissions);
            navigator.permissions.query = function (descriptor) {
              if (!descriptor || (descriptor.name !== 'notifications' && descriptor.name !== 'push')) return query(descriptor);
              var status = new EventTarget();
              status.name = descriptor.name;
              status.state = state === 'default' ? 'prompt' : state;
              status.onchange = null;
              return Promise.resolve(status);
            };
          }
        })();
        """
    }

    /// mnml's side, in its own world: the page's questions up to mnml, and
    /// the answers back.
    static let bridge = """
    (function () {
      var handler = window.webkit && webkit.messageHandlers && webkit.messageHandlers.\(name);
      if (!handler || window.__notifyBridged) return;
      window.__notifyBridged = true;
      window.addEventListener('\(asked)', function (event) {
        var message;
        try { message = JSON.parse(event.detail); } catch (e) { return; }
        if (!message || typeof message !== 'object' || typeof message.token !== 'string') return;
        function answer(reply) {
          window.dispatchEvent(new CustomEvent('\(answered)', { detail: JSON.stringify({ token: message.token, reply: reply }) }));
        }
        handler.postMessage(message).then(answer, function () { answer(null); });
      });
    })();
    """
}
