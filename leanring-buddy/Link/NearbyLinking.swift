//
//  NearbyLinking.swift
//  leanring-buddy
//
//  One-click linking. While a Mac isn't linked it shows up to Macs nearby (Bonjour `_theopair._tcp`), and they show it in
//  Settings › Devices with a Link button. Link on one Mac, Allow on the other, and both hold the same link code, so Theo Link
//  takes over from there. The keys, the check number and the sealed code are ClickyCore `NearbyPairing`.
//
//  The asked Mac never takes a code until its owner presses Allow, and both Macs show the same six-digit number so the owner can
//  see nobody sits in between. Only one request is shown at a time, and a request nobody answers is dropped after two minutes.
//

import AppKit
import ClickyCore
import CryptoKit
import Foundation
import Network

@MainActor
final class NearbyLinking: ObservableObject {
    static let shared = NearbyLinking()

    /// A Mac nearby with Theo open and not linked yet.
    struct NearbyMac: Identifiable, Equatable {
        let name: String
        let endpoint: NWEndpoint
        var id: String { name }
    }

    /// Another Mac asking to link with this one, waiting for Allow.
    struct IncomingRequest: Identifiable {
        let id = UUID()
        let name: String
        let checkNumber: String
        let sealedCode: String
        let key: SymmetricKey
        let channel: PairingChannel
    }

    enum Outgoing: Equatable {
        case idle
        /// Waiting for the other Mac's owner to press Allow. The check number shows once the keys are swapped.
        case asking(name: String, checkNumber: String?)
        case linked(name: String)
        case declined(name: String)
        case failed(name: String, reason: String)
    }

    @Published private(set) var nearby: [NearbyMac] = []
    @Published private(set) var incoming: IncomingRequest?
    @Published private(set) var outgoing: Outgoing = .idle

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var outgoingChannel: PairingChannel?
    private var outgoingCode: String?
    /// Bumped on every new ask, so a timer from an earlier one leaves a newer one alone.
    private var outgoingGeneration = 0
    /// After the owner says no, nothing else is shown for a moment, so a Mac that keeps asking can't keep popping the window up.
    private var quietUntil = Date.distantPast
    private let queue = DispatchQueue(label: "theo.link.nearby")

    private var serviceType: String { TheoProfile.isTest ? NearbyPairing.testServiceType : NearbyPairing.serviceType }

    /// On while this Mac isn't linked, off once it is.
    func update() {
        if TheoLink.shared.isPaired {
            stop()
        } else if listener == nil {
            start()
        }
    }

    private func start() {
        guard let listener = try? NWListener(using: .tcp) else { return }
        listener.service = NWListener.Service(name: TheoLink.localName, type: serviceType)
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard case .failed = state else { return }
            Task { @MainActor in
                guard let self, self.listener === listener else { return }
                // A network change or waking from sleep: try again in a little while.
                self.stop()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self.update()
            }
        }
        listener.start(queue: queue)
        self.listener = listener

        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { result -> NearbyMac? in
                guard case .service(let name, _, _, _) = result.endpoint, name != TheoLink.localName else { return nil }
                return NearbyMac(name: name, endpoint: result.endpoint)
            }
            Task { @MainActor in self?.nearby = found.sorted { $0.name < $1.name } }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private func stop() {
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil
        nearby = []
        if let incoming { incoming.channel.close() }
        incoming = nil
    }

    // MARK: Asking another Mac

