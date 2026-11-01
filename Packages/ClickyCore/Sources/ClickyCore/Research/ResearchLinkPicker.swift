//
//  ResearchLinkPicker.swift
//  ClickyCore
//
//  "Research these 3 links on my screen": which links does the owner mean?
//  Taking the first links in the page's accessibility tree picked the
//  navigation bar, logos and "Sign in". Now only links actually visible in
//  the window are candidates, and a quick Haiku call picks the ones the
//  owner means (search results, the articles in the list, the sites named),
//  given the numbered list with each link's text and position. When that
//  call fails, a heuristic keeps the content-looking links (long titles,
//  other sites than the page's own) in top-to-bottom order.
//

import CoreGraphics
import Foundation

public struct ResearchLinkCandidate: Equatable, Sendable {
    public var url: URL
    public var text: String
    /// CG global points.
    public var frame: CGRect

    public init(url: URL, text: String, frame: CGRect) {
        self.url = url
        self.text = text
        self.frame = frame
    }
}

public enum ResearchLinkPicker {
    public static let maximumCandidates = 60

    /// Links visible in the window (at least half inside it, a real size), each URL once, top to bottom.
    public static func visibleCandidates(_ candidates: [ResearchLinkCandidate], windowFrame: CGRect) -> [ResearchLinkCandidate] {
        var seen = Set<String>()
        let visible = candidates.filter { candidate in
            guard candidate.frame.width >= 8, candidate.frame.height >= 6 else { return false }
            let overlap = candidate.frame.intersection(windowFrame)
            guard !overlap.isNull, overlap.width * overlap.height >= 0.5 * candidate.frame.width * candidate.frame.height else { return false }
            return seen.insert(normalizedKey(candidate.url)).inserted
        }
        return Array(visible.sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }.prefix(maximumCandidates))
    }

    /// What's on screen, topped up with the next links down the page when the screen shows too few:
    /// a search page's AI overview can fill the whole first screen.
    public static func onScreenCandidates(_ candidates: [ResearchLinkCandidate], windowFrame: CGRect, wanted: Int = 6) -> [ResearchLinkCandidate] {
        let visible = visibleCandidates(candidates, windowFrame: windowFrame)
        guard visible.count < wanted else { return visible }
        var seen = Set(visible.map { normalizedKey($0.url) })
        let further = candidates
            .filter { $0.frame.width >= 8 && $0.frame.height >= 6 && $0.frame.minY >= windowFrame.maxY }
            .sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
            .filter { seen.insert(normalizedKey($0.url)).inserted }
        return visible + further.prefix(wanted * 2)
    }

    /// The prompt for the picking call: the owner's words, the page, and the numbered links.
    public static func pickerPrompt(request: String, count: Int, pageTitle: String?, pageURL: URL?, candidates: [ResearchLinkCandidate], windowFrame: CGRect) -> String {
        var lines: [String] = []
        lines.append("The owner said: \"\(request)\"")
        lines.append("They want \(count) link\(count == 1 ? "" : "s") from what is visible in their browser window.")
        if let pageTitle, !pageTitle.isEmpty { lines.append("Page title: \(pageTitle)") }
        if let pageURL { lines.append("Page URL: \(pageURL.absoluteString)") }
        lines.append("Links, top to bottom (y = distance from the window's top in points; y over \(Int(windowFrame.height)) is just below what's visible):")
        for (index, candidate) in candidates.enumerated() {
            let text = candidate.text.count > 120 ? String(candidate.text.prefix(119)) + "…" : candidate.text
            let y = Int(candidate.frame.minY - windowFrame.minY)
            lines.append("\(index + 1). y=\(y) \"\(text)\" → \(candidate.url.absoluteString)")
        }
        lines.append("")
        lines.append("Pick the \(count) links the owner means. They mean the main content: search results, the articles or items in a list, or sites they named. Never navigation, menus, logos, sign-in, ads, footers, \"more\" or filter links, links back to the search engine, citation or footnote numbers, identifier/database links (Wikidata, ISBN, DOI, authority control) or sister projects (Commons, Wiktionary). If they named sites or titles, pick those. Otherwise take one link per result (a result's title link, not its sub-links or \"page 2\" links), from different sites when you can, nearest the top first.")
        lines.append("Answer with only a JSON array of the numbers, for example [3, 7, 9].")
        return lines.joined(separator: "\n")
    }

    /// The numbers from the reply ("[3, 7, 9]"), valid and unique, in the order given.
    public static func parsePick(_ reply: String, candidateCount: Int) -> [Int] {
        guard let open = reply.firstIndex(of: "["), let close = reply[open...].firstIndex(of: "]") else { return [] }
        var picked: [Int] = []
        for piece in reply[reply.index(after: open)..<close].split(separator: ",") {
            if let number = Int(piece.trimmingCharacters(in: .whitespaces)), (1...candidateCount).contains(number), !picked.contains(number) {
                picked.append(number)
            }
        }
        return picked
    }

    /// No model: links that look like content (a title of 3+ words or 18+ characters, another site
    /// than the page's own, not a search engine), one per site, top to bottom.
    public static func heuristicPick(_ candidates: [ResearchLinkCandidate], count: Int, pageURL: URL?) -> [ResearchLinkCandidate] {
        let pageHost = pageURL?.host?.lowercased()
        var seenHosts = Set<String>()
        var picked: [ResearchLinkCandidate] = []
        let contentLooking = candidates.filter { candidate in
            let words = candidate.text.split(separator: " ").count
            return (words >= 3 || candidate.text.count >= 18) && !ResearchURLPolicy.isSearchEngine(candidate.url)
        }
        let preferred = contentLooking.filter { $0.url.host?.lowercased() != pageHost }
        for candidate in preferred + contentLooking where picked.count < count {
            guard let host = candidate.url.host?.lowercased(), !picked.contains(where: { $0.url == candidate.url }) else { continue }
            if seenHosts.insert(host).inserted || preferred.isEmpty { picked.append(candidate) }
        }
        return picked
    }

    /// google.com/url?q=… and similar redirect wrappers → the real page.
    public static func unwrapRedirect(_ url: URL) -> URL {
        guard let host = url.host?.lowercased(), ResearchURLPolicy.isSearchEngine(url) || host.hasSuffix("duckduckgo.com"),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        for name in ["q", "url", "uddg", "u"] {
            if let value = components.queryItems?.first(where: { $0.name == name })?.value,
               let target = URL(string: value), let scheme = target.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                return target
            }
        }
        return url
    }

    static func normalizedKey(_ url: URL) -> String {
        var key = url.absoluteString
        if let hashIndex = key.firstIndex(of: "#") { key = String(key[..<hashIndex]) }
        if key.hasSuffix("/") { key.removeLast() }
        return key.lowercased()
    }
}
