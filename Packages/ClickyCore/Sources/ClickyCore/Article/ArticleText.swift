//
//  ArticleText.swift
//  ClickyCore
//
//  P8 article reader, the pure half. The app walks the frontmost browser's
//  AXWebArea in reading order (depth first, children in order) and hands
//  every AXStaticText run here as an ArticleTextNode: its text and the id
//  of the block it sits in (the nearest non-inline ancestor: a paragraph,
//  heading, list item…). This file
//   - decides which subtrees are page chrome (navigation, banner, footer,
//     sidebars, search, menus, toolbars) and which one is the article
//     (AXLandmarkMain / AXDocumentArticle / <article>), ArticleLandmarkPolicy;
//   - joins the runs into one text (runs of one block join as they are,
//     blocks are separated by a blank line), capped at ~30k characters;
//   - keeps a run map: where each run sits in the joined text (UTF-16
//     offsets, the unit of AX ranges), so a sentence found in the joined
//     text can be turned back into per-run ranges for AXBoundsForRange.
//

import CoreGraphics
import Foundation

/// Where the article text came from.
public enum ArticleTextSource: String, Equatable, Sendable {
    /// The web area's AXStaticText runs.
    case accessibility = "AX"
    /// Screenshots of the article column, scrolled page by page, OCR'd.
    case ocr = "OCR"
    case none
}

/// One AXStaticText run, in reading order.
public struct ArticleTextNode: Equatable, Sendable {
    public var text: String
    /// The block (paragraph, heading, list item) the run belongs to; runs of
    /// one block are joined without a separator, a new block starts a new paragraph.
    public var blockIdentifier: Int
    /// The run is a heading's text (its own paragraph).
    public var isHeading: Bool

    public init(text: String, blockIdentifier: Int, isHeading: Bool = false) {
        self.text = text
        self.blockIdentifier = blockIdentifier
        self.isHeading = isHeading
    }
}

/// Where run `nodeIndex` sits in the joined text.
public struct ArticleRunSpan: Equatable, Sendable {
    public var nodeIndex: Int
    /// UTF-16 range in the joined text.
    public var rangeInText: Range<Int>
    /// The run's own text may have been trimmed at the front when joined
    /// (leading whitespace at a paragraph start): add this to map a joined
    /// offset back to an offset in the run's AXValue.
    public var offsetInRun: Int

    public init(nodeIndex: Int, rangeInText: Range<Int>, offsetInRun: Int) {
        self.nodeIndex = nodeIndex
        self.rangeInText = rangeInText
        self.offsetInRun = offsetInRun
    }
}

/// A range inside one run's AXValue (UTF-16), what AXBoundsForRange takes.
public struct ArticleRunRange: Equatable, Sendable {
    public var nodeIndex: Int
    public var range: Range<Int>

    public init(nodeIndex: Int, range: Range<Int>) {
        self.nodeIndex = nodeIndex
        self.range = range
    }
}

/// The joined article and its run map.
public struct ArticleDocument: Equatable, Sendable {
    public var text: String
    public var spans: [ArticleRunSpan]
    public var title: String?
    public var url: String?
    public var source: ArticleTextSource
    /// The text hit the cap (the rest of the article wasn't included).
    public var isTruncated: Bool

    public init(text: String, spans: [ArticleRunSpan] = [], title: String? = nil, url: String? = nil, source: ArticleTextSource, isTruncated: Bool = false) {
        self.text = text
        self.spans = spans
        self.title = title
        self.url = url
        self.source = source
        self.isTruncated = isTruncated
    }

    public var utf16Length: Int { text.utf16.count }

    /// A UTF-16 range of the joined text → the ranges inside each run it covers (in reading order).
    public func runRanges(for rangeInText: Range<Int>) -> [ArticleRunRange] {
        var result: [ArticleRunRange] = []
        for span in spans {
            let lower = max(span.rangeInText.lowerBound, rangeInText.lowerBound)
            let upper = min(span.rangeInText.upperBound, rangeInText.upperBound)
            guard lower < upper else { continue }
            let localLower = lower - span.rangeInText.lowerBound + span.offsetInRun
            let localUpper = upper - span.rangeInText.lowerBound + span.offsetInRun
            result.append(ArticleRunRange(nodeIndex: span.nodeIndex, range: localLower..<localUpper))
        }
        return result
    }

