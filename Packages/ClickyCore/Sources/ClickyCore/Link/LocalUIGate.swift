//
//  LocalUIGate.swift
//  ClickyCore
//
//  Who may use Theo's local page server (127.0.0.1:47320, T3 Code's Theo section). Its token drives every bot as the owner, so:
//  the Host header must be this Mac's loopback at that port (a page on another name that resolves here, DNS rebinding, gets nothing),
//  and only T3 Code's own page, matched exactly on its Origin, is handed the token. A Referer counts only for embedding the page.
//  T3 Code's dev server (port 5733, t3code-dev://) is trusted only when that's switched on: any other dev server on that port could
//  otherwise take the token from a browser page.
//

import Foundation

public enum LocalUIGate {
    /// T3 Code as installed: the desktop app and its local server.
    public static let t3CodeOrigins = ["t3code://app", "http://127.0.0.1:3773", "http://localhost:3773", "http://127.0.0.1:3783", "http://localhost:3783"]
    /// T3 Code run from source.
    public static let t3CodeDevOrigins = ["t3code-dev://app", "http://127.0.0.1:5733", "http://localhost:5733"]

    public static func hostAllowed(_ host: String?, port: UInt16) -> Bool {
        guard let host = host?.lowercased().trimmingCharacters(in: .whitespaces) else { return false }
        return ["127.0.0.1:\(port)", "localhost:\(port)", "[::1]:\(port)"].contains(host)
    }

    /// The origin a Referer stands for: scheme, host and port, nothing more.
    public static func origin(ofReferer referer: String) -> String? {
        guard let url = URL(string: referer), let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == "t3code" || scheme == "t3code-dev" { return url.host.map { "\(scheme)://\($0)" } }
        guard let host = url.host?.lowercased() else { return nil }
        return url.port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
    }

    /// `origin`: the request's Origin header. `referer`: only where a Referer may stand in (embedding the page in an iframe).
    public static func isT3Code(origin: String?, referer: String? = nil, devServer: Bool) -> Bool {
        let allowed = t3CodeOrigins + (devServer ? t3CodeDevOrigins : [])
        if let origin, !origin.isEmpty { return allowed.contains(origin.lowercased()) }
        if let referer, let derived = Self.origin(ofReferer: referer) { return allowed.contains(derived) }
        return false
    }
}
