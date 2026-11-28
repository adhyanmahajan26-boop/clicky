//
//  SpaceWebSearch.swift
//  ClickyCore
//
//  Web search for the X Space bot on a local model, with no paid service and nothing to install: the model writes a
//  "SEARCH: query" line when someone asks it to look something up, the app searches (DuckDuckGo's plain results page,
//  then Wikipedia's API if that gives nothing), and the model answers from the top results in a turn of its own.
//

import Foundation

public enum SpaceWebSearch {
    public struct Result: Equatable, Sendable {
        public let title: String
        public let snippet: String
        public let url: String
    }

    /// The line the local model is told to write, alone, to search.
    public static let marker = "SEARCH:"

    /// The instruction for the local model's system prompt.
    public static let rule = """
    You can search the web. Only when someone asks you to search, Google, check or look something up, or asks for the latest news or a fact you'd need to check: write one short line first ("Ek sec, check karta hun."), then on its own line write SEARCH: followed by a short search query in English, and stop there. You'll get the results in the next message, and then you answer from them in one or two short sentences. Never write SEARCH: when nobody asked.
    """

    /// The query in a line the model wrote, or nil when the line isn't a search.
    public static func query(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: #"^\**\s*search\s*:\s*"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let query = trimmed[range.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " *\"'`.").union(.whitespacesAndNewlines))
        return query.isEmpty ? nil : String(query.prefix(200))
    }

    /// DuckDuckGo's plain results page (html.duckduckgo.com/html/?q=): titles, snippets and links.
    public static func duckDuckGoResults(html: String, limit: Int = 3) -> [Result] {
        let titles = matches(#"class="result__a"[^>]*href="([^"]*)"[^>]*>([\s\S]*?)</a>"#, in: html)
        let snippets = matches(#"class="result__snippet"[^>]*>([\s\S]*?)</a>"#, in: html).map { plainText($0[0]) }
        var results: [Result] = []
        for (index, title) in titles.enumerated() where results.count < limit {
            let snippet = index < snippets.count ? snippets[index] : ""
            guard !snippet.isEmpty else { continue }
            results.append(Result(title: plainText(title[1]), snippet: snippet, url: realURL(title[0])))
        }
        return results
    }

    /// Wikipedia's search API (/w/rest.php/v1/search/page): page titles and excerpts.
    public static func wikipediaResults(json: Data, limit: Int = 3) -> [Result] {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any], let pages = object["pages"] as? [[String: Any]] else { return [] }
        return pages.prefix(limit).compactMap { page in
            guard let title = page["title"] as? String else { return nil }
            let excerpt = plainText(page["excerpt"] as? String ?? (page["description"] as? String ?? ""))
            let key = page["key"] as? String ?? title.replacingOccurrences(of: " ", with: "_")
            return Result(title: title, snippet: excerpt, url: "https://en.wikipedia.org/wiki/" + key)
        }
    }

    /// Wikipedia's page summary (/api/rest_v1/page/summary/<title>): the lead of the article, which usually holds the answer.
    public static func wikipediaSummary(json: Data) -> Result? {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any], let title = object["title"] as? String,
              let extract = object["extract"] as? String, !extract.isEmpty else { return nil }
        let url = ((object["content_urls"] as? [String: Any])?["desktop"] as? [String: Any])?["page"] as? String ?? ""
        return Result(title: title, snippet: String(extract.prefix(700)), url: url)
    }

    /// GDELT's free news index (api.gdeltproject.org/api/v2/doc/doc, mode=artlist): the latest headlines on a topic.
    public static func gdeltHeadlines(json: Data, limit: Int = 5) -> [Result] {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any], let articles = object["articles"] as? [[String: Any]] else { return [] }
        return articles.prefix(limit).compactMap { article in
            guard let title = article["title"] as? String else { return nil }
            let when = (article["seendate"] as? String).map { String($0.prefix(8)) } ?? ""
            return Result(title: title, snippet: "\(article["domain"] as? String ?? "") \(when)", url: article["url"] as? String ?? "")
        }
    }

    /// Whether a query is about the news (latest headlines, today), which an encyclopedia doesn't have.
    public static func isNewsQuery(_ query: String) -> Bool {
        let lower = query.lowercased()
        return ["news", "latest", "today", "headline", "breaking", "this week", "aaj", "abhi"].contains { lower.contains($0) }
    }

    /// The turn that gives the model what was found.
    public static func resultsMessage(query: String, results: [Result]) -> String {
        guard !results.isEmpty else {
            return "(Your search for \"\(query)\" found nothing. Say in one short line that you couldn't find it right now. Don't write SEARCH: again.)"
        }
        let lines = results.enumerated().map { index, result in "\(index + 1). \(result.title): \(result.snippet)" }.joined(separator: "\n")
        return """
        (What your search for "\(query)" found, top results:
        \(lines)
        Now answer what was asked in one or two short sentences, in the language of whoever asked, saying it's from a quick search. No links, no list, and don't write SEARCH: again.)
        """
    }

    static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).map { match in
            (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
        }
    }

    /// Text without tags, with the usual entities read.
    static func plainText(_ html: String) -> String {
        var text = html.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (entity, character) in [("&amp;", "&"), ("&quot;", "\""), ("&#x27;", "'"), ("&#39;", "'"), ("&#039;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    /// DuckDuckGo's links go through its redirect ("//duckduckgo.com/l/?uddg=<encoded>"): the page's own address.
    static func realURL(_ link: String) -> String {
        if let components = URLComponents(string: link.hasPrefix("//") ? "https:" + link : link),
           let target = components.queryItems?.first(where: { $0.name == "uddg" })?.value {
            return target
        }
        return link
    }
}