    /// The text at a UTF-16 range (empty when out of bounds).
    public func substring(utf16Range: Range<Int>) -> String {
        let utf16 = text.utf16
        guard utf16Range.lowerBound >= 0, utf16Range.upperBound <= utf16.count, !utf16Range.isEmpty else { return "" }
        let start = utf16.index(utf16.startIndex, offsetBy: utf16Range.lowerBound)
        let end = utf16.index(utf16.startIndex, offsetBy: utf16Range.upperBound)
        return String(utf16[start..<end]) ?? ""
    }
}

/// Which parts of a web page are chrome, and which is the article.
public enum ArticleLandmarkPolicy {
    /// Subroles of landmarks that are never the article.
    public static let skippedSubroles: Set<String> = [
        "AXLandmarkNavigation", "AXLandmarkBanner", "AXLandmarkContentInfo", "AXLandmarkComplementary", "AXLandmarkSearch",
        "AXLandmarkForm", "AXApplicationDialog", "AXApplicationAlertDialog", "AXApplicationAlert", "AXApplicationStatus"
    ]
    /// Roles whose whole subtree is controls, not prose.
    public static let skippedRoles: Set<String> = [
        "AXToolbar", "AXMenuBar", "AXMenu", "AXMenuButton", "AXTabGroup", "AXScrollBar", "AXButton", "AXPopUpButton",
        "AXTextField", "AXComboBox", "AXSearchField", "AXCheckBox", "AXRadioButton", "AXSlider", "AXDialog"
    ]
    /// DOM tags Chrome exposes as AXDOMClassList/AXRoleDescription hints are not
    /// reliable; these subroles mark the article itself.
    public static let articleSubroles: Set<String> = ["AXLandmarkMain", "AXDocumentArticle"]

    public static func isSkipped(role: String?, subrole: String?) -> Bool {
        if let role, skippedRoles.contains(role) { return true }
        if let subrole, skippedSubroles.contains(subrole) { return true }
        return false
    }

    public static func isArticleRoot(role: String?, subrole: String?) -> Bool {
        guard let subrole else { return false }
        return articleSubroles.contains(subrole)
    }

    /// Inline roles: a static text inside one of these belongs to the enclosing block.
    public static let inlineRoles: Set<String> = ["AXLink", "AXStaticText", "AXImage", "AXGroup"]
    /// Inline subroles of AXGroup (Chrome/WebKit use these for <em>, <strong>, <mark>, <code>…).
    public static let inlineGroupSubroles: Set<String> = ["AXEmphasis", "AXStrong", "AXMark", "AXCodeStyleGroup", "AXSubscriptStyleGroup",
                                                          "AXSuperscriptStyleGroup", "AXDeleteStyleGroup", "AXInsertStyleGroup", "AXTime", "AXAbbr"]

    /// True when `role`/`subrole` starts a new block (paragraph) for the runs under it.
    public static func startsBlock(role: String?, subrole: String?) -> Bool {
        guard let role else { return false }
        if role == "AXLink" || role == "AXStaticText" || role == "AXImage" { return false }
        if role == "AXGroup", let subrole, inlineGroupSubroles.contains(subrole) { return false }
        return true
    }
}

public enum ArticleTextAssembler {
    public static let maximumCharacters = 30_000
    /// Less AX article text than this and OCR is tried as well.
    public static let minimumUsefulAccessibilityCharacters = 400