    /// Link on a nearby Mac's row.
    func link(with mac: NearbyMac) {
        outgoingChannel?.close()
        outgoingGeneration += 1
        let generation = outgoingGeneration
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let code = LinkPairing.newCode()
        outgoingCode = code
        outgoing = .asking(name: mac.name, checkNumber: nil)
        let channel = PairingChannel(connection: NWConnection(to: mac.endpoint, using: .tcp), queue: queue)
        outgoingChannel = channel
        channel.onReady = { [weak channel] in
            channel?.send(NearbyPairing.Message(kind: .hello, name: TheoLink.localName, deviceID: DeviceRoles.thisMacID,
                                                publicKey: privateKey.publicKey.rawRepresentation.base64EncodedString()))
        }
        channel.onMessage = { [weak self, weak channel] message in
            guard let self, let channel, self.outgoingChannel === channel else { return }
            switch message.kind {
            case .hello:
                guard let theirKey = message.publicKey, let agreement = NearbyPairing.agree(myPrivateKey: privateKey, theirPublicKeyBase64: theirKey),
                      let sealed = NearbyPairing.seal(code: code, with: agreement.key) else {
                    return self.finishOutgoing(.failed(name: mac.name, reason: "It didn't answer the way Theo does."))
                }
                self.outgoing = .asking(name: mac.name, checkNumber: agreement.checkNumber)
                channel.send(NearbyPairing.Message(kind: .offer, sealed: sealed))
            case .accepted:
                TheoLink.shared.pair(typed: code)
                self.finishOutgoing(.linked(name: mac.name))
            case .declined:
                self.finishOutgoing(.declined(name: mac.name))
            case .offer:
                break
            }
        }
        channel.onEnd = { [weak self, weak channel] in
            guard let self, let channel, self.outgoingChannel === channel else { return }
            if case .asking = self.outgoing { self.finishOutgoing(.failed(name: mac.name, reason: "The connection closed before it answered.")) }
        }
        channel.start()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(NearbyPairing.requestLifetimeSeconds * 1_000_000_000))
            guard let self, self.outgoingGeneration == generation, case .asking = self.outgoing else { return }
            self.finishOutgoing(.failed(name: mac.name, reason: "Nobody pressed Allow on it in time."))
        }
    }

    func cancelOutgoing() {
        outgoingChannel?.close()
        outgoingChannel = nil
        outgoingCode = nil
        outgoing = .idle
    }

    private func finishOutgoing(_ result: Outgoing) {
        outgoingChannel?.close()
        outgoingChannel = nil
        outgoingCode = nil
        outgoing = result
    }

    // MARK: Being asked

    private func accept(_ connection: NWConnection) {
        // One request at a time, and none while the owner just said no.
        guard incoming == nil, Date() >= quietUntil else {
            connection.cancel()
            return
        }
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let channel = PairingChannel(connection: connection, queue: queue)
        var askingName: String?
        var agreement: NearbyPairing.Agreement?
        channel.onMessage = { [weak self, weak channel] message in
            guard let self, let channel else { return }
            switch message.kind {
            case .hello:
                guard agreement == nil, let theirKey = message.publicKey, let name = message.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
                      let agreed = NearbyPairing.agree(myPrivateKey: privateKey, theirPublicKeyBase64: theirKey) else { return channel.close() }
                askingName = String(name.prefix(80))
                agreement = agreed
                channel.send(NearbyPairing.Message(kind: .hello, name: TheoLink.localName, deviceID: DeviceRoles.thisMacID,
                                                   publicKey: privateKey.publicKey.rawRepresentation.base64EncodedString()))
            case .offer:
                guard let askingName, let agreement, let sealed = message.sealed, self.incoming == nil else { return channel.close() }
                let request = IncomingRequest(name: askingName, checkNumber: agreement.checkNumber, sealedCode: sealed, key: agreement.key, channel: channel)
                self.incoming = request
                self.showRequest()
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(NearbyPairing.requestLifetimeSeconds * 1_000_000_000))
                    guard let self, self.incoming?.id == request.id else { return }
                    self.deny()
                }
            case .accepted, .declined:
                channel.close()
            }
        }
        channel.onEnd = { [weak self, weak channel] in
            guard let self, let channel, self.incoming?.channel === channel else { return }
            self.incoming = nil
        }
        channel.start()
    }

    /// The request shows in Settings › Devices, brought to the front, since the owner may be anywhere else on this Mac.
    private func showRequest() {
        guard !TheoProfile.isTest || UserDefaults.standard.bool(forKey: "test.nearby.showsWindow") else { return }
        TheoSettingsWindowController.show(section: .devices)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Allow on the request: the code is saved, so both Macs are linked.
    func allow() {
        guard let request = incoming else { return }
        incoming = nil
        guard let code = NearbyPairing.open(sealed: request.sealedCode, with: request.key) else {
            request.channel.close()
            return
        }
        TheoLink.shared.pair(typed: code)
        request.channel.send(NearbyPairing.Message(kind: .accepted), thenClose: true)
    }

    func deny() {
        guard let request = incoming else { return }
        incoming = nil
        quietUntil = Date().addingTimeInterval(10)
        request.channel.send(NearbyPairing.Message(kind: .declined), thenClose: true)
    }

    /// For `uiNearby` in a test profile.
    var testState: [String: Any] {
        let outgoingWords: String
        switch outgoing {
        case .idle: outgoingWords = "idle"
        case .asking(let name, let check): outgoingWords = "asking:\(name):\(check ?? "")"
        case .linked(let name): outgoingWords = "linked:\(name)"
        case .declined(let name): outgoingWords = "declined:\(name)"
        case .failed(let name, let reason): outgoingWords = "failed:\(name):\(reason)"
        }
        return ["advertising": listener != nil, "nearby": nearby.map(\.name), "incoming": incoming.map { ["name": $0.name, "check": $0.checkNumber] } ?? NSNull(),
                "outgoing": outgoingWords, "paired": TheoLink.shared.isPaired,
                "codeDigest": TheoLink.shared.code.map { LinkCoding.digest(Data($0.utf8)) } ?? NSNull()]
    }
}

/// One pairing conversation: small framed JSON messages over plain TCP. Nothing secret goes over it unsealed.
@MainActor
final class PairingChannel {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var reader = LinkFrameReader()
    private var receivedBytes = 0
    private var isClosed = false
    var onReady: (() -> Void)?
    var onMessage: ((NearbyPairing.Message) -> Void)?
    var onEnd: (() -> Void)?

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, !self.isClosed else { return }
                switch state {
                case .ready:
                    self.onReady?()
                    self.receive()
                case .failed, .cancelled:
                    self.close()
                default:
                    break
                }
            }
        }
        connection.start(queue: queue)
    }

    func send(_ message: NearbyPairing.Message, thenClose: Bool = false) {
        guard !isClosed, let data = NearbyPairing.encode(message) else { return }
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            guard thenClose else { return }
            Task { @MainActor in self?.close() }
        })
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        connection.cancel()
        let ended = onEnd
        onReady = nil
        onMessage = nil
        onEnd = nil
        ended?()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: NearbyPairing.maximumMessageBytes) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, !self.isClosed else { return }
                if let data, !data.isEmpty {
                    self.receivedBytes += data.count
                    // A pairing is a few small messages: anything more isn't one.
                    guard self.receivedBytes <= NearbyPairing.maximumMessageBytes * 4, let frames = self.reader.feed(data) else { return self.close() }
                    for frame in frames {
                        guard let message = NearbyPairing.decode(frame) else { return self.close() }
                        self.onMessage?(message)
                        if self.isClosed { return }
                    }
                }
                if isComplete || error != nil { self.close() } else { self.receive() }
            }
        }
    }
}
