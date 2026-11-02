//
//  TheoLink.swift
//  leanring-buddy
//
//  Theo Link: one encrypted connection between the owner's two Macs, so they run as one Theo. Both hold the same pairing
//  code, and a connection only opens for someone who proves they have it (TLS with a pre-shared key). They find each other
//  on the local network, or at an address the owner gives (a Tailscale name works from anywhere).
//
//  Every few seconds each side sends fingerprints of what it holds. Whatever differs gets asked for and merged with
//  LinkMerge, so both end up the same. API keys, engine sessions and routines stay on their own Mac: a key shouldn't leave
//  the Keychain, a session only exists where it ran, and a routine must fire once.
//

import ClickyCore
import Combine
import CryptoKit
import Foundation
import Network
import SwiftUI

@MainActor
final class TheoLink: ObservableObject {
    static let shared = TheoLink()
    static let port: NWEndpoint.Port = 47331
    private static let serviceType = "_theolink._tcp"
    private static let hostKey = "v3.link.host"
    private static let identity = "theo-link"
    private static let clickyMacKey = "v3.clicky.mac"
    private static let clickyMacAtKey = "v3.clicky.macChangedAt"
    private static let knownPeerKey = "v3.link.knownPeer"
    nonisolated static let localName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName

    @Published private(set) var isPaired = false
    @Published private(set) var peerName: String?
    @Published private(set) var peerBuild: Int?
    @Published private(set) var lastSync: Date?
    @Published private(set) var problem: String?
    @Published private(set) var code: String?

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var reader = LinkFrameReader()
    private var isHelloDone = false
    private var digestTimer: Timer?
    private var retryTimer: Timer?
    private var foundPeers: [NWEndpoint] = []
    private var waitingOrders: [String: (String) -> Void] = [:]
    private var isSyncQueued = false
    private var waitingRequests: [(action: String, fields: [String: String])] = []
    private var connectionState = "none"
    private var isConnectionReady = false
    private var failedDials = 0
    /// A connection that hasn't opened in this long is given up on, so a stuck one can't block the next try.
    private static let dialTimeoutSeconds: UInt64 = 15

