//
//  ConnectorHubViews.swift
//  leanring-buddy
//
//  The parts of the Connectors screen and the bot settings that only exist with Theo's own connector hub
//  (ConnectorHub.swift): an app's details (how it's reached, its sign-in, who may do what with it), the
//  starter catalog and "Add your own" (an address or a command), and the level each bot has for each app.
//  Without the helper none of this shows, and the screen is as it was before the hub.
//

import ClickyCore
import SwiftUI

// MARK: - One hub app's details

/// What a hub app's row opens to: how it's reached, what it last said, which bots use it and how far each may go, and its
/// sign-in, off switch and Remove.
struct HubAppDetails: View {
    let connector: BotConnector
    let record: HubAppRecord
    let users: [NativeBot]
    /// The screen's note line, for what an action did.
    @Binding var note: String?
    @ObservedObject private var health = ConnectorHealth.shared
    @State private var pastedToken = ""
    @State private var working = false
    @State private var confirmsRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            line("Reached", reachedWords)
            if let reason = record.reason, record.status == "failed" { line("What it said", reason) }
            line("Last worked", record.lastWorked.map { ConnectorListing.workedAgo($0).replacingOccurrences(of: "worked ", with: "") } ?? "Not seen connected yet")
            line("Used by", users.isEmpty ? "No bot yet. Give it to a bot in the bot's settings." :
                    users.map { "\($0.name) (\(HubAccessLevel(saved: $0.appLevels?[record.id]).label.lowercased()))" }.joined(separator: ", "))
            if record.takesPastedToken {
                HStack(spacing: 8) {
                    SecureField(record.signedIn ? "Paste a new token to replace it" : "Paste its token", text: $pastedToken)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                    Button(working ? "Saving…" : "Save token") { saveToken() }
                        .buttonStyle(.theo(.primary, .small)).disabled(working || pastedToken.isEmpty)
                }
                .padding(.top, 2)
                Text("It stays encrypted on this Mac, with its key in your Keychain. Theo never shows it again.")
                    .font(TheoType.caption).foregroundColor(DS.Colors.textTertiary)
            }
            HStack(spacing: 8) {
                if record.signsInWithBrowser {
                    if record.signedIn {
                        Button("Sign out") { act("Signed out of \(record.name).") { try await ConnectorHub.signOut(record.id) } }
                            .buttonStyle(.theo(.secondary, .small))
                    } else {
                        Button("Sign in") {
                            working = true
                            Task {
                                note = await health.signIn(connector, forBot: nil)
                                working = false
                                await health.refresh()
                            }
                        }
                        .buttonStyle(.theo(.primary, .small))
                    }
                } else if record.takesPastedToken, record.signedIn {
                    Button("Forget token") { act("Forgot \(record.name)'s token.") { try await ConnectorHub.signOut(record.id) } }
                        .buttonStyle(.theo(.secondary, .small))
                } else if record.isClaudeAccount, record.status == "needsSignIn" || record.status == "failed" {
                    Button("Open claude.ai connectors") { BotConnectors.openClaudeConnectors() }.buttonStyle(.theo(.secondary, .small))
                }
                Button(record.enabled ? "Turn off" : "Turn on") {
                    act(record.enabled ? "\(record.name) is off: no bot can use it until you turn it on." : "\(record.name) is on.") {
                        try await ConnectorHub.setEnabled(record.id, !record.enabled)
                    }
                }
                .buttonStyle(.theo(.secondary, .small))
                Button("Remove…") { confirmsRemove = true }.buttonStyle(.theo(.ghost, .small))
            }
            .disabled(working)
            .padding(.top, 4)
        }
        .padding(.leading, 66).padding(.trailing, 14).padding(.bottom, 12)
        .confirmationDialog("Remove \(record.name) from Theo?", isPresented: $confirmsRemove) {
            Button("Remove", role: .destructive) {
                act("Removed \(record.name). Bots that had it keep it in their settings, unused, until you add it again.") {
                    try await ConnectorHub.remove(record.id)
                }
            }
        } message: {
            Text("Its sign-in is forgotten too. You can add it again any time.")
        }
    }

    private var reachedWords: String {
        switch record.kind {
        case .claudeAccount: return "Through your Claude account (\(record.server ?? record.name)), so it needs Claude Code"
        case .remote:
            let signIn = record.auth == "oauth" ? "signs in in your browser" : record.auth == "token" ? "with a token you pasted" : "no sign-in"
            return "\(record.url ?? "An address"), \(signIn)"
        case .local: return "A program on this Mac: \(record.command ?? "a command")"
        }
    }

    private func line(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(TheoType.caption).foregroundColor(DS.Colors.textTertiary).frame(width: 170, alignment: .leading)
            Text(value).font(TheoType.caption).foregroundColor(DS.Colors.textSecondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func saveToken() {
        let token = pastedToken
        pastedToken = ""
        act("Saved \(record.name)'s token.") {
            try await ConnectorHub.savePastedToken(record.id, token: token)
            try? await ConnectorHub.check(record.id)
        }
    }

    /// Runs one change through the hub, then reads the list again.
    private func act(_ done: String, _ change: @escaping () async throws -> Void) {
        working = true
        Task {
            do {
                try await change()
                note = done
            } catch {
                note = error.localizedDescription
            }
            working = false
            await health.refresh()
        }
    }
}

// MARK: - Adding apps

/// The starter catalog's apps that aren't added yet, then "Add your own": an MCP server's address (signed in in the browser,
/// with a token, or not at all) or a command on this Mac.
struct AddConnectorSection: View {
    @Binding var note: String?
    @ObservedObject private var health = ConnectorHealth.shared
    @State private var catalog: [HubCatalogEntry] = []
    @State private var working: String?
    @State private var name = ""
    @State private var kind = "address"
    @State private var address = ""
    @State private var signIn = "oauth"
    @State private var commandLine = ""

    private var notAddedYet: [HubCatalogEntry] {
        let added = Set(health.hubApps.map(\.id))
        return catalog.filter { !added.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add an app").font(.system(size: 13, weight: .semibold)).foregroundColor(DS.Colors.textSecondary)
            VStack(spacing: 0) {
                ForEach(Array(notAddedYet.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { RowDivider() }
                    HStack(spacing: 12) {
                        AppLogo(connector: BotConnector(id: entry.id, name: entry.name, symbol: BotConnectors.symbol(for: HubAppRecord.Kind(rawValue: entry.kind) ?? .remote),
                                                        claudeServer: nil, claudeToolPrefix: nil, openCodeServer: nil, openCodeURL: nil), size: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name).font(.system(size: 13, weight: .medium)).foregroundColor(DS.Colors.textPrimary)
                            Text([entry.description, entry.via].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(TheoType.caption).foregroundColor(DS.Colors.textTertiary).lineLimit(2)
                        }
                        Spacer(minLength: 12)
                        Button(working == entry.id ? "Adding…" : "Add") { addFromCatalog(entry) }
                            .buttonStyle(.theo(.secondary, .small)).disabled(working != nil)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10).frame(minHeight: 52)
                }
                if !notAddedYet.isEmpty { RowDivider() }
                ownAppForm.padding(.horizontal, 14).padding(.vertical, 12)
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Colors.surface1))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
        }
        .task { catalog = (try? await ConnectorHub.catalog()) ?? [] }
    }

    private var ownAppForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add your own").font(.system(size: 13, weight: .medium)).foregroundColor(DS.Colors.textPrimary)
            Text("Any MCP server: its address (most apps list one in their docs), or a command that starts it on this Mac.")
                .font(TheoType.caption).foregroundColor(DS.Colors.textTertiary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField("Name", text: $name).textFieldStyle(.roundedBorder).frame(width: 160)
                Picker("", selection: $kind) {
                    Text("Address").tag("address")
                    Text("Command").tag("command")
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 180)
            }
            if kind == "address" {
                HStack(spacing: 8) {
                    TextField("https://mcp.example.com/mcp", text: $address).textFieldStyle(.roundedBorder)
                    Picker("", selection: $signIn) {
                        Text("Sign in in the browser").tag("oauth")
                        Text("Paste a token").tag("token")
                        Text("No sign-in").tag("none")
                    }
                    .labelsHidden().frame(width: 190)
                }
            } else {
                TextField("npx -y @modelcontextprotocol/server-filesystem ~/Notes", text: $commandLine).textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button(working == "own" ? "Adding…" : "Add") { addOwn() }
                    .buttonStyle(.theo(.primary, .small))
                    .disabled(working != nil || name.trimmingCharacters(in: .whitespaces).isEmpty
                              || (kind == "address" ? address.isEmpty : commandLine.isEmpty))
            }
        }
    }

    private func addFromCatalog(_ entry: HubCatalogEntry) {
        working = entry.id
        Task {
            do {
                try await ConnectorHub.addFromCatalog(entry.id)
                note = "Added \(entry.name). Give it to a bot in the bot's settings."
            } catch {
                note = error.localizedDescription
            }
            working = nil
            await health.refresh()
        }
    }

    private func addOwn() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = ConnectorHubNewApp.id(fromName: trimmedName, taken: Set(health.hubApps.map(\.id)))
        let entry: [String: Any]?
        if kind == "address" {
            entry = ConnectorHubNewApp.remote(id: id, name: trimmedName, address: address, signIn: signIn)
            if entry == nil {
                note = "That address doesn't work: it has to start with https:// (or http:// on this Mac)."
                return
            }
        } else {
            entry = ConnectorHubNewApp.local(id: id, name: trimmedName, commandLine: commandLine, home: TheoProfile.realHome)
        }
        guard let entry else { return }
        let wantsBrowserSignIn = kind == "address" && signIn == "oauth"
        working = "own"
        Task {
            do {
                try await ConnectorHub.add(entry: entry)
                note = wantsBrowserSignIn ? "Added \(trimmedName). Press Sign in on its row to connect it." :
                    kind == "address" && signIn == "token" ? "Added \(trimmedName). Open its row and paste its token." : "Added \(trimmedName)."
                name = ""
                address = ""
                commandLine = ""
            } catch {
                note = error.localizedDescription
            }
            working = nil
            await health.refresh()
        }
    }
}

