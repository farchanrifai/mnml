import SwiftUI
import UniformTypeIdentifiers

/// Accounts and credentials are managed separately from the chat's choice of
/// sources. Importing a client configuration never starts authorization.
struct ConnectionsSettings: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var accounts = ConnectionAccounts.shared
    @State private var importError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose accounts for \(browser.space.name). Antigravity can search them when useful, or you can choose a source with @. Retrieved content goes to Antigravity.")
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            Card {
                Line("Automatic search in \(browser.space.name)", "Search enabled accounts when a question needs their content") {
                    Toggle("Automatic search", isOn: Binding(
                        get: { accounts.policy(for: browser.spaceID).automatic },
                        set: { enabled in
                            let space = browser.spaceID
                            Task { await accounts.setAutomatic(enabled, in: space) }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(accounts.busy)
                }
            }
            Card {
                Line("Google", "Gmail and Calendar · read-only; Drive · optional writes") {
                    Button("Connect Google") {
                        importError = nil
                        let space = browser.spaceID
                        Task { await accounts.connectGoogle(in: space) }
                    }
                    .disabled(accounts.busy || !accounts.googleConfigured)
                }
                connected(.google)
                Rule()
                Line("Desktop app client", accounts.googleConfigured ? "Credentials imported on this Mac" : "Import your own Google OAuth Desktop app JSON to enable sign-in") {
                    Button(accounts.googleConfigured ? "Replace JSON…" : "Import JSON…", action: chooseGoogleCredentials)
                        .disabled(accounts.busy)
                }
                googleGuide
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
            Card {
                Line("Notion", "Search and read pages you authorize") {
                    Button("Connect Notion") {
                        importError = nil
                        let space = browser.spaceID
                        Task { await accounts.connectNotion(in: space) }
                    }
                    .disabled(accounts.busy)
                }
                connected(.notion)
                Text("Search and read are available after connecting. Enable writes for an account below to create or append notes; each write needs your review in the chat. Review the pages you share on Notion’s permission screen.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
            if accounts.busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Connecting… Complete sign-in in your browser.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                    Spacer(minLength: 8)
                    Button("Cancel") { accounts.cancelAuthorization() }
                }
            }
            if let error = importError ?? accounts.error {
                Text(error)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.unsafe)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    @ViewBuilder
    private func connected(_ provider: ConnectionProvider) -> some View {
        ForEach(accounts.accounts.filter { $0.provider == provider }) { account in
            Rule()
            ConnectionAccountSettings(account: account, spaceID: browser.spaceID, spaceName: browser.space.name)
        }
    }

    private var googleGuide: some View {
        DisclosureGroup("Google setup for personal use") {
            VStack(alignment: .leading, spacing: 8) {
                Text("1. Create a Google Cloud project and enable the Gmail, Google Calendar and Google Drive APIs.")
                Text("2. Configure Google Auth Platform. For a personal Gmail account, choose External, keep it in Testing, and add your own account as a test user.")
                Text("3. In Data Access, add these scopes for account identity and read-only access:")
                Text(ConnectionOAuth.googleScopes.joined(separator: "\n"))
                    .font(.system(size: 10.5, design: .monospaced))
                    .textSelection(.enabled)
                Text("4. In Clients, create a Desktop app OAuth client and download its JSON. Import that file here, then choose Connect Google.")
                Text("For writes, also enable the Google Sheets and Google Docs APIs. Add https://www.googleapis.com/auth/drive in Data Access, then choose Enable writes… on the connected account. The same imported JSON is reused. Google asks for permission to edit and move Drive files; Gmail and Calendar remain read-only.")
                Text("With External apps in Testing, Google’s refresh token expires after seven days for these permissions. Reconnect Google when it expires.")
                HStack(spacing: 12) {
                    Link("Google Cloud Console", destination: URL(string: "https://console.cloud.google.com/auth/clients")!)
                    Link("Google’s setup guide", destination: URL(string: "https://developers.google.com/workspace/gmail/api/quickstart/python#authorize_credentials_for_a_desktop_application")!)
                }
                Link("Google’s token expiry guidance", destination: URL(string: "https://developers.google.com/identity/protocols/oauth2#expiration")!)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Palette.muted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Palette.ink)
    }

    private func chooseGoogleCredentials() {
        let panel = NSOpenPanel()
        panel.title = "Import Google Desktop App Credentials"
        panel.message = "Choose the JSON downloaded for your own Google OAuth Desktop app client."
        panel.prompt = "Import"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        let selected: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            importError = nil
            Task {
                do {
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 64_000 else { throw ConnectionFailure("Credentials file is too large.") }
                    let data = try Data(contentsOf: url)
                    guard data.count <= 64_000 else { throw ConnectionFailure("Credentials file is too large.") }
                    try await accounts.importGoogleCredentials(data)
                } catch {
                    // A malformed file or server response must never cause
                    // credentials to appear in an error message.
                    importError = "Couldn’t import these credentials. Choose the JSON for a Google OAuth Desktop app client."
                }
            }
        }
        if let window = browser.window {
            panel.beginSheetModal(for: window, completionHandler: selected)
        } else {
            selected(panel.runModal())
        }
    }
}

/// Labels belong to the connected account, while eligibility belongs to a
/// space. The account identity stays visible when a friendly label is used.
private struct ConnectionAccountSettings: View {
    let account: ConnectionAccount
    let spaceID: UUID
    let spaceName: String
    @ObservedObject private var accounts = ConnectionAccounts.shared
    @State private var label = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.displayTitle).font(.system(size: 13)).foregroundStyle(Palette.ink)
                    if account.displayTitle != account.title {
                        Text(account.title).font(.system(size: 11.5)).foregroundStyle(Palette.muted)
                            .textSelection(.enabled)
                    }
                    Text(account.services.map(\.title).joined(separator: ", ") +
                         (account.canWrite(account.provider == .google ? .drive : .notion) ? " · writes available" : " · search and read"))
                        .font(.system(size: 11.5)).foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 8)
                Button("Disconnect") { Task { await accounts.disconnect(account.id) } }
                    .disabled(accounts.busy)
            }
            HStack(spacing: 8) {
                TextField("Label, e.g. Personal account", text: $label)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .accessibilityLabel("Label for \(account.title)")
                    .onSubmit(saveLabel)
                Button("Save", action: saveLabel)
                    .disabled(accounts.busy || label.trimmingCharacters(in: .whitespacesAndNewlines) == (account.label ?? ""))
            }
            Toggle("Use in \(spaceName)", isOn: Binding(
                get: { accounts.eligible(in: spaceID).contains { $0.id == account.id } },
                set: { enabled in Task { await accounts.setEnabled(account: account.id, in: spaceID, enabled: enabled) } }
            ))
            .font(.system(size: 11.5))
            .toggleStyle(.checkbox)
            .disabled(accounts.busy)
            if account.canWrite(account.provider == .google ? .drive : .notion) {
                Toggle("Allow writes in \(spaceName)", isOn: Binding(
                    get: { accounts.writesEnabled(account: account.id, in: spaceID) },
                    set: { enabled in
                        Task { await accounts.setWritesEnabled(account: account.id, in: spaceID, enabled: enabled) }
                    }
                ))
                .font(.system(size: 11.5))
                .toggleStyle(.checkbox)
                .disabled(accounts.busy || !accounts.eligible(in: spaceID).contains { $0.id == account.id })
            } else {
                Button(account.provider == .google ? "Enable writes…" : "Allow Notion writes") {
                    Task { await accounts.enableWrites(account: account.id, in: spaceID) }
                }
                .disabled(accounts.busy || !accounts.eligible(in: spaceID).contains { $0.id == account.id })
            }
            Text(account.provider == .google
                 ? "Writes support Sheets, Docs and moving Drive files. Every change is reviewed in the chat before it is applied."
                 : "Writes support creating and appending notes in authorized pages. Every change is reviewed in the chat before it is applied.")
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .onAppear { label = account.label ?? "" }
        .onChange(of: account.label) { _, value in label = value ?? "" }
    }

    private func saveLabel() {
        guard !accounts.busy else { return }
        let value = label
        Task { await accounts.rename(account.id, label: value) }
    }
}

