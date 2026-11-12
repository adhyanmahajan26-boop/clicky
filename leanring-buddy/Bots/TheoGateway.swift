//
//  TheoGateway.swift
//  leanring-buddy
//
//  Theo's local API, the "gateway" of Hermes and OpenClaw for this Mac only: a script, a cron job or a webhook relay on the
//  Mac can message a bot or fire a routine over HTTP. Off by default (`v3.gateway.enabled`), bound to 127.0.0.1 only
//  (`v3.gateway.port`, default 47380), and every request needs the token kept in the Keychain. What comes in this way is
//  never the owner's own words: the turn runs with `fromOwner: false`, so it can't start a coding run or a routine, use the
//  screen or research, and it goes through the same engine sandbox, private-message caps and time limit as any other turn.
//  Requests that start work are held to 30 a minute. Parsing and checks are ClickyCore's `TheoGatewayHTTP`.
//
//    GET  /v1/health                  {"ok", "bots"}
//    GET  /v1/bots                    the bots that can be messaged
//    POST /v1/bots/<id>/messages      {"text", "source", "wait", "timeout"} → {"id", "status", "reply"}
//    GET  /v1/routines                the routines
//    POST /v1/routines/<id>/run       fires one now (a webhook trigger)
//

import ClickyCore
import Foundation
import Network
import Security

enum TheoGatewayToken {
    static let service = "com.theo.gateway" + TheoProfile.keychainSuffix
    static let account = "token"

    static func read() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let token = String(data: data, encoding: .utf8), token.count >= 32 else { return nil }
        return token
    }

    /// A new random token, replacing any old one (which stops working at once).
    @discardableResult static func renew() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let token = "theo_" + bytes.map { String(format: "%02x", $0) }.joined()
        let match: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(match as CFDictionary)
        var add = match
        add[kSecValueData as String] = Data(token.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess ? token : nil
    }

    static func remove() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] as CFDictionary)
    }
}

@MainActor
final class TheoGateway {
    static let shared = TheoGateway()

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "v3.gateway.enabled") }
    static var port: UInt16 {
        let saved = UserDefaults.standard.integer(forKey: "v3.gateway.port")
        return (1024...65535).contains(saved) ? UInt16(saved) : TheoGatewayHTTP.defaultPort
    }

    private var listener: NWListener?
    private var limiter = TheoGatewayHTTP.RateLimiter()
    private(set) var listeningPort: UInt16?
    private(set) var lastProblem: String?
    /// Messages in, for the Settings line and tests: (when, source, bot).
    private(set) var recent: [(at: Date, source: String, bot: String)] = []

    /// Starts or stops it to match the setting. Called at launch and whenever the setting changes.
    func apply() {
        if Self.isEnabled {
            if TheoGatewayToken.read() == nil { TheoGatewayToken.renew() }
            if listener == nil || listeningPort != Self.port { start() }
        } else {
            stop()
        }
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "v3.gateway.enabled")
        apply()
    }

    var report: [String: Any] {
        ["enabled": Self.isEnabled, "listening": listeningPort.map { Int($0) } ?? NSNull(), "port": Int(Self.port),
         "hasToken": TheoGatewayToken.read() != nil, "problem": lastProblem ?? NSNull(), "received": recent.count]
    }

    private func start() {
        stop()
        let port = Self.port
        let parameters = NWParameters.tcp
        // Loopback only: nothing on the network can reach it, whatever the firewall says.
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        parameters.requiredInterfaceType = .loopback
        do {
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.serve(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready: self?.listeningPort = port; self?.lastProblem = nil
                    case .failed(let error): self?.lastProblem = "Couldn't listen on 127.0.0.1:\(port): \(error)"; self?.listeningPort = nil
                    case .cancelled: self?.listeningPort = nil
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
            print("[gateway] local API on http://127.0.0.1:\(port)")
        } catch {
            lastProblem = "Couldn't listen on 127.0.0.1:\(port): \(error)"
        }
    }

    private func stop() {
        listener?.cancel()
        listener = nil
        listeningPort = nil
    }

    // MARK: HTTP

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(on: connection, buffer: Data(), started: Date())
    }

    private func receive(on connection: NWConnection, buffer: Data, started: Date) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                var buffer = buffer
                if let data { buffer.append(data) }
                switch TheoGatewayHTTP.parse(buffer) {
                case .request(let request):
                    await self.respond(to: request, on: connection)
                case .bad(let status, let reason):
                    self.send(connection, status: status, ["error": reason])
                case .incomplete:
                    // A slow or stalled client gets 10 seconds to send its request.
                    if isComplete || error != nil || Date().timeIntervalSince(started) > 10 { connection.cancel() } else {
                        self.receive(on: connection, buffer: buffer, started: started)
                    }
                }
            }
        }
    }

    private func respond(to request: TheoGatewayHTTP.Request, on connection: NWConnection) async {
        guard Self.isEnabled, let token = TheoGatewayToken.read() else { return send(connection, status: 503, ["error": "Theo's local API is off"]) }
        switch TheoGatewayHTTP.check(request, port: Self.port, token: token) {
        case .forbidden(let why): return send(connection, status: 403, ["error": why])
        case .unauthorized: return send(connection, status: 401, ["error": "Needs Authorization: Bearer <token from Theo's Settings>"])
        case nil: break
        }
        let store = BotsStore.shared
        switch TheoGatewayHTTP.route(method: request.method, path: request.path) {
        case .health:
            send(connection, status: 200, ["ok": true, "bots": store.gatewayBots.count])
        case .listBots:
            send(connection, status: 200, ["bots": store.gatewayBots.map { ["id": $0.id, "name": $0.name, "description": $0.description] }])
        case .listRoutines:
            send(connection, status: 200, ["routines": store.routines.map { ["id": $0.id, "name": $0.name, "target": $0.target, "paused": $0.paused, "schedule": $0.schedule.label] }])
        case .runRoutine(let id):
            guard limiter.allow(now: Date().timeIntervalSince1970) else { return send(connection, status: 429, ["error": "Too many requests: 30 a minute"]) }
            guard let routine = store.routines.first(where: { $0.id == id }) else { return send(connection, status: 404, ["error": "No such routine"]) }
            store.runRoutineNow(routine.id)
            send(connection, status: 202, ["ok": true, "routine": routine.name])
        case .message(let botID):
            guard limiter.allow(now: Date().timeIntervalSince1970) else { return send(connection, status: 429, ["error": "Too many requests: 30 a minute"]) }
            let body: TheoGatewayHTTP.MessageBody
            switch TheoGatewayHTTP.messageBody(request.body) {
            case .success(let parsed): body = parsed
            case .failure(.forbidden(let why)): return send(connection, status: 400, ["error": why])
            case .failure: return send(connection, status: 400, ["error": "Bad body"])
            }
            guard store.gatewayBots.contains(where: { $0.id == botID }) else { return send(connection, status: 404, ["error": "No bot with that id can be messaged"]) }
            guard let messageID = store.receiveFromGateway(body.text, source: body.source, to: botID) else {
                return send(connection, status: 409, ["error": "That bot is turned off"])
            }
            recent.append((Date(), body.source, botID))
            if recent.count > 50 { recent.removeFirst(recent.count - 50) }
            guard body.wait else { return send(connection, status: 202, ["id": messageID, "status": "queued"]) }
            let reply = await store.gatewayReply(after: messageID, botID: botID, timeout: body.timeout)
            if let reply {
                send(connection, status: 200, ["id": messageID, "status": "answered", "reply": reply])
            } else {
                send(connection, status: 504, ["id": messageID, "status": "still working", "error": "No answer within \(Int(body.timeout)) s; it will appear in the chat"])
            }
        case .notFound:
            send(connection, status: 404, ["error": "Not found"])
        case .methodNotAllowed:
            send(connection, status: 405, ["error": "Method not allowed"])
        }
    }

    private func send(_ connection: NWConnection, status: Int, _ json: [String: Any]) {
        connection.send(content: TheoGatewayHTTP.response(status: status, json: json), completion: .contentProcessed { _ in connection.cancel() })
    }
}

