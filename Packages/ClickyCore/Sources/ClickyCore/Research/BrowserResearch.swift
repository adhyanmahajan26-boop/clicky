//
//  BrowserResearch.swift
//  ClickyCore
//
//  The pure parts of research reading a page in the owner's own browser, on a hidden Studio screen: which pages may be
//  opened there, when a page needs it, what a human check looks like, and who gets a tile. A real browser with real
//  logins is powerful, so it only ever opens and reads. Nothing here gets past a human check: that waits for the owner.
//

import Foundation

public enum BrowserResearchPolicy {
    /// Two tiles at most, so the others stay free for the owner's own use.
    public static let maximumBrowsersAtOnce = 2
    public static let secondsToWaitForATile: TimeInterval = 120
    public static let secondsToWaitForTheOwner: TimeInterval = 300
    public static let maximumCharacters = 40_000

    /// Hosts that are the owner's private life, not sources. A link on a page must not be able to send a logged-in window there.
    private static let privateHosts = ["mail.", "outlook.", "accounts.", "myaccount.", "login.", "signin.", "auth.", "icloud.", "drive.google.", "docs.google.",
                                       "calendar.google.", "contacts.google.", "photos.google.", "paypal.", "stripe.", "razorpay.", "paytm.", "phonepe.", "wise.com",
                                       "web.whatsapp.", "messages.google."]
    private static let privateHostWords = ["bank", "billing", "wallet", "broker", "zerodha", "groww", "coinbase", "binance"]
    /// Addresses that do something when visited, or show an account.
    private static let actionPathWords = ["login", "logout", "log-out", "signin", "sign-in", "signout", "sign-out", "account", "settings", "billing", "checkout", "cart",
                                          "payment", "invoice", "unsubscribe", "delete", "remove", "cancel", "confirm", "approve", "oauth", "authorize", "password", "admin"]
    private static let secretQueryWords = ["token", "secret", "password", "session", "apikey", "api_key", "auth", "otp", "code", "key", "sig"]

    /// Whether this address may open in the owner's logged-in browser. Stricter than a plain fetch, which carries no logins.
    public static func mayOpen(_ url: URL, allowsLocalHostForTests: Bool = false) -> Bool {
        guard ResearchURLPolicy.isAllowed(url, allowsLocalHostForTests: allowsLocalHostForTests),
              let host = url.host?.lowercased(), url.user == nil, url.password == nil else { return false }
        // It's handed to the browser on a command line, so it must look like nothing but a web address.
        let text = url.absoluteString
        guard text.lowercased().hasPrefix("http"), !text.contains(" ") else { return false }
        if privateHosts.contains(where: { host.hasPrefix($0) || host.contains("." + $0) }) { return false }
        if privateHostWords.contains(where: host.contains) { return false }
        let pathWords = url.path.lowercased().split(whereSeparator: { "/._".contains($0) }).map(String.init)
        if pathWords.contains(where: { actionPathWords.contains($0) }) { return false }
        let names = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map { $0.name.lowercased() } ?? []
        return !names.contains { secretQueryWords.contains($0) }
    }

    /// The plain fetch came back with nothing useful: nothing at all, a wall, or a shell of a page waiting on scripts.
    public static func needsBrowser(text: String?) -> Bool {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return true }
        return ReadableText.looksWalled(text) || text.count < 200
    }

    private static let humanCheckWords = ["verify you are human", "verify you're human", "verifying you are human", "confirm you are human", "confirm you're human",
                                          "are you a robot", "are you human", "i'm not a robot", "not a robot", "checking your browser", "checking if the site connection is secure",
                                          "unusual traffic", "press and hold", "press & hold", "complete the security check", "captcha", "just a moment"]

    /// A page asking for a person. Long pages only mention these words, so only short ones count.
    public static func isHumanCheck(title: String?, text: String) -> Bool {
        let body = text.lowercased()
        if (title ?? "").lowercased().contains("just a moment") { return true }
        return body.count < 1_500 && humanCheckWords.contains { body.contains($0) }
    }

    /// Text runs from the page, in order: one block joins with spaces, a new block starts a line.
    public static func joined(runs: [(text: String, block: Int)]) -> String {
        var output = ""
        var lastBlock: Int?
        for run in runs {
            let piece = run.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            if let lastBlock { output += lastBlock == run.block ? " " : "\n" }
            output += piece
            lastBlock = run.block
            if output.count >= maximumCharacters { return String(output.prefix(maximumCharacters)) }
        }
        return output
    }
}

/// Who holds a tile for research and who's waiting, first come first served. Only research asks here; any other bot waits
/// for the owner to assign it by hand.
public struct ResearchTileQueue: Equatable, Sendable {
    public private(set) var waiting: [String] = []
    public private(set) var holding: [String: StudioTileID] = [:]
    public let limit: Int

    public init(limit: Int = BrowserResearchPolicy.maximumBrowsersAtOnce) {
        self.limit = limit
    }

    /// A tile if one can be had now, else it joins the line.
    public mutating func request(_ id: String, free: [StudioTileID]) -> StudioTileID? {
        if let held = holding[id] { return held }
        if waiting.isEmpty || waiting.first == id, holding.count < limit, let tile = free.first {
            waiting.removeAll { $0 == id }
            holding[id] = tile
            return tile
        }
        if !waiting.contains(id) { waiting.append(id) }
        return nil
    }

    /// The tile goes back. Whoever waited longest may be next.
    public mutating func release(_ id: String) { holding[id] = nil }

    /// Gave up waiting.
    public mutating func leave(_ id: String) { waiting.removeAll { $0 == id } }

    /// The next in line, if a tile is there for them.
    public mutating func grantNext(free: [StudioTileID]) -> (id: String, tile: StudioTileID)? {
        guard let id = waiting.first, holding.count < limit, let tile = free.first else { return nil }
        waiting.removeFirst()
        holding[id] = tile
        return (id, tile)
    }
}
