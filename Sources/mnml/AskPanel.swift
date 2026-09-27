import SwiftUI

// The chat beside the page (Ask.swift has the chat itself), laid out as Dia
// lays out its own: a column on the right, new chat and close along the top,
// the thread, and a box at the bottom with what the question is about above
// it. The column wears what the column of tabs wears.

struct AskPanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    @ObservedObject var chat: Chat
    @ObservedObject var prefs: Preferences

    static let width: CGFloat = 320

    @State private var question = ""
    @State private var key = ""
    @FocusState private var typing: Bool

    private var accent: Color { Spaces.colours[browser.space.colour % Spaces.colours.count] }
    @State private var keyed = GeminiKey.read() != nil

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                if chat.turns.isEmpty {
                    empty
                } else {
                    thread
                }
            }
            .frame(maxHeight: .infinity)
            // The @ menu, rising from the box into the room above it.
            .overlay(alignment: .bottom) {
                if menuShowing {
                    menu
                        .padding(.horizontal, 10)
                        .transition(.opacity.combined(with: .offset(y: 4)))
                }
            }
            .animation(Motion.quick, value: menuShowing)
            composer
        }
        .frame(width: AskPanel.width)
        .frame(maxHeight: .infinity)
        .background {
            if browser.prefs.frostedSidebar { Frosted() } else { Palette.ground }
        }
        .overlay(alignment: .leading) {
            Rectangle().fill(Palette.hairline).frame(width: 1)
        }
        .onAppear {
            guard browser.askTyping else { return }
            browser.askTyping = false
            // A beat later: on the frame it's added, the page still holds
            // the keys and the box isn't in the window to take them.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { typing = true }
        }
    }

    // MARK: - top

    private var header: some View {
        HStack(spacing: 2) {
            Door(icon: "square.and.pencil", help: "New chat") {
                chat.stop()
                browser.chats[tab.id] = Chat()
                browser.objectWillChange.send()
                typing = true
            }
            Spacer()
            Picker("", selection: $prefs.askModel) {
                ForEach(Gemini.models, id: \.0) { Text($0.1).tag($0.0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .controlSize(.small)
            Door(icon: "xmark", help: "Close   ⌘E") { browser.chatting.remove(tab.id) }
        }
        .padding(.horizontal, 10)
        .frame(height: Metrics.strip)
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Spacer()
            if keyed {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Ask This Tab", systemImage: "sparkles")
                        .font(.system(size: 11.5, weight: .semibold))
                    Text("Grammar-check what I highlighted, or how much is the total here?")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                }
                .padding(12)
                .frame(width: 180, alignment: .leading)
                .background(Palette.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .rotationEffect(.degrees(-4))
                VStack(spacing: 3) {
                    Text("Ask about this page")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Palette.ink)
                    Text("Each tab keeps its own chat")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                }
            } else {
                keyForm
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
    }

    /// No key yet: where to get one, and a field for it.
    private var keyForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add a Gemini key")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.ink)
            Text("Free from Google AI Studio. On the free tier Google may use what you send to improve its models.")
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            Link("Get a key at aistudio.google.com", destination: URL(string: "https://aistudio.google.com/apikey")!)
                .font(.system(size: 11.5))
            HStack(spacing: 6) {
                SecureField("Paste the key", text: $key)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Palette.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .onSubmit(saveKey)
                Pill("Save", filled: true, action: saveKey)
            }
        }
    }

    private func saveKey() {
        guard !key.isEmpty else { return }
        GeminiKey.keep(key)
        keyed = true
        key = ""
        typing = true
    }

    // MARK: - the thread

    private var thread: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(chat.turns) { turn in
                        if turn.mine { mine(turn) } else { theirs(turn) }
                    }
                    if chat.working, chat.turns.last.map({ $0.mine || $0.text.isEmpty }) == true {
                        Thinking()
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: chat.turns.count) { _, _ in scroller.scrollTo("end", anchor: .bottom) }
        }
    }

    private func mine(_ turn: Chat.Turn) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(turn.about, id: \.self) { title in
                Text(title)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Palette.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .rotationEffect(.degrees(-2))
            }
            Text(turn.text)
                .font(.system(size: 12.5))
                .foregroundStyle(.white)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(accent.opacity(0.85), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 40)
    }

    private func theirs(_ turn: Chat.Turn) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if turn.failed {
                Text(turn.text).font(.system(size: 12.5)).foregroundStyle(Palette.unsafe)
            } else if !turn.text.isEmpty {
                Streaming(text: turn.text, live: chat.working && turn.id == chat.turns.last?.id)
                if let note = turn.note {
                    Text(note).font(.system(size: 10.5)).foregroundStyle(Palette.muted)
                }
                if !(chat.working && turn.id == chat.turns.last?.id) {
                    HStack(spacing: 2) {
                        Door(icon: "doc.on.doc", help: "Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(Chat.finished(turn.text), forType: .string)
                            browser.announce("Copied")
                        }
                        if chat.replaceable(turn) {
                            Button {
                                chat.replace(turn, in: tab) { worked in
                                    browser.announce(worked ? "Replaced — ⌘Z on the page undoes it" : "The highlighted text is gone from the page")
                                }
                            } label: {
                                Label("Replace selection", systemImage: "text.insert")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Palette.ink)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Palette.ink.opacity(0.07), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .help("Writes this over the text you highlighted, where it was")
                        }
                    }
                    .padding(.leading, -6)
                }
            }
        }
    }

    // MARK: - the box

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Chip(title: tab.label, detail: tab.address?.host() ?? "") { TabIcon(tab: tab) }
                    ForEach(chat.mentions, id: \.self) { mention in
                        mentionChip(mention)
                            .transition(.scale(scale: 0.9, anchor: .leading).combined(with: .opacity))
                    }
                    if let picked = tab.picked {
                        Chip(title: picked.text.trimmingCharacters(in: .whitespacesAndNewlines)
                                .replacingOccurrences(of: "\n", with: " "),
                             detail: "Selected Text", leave: { tab.picked = nil }) {
                            Image(systemName: "text.cursor")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Palette.muted)
                        }
                        .transition(.scale(scale: 0.9, anchor: .leading).combined(with: .opacity))
                    }
                }
            }
            .animation(Motion.quick, value: tab.picked?.text)
            .animation(Motion.quick, value: chat.mentions)

            TextField(chat.turns.isEmpty ? "Ask a question about this page…" : "Ask another question…",
                      text: $question, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .lineLimit(1...8)
                .focused($typing)
                .onSubmit(send)
                .onKeyPress(.downArrow) { move(1) }
                .onKeyPress(.upArrow) { move(-1) }
                .onKeyPress(.tab) { pickLit() }
                .onKeyPress(.escape) {
                    guard menuShowing else { return .ignored }
                    menuShut = true
                    return .handled
                }
                .onChange(of: question) { _, _ in menuShut = false; lit = 0 }

            HStack {
                Text("@ to add tabs").font(.system(size: 10.5)).foregroundStyle(Palette.muted.opacity(0.8))
                Spacer()
                Button(action: chat.working ? chat.stop : send) {
                    Image(systemName: chat.working ? "stop.fill" : "arrow.up")
                        .font(.system(size: chat.working ? 9 : 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(accent, in: Circle())
                }
                .buttonStyle(.plain)
                .help(chat.working ? "Stop" : "Send   ↩")
                .disabled(!chat.working && question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(10)
        .background(Palette.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        .padding(10)
    }

    private func mentionChip(_ mention: Mention) -> some View {
        let tabs = browser.tabs(for: mention, besides: tab)
        let cut = tabs.contains { chat.trimmed.contains($0.id) }
        let detail: String
        switch mention {
        case .tab(let id): detail = browser.tabs.first { $0.id == id }?.address?.host() ?? ""
        default: detail = "\(tabs.count) tab\(tabs.count == 1 ? "" : "s")"
        }
        return Chip(title: browser.name(of: mention), detail: cut ? "\(detail) · trimmed" : detail,
                    leave: { chat.mentions.removeAll { $0 == mention } }) {
            switch mention {
            case .tab(let id):
                if let other = browser.tabs.first(where: { $0.id == id }) { TabIcon(tab: other) }
            case .group(let id):
                Circle().fill(TabGroup.tint(browser.groups.first { $0.id == id }?.colour ?? 0)).frame(width: 8, height: 8)
            case .all, .site:
                Image(systemName: "square.on.square").font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
        }
    }

    // MARK: - the @ menu

    @State private var lit = 0
    @State private var more = false
    @State private var menuShut = false

    /// What's typed after the last @, while it's being typed.
    private var mentionQuery: String? {
        guard let at = question.lastIndex(of: "@") else { return nil }
        let after = question[question.index(after: at)...]
        guard !after.contains(where: \.isWhitespace) else { return nil }
        // An address, not a mention: name@host.
        if at > question.startIndex, !question[question.index(before: at)].isWhitespace { return nil }
        return after.lowercased()
    }

    private var menuShowing: Bool { mentionQuery != nil && !menuShut && !rows.isEmpty }

    private enum Row: Hashable {
        case group(UUID), tab(Tab.ID), more, all, site(String)
    }

    private var rows: [Row] {
        guard let query = mentionQuery else { return [] }
        func fits(_ s: String) -> Bool { query.isEmpty || s.lowercased().contains(query) }
        let open = browser.tabs.filter { !$0.shy && !$0.isBlank && $0 !== tab }
        var out: [Row] = browser.groups
            .filter { g in fits(g.name) && open.contains { $0.group == g.id } }
            .map { .group($0.id) }
        let tabs = open.filter { fits($0.label) || fits($0.address?.host() ?? "") }
        out += tabs.prefix(more || !query.isEmpty ? 30 : 5).map { .tab($0.id) }
        if !more, query.isEmpty, tabs.count > 5 { out.append(.more) }
        if query.isEmpty || fits("all open tabs") {
            out.append(.all)
            if let host = tab.address?.host(), open.contains(where: { $0.address?.host() == host }) {
                out.append(.site(host))
            }
        }
        return out.filter { row in
            switch row {
            case .group(let id): return !chat.mentions.contains(.group(id))
            case .tab(let id): return !chat.mentions.contains(.tab(id))
            case .all: return !chat.mentions.contains(.all)
            case .site(let h): return !chat.mentions.contains(.site(h))
            case .more: return true
            }
        }
    }

    private var menu: some View {
        let rows = rows
        return ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(rows.enumerated()), id: \.element) { n, row in
                        if n == 0, case .group = row { heading("Groups") }
                        if case .tab = row, n == 0 || { if case .group = rows[n - 1] { return true }; return false }() {
                            heading("Tabs")
                        }
                        menuRow(row, lit: n == min(lit, rows.count - 1))
                            .id(n)
                            .onTapGesture { pick(row) }
                    }
                }
                .padding(5)
            }
            .frame(maxHeight: 260)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: lit) { _, n in scroller.scrollTo(n) }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
    }

    private func heading(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 7)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }

    private func menuRow(_ row: Row, lit: Bool) -> some View {
        HStack(spacing: 8) {
            switch row {
            case .group(let id):
                let group = browser.groups.first { $0.id == id }
                Circle().fill(TabGroup.tint(group?.colour ?? 0)).frame(width: 8, height: 8).frame(width: 14)
                Text(group?.name ?? "Group")
            case .tab(let id):
                if let other = browser.tabs.first(where: { $0.id == id }) {
                    TabIcon(tab: other)
                    Text(other.label)
                }
            case .more:
                Image(systemName: "ellipsis").frame(width: 14)
                Text("View more")
            case .all:
                Image(systemName: "square.on.square").frame(width: 14)
                Text("All open tabs (\(browser.tabs(for: .all, besides: tab).count))")
            case .site(let host):
                Image(systemName: "globe").frame(width: 14)
                Text("All open \(host) tabs (\(browser.tabs(for: .site(host), besides: tab).count))")
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .foregroundStyle(lit ? .white : Palette.ink)
        .padding(.horizontal, 7)
        .frame(height: 24)
        .background(lit ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
    }

    private func move(_ by: Int) -> KeyPress.Result {
        guard menuShowing else { return .ignored }
        lit = max(0, min(rows.count - 1, lit + by))
        return .handled
    }

    private func pickLit() -> KeyPress.Result {
        guard menuShowing else { return .ignored }
        let rows = rows
        pick(rows[min(lit, rows.count - 1)])
        return .handled
    }

    private func pick(_ row: Row) {
        let mention: Mention
        switch row {
        case .more:
            more = true
            return
        case .group(let id): mention = .group(id)
        case .tab(let id): mention = .tab(id)
        case .all: mention = .all
        case .site(let host): mention = .site(host)
        }
        if let at = question.lastIndex(of: "@") { question = String(question[..<at]) }
        chat.mentions.append(mention)
        more = false
        typing = true
    }

    private func send() {
        if menuShowing {
            _ = pickLit()
            return
        }
        guard !chat.working, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var others: [Tab] = []
        for mention in chat.mentions {
            for other in browser.tabs(for: mention, besides: tab) where !others.contains(where: { $0 === other }) {
                others.append(other)
            }
        }
        chat.send(question, about: tab, also: others, named: chat.mentions.map(browser.name(of:)),
                  model: browser.prefs.askModel, picked: tab.picked)
        question = ""
    }
}

/// A tab's own icon, or a globe for one without.
private struct TabIcon: View {
    @ObservedObject var tab: Tab
    var body: some View {
        Group {
            if let icon = tab.icon {
                Image(nsImage: icon).resizable()
            } else {
                Image(systemName: "globe").foregroundStyle(Palette.muted)
            }
        }
        .frame(width: 14, height: 14)
    }
}

/// One thing a question is about, over the box: an icon, a name, a line
/// under it, and — for what can be left out — a × on hover.
private struct Chip<Icon: View>: View {
    let title: String
    let detail: String
    var leave: (() -> Void)?
    @ViewBuilder let icon: () -> Icon
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            icon().frame(width: 14, height: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 11)).foregroundStyle(Palette.ink).lineLimit(1)
                Text(detail).font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: 130, alignment: .leading)
        .background(Palette.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if hovering, let leave {
                Button(action: leave) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Palette.ground)
                        .frame(width: 14, height: 14)
                        .background(Palette.muted, in: Circle())
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
                .help("Leave it out")
            }
        }
        .padding(.top, 5)
        .padding(.trailing, 5)
        .onHover { hovering = $0 }
    }
}

