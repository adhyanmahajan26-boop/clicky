//
//  ClaudiaUIServer.swift
//  leanring-buddy
//
//  Claudia's full UI as a page (for T3 Code's Claudia section, or any
//  browser on this Mac): http://127.0.0.1:47320/?token=… . Loopback only,
//  and every API call needs the token in ~/.clicky/ui-token (0600), so a
//  web page elsewhere can't drive Claudia. The page talks to the same
//  command set as the MCP server (ClaudiaControlInbox.execute).
//
//    GET  /                 the page (ClaudiaUI.html)
//    POST /api/<cmd>        a JSON body → {"ok", "result", "error"}
//    GET  /api/board.png    the open whiteboard as a PNG (exported on the spot)
//

import ClickyCore
import Foundation
import Network

@MainActor
final class ClaudiaUIServer {
    static let port: UInt16 = 47320
    static let tokenURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".clicky/ui-token")

    private let controlInbox: ClaudiaControlInbox
    private let companionManager: CompanionManager
    private var listener: NWListener?
    let token: String

    init(controlInbox: ClaudiaControlInbox, companionManager: CompanionManager) {
        self.controlInbox = controlInbox
        self.companionManager = companionManager
        if let saved = try? String(contentsOf: Self.tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), saved.count >= 32 {
            token = saved
        } else {
            token = (0..<4).map { _ in UUID().uuidString.replacingOccurrences(of: "-", with: "") }.joined().lowercased()
            try? FileManager.default.createDirectory(at: Self.tokenURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? token.write(to: Self.tokenURL, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.tokenURL.path)
        }
    }

    /// The address T3 Code (or a browser) opens.
    var pageURL: URL { URL(string: "http://127.0.0.1:\(Self.port)/?token=\(token)")! }

    func start() {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: Self.port)!)
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters) else {
            print("⚠️ Theo UI: couldn't listen on 127.0.0.1:\(Self.port)")
            return
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.serve(connection) }
        }
        listener.start(queue: .main)
        self.listener = listener
        print("🪟 Claudia UI on http://127.0.0.1:\(Self.port)")
    }

    // MARK: - HTTP

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .main)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                var buffer = buffer
                if let data { buffer.append(data) }
                if let request = HTTPRequest(buffer) {
                    self.respond(to: request, on: connection)
                } else if isComplete || error != nil || buffer.count > 4 << 20 {
                    connection.cancel()
                } else {
                    self.receiveRequest(on: connection, buffer: buffer)
                }
            }
        }
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection) {
        let path = request.path.split(separator: "?").first.map(String.init) ?? "/"
        let corsHeaders: [String: String] = Self.isT3Code(request) ? [
            "Access-Control-Allow-Origin": request.headers["origin"] ?? "*",
            "Access-Control-Allow-Headers": "Content-Type, X-Claudia-Token",
            "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
            "Vary": "Origin"
        ] : [:]
        // T3 Code calls the API from its own page: answer the CORS preflight.
        if request.method == "OPTIONS" {
            return send(connection, status: corsHeaders.isEmpty ? 403 : 204, type: "text/plain", body: Data(), extraHeaders: corsHeaders)
        }
        // T3 Code (only) gets the token, so its native Notes and assistant UI can call the API.
        if path == "/t3-token" {
            guard !corsHeaders.isEmpty else { return send(connection, status: 403, type: "text/plain", body: Data("T3 Code only".utf8)) }
            let body = (try? JSONSerialization.data(withJSONObject: ["token": token, "name": ClickySettings.assistantName])) ?? Data()
            return send(connection, status: 200, type: "application/json", body: body, extraHeaders: corsHeaders)
        }
        // T3 Code's Claudia section checks she's running (no token, says nothing else).
        if path == "/health" {
            return send(connection, status: 200, type: "application/json", body: Data(#"{"ok":true}"#.utf8),
                        extraHeaders: Self.isT3Code(request) ? ["Access-Control-Allow-Origin": request.headers["origin"] ?? "*"] : [:])
        }
        // Embedded in T3 Code (its own page at 127.0.0.1:3773): the token is filled in for that page only.
        if request.method == "GET" && path == "/t3" {
            guard Self.isT3Code(request) else { return send(connection, status: 403, type: "text/plain", body: Data("Only T3 Code can embed Theo.".utf8)) }
            let page = ClaudiaUIPage.html.replacingOccurrences(of: "/*CLAUDIA_TOKEN*/\"\"", with: "\"\(token)\"")
            return send(connection, status: 200, type: "text/html; charset=utf-8", body: Data(page.utf8))
        }
        if request.method == "GET" && (path == "/" || path == "/index.html") {
            guard request.query["token"] == token else { return send(connection, status: 403, type: "text/plain", body: Data("Open Theo from her app (Setup › Theo in T3 Code).".utf8)) }
            return send(connection, status: 200, type: "text/html; charset=utf-8", body: Data(ClaudiaUIPage.html.utf8))
        }
        guard path.hasPrefix("/api/"), request.headers["x-claudia-token"] == token || request.query["token"] == token else {
            return send(connection, status: 403, type: "application/json", body: Data(#"{"ok":false,"error":"bad token"}"#.utf8))
        }
        let commandName = String(path.dropFirst("/api/".count))
        // A library image (whiteboard or screenshot) for the Notes tab.
        if commandName == "file" {
            guard let item = request.query["id"].flatMap(ClaudiaLibrary.item(id:)), item.isImage,
                  let data = try? Data(contentsOf: item.url) else {
                return send(connection, status: 404, type: "text/plain", body: Data("not found".utf8))
            }
            return send(connection, status: 200, type: "image/png", body: data, extraHeaders: corsHeaders)
        }
        if commandName == "board.png" {
            guard let exported = companionManager.boardController.exportBoard() else {
                return send(connection, status: 404, type: "text/plain", body: Data("no board".utf8))
            }
            let pngURL = exported.deletingPathExtension().appendingPathExtension("png")
            let imageURL = FileManager.default.fileExists(atPath: pngURL.path) ? pngURL : exported
            return send(connection, status: 200, type: imageURL.pathExtension == "png" ? "image/png" : "application/pdf",
                        body: (try? Data(contentsOf: imageURL)) ?? Data())
        }
        var command = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]) ?? [:]
        command["cmd"] = commandName
        controlInbox.execute(command) { [weak self] ok, result, error in
            let object: [String: Any] = ["ok": ok, "result": result ?? NSNull(), "error": error ?? NSNull()]
            let body = (JSONSerialization.isValidJSONObject(object) ? try? JSONSerialization.data(withJSONObject: object) : nil) ?? Data(#"{"ok":false}"#.utf8)
            self?.send(connection, status: 200, type: "application/json", body: body, extraHeaders: corsHeaders)
        }
    }

    /// T3 Code's web UI runs at 127.0.0.1:3773 (its server port; the dev web server uses 5733).
    /// T3 Code's packaged app loads its UI from t3code://app (t3code-dev:// in development).
    static let t3CodeOrigins = ["t3code://app", "t3code-dev://app", "http://127.0.0.1:3783", "http://localhost:3783", "http://127.0.0.1:3773", "http://localhost:3773", "http://127.0.0.1:5733", "http://localhost:5733"]

    static func isT3Code(_ request: HTTPRequest) -> Bool {
        let source = request.headers["origin"] ?? request.headers["referer"] ?? ""
        return t3CodeOrigins.contains { source == $0 || source.hasPrefix($0 + "/") }
    }

    private func send(_ connection: NWConnection, status: Int, type: String, body: Data, extraHeaders: [String: String] = [:]) {
        let reason = [200: "OK", 204: "No Content", 403: "Forbidden", 404: "Not Found"][status] ?? "OK"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
        for (name, value) in extraHeaders { head += "\(name): \(value)\r\n" }
        head += "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// A minimal HTTP/1.1 request parser (one request per connection).
struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let query: [String: String]
    let body: Data

    init?(_ data: Data) {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)),
              let headText = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        let lines = headText.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2 else { return nil }
        method = String(requestLine[0])
        path = String(requestLine[1])
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        self.headers = headers
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        guard data.count - bodyStart >= length else { return nil }
        body = data[bodyStart..<(bodyStart + length)]
        var query: [String: String] = [:]
        if let components = URLComponents(string: "http://x" + path) {
            for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
        }
        self.query = query
    }
}