    /// Runs in reading order → the joined article. Runs of one block join
    /// as they are (their own spaces); blocks are separated by "\n\n";
    /// whitespace runs collapse; repeated short chrome lines are dropped.
    public static func assemble(_ nodes: [ArticleTextNode], title: String? = nil, url: String? = nil,
                                maximumCharacters: Int = maximumCharacters) -> ArticleDocument {
        var text = ""
        var utf16Length = 0
        var spans: [ArticleRunSpan] = []
        var previousBlockIdentifier: Int?
        var isTruncated = false

        for (nodeIndex, node) in nodes.enumerated() {
            // Collapse internal newlines/tabs to spaces but keep the run's length the same
            // (offsets into the AXValue must stay valid), so only same-length replacements.
            let runText = node.text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
            guard !runText.trimmingCharacters(in: .whitespaces).isEmpty else { continue }

            let startsNewBlock = previousBlockIdentifier != nil && (previousBlockIdentifier != node.blockIdentifier || node.isHeading)
            var leadingTrimCount = 0
            var appended = runText
            if text.isEmpty || startsNewBlock {
                // A paragraph's first run loses its leading spaces.
                let trimmed = String(runText.drop(while: { $0 == " " }))
                leadingTrimCount = runText.utf16.count - trimmed.utf16.count
                appended = trimmed
                if !text.isEmpty {
                    // The previous paragraph loses its trailing spaces.
                    while text.hasSuffix(" ") {
                        text.removeLast()
                        utf16Length -= 1
                        if var last = spans.last, last.rangeInText.upperBound > utf16Length {
                            last.rangeInText = last.rangeInText.lowerBound..<max(last.rangeInText.lowerBound, utf16Length)
                            spans[spans.count - 1] = last
                        }
                    }
                    text += "\n\n"
                    utf16Length += 2
                }
            } else if let lastCharacter = text.last, lastCharacter != " ", let firstCharacter = appended.first, firstCharacter != " ",
                      needsSpaceBetween(lastCharacter, firstCharacter) {
                // Two runs of one block with no space at the seam ("word" + "word" from separate nodes).
                text += " "
                utf16Length += 1
            }

            let appendedLength = appended.utf16.count
            if utf16Length + appendedLength > maximumCharacters {
                let room = maximumCharacters - utf16Length
                if room > 20 {
                    let clipped = clippedAtWordBoundary(appended, utf16Limit: room)
                    spans.append(ArticleRunSpan(nodeIndex: nodeIndex, rangeInText: utf16Length..<(utf16Length + clipped.utf16.count), offsetInRun: leadingTrimCount))
                    text += clipped
                    utf16Length += clipped.utf16.count
                }
                isTruncated = true
                break
            }
            spans.append(ArticleRunSpan(nodeIndex: nodeIndex, rangeInText: utf16Length..<(utf16Length + appendedLength), offsetInRun: leadingTrimCount))
            text += appended
            utf16Length += appendedLength
            previousBlockIdentifier = node.isHeading ? -1 - nodeIndex : node.blockIdentifier
        }
        while text.hasSuffix(" ") || text.hasSuffix("\n") {
            text.removeLast()
            utf16Length -= 1
        }
        spans = spans.map { span in
            var clamped = span
            clamped.rangeInText = span.rangeInText.lowerBound..<min(span.rangeInText.upperBound, utf16Length)
            return clamped
        }.filter { !$0.rangeInText.isEmpty }
        return ArticleDocument(text: text, spans: spans, title: cleanedTitle(title), url: url, source: text.isEmpty ? .none : .accessibility, isTruncated: isTruncated)
    }