/// Automatic search uses the space's accounts. Explicit choices narrow a chat
/// to the named account and service, and never enable other spaces' accounts.
struct ConnectionChatMenu: View {
    @ObservedObject var browser: Browser
    @ObservedObject var chat: Chat
    let provider: AIProvider
    @ObservedObject private var accounts = ConnectionAccounts.shared

    private var available: [ConnectionSelection] { chat.availableConnections }

    var body: some View {
        Menu {
            if provider != .antigravity {
                Text("Automatic search requires Antigravity")
            }
            Toggle("Search automatically in this space", isOn: Binding(
                get: { chat.automaticConnections },
                set: { enabled in
                    let space = chat.connectionSpaceID
                    Task { await accounts.setAutomatic(enabled, in: space) }
                }
            ))
            .disabled(provider != .antigravity || accounts.busy)
            if provider == .antigravity {
                Text(chat.connectionSelections.isEmpty ? "Accounts enabled for this space" : "This chat searches only the selected sources")
            }
            Divider()
            if available.isEmpty {
                Text("No accounts enabled in this space")
            } else {
                ForEach(available) { selection in
                    Toggle(isOn: Binding(
                        get: { chat.connectionSelections.contains(selection) },
                        set: { selected in
                            chat.connectionSelections.removeAll { $0 == selection }
                            if selected { chat.mentionConnection(selection) }
                        }
                    )) {
                        Label(selection.service.title + " · " + accountTitle(selection), systemImage: selection.service.icon)
                    }
                    .disabled(provider != .antigravity)
                }
            }
            Divider()
            Button("Manage Connections…") {
                browser.settingsPage = .connections
                browser.tuning = true
            }
        } label: {
            HStack(spacing: 4) {
                Label("Connections", systemImage: "link")
                if provider == .antigravity, chat.automaticConnections, chat.connectionSelections.isEmpty, !available.isEmpty {
                    Text("Auto").font(.system(size: 9, weight: .medium))
                }
            }
            .font(.system(size: 10.5))
            .foregroundStyle(Palette.muted)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(provider == .antigravity ? "Search this space’s accounts automatically, or use @ to choose a source" : "Manage accounts. Automatic search requires Antigravity.")
        .accessibilityLabel("Connections")
    }

    private func accountTitle(_ selection: ConnectionSelection) -> String {
        accounts.accounts.first { $0.id == selection.accountID }?.displayIdentity ?? "Disconnected account"
    }
}

/// Citation metadata survives in the chat, including the account label at the
/// time it was read. Credentials and complete fetched documents stay elsewhere.
struct ConnectionSources: View {
    let hits: [ConnectionHit]
    @ObservedObject private var accounts = ConnectionAccounts.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Sources").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Palette.muted)
            ForEach(hits, id: \.reference) { hit in
                VStack(alignment: .leading, spacing: 2) {
                    if ["https", "http"].contains(hit.url.scheme?.lowercased() ?? "") {
                        Link(destination: hit.url) {
                            Label(hit.title, systemImage: hit.service.icon)
                                .font(.system(size: 11.5))
                                .lineLimit(2)
                        }
                        .help(hit.url.absoluteString)
                    } else {
                        Label(hit.title, systemImage: hit.service.icon)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(2)
                    }
                    Text(hit.service.title + " · " + accountTitle(hit))
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .help(hit.service.title + " · " + accountTitle(hit))
                }
                .padding(.vertical, 2)
            }
        }
        .textSelection(.enabled)
    }

    private func accountTitle(_ hit: ConnectionHit) -> String {
        hit.accountTitle ?? accounts.accounts.first(where: { $0.id == hit.accountID })?.displayIdentity ?? "Disconnected account"
    }
}