// MARK: - What each bot may do

/// Under a bot's apps: for each of Theo's own apps it has, how far it may go (read only, read and draft, everything).
/// Theo's screen tools and Chrome aren't hub apps and have no levels.
struct AppLevelRows: View {
    let bot: NativeBot
    let onChange: (String, HubAccessLevel) -> Void

    var body: some View {
        let hubApps = BotConnectors.known.filter { $0.hub != nil && bot.apps.contains($0.id) }
        if !hubApps.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("What it may do").font(.system(size: 11, weight: .medium)).foregroundColor(DS.Colors.textTertiary).padding(.top, 4)
                ForEach(hubApps) { connector in
                    let level = HubAccessLevel(saved: bot.appLevels?[connector.id])
                    HStack(spacing: 8) {
                        Text(connector.name).font(.system(size: 11.5)).foregroundColor(DS.Colors.textSecondary).lineLimit(1)
                        Spacer(minLength: 8)
                        Picker("", selection: Binding(get: { level }, set: { onChange(connector.id, $0) })) {
                            ForEach(HubAccessLevel.allCases, id: \.self) { option in Text(option.label).tag(option) }
                        }
                        .labelsHidden().pickerStyle(.menu).fixedSize()
                        .help(level.explanation)
                    }
                }
                Text("Only on your own words: a routine, another bot or the local API only ever reads.")
                    .font(.system(size: 10.5)).foregroundColor(DS.Colors.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The bot's saved levels after one change (the standard level isn't saved, so older Theos read the same).
    static func levels(_ saved: [String: String]?, setting appID: String, to level: HubAccessLevel) -> [String: String]? {
        var levels = saved ?? [:]
        levels[appID] = level == .standard ? nil : level.rawValue
        return levels.isEmpty ? nil : levels
    }
}
