//
//  ArticleHighlightController.swift
//  leanring-buddy
//
//  P8 "highlight the important things and make notes": owns the last
//  article read, the highlighter strokes on it, the notes panel and saving.
//
//  Highlights. Each highlighted sentence is found in the article text
//  (ArticleSentenceMatcher), turned into ranges of its AXStaticText runs,
//  and measured per line (ArticleTextBounds: AXBoundsForRange, text
//  markers, or the run's frame). When the AX path can't place it (an OCR'd
//  page, a sentence the AX text doesn't have) the visible viewport is OCR'd
//  and the sentence fuzzy-matched across consecutive lines (one rect per
//  line). The strokes are drawn in a click-through overlay over the page's
//  viewport (ArticleHighlightCanvas).
//
//  Tracking. While highlights exist, a 10 Hz timer (and only then) reads
//  each highlight's anchor run's AXFrame: the page scrolled by however far
//  the anchor moved, so the strokes move with it. A run that changed size
//  (the page reflowed) is measured again (≤ every 0.75 s, off the main
//  thread). Highlights scrolled out of view become small numbered ticks in
//  the viewport's right margin (ArticleHighlightLayout). The overlay and the
//  panel hide while another app is in front, and come back with the browser.
//
//  Notes. A non-activating panel docked beside the article window
//  (ArticleNotesDock: the side with the most free space on that display,
//  never over the article column), re-docked when the window moves.
//  Clicking a note asks the page to scroll its highlight into view
//  (AXScrollToVisible on the run; a tagged scroll-wheel event as the
//  fallback) — never a click on the page, never an edit. Close removes the
//  panel and the highlights (the notes stay saveable).
//
//  Saving. "save my notes" / [NOTES:save] / the Save button →
//  ~/Clicky Notes/<title>.md and .pdf (ArticleNotesExport).
//

import AppKit
import ApplicationServices
import ClickyCore
import Combine
import SwiftUI

@MainActor
final class ArticleHighlightController {
    struct TrackedHighlight {
        var number: Int
        var sentence: String
        /// Where it is now (CG global).
        var geometry: ArticleHighlightGeometry
        /// Where it was when measured, and the anchor's frame then.
        var measuredGeometry: ArticleHighlightGeometry
        var anchorElement: AXUIElement?
        var anchorFrameAtMeasure: CGRect?
        /// The runs it covers (scroll-to-visible targets and remeasuring).
        var runRanges: [ArticleRunRange]
        var source: ArticleTextSource
        var method: String
        var isAnchorLost = false
        /// A fresh anchor was found after the old one vanished: hidden until measured again.
        var awaitsRemeasure = false
    }

    struct HighlightOutcome {
        var matchedCount: Int
        var unmatchedSentences: [String]
        var methods: [String]
    }

    private unowned let companionManager: CompanionManager
    private(set) var article: ArticleReadResult?
    private(set) var highlights: [TrackedHighlight] = []
    private(set) var notes: ArticleNotes?
    private var linkedHighlightNumberByNote: [Int: Int] = [:]
    private var savedPaths: [String] = []
    private var ownedFileNames: Set<String> = []
    private var lastSaveError: String?

