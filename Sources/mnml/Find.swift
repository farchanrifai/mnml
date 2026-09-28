import SwiftUI
import WebKit

/// Looking for a word on the page. A pill in the top corner, the same white and
/// hairline as everything else that floats, and gone the moment it isn't wanted.
struct FindBar: View {
    @ObservedObject var browser: Browser

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                if browser.needle.isEmpty {
                    Text("Find on page")
                        .foregroundStyle(Palette.ink.opacity(0.3))
                }
                TextField("", text: $browser.needle)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Palette.ink)
                    .focused($focused)
                    // Return the next match, ⇧Return the one before, as in Safari.
                    .onSubmit { browser.look(forward: !NSEvent.modifierFlags.contains(.shift)) }
                    .onExitCommand { browser.closeFind() }
            }
            .font(.system(size: 12.5))
            .frame(width: 160)

            // Which one of how many, once there is something to count.
            if !browser.needle.isEmpty {
                Text(tally)
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(browser.missed ? Color.red.opacity(0.7) : Palette.muted)
                    .fixedSize()
            }

            step("chevron.up") { browser.look(forward: false) }
            step("chevron.down") { browser.look(forward: true) }
            step("xmark") { browser.closeFind() }
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(Palette.ground, in: Capsule())
        .overlay(
            Capsule().strokeBorder(
                browser.missed ? Color.red.opacity(0.35) : Palette.hairline,
                lineWidth: 1
            )
        )
        .shadow(color: .black.opacity(0.10), radius: 18, y: 5)
        .padding(.top, 12)
        .padding(.trailing, 14)
        .animation(Motion.quick, value: browser.missed)
        .onAppear(perform: focus)
        .onChange(of: browser.findFocus) { _, _ in focus() }
    }

    private func focus() {
        focused = true
        DispatchQueue.main.async { if !focused { focused = true } }
    }

    private var tally: String {
        if browser.missed || browser.matches == 0 { return "No matches" }
        let at = browser.matchIndex >= 0 ? browser.matchIndex + 1 : 1
        return "\(at) of \(browser.matches)"
    }

    private func step(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Palette.muted)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Find, done in the page: every match marked with the page's own text
/// highlights, the one you are on in a stronger colour and scrolled to, and
/// a count kept here rather than by WebKit. WebKit's find stepped on from
/// wherever it last stopped — a scroll or a change on the page moved that,
/// and turning round with ⇧Return started it over — so Return jumped, or
/// stuck. Here stepping is a number going up or down.
enum PageFind {
    /// [how many, which one (from 0)], after looking for `text` — afresh when
    /// it differs from last time, or a step `by` from the current one.
    static func script(_ text: String, by step: Int) -> String {
        let needle = (try? JSONEncoder().encode(text)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        return """
        (function (q, step) {
          var s = window.__mnmlFind || (window.__mnmlFind = { q: null, ranges: [], i: -1 });
          if (!window.CSS || !CSS.highlights) return null;
          if (!document.getElementById('mnml-find-style')) {
            var style = document.createElement('style');
            style.id = 'mnml-find-style';
            style.textContent = '::highlight(mnml-find){background:rgba(255,214,10,.45);color:inherit}' +
              '::highlight(mnml-find-now){background:rgb(255,150,0);color:#000}';
            (document.head || document.documentElement).appendChild(style);
          }
          var stale = s.ranges.some(function (r) { return !r.startContainer.isConnected; });
          if (q !== s.q || stale) {
            var keep = s.q === q ? s.i : -1;
            s.q = q; s.ranges = []; s.i = -1;
            var want = q.toLowerCase();
            var walk = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_TEXT, {
              acceptNode: function (n) {
                var p = n.parentElement;
                if (!p || /^(SCRIPT|STYLE|NOSCRIPT|TEMPLATE)$/.test(p.tagName)) return NodeFilter.FILTER_REJECT;
                return p.getClientRects().length ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
              }
            });
            for (var n = walk.nextNode(); n && s.ranges.length < 1000; n = walk.nextNode()) {
              var text = n.data.toLowerCase(), at = text.indexOf(want);
              while (at >= 0 && s.ranges.length < 1000) {
                var r = document.createRange();
                r.setStart(n, at); r.setEnd(n, at + q.length);
                s.ranges.push(r);
                at = text.indexOf(want, at + want.length);
              }
            }
            if (s.ranges.length) {
              if (keep >= 0) {
                s.i = Math.min(keep, s.ranges.length - 1);
              } else {
                // The first one on screen or below it, as Safari starts.
                s.i = 0;
                for (var k = 0; k < s.ranges.length; k++) {
                  if (s.ranges[k].getBoundingClientRect().bottom >= 0) { s.i = k; break; }
                }
              }
            }
            step = 0;
          }
          CSS.highlights.delete('mnml-find');
          CSS.highlights.delete('mnml-find-now');
          if (!s.ranges.length) return [0, -1];
          s.i = (s.i + step + s.ranges.length) % s.ranges.length;
          CSS.highlights.set('mnml-find', new Highlight(...s.ranges));
          CSS.highlights.set('mnml-find-now', new Highlight(s.ranges[s.i]));
          var box = s.ranges[s.i].getBoundingClientRect();
          if (box.top < 60 || box.bottom > window.innerHeight - 40 || box.left < 0 || box.right > window.innerWidth) {
            var el = s.ranges[s.i].startContainer.parentElement;
            if (el) el.scrollIntoView({ block: 'center', inline: 'nearest' });
          }
          return [s.ranges.length, s.i];
        })(\(needle), \(step))
        """
    }

    static let clear = """
    (function () {
      if (window.CSS && CSS.highlights) { CSS.highlights.delete('mnml-find'); CSS.highlights.delete('mnml-find-now'); }
      window.__mnmlFind = null;
    })()
    """
}