// MARK: - Markdown

/// An answer's Markdown, in the blocks Gemini writes: paragraphs, headings,
/// lists, code and tables. Inline marks (bold, italic, code, links) by
/// Foundation's own parser.
struct Markdown: View {
    let text: String
    /// Characters at the very end drawn fainter and fainter, for an answer
    /// still being written (see Streaming).
    var fade = 0

    enum Block: Equatable {
        case paragraph(String), heading(String), item(String, marker: String), code(String), table([[String]])
        /// Finished text to paste — a ```text block, asked for (Ask.swift).
        case draft(String)
        case rule
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            let blocks = Markdown.blocks(text)
            ForEach(Array(blocks.enumerated()), id: \.offset) { n, block in
                view(block, fade: n == blocks.count - 1 ? fade : 0)
            }
        }
        .font(.system(size: 12.5))
        .foregroundStyle(Palette.ink)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(_ block: Block, fade: Int) -> some View {
        switch block {
        case .paragraph(let s): Text(Markdown.inline(s, fade: fade)).fixedSize(horizontal: false, vertical: true)
        case .heading(let s):
            Text(Markdown.inline(s, fade: fade))
                .font(.system(size: 13, weight: .semibold))
                .padding(.top, 4)
        case .item(let s, let marker):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).foregroundStyle(Palette.muted)
                Text(Markdown.inline(s, fade: fade)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 4)
        case .code(let s):
            Text(s)
                .font(.system(size: 11.5, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .draft(let s):
            Text(s)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        case .table(let rows):
            // Wrapped to the panel's width, the columns sharing it: scrolled
            // sideways, all but the first column went unseen.
            Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { n, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(Markdown.inline(cell))
                                .fontWeight(n == 0 ? .semibold : .regular)
                                .foregroundStyle(n == 0 ? Palette.muted : Palette.ink)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if n < rows.count - 1 { Divider().opacity(n == 0 ? 1 : 0.4) }
                }
            }
            .font(.system(size: 11.5))
            .padding(10)
            .background(Palette.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .rule:
            Divider().padding(.vertical, 2)
        }
    }

    static func inline(_ s: String, fade: Int = 0) -> AttributedString {
        var out = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
        guard fade > 0 else { return out }
        // The last characters from ink to nearly nothing: the words arriving.
        var at = out.endIndex
        var n = 0
        while at > out.startIndex, n < fade {
            let before = out.characters.index(before: at)
            out[before..<at].foregroundColor = Palette.ink.opacity(0.15 + 0.85 * Double(n) / Double(fade))
            at = before
            n += 1
        }
        return out
    }

    static func blocks(_ text: String) -> [Block] {
        var out: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        var draft = false
        var table: [[String]] = []
        func flush() {
            if !paragraph.isEmpty { out.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
            if !table.isEmpty { out.append(.table(table)); table = [] }
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let lines = code {
                    let body = lines.joined(separator: "\n")
                    out.append(draft ? .draft(body) : .code(body))
                    code = nil
                } else {
                    flush()
                    code = []
                    draft = line.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased() == "text"
                }
                continue
            }
            if code != nil { code?.append(raw); continue }
            if line.hasPrefix("|") {
                if !paragraph.isEmpty { flush() }
                let cells = line.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                    .components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                // The |---|---| under the heading row.
                if !cells.allSatisfy({ !$0.isEmpty && $0.allSatisfy { "-:".contains($0) } }) { table.append(cells) }
                continue
            }
            if line.isEmpty { flush(); continue }
            if line.count >= 3, line.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }) {
                flush(); out.append(.rule); continue
            }
            if let hashes = line.firstIndex(where: { $0 != "#" }), hashes != line.startIndex,
               line[hashes] == " " {
                flush(); out.append(.heading(String(line[hashes...]).trimmingCharacters(in: .whitespaces))); continue
            }
            let indent = String(repeating: "  ", count: min(2, (raw.prefix { $0 == " " }.count) / 2))
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                flush(); out.append(.item(String(line.dropFirst(2)), marker: indent + "•")); continue
            }
            if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
               line[line.index(after: dot)...].hasPrefix(" ") {
                flush(); out.append(.item(String(line[line.index(dot, offsetBy: 2)...]), marker: indent + line[...dot])); continue
            }
            if !table.isEmpty { flush() }
            paragraph.append(line)
        }
        if let lines = code { out.append(draft ? .draft(lines.joined(separator: "\n")) : .code(lines.joined(separator: "\n"))) }
        flush()
        return out
    }
}