    private let overlayModel = ArticleHighlightOverlayModel()
    private let notesModel = ArticleNotesPanelModel()
    private var overlayPanel: ArticleOverlayPanel?
    private var notesPanel: ArticleNotesPanel?
    private var trackingTimer: Timer?
    private var lastWindowFrameCG: CGRect?
    private var lastViewportCG: CGRect?
    private var lastRemeasureUptime: TimeInterval = 0
    private var isRemeasuring = false
    private var tickCount = 0
    private var lastURLCheckURL: String?
    private(set) var recentEvents: [String] = []

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
    }

    var isNotesPanelVisible: Bool { notesPanel?.isVisible ?? false }
    var hasNotes: Bool { notes != nil }

    // MARK: - Reading

    /// Reads the article in `target` (and remembers it for highlighting).
    func readArticle(target: ArticleWindowTarget, scroll: ((CGPoint, Int) -> Void)?, isCancelled: @escaping () -> Bool) async -> ArticleReadResult {
        let result = await ArticleReader.read(target: target, maximumCharacters: ClickySettings.articleMaximumCharacters, scroll: scroll, isCancelled: isCancelled)
        article = result
        note("read \(result.document.utf16Length) chars via \(result.document.source.rawValue) in \(result.milliseconds) ms: \(result.document.title ?? "untitled")")
        return result
    }

    /// The remembered article when it is of this window and recent, else a fresh read (no scrolling).
    private func articleForHighlighting(target: ArticleWindowTarget) async -> ArticleReadResult {
        if let article, article.target.processIdentifier == target.processIdentifier, article.target.windowNumber == target.windowNumber,
           Date().timeIntervalSince(article.readAt) < 15 * 60, article.document.utf16Length > 0 {
            // Same page still? (A navigation in the same window means a fresh read.)
            let currentURL = article.webAreaElement.flatMap(ArticleReader.urlString)
            if currentURL == nil || currentURL == article.document.url { return article }
        }
        return await readArticle(target: target, scroll: nil, isCancelled: { false })
    }

    // MARK: - Highlights

    /// Highlights these sentences on the article (replacing any earlier ones). Numbers follow the given order.
    func highlight(sentences: [String], target: ArticleWindowTarget) async -> HighlightOutcome {
        removeHighlights()
        let article = await articleForHighlighting(target: target)
        let document = article.document
        let runElements = article.runElements
        let webArea = article.webAreaElement
        let haystack = ArticleSentenceMatcher.Skeleton(document.text)
        let nodeTexts = runTextsByNodeIndex(article)

        // AX: match → run ranges → per-line rects, measured off the main thread.
        nonisolated struct Planned: @unchecked Sendable {
            var index: Int
            var runRanges: [ArticleRunRange]
            var elements: [AXUIElement]
            var texts: [String]
        }
        var planned: [Planned] = []
        for (index, sentence) in sentences.enumerated() where !runElements.isEmpty {
            guard let match = ArticleSentenceMatcher.match(sentence, in: haystack) else { continue }
            let runRanges = document.runRanges(for: match.utf16Range).filter { $0.nodeIndex < runElements.count }
            guard !runRanges.isEmpty else { continue }
            planned.append(Planned(index: index, runRanges: runRanges, elements: runRanges.map { runElements[$0.nodeIndex] },
                                   texts: runRanges.map { nodeTexts[$0.nodeIndex] ?? "" }))
        }
        let uncheckedWebArea = webArea.map(UncheckedAXElement.init)
        let measured: [(index: Int, rects: [CGRect], method: String, anchorFrame: CGRect?)] = await Task.detached(priority: .userInitiated) {
            planned.map { plan in
                var rects: [CGRect] = []
                var methods: Set<String> = []
                for (offset, runRange) in plan.runRanges.enumerated() {
                    let measurement = ArticleTextBounds.lineRects(element: plan.elements[offset], runText: plan.texts[offset], range: runRange.range,
                                                                  webArea: uncheckedWebArea?.element)
                    rects += measurement.lineRects
                    if let method = measurement.method { methods.insert(method.rawValue) }
                }
                let anchorFrame = plan.elements.first.flatMap(TypeForMeAccessibilityFrame.frameCG)
                return (plan.index, ArticleLineFragments.lineRects(fromWordRects: rects), methods.sorted().joined(separator: "+"), anchorFrame)
            }
        }.value

        var placedIndexes: Set<Int> = []
        for measurement in measured where !measurement.rects.isEmpty {
            guard let plan = planned.first(where: { $0.index == measurement.index }) else { continue }
            let geometry = ArticleHighlightGeometry(number: measurement.index + 1, lineRects: measurement.rects)
            if let anchor = plan.elements.first { AXUIElementSetMessagingTimeout(anchor, 0.1) }
            highlights.append(TrackedHighlight(number: measurement.index + 1, sentence: sentences[measurement.index], geometry: geometry, measuredGeometry: geometry,
                                               anchorElement: plan.elements.first, anchorFrameAtMeasure: measurement.anchorFrame, runRanges: plan.runRanges,
                                               source: .accessibility, method: measurement.method))
            placedIndexes.insert(measurement.index)
        }

        // OCR of the visible viewport for the rest.
        let remainingIndexes = sentences.indices.filter { !placedIndexes.contains($0) }
        if !remainingIndexes.isEmpty {
            let viewport = ArticleReader.viewportCG(webArea: webArea, windowFrameCG: currentWindowFrame(of: article.target) ?? article.target.windowFrameCG)
            let lines = await ocrLines(in: viewport)
            // A scroll anchor for OCR highlights: any run of the web area (the page moves as one).
            let scrollAnchor = runElements.first ?? webArea.flatMap(firstStaticText)
            let scrollAnchorFrame = scrollAnchor.flatMap(TypeForMeAccessibility.frameCG)
            for index in remainingIndexes {
                guard let rects = ArticleOCRMatcher.lineRects(for: sentences[index], lines: lines) else { continue }
                let geometry = ArticleHighlightGeometry(number: index + 1, lineRects: rects)
                highlights.append(TrackedHighlight(number: index + 1, sentence: sentences[index], geometry: geometry, measuredGeometry: geometry,
                                                   anchorElement: scrollAnchor, anchorFrameAtMeasure: scrollAnchorFrame, runRanges: [], source: .ocr, method: "ocr"))
                placedIndexes.insert(index)
            }
        }
        highlights.sort { $0.number < $1.number }
        let unmatched = sentences.indices.filter { !placedIndexes.contains($0) }.map { sentences[$0] }
        note("highlighted \(highlights.count) of \(sentences.count)\(unmatched.isEmpty ? "" : "; not found: \(unmatched.map { String($0.prefix(40)) })")")
        lastWindowFrameCG = nil
        startTrackingIfNeeded()
        tick()
        return HighlightOutcome(matchedCount: highlights.count, unmatchedSentences: unmatched, methods: Array(Set(highlights.map(\.method))).sorted())
    }

    private func runTextsByNodeIndex(_ article: ArticleReadResult) -> [Int: String] {
        var texts: [Int: String] = [:]
        for (nodeIndex, element) in article.runElements.enumerated() {
            texts[nodeIndex] = TypeForMeAccessibility.stringAttribute(kAXValueAttribute, of: element) ?? ""
        }
        return texts
    }

    private func firstStaticText(in webArea: AXUIElement) -> AXUIElement? {
        var stack: [AXUIElement] = [webArea]
        var visited = 0
        while let element = stack.popLast(), visited < 300 {
            visited += 1
            if TypeForMeAccessibility.stringAttribute(kAXRoleAttribute, of: element) == "AXStaticText" { return element }
            stack += TypeForMeAccessibility.elementArrayAttribute(kAXChildrenAttribute, of: element).reversed()
        }
        return nil
    }

    private func ocrLines(in viewport: CGRect) async -> [ArticleOCRLine] {
        guard viewport.width > 20, viewport.height > 20,
              let display = ScreenTopology.current().max(by: { $0.boundsCG.intersection(viewport).articleOverlapArea < $1.boundsCG.intersection(viewport).articleOverlapArea }) else { return [] }
        let region = viewport.intersection(display.boundsCG)
        guard !region.isNull, let capture = try? await ScreenCaptureService.captureNativeImage(of: display, regionCG: region, includesOwnWindows: false) else { return [] }
        let frame = CaptureFrame(display: display, screenNumber: 0, regionCG: capture.regionCG, native: PixelSize(width: capture.image.width, height: capture.image.height), model: nil)
        return await OCREngine.recognizeLines(in: capture.image, frame: frame).map { ArticleOCRLine(text: $0.text, frameCG: $0.frameCG) }
    }

    func removeHighlights() {
        highlights = []
        overlayModel.update(layout: ArticleHighlightLayout(strokes: [], ticks: []), originCG: .zero)
        overlayPanel?.orderOut(nil)
        stopTrackingIfIdle()
    }

    // MARK: - Notes

    /// Shows the notes panel beside the article and links each note to its highlight.
    func showNotes(_ newNotes: ArticleNotes, target: ArticleWindowTarget?) {
        var filled = newNotes
        if filled.title.isEmpty { filled.title = article?.document.title ?? target.flatMap { $0.windowElement }.flatMap { TypeForMeAccessibility.stringAttribute(kAXTitleAttribute, of: $0) } ?? "Article" }
        if filled.url == nil { filled.url = article?.document.url }
        notes = filled
        savedPaths = []
        lastSaveError = nil
        linkNotesToHighlights()
        if let target, article == nil || article?.target.windowNumber != target.windowNumber {
            // Notes without a read (the model wrote them from the screen): dock against this window.
            article = ArticleReadResult(document: ArticleDocument(text: "", title: filled.title, url: filled.url, source: .none), runElements: [],
                                        webAreaElement: nil, target: target, readAt: Date(), milliseconds: 0)
        }
        lastWindowFrameCG = nil
        openNotesPanel()
        startTrackingIfNeeded()
        tick()
        note("notes shown: \(filled.items.count) items, \(linkedHighlightNumberByNote.count) linked")
    }

    /// Note n ↔ the highlight whose sentence its quote matches (else the n-th highlight when the counts agree).
    private func linkNotesToHighlights() {
        linkedHighlightNumberByNote = [:]
        guard let notes else { return }
        var usedHighlightNumbers: Set<Int> = []
        for (index, item) in notes.items.enumerated() where !item.quote.isEmpty {
            let quoteSkeleton = ArticleSentenceMatcher.normalizedForComparison(item.quote)
            guard !quoteSkeleton.isEmpty else { continue }
            if let highlight = highlights.first(where: { highlight in
                guard !usedHighlightNumbers.contains(highlight.number) else { return false }
                let sentenceSkeleton = ArticleSentenceMatcher.normalizedForComparison(highlight.sentence)
                return sentenceSkeleton == quoteSkeleton || sentenceSkeleton.contains(quoteSkeleton) || quoteSkeleton.contains(sentenceSkeleton)
                    || ArticleSentenceMatcher.match(item.quote, in: highlight.sentence) != nil
            }) {
                linkedHighlightNumberByNote[index + 1] = highlight.number
                usedHighlightNumbers.insert(highlight.number)
            }
        }
        if linkedHighlightNumberByNote.isEmpty && notes.items.count == highlights.count {
            for (index, highlight) in highlights.enumerated() { linkedHighlightNumberByNote[index + 1] = highlight.number }
        }
        // Highlights take their note's number, so the ticks and the panel agree.
        var renumbered = highlights
        for (noteNumber, highlightNumber) in linkedHighlightNumberByNote {
            guard let highlightIndex = highlights.firstIndex(where: { $0.number == highlightNumber }) else { continue }
            renumbered[highlightIndex].number = noteNumber
            renumbered[highlightIndex].geometry.number = noteNumber
            renumbered[highlightIndex].measuredGeometry.number = noteNumber
        }
        let linkedHighlightIndexes = Set(linkedHighlightNumberByNote.values.compactMap { number in highlights.firstIndex { $0.number == number } })
        var nextFreeNumber = notes.items.count + 1
        for highlightIndex in renumbered.indices where !linkedHighlightIndexes.contains(highlightIndex) {
            renumbered[highlightIndex].number = nextFreeNumber
            renumbered[highlightIndex].geometry.number = nextFreeNumber
            renumbered[highlightIndex].measuredGeometry.number = nextFreeNumber
            nextFreeNumber += 1
        }
        highlights = renumbered.sorted { $0.number < $1.number }
        linkedHighlightNumberByNote = Dictionary(uniqueKeysWithValues: linkedHighlightNumberByNote.keys.map { ($0, $0) })
    }

    private func openNotesPanel() {
        guard let notes else { return }
        let panel = notesPanel ?? makeNotesPanel()
        notesPanel = panel
        notesModel.state = notesViewState(for: notes)
        positionNotesPanel(force: true)
        panel.orderFrontRegardless()
    }

    private func notesViewState(for notes: ArticleNotes) -> ArticleNotesViewState {
        let unmatched = Set((1...max(1, notes.items.count)).filter { linkedHighlightNumberByNote[$0] == nil })
        return ArticleNotesViewState(notes: notes, unmatchedNumbers: notes.items.isEmpty ? [] : unmatched, offscreenDirections: notesModel.state?.offscreenDirections ?? [:],
                                     savedPaths: savedPaths, statusLine: lastSaveError)
    }

    private func makeNotesPanel() -> ArticleNotesPanel {
        let panel = ArticleNotesPanel(contentRect: NSRect(x: 0, y: 0, width: ArticleNotesDock.preferredWidth, height: 520),
                                      styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Above the highlight overlay (which is at .floating).
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        let rootView = ArticleNotesPanelRootView(model: notesModel, actions: ArticleNotesViewActions(
            selectNote: { [weak self] number in self?.scrollToNote(number) },
            save: { [weak self] in
                guard let self else { return }
                let line = self.saveNotesAndDescribe()
                self.companionManager.speakCodeModeLine(line)
            },
            close: { [weak self] in self?.close() }
        ))
        let hostingView = ArticleFirstMouseHostingView(rootView: rootView)
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        return panel
    }

    /// Docks the panel beside the article window (only when the window moved, unless forced).
    private func positionNotesPanel(force: Bool) {
        guard let notesPanel else { return }
        guard let article, let windowFrame = currentWindowFrame(of: article.target) else {
            // No article window: the right edge of the display under the pointer.
            guard force else { return }
            let display = ScreenTopology.current().first { $0.boundsCG.contains(ScreenTopology.cg(fromAppKit: NSEvent.mouseLocation, flipH: ScreenTopology.mainDisplayHeight)) }
                ?? ScreenTopology.current().first
            guard let visible = display?.visibleCG else { return }
            let height = min(visible.height - 2 * ArticleNotesDock.gap, min(720, preferredNotesHeight()))
            let frame = CGRect(x: visible.maxX - ArticleNotesDock.preferredWidth - ArticleNotesDock.gap, y: visible.minY + ArticleNotesDock.gap,
                               width: ArticleNotesDock.preferredWidth, height: height)
            notesPanel.setFrame(ScreenTopology.appKit(fromCG: frame, flipH: ScreenTopology.mainDisplayHeight), display: true)
            return
        }
        guard force || windowFrame != lastDockedWindowFrame else { return }
        lastDockedWindowFrame = windowFrame
        let displays = ScreenTopology.current()
        guard let display = displays.max(by: { $0.boundsCG.intersection(windowFrame).articleOverlapArea < $1.boundsCG.intersection(windowFrame).articleOverlapArea }) else { return }
        let placement = ArticleNotesDock.placement(windowFrameCG: windowFrame, articleColumnCG: articleColumnCG(windowFrame: windowFrame), visibleFrameCG: display.visibleCG,
                                                   maximumHeight: min(720, preferredNotesHeight()))
        lastDockPlacement = placement
        let appKitFrame = ScreenTopology.appKit(fromCG: placement.frameCG, flipH: ScreenTopology.mainDisplayHeight)
        notesPanel.setFrame(appKitFrame, display: true)
    }

    private var lastDockedWindowFrame: CGRect?
    private(set) var lastDockPlacement: ArticleNotesDockPlacement?

    /// A rough content height: header + summary + ~70 pt per note + footer.
    private func preferredNotesHeight() -> CGFloat {
        guard let notes else { return 400 }
        return 150 + CGFloat(notes.summary.count / 45) * 16 + CGFloat(notes.items.count) * 78
    }

    /// The article column: the horizontal extent of the highlighted lines (else the viewport's middle).
    private func articleColumnCG(windowFrame: CGRect) -> CGRect? {
        let rects = highlights.flatMap(\.geometry.lineRects)
        guard let union = rects.reduce(nil as CGRect?, { partial, rect in partial.map { $0.union(rect) } ?? rect }) else { return nil }
        return CGRect(x: union.minX, y: windowFrame.minY, width: union.width, height: windowFrame.height)
    }

    // MARK: - Scroll to a note

    func scrollToNote(_ noteNumber: Int) {
        guard let highlight = highlights.first(where: { $0.number == noteNumber }) else { return }
        note("scroll to note \(noteNumber)")
        // AXScrollToVisible on the run (Chrome and WebKit scroll the page; nothing is clicked or edited).
        if let element = highlight.runRanges.first.flatMap({ article?.runElements.indices.contains($0.nodeIndex) == true ? article?.runElements[$0.nodeIndex] : nil }),
           AXUIElementPerformAction(element, "AXScrollToVisible" as CFString) == .success {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 250_000_000)
                self?.tick()
            }
            return
        }
        // Fallback: a tagged scroll-wheel event over the page, by how far the highlight is from the viewport's middle.
        guard let viewport = lastViewportCG, let bounds = highlight.geometry.bounds else { return }
        let distance = Int(bounds.midY - viewport.midY)
        guard abs(distance) > 8 else { return }
        Self.postScroll(at: CGPoint(x: viewport.midX, y: viewport.midY), pixels: distance)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            self?.tick()
        }
    }

    /// One tagged pixel scroll at a point (positive = content moves up, i.e. scroll down).
    static func postScroll(at pointCG: CGPoint, pixels: Int) {
        guard let event = CGEvent(scrollWheelEvent2Source: CGEventSource(stateID: .hidSystemState), units: .pixel, wheelCount: 1,
                                  wheel1: Int32(clamping: -pixels), wheel2: 0, wheel3: 0) else { return }
        SyntheticEvents.stamp(event)
        event.location = pointCG
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Save

    /// Saves the notes and returns the line to say.
    func saveNotesAndDescribe() -> String {
        guard let notes else {
            companionManager.showHandsFreeStatusMessage("No notes to save")
            return ArticleNotesFileNaming.nothingToSaveLine
        }
        do {
            let result = try ArticleNotesExport.save(notes, to: ArticleNotesFileNaming.defaultDirectory(), ownedFileNames: ownedFileNames,
                                                     savesPDF: ClickySettings.articleSavesPDF)
            savedPaths = result.paths
            ownedFileNames.formUnion(result.paths.map { ($0 as NSString).lastPathComponent })
            lastSaveError = nil
            notesModel.state = notesViewState(for: notes)
            companionManager.showHandsFreeStatusMessage("Saved notes to ~/Clicky Notes")
            note("saved \(result.paths)")
            return ArticleNotesFileNaming.savedLine(markdownFileName: result.markdownURL.lastPathComponent, savedPDF: result.pdfURL != nil)
        } catch {
            lastSaveError = "Couldn't save: \(error.localizedDescription)"
            notesModel.state = notesViewState(for: notes)
            note("save failed: \(error)")
            return ArticleNotesFileNaming.failedLine
        }
    }

    // MARK: - Close

    func close() {
        removeHighlights()
        notesPanelHiddenForFocus = false
        notesPanel?.orderOut(nil)
        stopTrackingIfIdle()
        note("closed")
    }

    // MARK: - Tracking

    private func startTrackingIfNeeded() {
        guard trackingTimer == nil, ArticleHighlightCadence.shouldTrack(highlightCount: max(highlights.count, notes == nil ? 0 : 1), isPanelOrOverlayShown: true) else { return }
        let timer = Timer(timeInterval: ArticleHighlightCadence.trackingInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        trackingTimer = timer
    }

    private func stopTrackingIfIdle() {
        let panelShown = notesPanel?.isVisible ?? false
        guard highlights.isEmpty && !panelShown else { return }
        trackingTimer?.invalidate()
        trackingTimer = nil
    }

    private func currentWindowFrame(of target: ArticleWindowTarget) -> CGRect? {
        if let windowElement = target.windowElement, let frame = TypeForMeAccessibility.frameCG(of: windowElement), frame.width > 0 { return frame }
        // The AX window may be gone (closed): the CG window list says.
        guard let info = (CGWindowListCreateDescriptionFromArray([NSNumber(value: target.windowNumber)] as CFArray) as? [[String: Any]])?.first,
              let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary, let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
              (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false else { return nil }
        return bounds
    }

    /// 10 Hz while highlights or the panel exist: follow scrolling and window moves, hide behind other apps.
    private func tick() {
        tickCount += 1
        guard let article else { return }
        let panelWanted = notes != nil && (notesPanel?.isVisible ?? false || notesPanelHiddenForFocus)
        guard !highlights.isEmpty || panelWanted else {
            stopTrackingIfIdle()
            return
        }
        guard let windowFrame = currentWindowFrame(of: article.target) else {
            // The window closed or minimised.
            setOnScreen(false)
            return
        }
        // Behind another app: hide (Clicky in front, e.g. its panel, still counts as the browser's turn).
        let frontmostProcessIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let isArticleAppInFront = frontmostProcessIdentifier == article.target.processIdentifier || frontmostProcessIdentifier == getpid()
        setOnScreen(isArticleAppInFront)
        guard isArticleAppInFront else { return }

        // Navigated away: the highlights belong to the old page.
        if tickCount % 10 == 0, let webArea = article.webAreaElement {
            let url = ArticleReader.urlString(of: webArea)
            if let originalURL = article.document.url, let url, url != originalURL {
                note("page changed to \(url): highlights cleared")
                removeHighlights()
            }
        }

        if cachedViewportElementArticle !== article {
            cachedViewportElement = ArticleReader.viewportElement(webArea: article.webAreaElement)
            if let cachedViewportElement { AXUIElementSetMessagingTimeout(cachedViewportElement, 0.1) }
            cachedViewportElementArticle = article
        }
        let viewport = article.webAreaElement == nil ? ArticleReader.viewportCG(webArea: nil, windowFrameCG: windowFrame)
            : ArticleReader.viewportCG(viewportElement: cachedViewportElement, windowFrameCG: windowFrame)
        let windowDelta = lastWindowFrameCG.map { CGVector(dx: windowFrame.minX - $0.minX, dy: windowFrame.minY - $0.minY) } ?? .zero
        lastWindowFrameCG = windowFrame
        lastViewportCG = viewport

        var needsRemeasure: [Int] = []
        for index in highlights.indices {
            if highlights[index].awaitsRemeasure {
                needsRemeasure.append(index)
                continue
            }
            if let anchor = highlights[index].anchorElement, let measuredAnchorFrame = highlights[index].anchorFrameAtMeasure {
                guard let anchorFrame = TypeForMeAccessibilityFrame.frameCG(of: anchor), anchorFrame.width > 0 || anchorFrame.height > 0 else {
                    highlights[index].isAnchorLost = true
                    needsRemeasure.append(index)
                    continue
                }
                highlights[index].isAnchorLost = false
                if highlights[index].source == .accessibility && ArticleHighlightLayout.needsRemeasure(originalAnchorFrame: measuredAnchorFrame, currentAnchorFrame: anchorFrame) {
                    needsRemeasure.append(index)
                }
                let delta = ArticleHighlightLayout.trackingDelta(originalAnchorFrame: measuredAnchorFrame, currentAnchorFrame: anchorFrame)
                highlights[index].geometry = highlights[index].measuredGeometry.translated(by: delta)
            } else if windowDelta != .zero {
                // No anchor (OCR on a page without AX text): it moves with the window only.
                highlights[index].geometry = highlights[index].geometry.translated(by: windowDelta)
            }
        }
        if !needsRemeasure.isEmpty { remeasure(indexes: needsRemeasure) }

        let visibleHighlights = highlights.filter { !$0.isAnchorLost && !$0.awaitsRemeasure }.map(\.geometry)
        let layout = ArticleHighlightLayout.layout(highlights: visibleHighlights, viewport: viewport)
        updateOverlay(layout: layout, viewport: viewport)

        if let notes {
            var directions: [Int: ArticleHighlightTickDirection] = [:]
            for tick in layout.ticks { directions[tick.number] = tick.direction }
            if notesModel.state?.offscreenDirections != directions {
                var state = notesViewState(for: notes)
                state.offscreenDirections = directions
                notesModel.state = state
            }
            positionNotesPanel(force: false)
        }
    }

    private var notesPanelHiddenForFocus = false
    private var cachedViewportElement: AXUIElement?
    private weak var cachedViewportElementArticle: ArticleReadResult?

    private func setOnScreen(_ isOnScreen: Bool) {
        if isOnScreen {
            if notesPanelHiddenForFocus, notes != nil {
                notesPanel?.orderFrontRegardless()
                notesPanelHiddenForFocus = false
            }
        } else {
            // Only the highlights follow the article window; the notes stay up until the owner closes them.
            overlayPanel?.orderOut(nil)
        }
    }

    private func updateOverlay(layout: ArticleHighlightLayout, viewport: CGRect) {
        guard !layout.strokes.isEmpty || !layout.ticks.isEmpty else {
            overlayPanel?.orderOut(nil)
            overlayModel.update(layout: layout, originCG: viewport.origin)
            return
        }
        let panel = overlayPanel ?? makeOverlayPanel()
        overlayPanel = panel
        let appKitFrame = ScreenTopology.appKit(fromCG: viewport, flipH: ScreenTopology.mainDisplayHeight)
        if panel.frame != appKitFrame { panel.setFrame(appKitFrame, display: false) }
        overlayModel.update(layout: layout, originCG: viewport.origin)
        if !panel.isVisible { panel.orderFrontRegardless() }
        // Keep the notes panel above the strokes.
        if let notesPanel, notesPanel.isVisible { notesPanel.orderFrontRegardless() }
    }

    private func makeOverlayPanel() -> ArticleOverlayPanel {
        let panel = ArticleOverlayPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        let hostingView = NSHostingView(rootView: ArticleHighlightOverlayRootView(model: overlayModel))
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        return panel
    }

    /// Measures these highlights again (the page reflowed, or the anchor run was re-created), off the main thread.
    private func remeasure(indexes: [Int]) {
        let now = ProcessInfo.processInfo.systemUptime
        guard !isRemeasuring, now - lastRemeasureUptime >= ArticleHighlightCadence.minimumRemeasureInterval, let article else { return }
        lastRemeasureUptime = now
        isRemeasuring = true
        let lostSentences = indexes.filter { highlights[$0].isAnchorLost }.map { (number: highlights[$0].number, sentence: highlights[$0].sentence) }
        let reflowed = indexes.filter { !highlights[$0].isAnchorLost && highlights[$0].source == .accessibility }.map { index in
            (number: highlights[index].number, runRanges: highlights[index].runRanges)
        }
        nonisolated struct Job: @unchecked Sendable {
            var number: Int
            var elements: [AXUIElement]
            var texts: [String]
            var ranges: [Range<Int>]
        }
        let jobs: [Job] = reflowed.map { item in
            let elements = item.runRanges.compactMap { article.runElements.indices.contains($0.nodeIndex) ? article.runElements[$0.nodeIndex] : nil }
            return Job(number: item.number, elements: elements, texts: elements.map { TypeForMeAccessibility.stringAttribute(kAXValueAttribute, of: $0) ?? "" },
                       ranges: item.runRanges.map(\.range))
        }
        let uncheckedWebArea = article.webAreaElement.map(UncheckedAXElement.init)
        Task { [weak self] in
            let results: [(number: Int, rects: [CGRect], anchorFrame: CGRect?)] = await Task.detached(priority: .utility) {
                jobs.map { job in
                    var rects: [CGRect] = []
                    for (offset, element) in job.elements.enumerated() where offset < job.ranges.count {
                        rects += ArticleTextBounds.lineRects(element: element, runText: job.texts[offset], range: job.ranges[offset], webArea: uncheckedWebArea?.element).lineRects
                    }
                    return (job.number, ArticleLineFragments.lineRects(fromWordRects: rects), job.elements.first.flatMap(TypeForMeAccessibilityFrame.frameCG))
                }
            }.value
            guard let self else { return }
            for result in results where !result.rects.isEmpty {
                guard let index = self.highlights.firstIndex(where: { $0.number == result.number }) else { continue }
                let geometry = ArticleHighlightGeometry(number: result.number, lineRects: result.rects)
                self.highlights[index].geometry = geometry
                self.highlights[index].measuredGeometry = geometry
                self.highlights[index].anchorFrameAtMeasure = result.anchorFrame
                self.highlights[index].awaitsRemeasure = false
            }
            self.isRemeasuring = false
            // Lost anchors (the page re-rendered its text): read the page again and re-place those sentences.
            if !lostSentences.isEmpty { await self.replaceLostHighlights(lostSentences, target: article.target) }
        }
    }

    private func replaceLostHighlights(_ lost: [(number: Int, sentence: String)], target: ArticleWindowTarget) async {
        guard ProcessInfo.processInfo.systemUptime - lastLostRereadUptime > 3 else { return }
        lastLostRereadUptime = ProcessInfo.processInfo.systemUptime
        let fresh = await readArticle(target: target, scroll: nil, isCancelled: { false })
        guard !fresh.runElements.isEmpty else { return }
        let haystack = ArticleSentenceMatcher.Skeleton(fresh.document.text)
        for item in lost {
            guard let index = highlights.firstIndex(where: { $0.number == item.number }),
                  let match = ArticleSentenceMatcher.match(item.sentence, in: haystack) else { continue }
            let runRanges = fresh.document.runRanges(for: match.utf16Range).filter { $0.nodeIndex < fresh.runElements.count }
            guard let firstRun = runRanges.first else { continue }
            highlights[index].runRanges = runRanges
            highlights[index].anchorElement = fresh.runElements[firstRun.nodeIndex]
            highlights[index].isAnchorLost = false
            highlights[index].awaitsRemeasure = true
            highlights[index].source = .accessibility
        }
        // Measured again on the next tick.
        lastRemeasureUptime = 0
    }

    private var lastLostRereadUptime: TimeInterval = 0

    // MARK: - Status (debug inbox)

    func articleReadSnapshot() -> [String: Any] {
        guard let article else { return ["read": false] }
        return [
            "read": true,
            "length": article.document.utf16Length,
            "title": article.document.title ?? NSNull(),
            "url": article.document.url ?? NSNull(),
            "source": article.document.source.rawValue,
            "truncated": article.document.isTruncated,
            "runs": article.runElements.count,
            "milliseconds": article.milliseconds,
            "app": article.target.applicationName ?? NSNull(),
            "preview": String(article.document.text.prefix(300))
        ]
    }

    func notesStatusSnapshot() -> [String: Any] {
        [
            "panelVisible": notesPanel?.isVisible ?? false,
            "hiddenWhileAnotherAppIsInFront": notesPanelHiddenForFocus,
            "title": notes?.title ?? NSNull(),
            "url": notes?.url ?? NSNull(),
            "summary": notes?.summary ?? NSNull(),
            "items": notes?.items.map { ["note": $0.note, "quote": $0.quote] } ?? [],
            "linkedNotes": linkedHighlightNumberByNote.keys.sorted(),
            "highlights": highlights.map { highlight -> [String: Any] in
                [
                    "number": highlight.number, "sentence": String(highlight.sentence.prefix(80)), "source": highlight.source.rawValue, "method": highlight.method,
                    "lines": highlight.geometry.lineRects.map { [$0.minX, $0.minY, $0.width, $0.height].map { Double($0.rounded()) } },
                    "anchorLost": highlight.isAnchorLost
                ]
            },
            "dockSide": lastDockPlacement?.side.rawValue ?? NSNull(),
            "dockFrame": lastDockPlacement.map { [$0.frameCG.minX, $0.frameCG.minY, $0.frameCG.width, $0.frameCG.height].map { Double($0) } } ?? NSNull(),
            "tracking": trackingTimer != nil,
            "savedPaths": savedPaths,
            "saveError": lastSaveError ?? NSNull(),
            "recentEvents": recentEvents
        ]
    }

    private func note(_ line: String) {
        print("📰 Article: \(line)")
        recentEvents.append(line)
        if recentEvents.count > 30 { recentEvents.removeFirst(recentEvents.count - 30) }
    }
}

// MARK: - Panels and models

final class ArticleOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class ArticleNotesPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Clicks on the panel work on the first click, without activating Clicky.
final class ArticleFirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class ArticleHighlightOverlayModel: ObservableObject {
    @Published private(set) var layout = ArticleHighlightLayout(strokes: [], ticks: [])
    @Published private(set) var originCG: CGPoint = .zero

    /// Publishes only real changes (never the same value on every tick).
    func update(layout newLayout: ArticleHighlightLayout, originCG newOrigin: CGPoint) {
        if newLayout != layout { layout = newLayout }
        if newOrigin != originCG { originCG = newOrigin }
    }
}

@MainActor
final class ArticleNotesPanelModel: ObservableObject {
    @Published var state: ArticleNotesViewState?
}

private struct ArticleHighlightOverlayRootView: View {
    @ObservedObject var model: ArticleHighlightOverlayModel

    var body: some View {
        ArticleHighlightCanvas(layout: model.layout, originCG: model.originCG)
    }
}

private struct ArticleNotesPanelRootView: View {
    @ObservedObject var model: ArticleNotesPanelModel
    let actions: ArticleNotesViewActions

    var body: some View {
        if let state = model.state {
            ArticleNotesView(state: state, actions: actions, animatesWriting: true)
        } else {
            Color.clear
        }
    }
}