    private let queue = DispatchQueue(label: "theo.link")
    private static var secretFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".clicky/link-secret")
    }
    private var localName: String { Self.localName }
    var isConnected: Bool { peerName != nil }
    private var localBuild: Int { Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0 }

    var host: String {
        get { UserDefaults.standard.string(forKey: Self.hostKey) ?? "" }
        set {
            UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.hostKey)
            restart()
        }
    }

    var statusReport: [String: Any] {
        ["clickyHere": clickyRunsHere, "clickyMac": clickyMacNow, "paired": isPaired, "peer": peerName ?? NSNull(), "peerBuild": peerBuild ?? NSNull(), "build": localBuild,
         "lastSync": lastSync.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(), "problem": problem ?? NSNull(),
         "found": foundPeers.count, "listening": listener?.state == .ready, "connection": connectionState, "failedDials": failedDials]
    }

    // MARK: Where Clicky works

    /// The Mac Clicky works on for now, by name. Both Macs share it, and either can change it. Nil: the one with the work screen.
    @Published private(set) var clickyMac = UserDefaults.standard.string(forKey: TheoLink.clickyMacKey)
    private var clickyMacChangedAt = UserDefaults.standard.object(forKey: TheoLink.clickyMacAtKey) as? Date
    /// The other Mac's name, kept so the switch can offer it while it's away.
    @Published private(set) var knownPeerName = UserDefaults.standard.string(forKey: TheoLink.knownPeerKey)

    /// Everything asked of Clicky, by voice, in its chat or through Theo, happens on the chosen Mac.
    var clickyRunsHere: Bool { !isPaired || (clickyMac.map { $0 == Self.localName } ?? isWorkMac) }

    var clickyMacChoices: [String] { [Self.localName] + (knownPeerName.map { [$0] } ?? []) }

    /// The name on the switch: "Adhyan’s MacBook Air" → "MacBook Air".
    static func shortName(_ name: String) -> String {
        name.range(of: #"^.*['’]s\s+"#, options: .regularExpression).map { String(name[$0.upperBound...]) } ?? name
    }

    /// What the switch shows now.
    var clickyMacNow: String {
        clickyMac ?? (isWorkMac ? Self.localName : knownPeerName ?? Self.localName)
    }

    func setClickyMac(_ name: String) {
        saveClickyMac(name, at: Date())
        sendDigest()
    }

    /// "air" or "studio", said out loud. False when neither Mac goes by that.
    @discardableResult
    func setClickyMac(word: String) -> Bool {
        guard let name = clickyMacChoices.first(where: { $0.lowercased().contains(word) }) else { return false }
        setClickyMac(name)
        return true
    }

    private func saveClickyMac(_ name: String?, at date: Date?) {
        clickyMac = name
        clickyMacChangedAt = date
        UserDefaults.standard.set(name, forKey: Self.clickyMacKey)
        UserDefaults.standard.set(date, forKey: Self.clickyMacAtKey)
        CompanionManager.current?.clickyPlaceChanged()
    }

    var clickyMacItem: ClickyMacItem { ClickyMacItem(name: clickyMac, at: clickyMacChangedAt) }

    func applyClickyMac(_ item: ClickyMacItem) {
        guard let at = item.at, at > (clickyMacChangedAt ?? .distantPast) else { return }
        saveClickyMac(item.name, at: at)
    }

    /// This Mac has a work screen picked, even with that monitor off for now.
    var isWorkMac: Bool { !ClickySettings.claudiaScreenName.isEmpty }

    private var clickyElsewhere: String {
        "Clicky's set to work on \(Self.shortName(clickyMacNow)), which isn't connected right now. You can switch it in the menu bar."
    }

    /// Something said to Clicky here goes to the Mac it works on. It's never done here instead.
    func sendClickyToOtherMac(_ text: String, speaks: Bool) {
        let sent = request("clicky", ["text": text, "speaks": speaks ? "yes" : "no"])
        CompanionManager.current?.showHandsFreeStatusMessage(sent ? "Clicky's on it, on \(Self.shortName(clickyMacNow))" : "\(Self.shortName(clickyMacNow)) isn't connected")
        if sent { BotsStore.shared.post(BotChatMessage(author: "user", text: text), to: BotsStore.clickyID) }
        if !sent { BotsStore.shared.post(BotChatMessage(author: BotsStore.clickyID, text: clickyElsewhere), to: BotsStore.clickyID) }
    }

    func sendOrderToOtherMac(_ order: String, ownerWords: String?, onReport: ((String) -> Void)?) {
        let id = UUID().uuidString
        guard request("order", ["order": order, "ownerWords": ownerWords ?? "", "id": id]) else {
            onReport?(clickyElsewhere)
            if onReport == nil, let ceo = BotsStore.shared.primary {
                BotsStore.shared.post(BotChatMessage(author: BotsStore.clickyID, text: clickyElsewhere), to: ceo.id)
            }
            return
        }
        if let onReport { waitingOrders[id] = onReport }
    }

    func orderReported(_ id: String, report: String) {
        waitingOrders.removeValue(forKey: id)?(report)
    }

    // MARK: Pairing

    private init() {
        if let saved = try? String(contentsOf: Self.secretFile, encoding: .utf8), let normalized = LinkPairing.normalized(saved) {
            code = normalized
            isPaired = true
        }
    }

    func start() {
        if isPaired { startNetworking() }
    }

    /// A new code for this Mac, to type on the other one.
    func pairWithNewCode() { save(LinkPairing.newCode()) }

    /// False when it can't be a code.
    @discardableResult
    func pair(typed: String) -> Bool {
        guard let normalized = LinkPairing.normalized(typed) else { return false }
        save(normalized)
        return true
    }

    private func save(_ newCode: String) {
        let file = Self.secretFile
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(newCode.utf8).write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        code = newCode
        isPaired = true
        restart()
    }

    func unpair() {
        try? FileManager.default.removeItem(at: Self.secretFile)
        code = nil
        isPaired = false
        stopNetworking()
    }

    private func restart() {
        stopNetworking()
        if isPaired { startNetworking() }
    }

    // MARK: Networking

    private func parameters(code: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let key = LinkPairing.key(forCode: code)
        let keyData = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let identityData = Data(Self.identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, keyData as __DispatchData, identityData as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 15
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }

    private func startNetworking() {
        guard let code else { return }
        let params = parameters(code: code)
        problem = nil
        if let listener = try? NWListener(using: params, on: Self.port) {
            listener.service = NWListener.Service(name: localName, type: Self.serviceType)
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state { Task { @MainActor in self?.problem = "Can't listen: \(error.localizedDescription)" } }
            }
            listener.newConnectionHandler = { [weak self] incoming in
                Task { @MainActor in self?.accept(incoming) }
            }
            listener.start(queue: queue)
            self.listener = listener
        } else {
            problem = "Port \(Self.port.rawValue) is taken on this Mac."
        }
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let endpoints = results.map(\.endpoint)
            Task { @MainActor in
                self?.foundPeers = endpoints
                self?.dialIfNeeded()
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state { Task { @MainActor in self?.problem = "Can't look for your other Mac: \(error.localizedDescription)" } }
        }
        browser.start(queue: queue)
        self.browser = browser
        retryTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.dialIfNeeded() }
        }
        dialIfNeeded()
    }

    private func stopNetworking() {
        retryTimer?.invalidate()
        retryTimer = nil
        digestTimer?.invalidate()
        digestTimer = nil
        browser?.cancel()
        browser = nil
        listener?.cancel()
        listener = nil
        connection?.cancel()
        connection = nil
        peerName = nil
        peerBuild = nil
        foundPeers = []
    }

    /// One dials so there's only ever one connection: the Mac whose name sorts first, or whichever was given an address.
    private func dialIfNeeded() {
        guard connection == nil, let code else { return }
        let manual = host
        if !manual.isEmpty {
            dial(.hostPort(host: NWEndpoint.Host(manual), port: Self.port), code: code)
            return
        }
        for endpoint in foundPeers {
            // After a couple of failures the other way round gets a go too: one Mac's network can be the stuck one.
            guard case .service(let name, _, _, _) = endpoint, name != localName, localName < name || failedDials >= 2 else { continue }
            dial(endpoint, code: code)
            return
        }
    }

    private func dial(_ endpoint: NWEndpoint, code: String) {
        use(NWConnection(to: endpoint, using: parameters(code: code)))
    }

    private func accept(_ incoming: NWConnection) {
        guard connection == nil || !isConnectionReady else {
            incoming.cancel()
            return
        }
        connection?.cancel()
        use(incoming)
    }

    private func use(_ newConnection: NWConnection) {
        connection = newConnection
        reader = LinkFrameReader()
        isHelloDone = false
        isConnectionReady = false
        connectionState = "starting"
        Task { [weak self, weak newConnection] in
            try? await Task.sleep(nanoseconds: Self.dialTimeoutSeconds * 1_000_000_000)
            guard let self, let newConnection, self.connection === newConnection, !self.isConnectionReady else { return }
            self.failedDials += 1
            self.connectionEnded()
        }
        newConnection.stateUpdateHandler = { [weak self, weak newConnection] state in
            Task { @MainActor in
                guard let self, let newConnection, self.connection === newConnection else { return }
                self.connectionState = "\(state)"
                switch state {
                case .ready:
                    self.problem = nil
                    self.isConnectionReady = true
                    self.failedDials = 0
                    self.send(LinkEnvelope(kind: .hello, name: self.localName, build: self.localBuild))
                    self.receive(on: newConnection)
                case .failed(let error):
                    self.problem = "Couldn't connect: \(error.localizedDescription)"
                    self.failedDials += 1
                    self.connectionEnded()
                case .cancelled:
                    self.connectionEnded()
                case .waiting(let error):
                    self.problem = "Waiting to connect: \(error.localizedDescription)"
                default:
                    break
                }
            }
        }
        newConnection.start(queue: queue)
    }

    private func connectionEnded() {
        connection?.cancel()
        connection = nil
        connectionState = "none"
        isConnectionReady = false
        peerName = nil
        peerBuild = nil
        digestTimer?.invalidate()
        digestTimer = nil
    }

    private func receive(on current: NWConnection) {
        current.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self, weak current] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, let current, self.connection === current else { return }
                if let data, !data.isEmpty {
                    guard let messages = self.reader.feed(data) else {
                        self.connectionEnded()
                        return
                    }
                    for message in messages { self.handle(message) }
                }
                if isComplete || error != nil {
                    self.connectionEnded()
                } else {
                    self.receive(on: current)
                }
            }
        }
    }

    private func send(_ envelope: LinkEnvelope) {
        guard let connection, let data = try? LinkCoding.encoder.encode(envelope) else { return }
        connection.send(content: LinkFrameReader.frame(data), completion: .contentProcessed { _ in })
    }

    // MARK: The conversation

    private func handle(_ data: Data) {
        guard let envelope = try? LinkCoding.decoder.decode(LinkEnvelope.self, from: data) else { return }
        switch envelope.kind {
        case .hello:
            peerName = envelope.name
            if let name = envelope.name, name != knownPeerName {
                knownPeerName = name
                UserDefaults.standard.set(name, forKey: Self.knownPeerKey)
            }
            peerBuild = envelope.build
            isHelloDone = true
            sendDigest()
            digestTimer?.invalidate()
            digestTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sendDigest() }
            }
            for waiting in waitingRequests { _ = request(waiting.action, waiting.fields) }
            waitingRequests.removeAll()
            if (envelope.build ?? 0) > localBuild {
                // The other Mac is ahead: offer the update here too, so they don't drift.
                Task { await CompanionManager.current?.updateController.check(quietly: true) }
            }
        case .digest:
            guard let theirs = envelope.digests else { return }
            let store = BotsStore.shared
            Task {
                let mine = await self.currentDigests()
                let wanted = theirs.filter { mine[$0.key] != $0.value && store.wantsLinkItem($0.key) }.map(\.key)
                if wanted.isEmpty {
                    if mine == theirs || Set(theirs.keys).isSubset(of: Set(mine.keys)) { self.lastSync = Date() }
                } else {
                    self.send(LinkEnvelope(kind: .want, keys: wanted))
                }
            }
        case .want:
            for key in envelope.keys ?? [] {
                if let payload = BotsStore.shared.linkPayload(key) { send(LinkEnvelope(kind: .item, key: key, payload: payload)) }
            }
        case .item:
            guard let key = envelope.key, let payload = envelope.payload else { return }
            BotsStore.shared.applyLinkPayload(key, payload)
            lastSync = Date()
        case .request:
            guard let action = envelope.key, let payload = envelope.payload,
                  let fields = try? LinkCoding.decoder.decode([String: String].self, from: payload) else { return }
            BotsStore.shared.handleLinkRequest(action, fields)
        }
    }

    /// Something just changed: the other Mac hears within a second rather than at the next round.
    func syncSoon() {
        guard isHelloDone, !isSyncQueued else { return }
        isSyncQueued = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            self?.isSyncQueued = false
            self?.sendDigest()
        }
    }

    /// Asks the other Mac to do something. False when it isn't connected.
    func request(_ action: String, _ fields: [String: String]) -> Bool {
        guard isConnected, let payload = try? LinkCoding.encoder.encode(fields) else { return false }
        send(LinkEnvelope(kind: .request, key: action, payload: payload))
        return true
    }

    /// Like `request`, but if the other Mac's away it goes as soon as it's back. True when it went now.
    func requestWhenConnected(_ action: String, _ fields: [String: String]) -> Bool {
        if request(action, fields) { return true }
        waitingRequests.append((action, fields))
        return false
    }

    private func sendDigest() {
        guard isHelloDone else { return }
        Task {
            let digests = await currentDigests()
            send(LinkEnvelope(kind: .digest, digests: digests))
        }
    }

    private func currentDigests() async -> [String: String] {
        var digests = BotsStore.shared.linkDigests
        let memory = BotsStore.shared.memoryStore
        digests["memory"] = await Task.detached {
            LinkCoding.digest(memory.everything().map { "\($0.kind.rawValue)|\(Int($0.at.timeIntervalSince1970))|\($0.text)" }.sorted())
        }.value
        return digests
    }
}

