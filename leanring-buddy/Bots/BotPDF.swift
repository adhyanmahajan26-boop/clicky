//
//  BotPDF.swift
//  leanring-buddy
//
//  Bots can't run commands, so they can't make a PDF themselves. A bot writes the document (Markdown, HTML or plain
//  text) in its memory folder and adds a line [PDF: file name]; Theo renders it into a paged A4 PDF next to the file.
//

import AppKit
import ClickyCore

@MainActor
enum BotPDF {
    enum Problem: Error, LocalizedError {
        case notInFolder(String), unreadable(String), failed(String)
        var errorDescription: String? {
            switch self {
            case .notInFolder(let name): return "There's no file called \(name) in the bot's memory folder."
            case .unreadable(let name): return "\(name) couldn't be read as text."
            case .failed(let name): return "The PDF of \(name) couldn't be made."
            }
        }
    }

    /// Renders `name` (inside `folder`) to `<name>.pdf` beside it and returns where it went.
    static func make(named name: String, in folder: URL) throws -> URL {
        guard let source = BotPDFOrder.file(named: name, in: folder), FileManager.default.fileExists(atPath: source.path) else { throw Problem.notInFolder(name) }
        guard let text = try? String(contentsOf: source, encoding: .utf8) else { throw Problem.unreadable(source.lastPathComponent) }
        let body = attributed(text, kind: source.pathExtension.lowercased())
        let output = source.deletingPathExtension().appendingPathExtension("pdf")
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 595, height: 842)
        info.topMargin = 56; info.bottomMargin = 56; info.leftMargin = 56; info.rightMargin = 56
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        // From the top of the page, like a document, not floating in the middle.
        info.isVerticallyCentered = false
        info.isHorizontallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = output
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        view.textStorage?.setAttributedString(body)
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = true
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        let used = view.layoutManager?.usedRect(for: view.textContainer!).height ?? 10
        view.frame.size.height = max(used, 10)
        try? FileManager.default.removeItem(at: output)
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run(), FileManager.default.fileExists(atPath: output.path) else { throw Problem.failed(source.lastPathComponent) }
        return output
    }

    private static func attributed(_ text: String, kind: String) -> NSAttributedString {
        let html: String
        switch kind {
        // Nothing in a bot's HTML may make the renderer load a file or call out: images, frames, stylesheets and url() are taken out.
        case "html", "htm": html = BotPDFOrder.inertHTML(text)
        case "md", "markdown", "txt", "": html = page(MarkdownHTML.body(text))
        default: html = page("<pre>" + MarkdownHTML.escape(text) + "</pre>")
        }
        if let data = html.data(using: .utf8),
           let rendered = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil) {
            return rendered
        }
        return NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 11)])
    }

    private static func page(_ body: String) -> String {
        """
        <html><head><meta charset="utf-8"><style>
        body { font-family: -apple-system, Helvetica; font-size: 11pt; line-height: 1.35; }
        h1 { font-size: 20pt; margin: 0 0 8pt 0; } h2 { font-size: 15pt; margin: 12pt 0 6pt 0; } h3 { font-size: 12.5pt; margin: 10pt 0 4pt 0; }
        table { border-collapse: collapse; margin: 6pt 0; width: 100%; }
        th, td { border: 0.5pt solid #999; padding: 3pt 6pt; text-align: left; vertical-align: top; }
        th { background: #eee; }
        code, pre { font-family: Menlo, monospace; font-size: 9.5pt; }
        </style></head><body>\(body)</body></html>
        """
    }
}

/// Just enough Markdown for a document a bot writes: headings, paragraphs, lists, tables, rules, and bold, italics, code and links inline.
enum MarkdownHTML {
    static func escape(_ text: String) -> String {
        // Quotes too: a bot's link target lands inside an attribute, and a quote there would let it add attributes (style, and with it url()).
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
    }

    static func inline(_ text: String) -> String {
        var out = escape(text)
        let rules: [(String, String)] = [
            (#"`([^`]+)`"#, "<code>$1</code>"),
            (#"\*\*([^*]+)\*\*"#, "<b>$1</b>"),
            (#"__([^_]+)__"#, "<b>$1</b>"),
            (#"(?<![*\w])\*([^*\n]+)\*(?!\*)"#, "<i>$1</i>"),
            (#"(?<![\w])_([^_\n]+)_(?![\w])"#, "<i>$1</i>"),
            // Only web and mail links: a file: or javascript: link in a PDF is a trap for whoever clicks it.
            (#"\[([^\]]+)\]\(((?:https?://|mailto:)[^)\s]+)\)"#, "<a href=\"$2\">$1</a>")
        ]
        for (pattern, template) in rules { out = out.replacingOccurrences(of: pattern, with: template, options: .regularExpression) }
        return out
    }

    private static func cells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isDivider(_ line: String) -> Bool {
        line.range(of: #"^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$"#, options: .regularExpression) != nil
    }

    static func body(_ markdown: String) -> String {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var html = ""
        var paragraph: [String] = []
        var list: String?
        func flushParagraph() {
            if !paragraph.isEmpty { html += "<p>" + paragraph.map(inline).joined(separator: "<br>") + "</p>\n"; paragraph = [] }
        }
        func closeList() { if let tag = list { html += "</\(tag)>\n"; list = nil } }
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("|"), index + 1 < lines.count, isDivider(lines[index + 1]) {
                flushParagraph(); closeList()
                html += "<table><tr>" + cells(line).map { "<th>\(inline($0))</th>" }.joined() + "</tr>\n"
                index += 2
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    html += "<tr>" + cells(lines[index]).map { "<td>\(inline($0))</td>" }.joined() + "</tr>\n"
                    index += 1
                }
                html += "</table>\n"
                continue
            }
            if trimmed.isEmpty { flushParagraph(); closeList() }
            else if let range = trimmed.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                flushParagraph(); closeList()
                let level = trimmed[range].filter { $0 == "#" }.count
                html += "<h\(level)>\(inline(String(trimmed[range.upperBound...])))</h\(level)>\n"
            } else if trimmed.range(of: #"^(-{3,}|\*{3,}|_{3,})$"#, options: .regularExpression) != nil {
                flushParagraph(); closeList(); html += "<hr>\n"
            } else if let range = trimmed.range(of: #"^([-*+]|\d+[.)])\s+"#, options: .regularExpression) {
                flushParagraph()
                let tag = trimmed[range].first?.isNumber == true ? "ol" : "ul"
                if list != tag { closeList(); html += "<\(tag)>\n"; list = tag }
                html += "<li>\(inline(String(trimmed[range.upperBound...])))</li>\n"
            } else {
                closeList(); paragraph.append(trimmed)
            }
            index += 1
        }
        flushParagraph(); closeList()
        return html
    }
}