/// This card presents the frozen preflight request. Approval is scoped to its
/// identifier, so a stale button cannot authorize a different pending write.
struct ConnectionWriteReview: View {
    let chat: UUID
    @ObservedObject private var approvals = ConnectionWriteApprovals.shared

    var body: some View {
        if let pending = approvals.pending[chat] {
            let prepared = pending.prepared
            VStack(alignment: .leading, spacing: 10) {
                Label("Review write", systemImage: "square.and.pencil")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text(prepared.plan.operation.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.ink)
                detail("Account", prepared.account.displayIdentity)
                if let title = prepared.plan.title { detail("Title", title) }
                if let target = prepared.target { source("Target", target) }
                if let destination = prepared.destination { source("Destination", destination) }
                if let range = prepared.plan.range { detail("Cells", range) }
                if !prepared.before.isEmpty {
                    preview("Current content", prepared.before)
                }
                if [.createSheet, .updateSheet].contains(prepared.plan.operation), let values = prepared.plan.values {
                    preview("New cells (row by row)", cellsPreview(values))
                    Text("Cell values are written literally. Text beginning with = is not evaluated as a formula.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    preview(prepared.plan.operation == .moveDrive ? "Change" : "Text to write",
                            prepared.plan.operation == .moveDrive ? "Move the selected file into the destination folder." : (prepared.plan.text ?? ""))
                }
                HStack(spacing: 8) {
                    Button("Approve write") { approvals.approve(chat: chat, id: pending.id) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityLabel("Approve \(prepared.plan.operation.title) for \(prepared.account.displayIdentity)")
                    Button("Cancel") { approvals.reject(chat: chat, id: pending.id) }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Cancel proposed write")
                }
                .controlSize(.small)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.ink.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1) }
            .accessibilityElement(children: .contain)
            .id(pending.id)
        }
    }

    private func detail(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Palette.muted)
            Text(value).font(.system(size: 11.5)).foregroundStyle(Palette.ink).textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func source(_ label: String, _ hit: ConnectionHit) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Palette.muted)
            if hit.url.scheme?.lowercased() == "https" {
                Link(hit.title, destination: hit.url)
                    .font(.system(size: 11.5))
                    .help(hit.url.absoluteString)
            } else {
                Text(hit.title).font(.system(size: 11.5)).foregroundStyle(Palette.ink)
            }
        }
    }

    private func preview(_ label: String, _ content: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Palette.muted)
            ScrollView([.horizontal, .vertical]) {
                Text(content)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(minHeight: 40, maxHeight: 180)
            .background(Palette.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityLabel(label)
        }
    }

    private func cellsPreview(_ values: [[ConnectionCell]]) -> String {
        // JSON preserves cell boundaries, embedded tabs/newlines and value
        // types that would be ambiguous in a tab-separated text preview.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return (try? encoder.encode(values)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}
