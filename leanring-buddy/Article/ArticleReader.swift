//
//  ArticleReader.swift
//  leanring-buddy
//
//  P8 read_article, the system half: finds the article window (the front
//  browser, ArticleWindowChoice), walks its AXWebArea in reading order for
//  AXStaticText runs (skipping navigation, banners, footers, sidebars and
//  controls; only the AXLandmarkMain / AXDocumentArticle subtree when the
//  page has one) and joins them with ArticleTextAssembler. Each run keeps
//  its AXUIElement so a highlighted sentence can be measured with
//  AXBoundsForRange later.
//
//  When the web area has (almost) no text — a canvas reader, a PDF viewer,
//  an image of text — and v2.article.scrollOCRFallback is on, the article
//  column is captured and OCR'd page by page, scrolling down with tagged
//  scroll-wheel events (never a click, never a key), then scrolled back.
//
//  The walk runs off the main thread (AX calls are thread-safe) with a
//  deadline, so Clicky never freezes on a huge page.
//

import AppKit
import ApplicationServices
import ClickyCore

/// The article window, as found just before reading or highlighting.
struct ArticleWindowTarget {
    var processIdentifier: pid_t
    var bundleIdentifier: String?
    var applicationName: String?
    var windowElement: AXUIElement?
    var windowNumber: CGWindowID
    var windowFrameCG: CGRect
}

/// One read of an article: the joined text and, for AX reads, every run's element.
final class ArticleReadResult: @unchecked Sendable {
    let document: ArticleDocument
    /// Parallel to the nodes the document was assembled from (document.spans[i].nodeIndex indexes it).
    let runElements: [AXUIElement]
    let webAreaElement: AXUIElement?
    let target: ArticleWindowTarget
    let readAt: Date
    let milliseconds: Int

    init(document: ArticleDocument, runElements: [AXUIElement], webAreaElement: AXUIElement?, target: ArticleWindowTarget, readAt: Date, milliseconds: Int) {
        self.document = document
        self.runElements = runElements
        self.webAreaElement = webAreaElement
        self.target = target
        self.readAt = readAt
        self.milliseconds = milliseconds
    }
}

/// An AX walk's raw result (built off the main thread).
nonisolated struct ArticleAXWalk: @unchecked Sendable {
    var nodes: [ArticleTextNode] = []
    var elements: [AXUIElement] = []
    var webArea: AXUIElement?
    var title: String?
    var url: String?
    var visitedCount = 0
    var didHitDeadline = false
}

@MainActor
enum ArticleReader {
    nonisolated static let walkDeadlineSeconds: TimeInterval = 4
    nonisolated static let maximumVisitedNodes = 25_000
    static let maximumOCRPages = 14

    // MARK: - The window

