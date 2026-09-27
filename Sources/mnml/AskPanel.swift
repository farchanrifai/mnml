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

    let mode: AskMode
    /// Floating: the card dragged by its top, and let go (true).
    var dragged: ((DragGesture.Value, Bool) -> Void)?

    @State private var question = ""
    /// The list of past chats in place of this one.
    @State private var recalling = false
    @State private var key = ""
    @FocusState private var typing: Bool

    private var accent: Color { Spaces.colours[browser.space.colour % Spaces.colours.count] }
    @State private var keyed = GeminiKey.read() != nil

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                if recalling {
                    ChatHistory(current: chat.id) { saved in
                        chat.stop()
                        if let picked = Chat.load(saved.id) {
                            browser.chats[tab.id] = picked
                            browser.objectWillChange.send()
                            browser.rememberSession()
                        }
                        recalling = false
                    }
                } else if chat.turns.isEmpty {
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
            if !recalling { composer }
        }
        // Full page: a column down the middle, as a chat app's.
        .frame(maxWidth: mode == .full ? 720 : .infinity)
        .frame(maxWidth: .infinity)
        .frame(width: mode == .side ? prefs.askWidth : nil)
        .frame(maxHeight: .infinity)
        .background {
            if mode == .float {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.ground)
                    .shadow(color: .black.opacity(0.28), radius: 24, y: 10)
            } else if browser.prefs.frostedSidebar {
                Frosted()
            } else {
                Palette.ground
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: mode == .float ? 14 : 0, style: .continuous))
        .overlay {
            if mode == .float {
                RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1)
            }
        }
        .overlay(alignment: .leading) {
            if mode == .side {
                Rectangle().fill(Palette.hairline).frame(width: 1)
                    .overlay { Edge { prefs.askWidth = min(640, max(280, prefs.askWidth - $0)) } }
            }
        }

        // Files and pictures from Finder or another app, anywhere on the panel.
        .onDrop(of: [.fileURL, .image], isTargeted: $dropping, perform: drop)
        .onChange(of: typing) { _, on in browser.askFocused = on }
        .onChange(of: browser.askFocusTick) { _, _ in typing = true }
        .onDisappear { browser.askFocused = false }
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
                browser.rememberSession()
                recalling = false
                typing = true
            }
            Door(icon: "clock", on: recalling, help: "Past chats") { recalling.toggle() }
            Spacer()
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                // The floating card goes where it's dragged by its top.
                .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { dragged?($0, false) }
                    .onEnded { dragged?($0, true) })
            Picker("", selection: $prefs.askModel) {
                ForEach(Gemini.models, id: \.0) { Text($0.1).tag($0.0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .controlSize(.small)
            if !tab.isBlank {
                Menu {
                    ForEach(AskMode.allCases, id: \.self) { choice in
                        Toggle(isOn: Binding(get: { prefs.askMode == choice }, set: { if $0 { prefs.askMode = choice } })) {
                            Label(choice.title, systemImage: choice.icon)
                        }
                    }
                    Divider()
                    Button {
                        browser.askInNewTab(from: tab)
                    } label: {
                        Label("Open in New Tab", systemImage: "plus.square.on.square")
                    }
                } label: {
                    Image(systemName: mode.icon)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(Palette.muted)
                .padding(.horizontal, 4)
                .help("Sidebar, floating, or the whole page")
            }
            Door(icon: "xmark", help: "Close   ⌘E") {
                browser.chatting.remove(tab.id)
                browser.rememberSession()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Metrics.strip)
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Spacer()
            if keyed {
                VStack(alignment: .leading, spacing: 8) {
                    Label(tab.isBlank ? "New Chat" : "Ask This Tab", systemImage: "sparkles")
                        .font(.system(size: 11.5, weight: .semibold))
                    Text(tab.isBlank ? "Draft a reply to the email in @Gmail, or ask anything at all."
                                     : "Grammar-check what I highlighted, or how much is the total here?")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                }
                .padding(12)
                .frame(width: 180, alignment: .leading)
                .background(Palette.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .rotationEffect(.degrees(-4))
                VStack(spacing: 3) {
                    Text(tab.isBlank ? "Ask anything" : "Ask about this page")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Palette.ink)
                    Text(tab.isBlank ? "Type @ to bring in your tabs" : "Each tab keeps its own chat")
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
                    // The tab's own, there from the start; × leaves it out.
                    if !tab.isBlank, !chat.leftOwn {
                        Chip(title: tab.label, detail: tab.address?.host() ?? "", leave: { chat.leftOwn = true }) { TabIcon(tab: tab) }
                    }
                    ForEach(chat.mentions, id: \.self) { mention in
                        mentionChip(mention)
                            .transition(.scale(scale: 0.9, anchor: .leading).combined(with: .opacity))
                    }
                    ForEach(chat.files) { file in
                        Chip(title: file.name, detail: file.mime == "application/pdf" ? "PDF" : file.thumb != nil ? "Image" : "File",
                             leave: { chat.files.removeAll { $0 == file } }) {
                            if let thumb = file.thumb {
                                Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                                    .frame(width: 14, height: 14).clipShape(RoundedRectangle(cornerRadius: 3))
                            } else {
                                Image(systemName: "doc.text").font(.system(size: 11)).foregroundStyle(Palette.muted)
                            }
                        }
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
            .animation(Motion.quick, value: chat.files)
            .animation(Motion.quick, value: chat.leftOwn)

            TextField(chat.turns.isEmpty ? (tab.isBlank || chat.leftOwn ? "Ask anything…" : "Ask a question about this page…") : "Ask another question…",
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
                    if menuShowing {
                        menuShut = true
                        return .handled
                    }
                    // The floating card goes with Escape, as a small window
                    // does; beside the page, Escape is left alone.
                    guard mode == .float else { return .ignored }
                    browser.chatting.remove(tab.id)
                    browser.rememberSession()
                    return .handled
                }
                .onChange(of: question) { _, _ in menuShut = false; lit = 0 }
                // A picture or a file pasted: attached. Text pastes as ever.
                .onPasteCommand(of: [.fileURL, .png, .tiff]) { _ in attachPasted() }

            HStack(spacing: 2) {
                Door(icon: "plus", help: "Add images or files") { pickFiles() }
                    .padding(.leading, -6)
                Text("@ to add tabs").font(.system(size: 10.5)).foregroundStyle(Palette.muted.opacity(0.8))
                Spacer()
                Door(icon: "camera", help: "Add a screenshot of the page") { screenshot() }
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
        .background(dropping ? accent.opacity(0.12) : Palette.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        .padding(10)
    }

    // MARK: - files

    @State private var dropping = false

    private func add(_ files: [Attachment]) {
        guard !files.isEmpty else { return browser.announce("Only images, PDFs and text files can go in") }
        chat.files += files
        typing = true
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .pdf, .plainText, .commaSeparatedText]
        guard panel.runModal() == .OK else { return }
        add(panel.urls.compactMap(Attachment.file))
    }

    /// What the page shows now, as a picture — for what its text doesn't
    /// say: a chart, a grid drawn on a canvas, a scanned bill.
    private func screenshot() {
        guard let web = tab.built else { return }
        web.takeSnapshot(with: nil) { image, _ in
            guard let image, let shot = Attachment.image(image, name: "Screenshot of \(tab.label)") else { return }
            add([shot])
        }
    }

    private func attachPasted() {
        let board = NSPasteboard.general
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            add(urls.compactMap(Attachment.file))
        } else if let image = NSImage(pasteboard: board), let shot = Attachment.image(image, name: "Pasted image") {
            add([shot])
        }
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.isFileURL else { return }
                    DispatchQueue.main.async { add([Attachment.file(url)].compactMap { $0 }) }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadObject(ofClass: NSImage.self) { image, _ in
                    guard let image = image as? NSImage else { return }
                    DispatchQueue.main.async { add([Attachment.image(image, name: "Dropped image")].compactMap { $0 }) }
                }
            }
        }
        return true
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
        // The chat's own tab too, once it's been left out, to add it back.
        let open = browser.tabs.filter { !$0.shy && !$0.isBlank && ($0 !== tab || chat.leftOwn) }
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
        case .tab(let id) where id == tab.id:
            if let at = question.lastIndex(of: "@") { question = String(question[..<at]) }
            chat.leftOwn = false
            more = false
            typing = true
            return
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


/// Past chats, newest first, to open one on this tab.
private struct ChatHistory: View {
    let current: UUID
    let open: (Chat.Saved) -> Void
    @State private var all = Chat.history()
    @State private var search = ""
    @State private var hovered: UUID?

    private var shown: [Chat.Saved] {
        guard !search.isEmpty else { return all }
        return all.filter {
            $0.title.localizedCaseInsensitiveContains(search) || $0.site.localizedCaseInsensitiveContains(search)
                || $0.turns.contains { $0.text.localizedCaseInsensitiveContains(search) }
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            TextField("Search past chats", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Palette.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.horizontal, 10)
            if all.isEmpty {
                Spacer()
                Text("No past chats yet").font(.system(size: 12)).foregroundStyle(Palette.muted)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(shown) { row($0) }
                    }
                    .padding(.horizontal, 6)
                }
                HStack {
                    Spacer()
                    Button("Delete All…") {
                        let alert = NSAlert()
                        alert.messageText = "Delete all past chats?"
                        alert.informativeText = "They can't be brought back. Chats open on tabs stay until you close them."
                        alert.addButton(withTitle: "Delete All")
                        alert.addButton(withTitle: "Cancel")
                        guard alert.runModal() == .alertFirstButtonReturn else { return }
                        Chat.forgetAll()
                        all = []
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }
        }
    }

    private func row(_ saved: Chat.Saved) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(saved.title).font(.system(size: 12)).foregroundStyle(Palette.ink).lineLimit(1)
                Text([saved.site, saved.updated.formatted(.relative(presentation: .named))]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 10.5)).foregroundStyle(Palette.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
            if hovered == saved.id, saved.id != current {
                Door(icon: "trash", help: "Delete") {
                    Chat.forget(saved.id)
                    all.removeAll { $0.id == saved.id }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(saved.id == current ? SideBar.liveFill : hovered == saved.id ? SideBar.hoverFill : .clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onHover { if $0 { hovered = saved.id } else if hovered == saved.id { hovered = nil } }
        .onTapGesture { open(saved) }
    }
}

/// The side panel's left edge, to drag it wider or narrower. Tells how far
/// it moved since last told.
private struct Edge: View {
    let moved: (CGFloat) -> Void
    @State private var last: CGFloat = 0

    var body: some View {
        Color.clear
            .frame(width: 8)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global).onChanged { drag in
                moved(drag.translation.width - last)
                last = drag.translation.width
            }.onEnded { _ in last = 0 })
    }
}

/// The chat as a card over the window, in one of its corners. Dragged, only
/// the card moves; let go, it springs to the corner the throw was heading
/// for, as the floating video does. Its inner corner sizes it. Settings are
/// written once, at the end — every frame of a drag, they redrew the window.
struct AskFloat: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    @ObservedObject var chat: Chat
    @ObservedObject var prefs: Preferences
    let room: CGSize

    @State private var moving: CGSize = .zero
    @State private var sizing: CGSize = .zero
    @State private var flicks = Flicks()

    private static let margin: CGFloat = 12

    private var right: Bool { prefs.askCorner % 2 == 0 }
    private var bottom: Bool { prefs.askCorner < 2 }

    private var size: CGSize {
        CGSize(width: min(room.width - 24, min(640, max(260, prefs.askFloat.width + sizing.width))),
               height: min(room.height - 24, min(900, max(300, prefs.askFloat.height + sizing.height))))
    }

    /// Where the card's middle sits in its corner.
    private func spot(_ corner: Int, _ size: CGSize) -> CGPoint {
        let m = Self.margin
        return CGPoint(x: corner % 2 == 0 ? room.width - m - size.width / 2 : m + size.width / 2,
                       y: corner < 2 ? room.height - m - size.height / 2 : m + size.height / 2)
    }

    private var home: CGPoint { spot(prefs.askCorner, size) }

    /// The pointer for the inner corner: the Mac's own two-way one where it
    /// has it (macOS 15), crosshairs before.
    private var cornerCursor: NSCursor {
        if #available(macOS 15, *) {
            return NSCursor.frameResize(position: right ? (bottom ? .topLeft : .bottomLeft) : (bottom ? .topRight : .bottomRight),
                                        directions: .all)
        }
        return .crosshair
    }

    private func grip(width: CGFloat?, height: CGFloat?, cursor: NSCursor, across: Bool, down: Bool) -> some View {
        Color.clear
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, maxHeight: height == nil ? .infinity : nil)
            .contentShape(Rectangle())
            .onHover { inside in if inside { cursor.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global).onChanged { drag in
                sizing = CGSize(width: across ? (right ? -drag.translation.width : drag.translation.width) : 0,
                                height: down ? (bottom ? -drag.translation.height : drag.translation.height) : 0)
            }.onEnded { _ in
                prefs.askFloat.size = self.size
                sizing = .zero
            })
    }

    /// A two-finger swipe over the card's top bar sends it to another corner,
    /// as the floating video's does: along the way the fingers went, or to
    /// the corner they pointed at. Only over the top bar — below it, the same
    /// fingers scroll the chat.
    func flick(_ way: CGVector) {
        let across = abs(way.dx), up = abs(way.dy)
        var toRight = right, toTop = !bottom
        if min(across, up) >= 0.4 * max(across, up) {
            toRight = way.dx > 0
            toTop = way.dy > 0
        } else if across >= up {
            toRight = way.dx > 0
        } else {
            toTop = way.dy > 0
        }
        let corner = (toRight ? 0 : 1) + (toTop ? 2 : 0)
        guard corner != prefs.askCorner else { return }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) { prefs.askCorner = corner }
    }

    var body: some View {
        let size = size
        let home = home
        AskPanel(browser: browser, tab: tab, chat: chat, prefs: prefs, mode: .float) { drag, done in
            guard done else { return moving = drag.translation }
            let end = CGPoint(x: home.x + drag.predictedEndTranslation.width, y: home.y + drag.predictedEndTranslation.height)
            let corner = (end.x < room.width / 2 ? 1 : 0) + (end.y < room.height / 2 ? 2 : 0)
            withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) {
                prefs.askCorner = corner
                moving = .zero
            }
        }
        .frame(width: size.width, height: size.height)
        // Sized from the edges and the corner facing the middle of the window;
        // the size is kept when let go.
        .overlay(alignment: right ? .leading : .trailing) {
            grip(width: 6, height: nil, cursor: .resizeLeftRight, across: true, down: false)
        }
        .overlay(alignment: bottom ? .top : .bottom) {
            grip(width: nil, height: 6, cursor: .resizeUpDown, across: false, down: true)
        }
        .overlay(alignment: Alignment(horizontal: right ? .leading : .trailing, vertical: bottom ? .top : .bottom)) {
            grip(width: 16, height: 16, cursor: cornerCursor, across: true, down: true)
        }
        .onAppear {
            flicks.card = CGRect(x: home.x - size.width / 2, y: home.y - size.height / 2, width: size.width, height: size.height)
            flicks.start(for: self)
        }
        .onDisappear { flicks.stop() }
        .onChange(of: room) { _, room in flicks.room = room }
        .onChange(of: home) { _, _ in flicks.card = CGRect(x: home.x - size.width / 2, y: home.y - size.height / 2,
                                                         width: size.width, height: size.height) }
        .position(x: home.x + moving.width, y: home.y + moving.height)
    }
}