    /// OCR'd pages of the article column (top to bottom, overlapping) → one text, capped.
    /// Lines already seen on the previous page (the overlap after a scroll) are dropped.
    public static func assembleOCRPages(_ pages: [[String]], title: String? = nil, url: String? = nil,
                                        maximumCharacters: Int = maximumCharacters) -> ArticleDocument {
        var lines: [String] = []
        for page in pages {
            let pageLines = page.map(ActionPageText.collapseWhitespace).filter { !$0.isEmpty }
            let overlap = overlapCount(previous: lines, next: pageLines)
            lines += pageLines.dropFirst(overlap)
        }
        var text = ""
        for line in lines {
            if text.isEmpty {
                text = line
                continue
            }
            // A line ending in a sentence end (or a short heading-like line) closes a paragraph.
            let endsParagraph = text.last.map { ".!?:\u{201D}\"".contains($0) } ?? false
            if text.hasSuffix("-"), let first = line.first, first.isLowercase {
                // "impor-" + "tant": a word hyphenated across lines.
                text.removeLast()
                text += line
            } else {
                text += (endsParagraph && line.count > 0 && (line.first?.isUppercase ?? false)) ? "\n" : " "
                text += line
            }
        }
        let isTruncated = text.utf16.count > maximumCharacters
        if isTruncated { text = clippedAtWordBoundary(text, utf16Limit: maximumCharacters) }
        return ArticleDocument(text: text, spans: [], title: cleanedTitle(title), url: url, source: text.isEmpty ? .none : .ocr, isTruncated: isTruncated)
    }

    /// How many lines at the start of `next` repeat the end of `previous` (the scroll overlap).
    static func overlapCount(previous: [String], next: [String]) -> Int {
        guard !previous.isEmpty, !next.isEmpty else { return 0 }
        let maximumOverlap = min(previous.count, next.count)
        for overlap in stride(from: maximumOverlap, to: 0, by: -1) {
            let previousTail = previous.suffix(overlap).map(ArticleSentenceMatcher.normalizedForComparison)
            let nextHead = next.prefix(overlap).map(ArticleSentenceMatcher.normalizedForComparison)
            if previousTail == nextHead { return overlap }
        }
        return 0
    }

    /// The tab/window title without the browser's " - Google Chrome" tail.
    public static func cleanedTitle(_ title: String?) -> String? {
        guard var cleaned = title?.trimmingCharacters(in: .whitespacesAndNewlines), !cleaned.isEmpty else { return nil }
        for suffix in [" - Google Chrome", " — Google Chrome", " - Chromium", " - Brave", " - Microsoft Edge", " — Safari", " - Safari", " - Arc"] where cleaned.hasSuffix(suffix) {
            cleaned = String(cleaned.dropLast(suffix.count))
        }
        return cleaned.trimmingCharacters(in: .whitespaces).isEmpty ? nil : cleaned
    }

    /// Runs keep their own spaces ("Hello " + "world"), and "<em>un</em>believable"
    /// must stay one word, so a space is only added between two sentences that
    /// touch ("…end." + "Next…", seen when a paragraph is split into nodes).
    static func needsSpaceBetween(_ last: Character, _ first: Character) -> Bool {
        ".!?".contains(last) && first.isUppercase
    }

    static func clippedAtWordBoundary(_ text: String, utf16Limit: Int) -> String {
        guard text.utf16.count > utf16Limit else { return text }
        let utf16 = text.utf16
        let limitIndex = utf16.index(utf16.startIndex, offsetBy: utf16Limit)
        let prefix = String(text[..<(String.Index(limitIndex, within: text) ?? text.startIndex)])
        if let lastSpace = prefix.lastIndex(of: " "), prefix.distance(from: prefix.startIndex, to: lastSpace) > prefix.count / 2 {
            return String(prefix[..<lastSpace])
        }
        return prefix
    }
}

/// Which window holds the article: the frontmost app when it is a browser,
/// else the topmost on-screen window of any browser (Clicky's own panels
/// and a terminal running the test harness may be in front), else the
/// frontmost app's window.
public enum ArticleWindowChoice {
    public struct Candidate: Equatable, Sendable {
        public var processIdentifier: Int32
        public var bundleIdentifier: String?
        /// CG window number (front to back order is the array order).
        public var windowNumber: UInt32
        public var frameCG: CGRect
        /// The window title (CG window name), when readable.
        public var title: String?
        /// Its app's AXFocusedWindow / AXMainWindow.
        public var isFocusedWindow: Bool
        /// Covers its whole display (full screen): a show or a film, never "the article".
        public var isFullScreen: Bool