struct ClickyMacItem: Codable {
    var name: String?
    var at: Date?
}

/// The switch for which Mac Clicky works on.
struct ClickyMacSwitch: View {
    @ObservedObject private var link = TheoLink.shared

    var body: some View {
        if link.clickyMacChoices.count > 1 {
            HStack(spacing: 8) {
                Text("Clicky works on").font(.system(size: 12, weight: .medium)).foregroundColor(DS.Colors.textSecondary)
                Spacer(minLength: 0)
                Picker("", selection: Binding(get: { link.clickyMacNow }, set: { link.setClickyMac($0) })) {
                    ForEach(link.clickyMacChoices, id: \.self) { name in Text(TheoLink.shortName(name)).tag(name) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
    }
}

struct LinkEnvelope: Codable {
    enum Kind: String, Codable { case hello, digest, want, item, request }
    var kind: Kind
    var name: String?
    var build: Int?
    var digests: [String: String]?
    var keys: [String]?
    var key: String?
    var payload: Data?
}

// MARK: - Settings

struct LinkSettingsContent: View {
    @ObservedObject private var link = TheoLink.shared
    @State private var typed = ""
    @State private var address = TheoLink.shared.host
    @State private var codeIsWrong = false

    private var statusLine: String {
        guard link.isPaired else { return "Not linked yet." }
        guard let name = link.peerName else { return link.problem ?? "Looking for your other Mac. Theo has to be open on both." }
        let synced = link.lastSync.map { " Last in step \(RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date()))." } ?? ""
        return "Linked to \(name).\(synced)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Circle().fill(link.peerName != nil ? Color.green : Color.secondary).frame(width: 8, height: 8)
                Text(statusLine).font(TheoType.bodyMedium).foregroundColor(DS.Colors.textPrimary)
            }
            if let peerBuild = link.peerBuild, peerBuild != localBuild {
                Text("Your other Mac is on build \(String(peerBuild)) and this one is on \(String(localBuild)). Update the older one in Updates.")
                    .font(TheoType.body).foregroundColor(DS.Colors.textSecondary)
            }
            if let code = link.code {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Pairing code").font(TheoType.bodyMedium).foregroundColor(DS.Colors.textPrimary)
                    Text(code).font(.system(size: 13, design: .monospaced)).foregroundColor(DS.Colors.textSecondary).textSelection(.enabled)
                    Button("Unlink this Mac") { link.unpair() }
                }
            } else {
                Button("Make a pairing code") { link.pairWithNewCode() }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(link.isPaired ? "Use a different code" : "Have a code from your other Mac?").font(TheoType.bodyMedium).foregroundColor(DS.Colors.textPrimary)
                HStack {
                    TextField("XXXX-XXXX-XXXX-XXXX-XXXX", text: $typed).textFieldStyle(.roundedBorder)
                    Button("Link") {
                        codeIsWrong = !link.pair(typed: typed)
                        if !codeIsWrong { typed = "" }
                    }
                }
                if codeIsWrong { Text("That isn't a full code.").font(TheoType.body).foregroundColor(.red) }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Away from home").font(TheoType.bodyMedium).foregroundColor(DS.Colors.textPrimary)
                Text("On the same network the Macs find each other. To stay linked anywhere, put the other Mac's Tailscale name here.")
                    .font(TheoType.body).foregroundColor(DS.Colors.textSecondary)
                HStack {
                    TextField("Other Mac's address (optional)", text: $address).textFieldStyle(.roundedBorder)
                    Button("Save") { link.host = address }
                }
            }
            if link.isPaired {
                VStack(alignment: .leading, spacing: 6) {
                    ClickyMacSwitch()
                    Text("Anything you ask Clicky, by voice, in its chat or through Theo, happens on that Mac's screen, and it answers where you asked. Change it here, in the menu bar, or say \"Clicky, work on the Air\".")
                        .font(TheoType.body).foregroundColor(DS.Colors.textSecondary)
                }
            }
            Text("Bots, group chats, chats, Clicky's team and memory stay the same on both. API keys and routines stay on their own Mac: keys don't leave the Keychain, and a routine should only fire once.")
                .font(TheoType.body).foregroundColor(DS.Colors.textSecondary)
        }
    }

    private var localBuild: Int { Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0 }
}

// MARK: - Runs on the other Mac

/// Where a run is going on, and the button that shows its terminal.
struct RemoteRunBadge: View {
    let run: T3Run
    @Binding var showsTerminal: Bool

    var body: some View {
        Label("On \(run.origin ?? "your other Mac")", systemImage: "laptopcomputer.and.arrow.down")
            .font(TheoType.caption).foregroundColor(DS.Colors.textSecondary)
        if run.paneTail != nil {
            Button { showsTerminal.toggle() } label: { Label(showsTerminal ? "Hide terminal" : "Show terminal", systemImage: "terminal") }
                .buttonStyle(.theo(.ghost, .small))
        }
    }
}

/// The run's terminal as the other Mac last saw it, a few seconds behind.
struct RemoteRunTerminal: View {
    let run: T3Run

    var body: some View {
        ScrollView {
            Text(run.paneTail ?? "")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(8)
        }
        .frame(height: 300)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.Colors.surface1))
    }
}
