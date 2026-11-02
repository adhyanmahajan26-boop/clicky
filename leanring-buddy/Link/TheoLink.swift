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
    private var connectionState = "none"
    private var isConnectionReady = false
    private var failedDials = 0
    /// A connection that hasn't opened in this long is given up on, so a stuck one can't block the next try.
    private static let dialTimeoutSeconds: UInt64 = 15

    private let queue = DispatchQueue(label: "theo.link")
    private static var secretFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".clicky/link-secret")
    }
    private var localName: String { Host.current().localizedName ?? ProcessInfo.processInfo.hostName }
    private var localBuild: Int { Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0 }

    var host: String {
        get { UserDefaults.standard.string(forKey: Self.hostKey) ?? "" }
        set {
            UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.hostKey)
            restart()
        }
    }

    var statusReport: [String: Any] {
        ["paired": isPaired, "peer": peerName ?? NSNull(), "peerBuild": peerBuild ?? NSNull(), "build": localBuild,
         "lastSync": lastSync.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(), "problem": problem ?? NSNull(),
         "found": foundPeers.count, "listening": listener?.state == .ready, "connection": connectionState, "failedDials": failedDials]
    }

    // MARK: Pairing

    func start() {
        guard let saved = try? String(contentsOf: Self.secretFile, encoding: .utf8), let normalized = LinkPairing.normalized(saved) else { return }
        code = normalized
        isPaired = true
        startNetworking()
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
            peerBuild = envelope.build
            isHelloDone = true
            sendDigest()
            digestTimer?.invalidate()
            digestTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sendDigest() }
            }
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
        }
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

struct LinkEnvelope: Codable {
    enum Kind: String, Codable { case hello, digest, want, item }
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
            Text("Bots, group chats, chats, Clicky's team and memory stay the same on both. API keys and routines stay on their own Mac: keys don't leave the Keychain, and a routine should only fire once.")
                .font(TheoType.body).foregroundColor(DS.Colors.textSecondary)
        }
    }

    private var localBuild: Int { Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0 }
}