/// The floating card's flicks (AskFloat): the window's scroll-wheel events,
/// watched while the card is up, taken only over its top bar.
@MainActor
final class Flicks {
    var room: CGSize = .zero
    /// The card, in the window's content, top left origin.
    var card: CGRect = .zero
    private var monitor: Any?
    private var swipe = CGVector.zero
    private var flicked = false
    private var lastWheel = Date.distantPast

    func start(for float: AskFloat) {
        room = float.room
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let content = event.window?.contentView,
                  content.bounds.size == self.room else { return event }
            let at = event.locationInWindow
            let point = CGPoint(x: at.x, y: content.bounds.height - at.y)
            let bar = CGRect(x: self.card.minX, y: self.card.minY, width: self.card.width, height: Metrics.strip)
            // A swipe begun anywhere else is nothing to do with a flick.
            if event.phase.contains(.began), !bar.contains(point) { self.flicked = false; self.swipe = .zero }
            // The rest of a swipe begun on the bar is the bar's, even off it.
            guard bar.contains(point) || (!event.phase.isEmpty && self.swipe != .zero)
                    || !event.momentumPhase.isEmpty && self.flicked else { return event }
            self.take(event, float)
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func take(_ event: NSEvent, _ float: AskFloat) {
        // The glide after a flick is swallowed, up to its end.
        guard event.momentumPhase.isEmpty else {
            if event.momentumPhase.contains(.ended) { flicked = false }
            return
        }
        // Which way the fingers went, on screen (as Float's flickWheel).
        let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        let step = CGVector(dx: sign * event.scrollingDeltaX, dy: -sign * event.scrollingDeltaY)
        if event.phase.isEmpty {
            // A mouse's wheel: each turn a flick, a moment apart.
            guard Date().timeIntervalSince(lastWheel) > 0.4, step != .zero else { return }
            lastWheel = Date()
            float.flick(step)
            return
        }
        if event.phase.contains(.began) {
            swipe = .zero
            flicked = false
        }
        swipe.dx += step.dx
        swipe.dy += step.dy
        if !flicked, hypot(swipe.dx, swipe.dy) > 30 {
            flicked = true
            float.flick(swipe)
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            swipe = .zero
        }
    }
}
