import SwiftUI

struct LinkRule: Codable, Equatable, Identifiable {
    var id = UUID()
    var domain = ""
    var includeSubdomains = true
    var destination: UUID = Space.firstID
    var enabled = true
}

@MainActor
final class LinkRoutes: ObservableObject {
    static let shared = LinkRoutes(defaults: Store.settings)
    @Published private(set) var rules: [LinkRule]
    private let defaults: UserDefaults
    private static let key = "links.routes"

    init(defaults: UserDefaults) {
        self.defaults = defaults
        rules = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([LinkRule].self, from: $0) } ?? []
    }

    // URL supplies the same IDNA spelling for both rules and incoming hosts.
    static func domain(_ text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = text.contains("://") ? text : "https://" + text
        guard let parts = URLComponents(string: address),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              var host = parts.url?.host?.lowercased() else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, host.utf8.count <= 253 else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }) else { return nil }
        return host
    }

    @discardableResult func save(_ draft: LinkRule) -> String? {
        guard let domain = Self.domain(draft.domain) else { return "Enter a domain such as example.com, without a path or port." }
        var rule = draft
        rule.domain = domain
        guard !rules.contains(where: { $0.id != rule.id && $0.enabled && rule.enabled && $0.domain == domain && $0.includeSubdomains == rule.includeSubdomains }) else {
            return "An enabled rule already covers this domain and subdomain setting."
        }
        if let at = rules.firstIndex(where: { $0.id == rule.id }) { rules[at] = rule } else { rules.append(rule) }
        persist()
        return nil
    }

    func remove(_ id: UUID) { rules.removeAll { $0.id == id }; persist() }
    func remove(space: UUID) { rules.removeAll { $0.destination == space }; persist() }
    private func persist() { if let data = try? JSONEncoder().encode(rules) { defaults.set(data, forKey: Self.key) } }

    func destination(for url: URL, spaces: [Space], enabled: Bool) -> UUID? {
        guard enabled, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let raw = url.host, let host = Self.domain(raw) else { return nil }
        return rules.filter { rule in
            rule.enabled && spaces.contains { $0.id == rule.destination }
                && (host == rule.domain || (rule.includeSubdomains && host.hasSuffix("." + rule.domain)))
        }.sorted { lhs, rhs in
            if (host == lhs.domain) != (host == rhs.domain) { return host == lhs.domain }
            if lhs.domain.count != rhs.domain.count { return lhs.domain.count > rhs.domain.count }
            return !lhs.includeSubdomains && rhs.includeSubdomains
        }.first?.destination
    }
}

extension Browser {
    /// Only the external-link entry point calls this; typed and restored URLs bypass it.
    @discardableResult func routeExternal(_ url: URL) -> Bool { routeExternal(url, using: .shared) }

    @discardableResult func routeExternal(_ url: URL, using routes: LinkRoutes) -> Bool {
        guard let id = routes.destination(for: url, spaces: spaces, enabled: prefs.usesSpaces) else { return false }
        switchSpace(to: id, animated: false)
        guard spaceID == id else { return false }
        open(url, foreground: true, atEnd: true)
        return true
    }
}

struct LinkRoutesPage: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var routes = LinkRoutes.shared
    @State private var draft: LinkRule?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Send links from other apps straight to a Space and its sign-ins. Exact domains win, then the closest parent domain.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
            if !browser.prefs.usesSpaces {
                Text("Routing is paused while Spaces are off.").font(.system(size: 12))
                Button("Enable Spaces") { browser.prefs.usesSpaces = true }
            }
            ForEach(routes.rules) { rule in
                if let value = draft, value.id == rule.id {
                    editor(value, editing: true)
                } else {
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Toggle(rule.domain, isOn: Binding(get: { rule.enabled }, set: { value in
                                    var changed = rule; changed.enabled = value; error = routes.save(changed)
                                }))
                                Spacer()
                                Button("Edit") { draft = rule; error = nil }
                                Button("Delete", role: .destructive) { routes.remove(rule.id) }
                            }
                            Text((browser.spaces.first { $0.id == rule.destination }?.name ?? "Unavailable Space") + (rule.includeSubdomains ? " · includes subdomains" : " · exact domain only"))
                                .font(.system(size: 11)).foregroundStyle(Palette.muted)
                        }.padding(12)
                    }
                }
            }
            if let value = draft, !routes.rules.contains(where: { $0.id == value.id }) {
                editor(value, editing: false)
            } else if draft == nil {
                Button("Add Rule") { draft = LinkRule(destination: browser.spaceID); error = nil }
                    .disabled(!browser.prefs.usesSpaces)
            }
            if draft == nil, let error { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
        }
    }

    private func editor(_ value: LinkRule, editing: Bool) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text(editing ? "Edit Rule" : "New Rule")
                        .font(.system(size: 13, weight: .semibold))
                    if editing {
                        Text(routes.rules.first { $0.id == value.id }?.domain ?? value.domain)
                            .font(.system(size: 12)).foregroundStyle(Palette.muted)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                }
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Domain").font(.system(size: 11)).foregroundStyle(Palette.muted)
                        TextField("example.com", text: Binding(get: { draft?.domain ?? value.domain }, set: { draft?.domain = $0 }))
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Domain")
                    }.frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Open in Space").font(.system(size: 11)).foregroundStyle(Palette.muted)
                        Picker("Destination Space", selection: Binding(get: { draft?.destination ?? value.destination }, set: { draft?.destination = $0 })) {
                            ForEach(browser.spaces) { space in Text(space.name).tag(space.id) }
                        }.labelsHidden().frame(maxWidth: .infinity)
                    }.frame(width: 170)
                }
                HStack(spacing: 20) {
                    Toggle("Include subdomains", isOn: Binding(get: { draft?.includeSubdomains ?? value.includeSubdomains }, set: { draft?.includeSubdomains = $0 }))
                        .help("Also match sites such as www.example.com.")
                    Toggle("Enabled", isOn: Binding(get: { draft?.enabled ?? value.enabled }, set: { draft?.enabled = $0 }))
                        .help("Turn off to pause this rule.")
                }.font(.system(size: 12))
                if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
                HStack(spacing: 8) {
                    Spacer()
                    Button("Cancel") { draft = nil; error = nil }
                    Button(editing ? "Save Changes" : "Add Rule") {
                        guard let draft else { return }
                        guard browser.spaces.contains(where: { $0.id == draft.destination }) else { error = "Choose an existing Space."; return }
                        error = routes.save(draft)
                        if error == nil { self.draft = nil }
                    }.buttonStyle(.borderedProminent)
                        .disabled(!browser.prefs.usesSpaces)
                }
            }.padding(14)
        }
    }
}