        public init(processIdentifier: Int32, bundleIdentifier: String?, windowNumber: UInt32, frameCG: CGRect, title: String? = nil,
                    isFocusedWindow: Bool = false, isFullScreen: Bool = false) {
            self.processIdentifier = processIdentifier
            self.bundleIdentifier = bundleIdentifier
            self.windowNumber = windowNumber
            self.frameCG = frameCG
            self.title = title
            self.isFocusedWindow = isFocusedWindow
            self.isFullScreen = isFullScreen
        }

        /// A window playing Netflix is never "the article" (a live read picked the owner's
        /// full-screen Netflix window in Safari and got nothing).
        public var isNetflix: Bool { title?.localizedCaseInsensitiveContains("netflix") ?? false }
    }

    public static let browserBundleIdentifiers: Set<String> = Set(ActionBrowserChoice.knownBrowsers.map(\.bundleIdentifier)).union([
        "org.chromium.Chromium", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary", "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera", "com.kagi.kagimacOS", "company.thebrowser.dia", "com.apple.SafariTechnologyPreview", "org.mozilla.firefoxdeveloperedition"
    ])

    public static func isBrowser(_ bundleIdentifier: String?) -> Bool {
        bundleIdentifier.map(browserBundleIdentifiers.contains) ?? false
    }

    /// `windows`: on-screen normal windows, front to back, Clicky's own already removed.
    /// Order: the frontmost browser's focused/main window, else the browser window under the cursor,
    /// else the largest browser window; never a full-screen (media) or Netflix window.
    public static func choose(frontmostProcessIdentifier: Int32?, windows: [Candidate], cursorCG: CGPoint? = nil) -> Candidate? {
        let usable = windows.filter { $0.frameCG.width >= 200 && $0.frameCG.height >= 150 && !$0.isNetflix && !$0.isFullScreen }
        let browsers = usable.filter { isBrowser($0.bundleIdentifier) }
        if let frontmostProcessIdentifier,
           let focused = browsers.first(where: { $0.processIdentifier == frontmostProcessIdentifier && $0.isFocusedWindow }) {
            return focused
        }
        if let cursorCG, let underCursor = browsers.first(where: { $0.frameCG.contains(cursorCG) }) { return underCursor }
        if let frontmostProcessIdentifier, let frontmostBrowserWindow = browsers.first(where: { $0.processIdentifier == frontmostProcessIdentifier }) {
            return frontmostBrowserWindow
        }
        if let largest = browsers.max(by: { $0.frameCG.width * $0.frameCG.height < $1.frameCG.width * $1.frameCG.height }) { return largest }
        if let frontmostProcessIdentifier, let frontmostWindow = usable.first(where: { $0.processIdentifier == frontmostProcessIdentifier }) {
            return frontmostWindow
        }
        return nil
    }
}

/// P9 "read further": when an article's accessibility text looks cut short, Clicky scrolls and re-reads.
public enum ArticleReadFurther {
    public static let maximumPasses = 10
    /// Under this many characters a page that says "read more" / lazy-loads is probably not all there.
    public static let shortArticleCharacters = 6000

    public static func looksCutShort(text: String, characterCount: Int, hitDeadline: Bool) -> Bool {
        if hitDeadline { return false }  // a huge page: re-walking would hit the same limit
        let lowered = text.lowercased()
        let hasExpander = ["read more", "continue reading", "show more", "load more", "read the full", "keep reading"].contains { lowered.contains($0) }
        return hasExpander || characterCount < shortArticleCharacters
    }

    /// A plain in-page expander, not a paywall or sign-in.
    public static func isPlainExpander(_ label: String) -> Bool {
        let lowered = label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lowered.isEmpty, lowered.count <= 40 else { return false }
        if ["subscribe", "sign in", "log in", "login", "sign up", "register", "trial", "paywall", "member", "buy"].contains(where: { lowered.contains($0) }) {
            return false
        }
        return ["read more", "continue reading", "show more", "read full article", "read the full story", "load more", "keep reading", "expand"]
            .contains { lowered.hasPrefix($0) }
    }
}