    /// The article window: the frontmost browser's front window (see ArticleWindowChoice).
    static func findArticleWindow() -> ArticleWindowTarget? {
        let ownProcessIdentifier = getpid()
        let windowInfoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var candidates: [ArticleWindowChoice.Candidate] = []
        for windowInfo in windowInfoList {
            guard let layer = (windowInfo[kCGWindowLayer as String] as? NSNumber)?.intValue, layer == 0,
                  let ownerProcessIdentifier = (windowInfo[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, ownerProcessIdentifier != ownProcessIdentifier,
                  let windowNumber = (windowInfo[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let boundsDictionary = windowInfo[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary) else { continue }
            let bundleIdentifier = NSRunningApplication(processIdentifier: ownerProcessIdentifier)?.bundleIdentifier
            candidates.append(ArticleWindowChoice.Candidate(processIdentifier: ownerProcessIdentifier, bundleIdentifier: bundleIdentifier,
                                                           windowNumber: windowNumber, frameCG: bounds,
                                                           title: windowInfo[kCGWindowName as String] as? String))
        }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let chosen = ArticleWindowChoice.choose(frontmostProcessIdentifier: frontmost == ownProcessIdentifier ? nil : frontmost, windows: candidates) else { return nil }
        let runningApplication = NSRunningApplication(processIdentifier: chosen.processIdentifier)
        return ArticleWindowTarget(processIdentifier: chosen.processIdentifier, bundleIdentifier: chosen.bundleIdentifier,
                                   applicationName: runningApplication?.localizedName,
                                   windowElement: axWindow(processIdentifier: chosen.processIdentifier, matching: chosen.frameCG),
                                   windowNumber: chosen.windowNumber, windowFrameCG: chosen.frameCG)
    }

    /// The app's AX window whose frame matches the CG window (else its focused window).
    static func axWindow(processIdentifier: pid_t, matching frameCG: CGRect) -> AXUIElement? {
        let applicationElement = TypeForMeAccessibility.applicationElement(processIdentifier: processIdentifier)
        let windows = TypeForMeAccessibility.elementArrayAttribute(kAXWindowsAttribute, of: applicationElement)
        if let exact = windows.first(where: { window in
            guard let windowFrame = TypeForMeAccessibility.frameCG(of: window) else { return false }
            return abs(windowFrame.minX - frameCG.minX) < 3 && abs(windowFrame.minY - frameCG.minY) < 3
                && abs(windowFrame.width - frameCG.width) < 3 && abs(windowFrame.height - frameCG.height) < 3
        }) {
            return exact
        }
        return ActionExecutor.focusedWindow(processIdentifier: processIdentifier)
    }

    // MARK: - Reading

    /// Reads the whole article: AX first, scroll + OCR when that has too little text.
    /// `scroll(pointCG, pixels)` posts one tagged scroll (positive = down); nil = never scroll.
    static func read(target: ArticleWindowTarget, maximumCharacters: Int,
                     scroll: ((CGPoint, Int) -> Void)?, isCancelled: @escaping () -> Bool) async -> ArticleReadResult {
        let startUptime = ProcessInfo.processInfo.systemUptime
        var walk = ArticleAXWalk()
        if let windowElement = target.windowElement {
            AXUIElementSetMessagingTimeout(windowElement, 0.5)
            let uncheckedWindow = UncheckedAXElement(element: windowElement)
            walk = await Task.detached(priority: .userInitiated) {
                walkArticle(window: uncheckedWindow.element, deadline: ProcessInfo.processInfo.systemUptime + walkDeadlineSeconds)
            }.value
        }
        let windowTitle = target.windowElement.flatMap { TypeForMeAccessibility.stringAttribute(kAXTitleAttribute, of: $0) }
        let title = walk.title ?? windowTitle
        var document = ArticleTextAssembler.assemble(walk.nodes, title: title, url: walk.url, maximumCharacters: maximumCharacters)
        var runElements = walk.elements
        print("📰 Article: AX walk visited \(walk.visitedCount) nodes, \(walk.nodes.count) runs, \(document.utf16Length) chars\(walk.didHitDeadline ? " (deadline)" : "")")

        // P9 read further: the AX text looks cut short (lazy-loaded page, "read more"): expand plain
        // in-page expanders, then scroll page by page and re-read until nothing new appears; then scroll back.
        if document.utf16Length >= ArticleTextAssembler.minimumUsefulAccessibilityCharacters, let scroll, let windowElement = target.windowElement,
           ArticleReadFurther.looksCutShort(text: document.text, characterCount: document.utf16Length, hitDeadline: walk.didHitDeadline),
           !isCancelled() {
            if let webArea = walk.webArea, pressReadMoreButtons(in: webArea) {
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
            let viewport = viewportCG(webArea: walk.webArea, windowFrameCG: target.windowFrameCG)
            let scrollPoint = CGPoint(x: viewport.midX, y: viewport.midY)
            let pageStep = max(200, Int(viewport.height * 0.85))
            var scrolledPixels = 0
            var passesWithoutNewText = 0
            for _ in 0..<ArticleReadFurther.maximumPasses {
                if isCancelled() || document.isTruncated { break }
                scroll(scrollPoint, pageStep)
                scrolledPixels += pageStep
                try? await Task.sleep(nanoseconds: 450_000_000)
                let uncheckedWindow = UncheckedAXElement(element: windowElement)
                let furtherWalk = await Task.detached(priority: .userInitiated) {
                    walkArticle(window: uncheckedWindow.element, deadline: ProcessInfo.processInfo.systemUptime + walkDeadlineSeconds)
                }.value
                let furtherDocument = ArticleTextAssembler.assemble(furtherWalk.nodes, title: title, url: furtherWalk.url ?? walk.url, maximumCharacters: maximumCharacters)
                if furtherDocument.utf16Length > document.utf16Length + 40 {
                    document = furtherDocument
                    runElements = furtherWalk.elements
                    walk = furtherWalk
                    passesWithoutNewText = 0
                } else {
                    passesWithoutNewText += 1
                    if passesWithoutNewText >= 2 { break }
                }
            }
            print("📰 Article: read further over \(scrolledPixels) px → \(document.utf16Length) chars")
            var remaining = scrolledPixels
            while remaining > 0 {
                let step = min(remaining, pageStep * 3)
                scroll(scrollPoint, -step)
                remaining -= step
                try? await Task.sleep(nanoseconds: 60_000_000)
            }
        }

        if document.utf16Length < ArticleTextAssembler.minimumUsefulAccessibilityCharacters, let scroll, ClickySettings.articleScrollOCRFallback, !isCancelled() {
            let viewport = viewportCG(webArea: walk.webArea, windowFrameCG: target.windowFrameCG)
            let ocrDocument = await readByScrollingOCR(viewportCG: viewport, title: title, url: walk.url, maximumCharacters: maximumCharacters,
                                                       scroll: scroll, isCancelled: isCancelled)
            if ocrDocument.utf16Length > document.utf16Length {
                document = ocrDocument
                runElements = []
            }
        }
        let milliseconds = Int((ProcessInfo.processInfo.systemUptime - startUptime) * 1000)
        return ArticleReadResult(document: document, runElements: runElements, webAreaElement: walk.webArea, target: target, readAt: Date(), milliseconds: milliseconds)
    }

    /// Presses plain in-page expanders ("read more", "continue reading", "show more"); never sign-in or
    /// subscribe buttons. Breadth first, at most 3000 nodes. True when one was pressed.
    static func pressReadMoreButtons(in webArea: AXUIElement) -> Bool {
        var queue: [AXUIElement] = [webArea]
        var visited = 0
        var pressed = false
        while !queue.isEmpty, visited < 3000 {
            let element = queue.removeFirst()
            visited += 1
            let role = TypeForMeAccessibility.stringAttribute(kAXRoleAttribute, of: element) ?? ""
            if role == kAXButtonRole as String || role == "AXLink" {
                let label = [kAXTitleAttribute, kAXDescriptionAttribute].compactMap { TypeForMeAccessibility.stringAttribute($0 as String, of: element) }.joined(separator: " ")
                if ArticleReadFurther.isPlainExpander(label) {
                    pressed = AXUIElementPerformAction(element, kAXPressAction as CFString) == .success || pressed
                    continue
                }
            }
            queue.append(contentsOf: TypeForMeAccessibility.elementArrayAttribute(kAXChildrenAttribute, of: element))
        }
        return pressed
    }

    /// The element whose frame is the page's viewport: the web area's scroll area (Safari), else the web area (Chrome).
    static func viewportElement(webArea: AXUIElement?) -> AXUIElement? {
        guard let webArea else { return nil }
        if let parent = parentElement(of: webArea), TypeForMeAccessibility.stringAttribute(kAXRoleAttribute, of: parent) == "AXScrollArea" { return parent }
        return webArea
    }

    /// The viewport from a cached viewport element (two AX calls at most, for the 10 Hz tracker).
    static func viewportCG(viewportElement: AXUIElement?, windowFrameCG: CGRect) -> CGRect {
        guard let viewportElement, let frame = TypeForMeAccessibilityFrame.frameCG(of: viewportElement), frame.width > 0, frame.height > 0 else {
            return viewportCG(webArea: nil, windowFrameCG: windowFrameCG)
        }
        let clipped = frame.intersection(windowFrameCG)
        return clipped.isNull ? windowFrameCG : clipped
    }

    /// The part of the window the page is drawn in: the web area's scroll area (or the web area), inside the window.
    static func viewportCG(webArea: AXUIElement?, windowFrameCG: CGRect) -> CGRect {
        guard let webArea else {
            // No web area: the window minus a typical toolbar.
            return CGRect(x: windowFrameCG.minX, y: windowFrameCG.minY + 80, width: windowFrameCG.width, height: max(0, windowFrameCG.height - 80))
        }
        var frame = TypeForMeAccessibility.frameCG(of: webArea)
        if let parent = parentElement(of: webArea), TypeForMeAccessibility.stringAttribute(kAXRoleAttribute, of: parent) == "AXScrollArea",
           let parentFrame = TypeForMeAccessibility.frameCG(of: parent) {
            frame = parentFrame
        }
        guard let frame, frame.width > 0, frame.height > 0 else { return windowFrameCG }
        let clipped = frame.intersection(windowFrameCG)
        return clipped.isNull ? windowFrameCG : clipped
    }

    static func parentElement(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        return (value as! AXUIElement)
    }

    // MARK: AX walk

    /// Depth first, children in order; runs inherit the nearest block's id.
    nonisolated static func walkArticle(window: AXUIElement, deadline: TimeInterval) -> ArticleAXWalk {
        var walk = ArticleAXWalk()
        guard let webArea = ActionExecutor.findDescendant(of: window, role: "AXWebArea", deadline: deadline) else {
            // Not a browser page (a document app): walk the window itself.
            walkSubtree(root: window, into: &walk, deadline: deadline)
            return walk
        }
        walk.webArea = webArea
        AXUIElementSetMessagingTimeout(webArea, 0.5)
        walk.title = ActionExecutor.stringValue(kAXTitleAttribute, of: webArea).flatMap { $0.isEmpty ? nil : $0 }
        walk.url = urlString(of: webArea)
        // The article landmark when the page marks one and it has the text; else the whole web area.
        if let articleRoot = findArticleRoot(in: webArea, deadline: deadline) {
            var articleWalk = ArticleAXWalk()
            walkSubtree(root: articleRoot, into: &articleWalk, deadline: deadline)
            let articleCharacters = articleWalk.nodes.reduce(0) { $0 + $1.text.count }
            if articleCharacters >= ArticleTextAssembler.minimumUsefulAccessibilityCharacters {
                articleWalk.webArea = webArea
                articleWalk.title = walk.title
                articleWalk.url = walk.url
                return articleWalk
            }
            walk.visitedCount += articleWalk.visitedCount
        }
        walkSubtree(root: webArea, into: &walk, deadline: deadline)
        return walk
    }

    nonisolated static func urlString(of webArea: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(webArea, "AXURL" as CFString, &value) == .success, let value else { return nil }
        if let url = value as? URL { return url.absoluteString }
        if let text = value as? String, !text.isEmpty { return text }
        return nil
    }

    /// Breadth first (≤ 3000 nodes) for AXLandmarkMain / AXDocumentArticle.
    nonisolated static func findArticleRoot(in webArea: AXUIElement, deadline: TimeInterval) -> AXUIElement? {
        var queue: [AXUIElement] = [webArea]
        var queueIndex = 0
        var visitedCount = 0
        var mainLandmark: AXUIElement?
        while queueIndex < queue.count {
            let element = queue[queueIndex]
            queueIndex += 1
            visitedCount += 1
            if visitedCount > 3_000 || ProcessInfo.processInfo.systemUptime > deadline { break }
            let attributes = basicAttributes(of: element)
            if ArticleLandmarkPolicy.isSkipped(role: attributes.role, subrole: attributes.subrole) { continue }
            if attributes.subrole == "AXDocumentArticle" { return element }
            if attributes.subrole == "AXLandmarkMain", mainLandmark == nil { mainLandmark = element }
            queue += attributes.children
        }
        return mainLandmark
    }

    nonisolated static func walkSubtree(root: AXUIElement, into walk: inout ArticleAXWalk, deadline: TimeInterval) {
        var nextBlockIdentifier = 1
        // (element, depth, block id of the nearest block ancestor, inside a heading)
        var stack: [(element: AXUIElement, depth: Int, blockIdentifier: Int, isHeading: Bool)] = [(root, 0, 0, false)]
        while let (element, depth, inheritedBlockIdentifier, inheritedIsHeading) = stack.popLast() {
            walk.visitedCount += 1
            if walk.visitedCount > maximumVisitedNodes || ProcessInfo.processInfo.systemUptime > deadline {
                walk.didHitDeadline = true
                break
            }
            let attributes = basicAttributes(of: element)
            if depth > 0 && ArticleLandmarkPolicy.isSkipped(role: attributes.role, subrole: attributes.subrole) { continue }
            if attributes.role == "AXStaticText" {
                if let text = attributes.value, !text.isEmpty {
                    walk.nodes.append(ArticleTextNode(text: text, blockIdentifier: inheritedBlockIdentifier, isHeading: inheritedIsHeading))
                    walk.elements.append(element)
                }
                continue
            }
            var blockIdentifier = inheritedBlockIdentifier
            if depth > 0 && ArticleLandmarkPolicy.startsBlock(role: attributes.role, subrole: attributes.subrole) {
                blockIdentifier = nextBlockIdentifier
                nextBlockIdentifier += 1
            }
            let isHeading = inheritedIsHeading || attributes.role == "AXHeading"
            guard depth < 80 else { continue }
            for child in attributes.children.reversed() { stack.append((child, depth + 1, blockIdentifier, isHeading)) }
        }
    }

    nonisolated struct BasicAttributes {
        var role: String?
        var subrole: String?
        var value: String?
        var children: [AXUIElement]
    }

    /// Role, subrole, value and children in one AX round trip.
    nonisolated static func basicAttributes(of element: AXUIElement) -> BasicAttributes {
        let names = [kAXRoleAttribute, kAXSubroleAttribute, kAXValueAttribute, kAXChildrenAttribute] as CFArray
        var valuesArray: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names, AXCopyMultipleAttributeOptions(rawValue: 0), &valuesArray) == .success,
              let values = valuesArray as? [AnyObject], values.count == 4 else {
            return BasicAttributes(role: ActionExecutor.stringValue(kAXRoleAttribute, of: element), subrole: nil, value: nil, children: [])
        }
        let children = (values[3] as? [AXUIElement]) ?? []
        return BasicAttributes(role: values[0] as? String, subrole: values[1] as? String, value: values[2] as? String, children: children)
    }

    // MARK: OCR fallback

    /// Captures and OCRs the viewport, scrolls ~80 % of it down, repeats until
    /// a page brings nothing new (the bottom) or the cap; then scrolls back.
    static func readByScrollingOCR(viewportCG: CGRect, title: String?, url: String?, maximumCharacters: Int,
                                   scroll: (CGPoint, Int) -> Void, isCancelled: () -> Bool) async -> ArticleDocument {
        guard viewportCG.width > 50, viewportCG.height > 50,
              let display = ScreenTopology.current().max(by: { $0.boundsCG.intersection(viewportCG).articleOverlapArea < $1.boundsCG.intersection(viewportCG).articleOverlapArea }) else {
            return ArticleDocument(text: "", source: .none)
        }
        let region = viewportCG.intersection(display.boundsCG)
        let scrollPoint = CGPoint(x: region.midX, y: region.midY)
        let pageStep = Int(region.height * 0.8)
        var pages: [[String]] = []
        var scrolledPixels = 0
        var totalCharacters = 0
        for pageIndex in 0..<maximumOCRPages {
            if isCancelled() { break }
            guard let capture = try? await ScreenCaptureService.captureNativeImage(of: display, regionCG: region, includesOwnWindows: false) else { break }
            let frame = CaptureFrame(display: display, screenNumber: 0, regionCG: capture.regionCG,
                                     native: PixelSize(width: capture.image.width, height: capture.image.height), model: nil)
            let lines = await OCREngine.recognizeLines(in: capture.image, frame: frame)
            let ordered = ArticleOCRMatcher.readingOrder(lines.map { ArticleOCRLine(text: $0.text, frameCG: $0.frameCG) }).map(\.text)
            pages.append(ordered)
            let assembled = ArticleTextAssembler.assembleOCRPages(pages, maximumCharacters: maximumCharacters)
            // Nothing new on this page (the scroll didn't move): the bottom of the article.
            if pageIndex > 0 && assembled.utf16Length <= totalCharacters + 10 { break }
            totalCharacters = assembled.utf16Length
            if assembled.isTruncated || pageIndex == maximumOCRPages - 1 { break }
            scroll(scrollPoint, pageStep)
            scrolledPixels += pageStep
            try? await Task.sleep(nanoseconds: 380_000_000)
        }
        // Back to where the owner was.
        if scrolledPixels > 0 {
            var remaining = scrolledPixels
            while remaining > 0 {
                let step = min(remaining, pageStep * 3)
                scroll(scrollPoint, -step)
                remaining -= step
                try? await Task.sleep(nanoseconds: 60_000_000)
            }
        }
        return ArticleTextAssembler.assembleOCRPages(pages, title: title, url: url, maximumCharacters: maximumCharacters)
    }
}

extension CGRect {
    var articleOverlapArea: CGFloat { isNull ? 0 : width * height }
}