/// An answer as it's being written: let out at an even pace rather than in
/// the lumps the network brings, its newest words fading in, as Dia's do.
private struct Streaming: View {
    let text: String
    let live: Bool
    @State private var shown: Int
    /// The text's length, kept where the pacing loop can see it change —
    /// the loop's own copy of the view keeps the text it started with.
    @State private var target: Int

    init(text: String, live: Bool) {
        self.text = text
        self.live = live
        // An answer already written is shown whole, not typed out again.
        _shown = State(initialValue: live ? 0 : text.count)
        _target = State(initialValue: text.count)
    }

    var body: some View {
        let count = text.count
        // Once it's all come, all of it: the pacing below only lasts while
        // words are arriving. Kept to the loop, an answer stopped part way
        // when SwiftUI cancelled it.
        Markdown(text: !live || shown >= count ? text : String(text.prefix(shown)), fade: live ? 24 : 0)
            .onChange(of: count) { _, new in target = new }
            .task(id: live) {
                while !Task.isCancelled {
                    let backlog = target - shown
                    if backlog <= 0 {
                        if !live { break }
                    } else {
                        // Faster the further behind: a long answer isn't typed
                        // out for a minute after it has arrived.
                        shown += max(2, backlog / 10)
                    }
                    try? await Task.sleep(for: .milliseconds(16))
                }
            }
    }
}

/// Three dots breathing in turn, while an answer is on its way.
private struct Thinking: View {
    var body: some View {
        TimelineView(.animation) { time in
            let t = time.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3) { n in
                    Circle()
                        .fill(Palette.muted)
                        .frame(width: 5, height: 5)
                        .opacity(0.3 + 0.7 * max(0, sin((t * 4) - Double(n) * 0.7)))
                }
            }
        }
        .padding(.vertical, 4)
        .transition(.opacity)
    }
}