extension BotsStore {
    /// Bots a script may message: the owner's own bots that are on. Clicky's team works only for Clicky.
    var gatewayBots: [NativeBot] { bots.filter { $0.owner == nil && $0.isOn && $0.id != Self.clickyID } }

    /// A message from outside: shown in the chat as from that program, and answered on a turn that isn't the owner's.
    /// Nil when the bot can't take it. Waits its turn behind whatever the bot is doing.
    func receiveFromGateway(_ text: String, source: String, to botID: String) -> String? {
        guard let bot = bot(botID), bot.isOn, bot.owner == nil else { return nil }
        let message = BotChatMessage(author: "routine", text: TheoGatewayHTTP.chatLine(source: source, text: text))
        post(message, to: botID)
        Task { [weak self] in
            while self?.replying[botID] != nil { try? await Task.sleep(nanoseconds: 500_000_000) }
            self?.startGatewayTurn(botID: botID, text: text, source: source)
        }
        return message.id
    }

    private func startGatewayTurn(botID: String, text: String, source: String) {
        guard let bot = bot(botID), bot.isOn else { return }
        // Another message took the turn first: this one waits again.
        if replying[botID] != nil {
            Task { [weak self] in
                while self?.replying[botID] != nil { try? await Task.sleep(nanoseconds: 500_000_000) }
                self?.startGatewayTurn(botID: botID, text: text, source: source)
            }
            return
        }
        let record = conversation(botID)
        let firstTurn = record.sessions[botID] == nil
        let body = TheoGatewayHTTP.outsideNote(source: source, owner: BotPrompts.ownerName) + "\n\n" + text
        var prompt = firstTurn ? BotPrompts.firstMessage(bot: bot, team: bots, text: body) : body
        if !bot.primary { prompt = "(\(BotPrompts.reachNote(for: bot)))\n\n" + prompt }
        prompt = BotPrompts.awarenessNote(for: bot, room: botID) + prompt
        // Its own fresh private-message budget, the same caps as an owner message gets.
        ownerSpoke(in: botID)
        reply(bot: bot, in: botID, prompt: prompt, session: record.sessions[botID], fromOwner: false) { _ in }
    }

    /// The bot's answer to a message from outside, once its turn is over. Nil if none came within `timeout` seconds.
    func gatewayReply(after messageID: String, botID: String, timeout: Double) async -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        // Give its turn a moment to begin before reading "not busy" as "done".
        try? await Task.sleep(nanoseconds: 700_000_000)
        while Date() < deadline {
            let messages = conversation(botID).messages
            if let index = messages.firstIndex(where: { $0.id == messageID }), replying[botID] == nil, liveExchanges.values.allSatisfy({ $0.room != botID }) {
                let answers = messages[(index + 1)...].filter { $0.author == botID && !$0.text.isEmpty }
                if let last = answers.last { return last.text }
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return nil
    }
}
