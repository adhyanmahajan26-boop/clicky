//
//  ResearchController.swift
//  leanring-buddy
//
//  P9 background research. "research these links" / "send these 3 links to
//  helpers" / "research black holes for me": Clicky collects the links (said,
//  on the page in front, or from a DuckDuckGo search), fetches each page
//  itself with an ephemeral URLSession (no cookies, honest user agent, 2 MB
//  and 15 s limits, public http(s) only), extracts the readable text, gives
//  one page to each Haiku helper (the text is data inside <page> tags; no
//  tools), then one Sonnet pass writes a brief with [n] citations. It all runs
//  in the background: the owner keeps working; the Agents dashboard and the
//  notch show the helpers; when done Clicky says "Your research is ready"
//  (only when it isn't mid-turn and Safari isn't in front) and shows the brief
//  in the notes panel, saved to ~/Clicky Notes/Research.
//

import AppKit
import ClickyCore
import Foundation

@MainActor
final class ResearchController: CompanionActivitySource {
    private weak var companionManager: CompanionManager?
    /// Research helpers orbit the spark like the brain's own workers.
    private(set) var workers: [CompanionWorkerActivity] = []
    var coordinatorIsThinking: Bool { false }
    var onActivityChanged: (() -> Void)?

    private func setHelper(_ agentID: String, title: String, isWorking: Bool) {
        workers.removeAll { $0.id == agentID }
        if isWorking { workers.append(CompanionWorkerActivity(id: agentID, workerTitle: title, isWorking: true)) }
        onActivityChanged?()
    }
    private var researchTask: Task<Void, Never>?
    private var parentAgentID: String?
    /// The card this run answers to, when it's a job for Clicky's team.
    private var teamJobID: String?
    /// For researchStatus (tests): the last run's outcome.
    private(set) var lastStatus: [String: Any] = ["state": "idle"]

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
    }

    var isRunning: Bool { researchTask != nil }
    /// Bumped by every start, so a caller waiting on one run can tell when another took its place.
    private(set) var runNumber = 0

    /// A research request or "cancel research" in the owner's words; true when handled here.
    func handleSpokenTranscript(_ transcript: String, speaks: Bool) -> Bool {
        if ResearchTrigger.isCancel(transcript) {
            say(cancel() ? "Research cancelled." : "No research is running.", speaks: speaks)
            return true
        }
        if ResearchTrigger.isHandover(transcript) {
            say(BotsStore.shared.handResearchToCEO() ? "Sent the research to Theo." : "There's no finished research to send yet.", speaks: speaks)
            return true
        }
        guard let request = ResearchTrigger.parse(transcript) else { return false }
        start(request, speaks: speaks, reportsToCEO: ResearchTrigger.wantsItHandedOver(transcript))
        return true
    }

    @discardableResult
    func cancel() -> Bool {
        guard let researchTask else { return false }
        researchTask.cancel()
        self.researchTask = nil
        workers.removeAll()
        onActivityChanged?()
        BotsStore.shared.researchEnded(teamJobID, text: "Stopped before it finished.", succeeded: false)
        teamJobID = nil
        companionManager?.agentsCenter.finish(parentAgentID, status: .cancelled)
        lastStatus["state"] = "cancelled"
        return true
    }

    /// `allowsLocalHostForTests`: the debug inbox's researchStart may use 127.0.0.1 test pages.
    /// `reportsToCEO`: Theo asked for it, so the brief goes to his chat too.
    func start(_ request: ResearchRequest, speaks: Bool, allowsLocalHostForTests: Bool = false, reportsToCEO: Bool = false) {
        guard let companionManager else { return }
        cancel()
        runNumber += 1
        // Researcher does it when there is one (it lights up, and its chat shows the work); otherwise hidden helpers.
        teamJobID = BotsStore.shared.researchStarted(question: request.question, reportsToCEO: reportsToCEO)
        let helperModel = BotsStore.shared.researcherClaudeModel
        let briefModel = BotsStore.shared.teamBot(.researcher) == nil ? ClickyModels.main : helperModel
        let jobID = teamJobID
        let topic: String
        switch request.source {
        case .topic(let text): topic = text
        case .links: topic = Self.shortTopic(from: request.question)
        }
        let agentsCenter = companionManager.agentsCenter
        let parentAgentID = agentsCenter.begin(kind: .worker, title: "Research: \(topic)", model: CompanionWorkerRunner.workerClaudeModel)
        self.parentAgentID = parentAgentID
        agentsCenter.setCancelHandler(parentAgentID) { [weak self] in self?.cancel() }
        lastStatus = ["state": "collecting", "topic": topic]
        let needsScreenLinks: Bool
        if case .links(let count) = request.source, request.namedURLs.count < count { needsScreenLinks = true } else { needsScreenLinks = false }

        researchTask = Task { [weak self] in
            guard let self else { return }
            // Chrome builds a page's accessibility tree on the first query: a fresh tab can show no links, so look again.
            var screenPage: ScreenLinks?
            if needsScreenLinks {
                for attempt in 0..<8 {
                    screenPage = await Self.visibleLinksOnScreen(allowsLocalHostForTests: allowsLocalHostForTests)
                    if screenPage != nil || Task.isCancelled { break }
                    print("🔎 Research: no visible links yet (try \(attempt + 1)), looking again")
                    try? await Task.sleep(nanoseconds: 800_000_000)
                }
            }
            var urls = request.namedURLs
            switch request.source {
            case .links(let count):
                if let screenPage {
                    let picked = await Self.pickLinks(screenPage, request: request.question, count: count - urls.count)
                    if let pageTitle = screenPage.pageTitle, !pageTitle.isEmpty {
                        let pageName = pageTitle.replacingOccurrences(of: " - Google Chrome", with: "").replacingOccurrences(of: " - Google Search", with: "")
                        self.lastStatus["topic"] = "Links from \(pageName.prefix(50))"
                    }
                    agentsCenter.log(parentAgentID, "picked \(picked.count) of \(screenPage.candidates.count) visible links (\(screenPage.pickMethod))")
                    for url in picked where !urls.contains(url) && urls.count < count { urls.append(url) }
                    // A picker that came up short: the next links on screen make up the number.
                    if urls.count < count {
                        for candidate in ResearchLinkPicker.heuristicPick(screenPage.candidates, count: screenPage.candidates.count, pageURL: screenPage.pageURL)
                        where !urls.contains(candidate.url) && urls.count < count { urls.append(candidate.url) }
                    }
                    // Chrome only shows part of a long results page to the outside: the same search makes up the rest.
                    if urls.count < count, let pageURL = screenPage.pageURL, ResearchURLPolicy.isSearchEngine(pageURL),
                       let query = URLComponents(url: pageURL, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value {
                        for url in await Self.searchResults(for: query, maximum: count + 2) where !urls.contains(url) && urls.count < count { urls.append(url) }
                    }
                }
            case .topic(let text):
                urls += await Self.searchResults(for: text, maximum: 3)
            }
            guard !urls.isEmpty else {
                self.finish(parentAgentID, status: .failed, line: "I couldn't find any links to research.", speaks: speaks)
                return
            }
            self.say("Researching \(urls.count) link\(urls.count == 1 ? "" : "s") in the background.", speaks: speaks)
            BotsStore.shared.researchProgress(jobID, line: "Reading " + urls.prefix(ResearchTrigger.maximumLinks).map { $0.host ?? $0.absoluteString }.joined(separator: ", ") + ".")
            self.lastStatus = ["state": "reading", "topic": topic, "urls": urls.map(\.absoluteString)]
            agentsCenter.log(parentAgentID, "links: " + urls.map(\.absoluteString).joined(separator: ", "))

            let reports = await self.runHelpers(urls: Array(urls.prefix(ResearchTrigger.maximumLinks)), question: request.question,
                                                parentAgentID: parentAgentID, allowsLocalHostForTests: allowsLocalHostForTests, model: helperModel, jobID: jobID)
            guard !Task.isCancelled else { return }
            self.lastStatus["state"] = "writing"
            var brief = await Self.synthesize(question: request.question, reports: reports, model: briefModel)
            guard !Task.isCancelled else { return }
            if request.question.range(of: #"(?i)\b(photos?|images?|pictures?|pics?)\b"#, options: .regularExpression) != nil {
                let photos = await Self.photoLinks(from: urls, topic: topic)
                brief += photos.isEmpty ? "\n\nI couldn't find any usable photos on those pages." : "\n\n**Photos from these pages:**\n" + photos.map { "- \($0)" }.joined(separator: "\n")
            }
            self.present(topic: self.lastStatus["topic"] as? String ?? topic, question: request.question, brief: brief, reports: reports, parentAgentID: parentAgentID, speaks: speaks)
        }
    }

    // MARK: - Helpers

    /// Full-size, freely licensed pictures on the subject, from Wikimedia Commons.
    private static func commonsPhotos(for topic: String) async -> [String] {
        let words = topic.lowercased().replacingOccurrences(of: #"\b(research|how|for me|and|get|good|photos?|images?|pictures?|of them|of|the|form|forms|about)\b"#, with: " ", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
        var components = URLComponents(string: "https://commons.wikimedia.org/w/api.php")
        components?.queryItems = [("action", "query"), ("format", "json"), ("generator", "search"), ("gsrnamespace", "6"), ("gsrlimit", "8"),
                                  ("gsrsearch", "\(words) filetype:bitmap"), ("prop", "imageinfo"), ("iiprop", "url")].map { URLQueryItem(name: $0.0, value: $0.1) }
        guard !words.isEmpty, let url = components?.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Theo/1.0 (macOS assistant)", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pages = (object["query"] as? [String: Any])?["pages"] as? [String: [String: Any]] else { return [] }
        return pages.values.compactMap { (($0["imageinfo"] as? [[String: Any]])?.first?["url"]) as? String }.prefix(4).map { $0 }
    }

    /// Each page's own lead image and its first few pictures.
    private static func photoLinks(from urls: [URL], topic: String) async -> [String] {
        var found: [String] = await commonsPhotos(for: topic)
        for url in urls.prefix(ResearchTrigger.maximumLinks) {
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
            guard let (data, _) = try? await URLSession.shared.data(for: request), let html = String(data: data, encoding: .utf8) else { continue }
            let patterns = [#"<meta[^>]+property=[\"']og:image[\"'][^>]+content=[\"']([^\"']+)"#, #"<img[^>]+src=[\"']([^\"']+\.(?:jpe?g|png|webp)[^\"']*)"#]
            var fromThisPage = 0
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
                for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) where fromThisPage < 3 {
                    guard let range = Range(match.range(at: 1), in: html), let link = URL(string: String(html[range]), relativeTo: url)?.absoluteString,
                          link.hasPrefix("http"), !["logo", "icon", "ai-image", "avatar", "-150x", "-300x"].contains(where: link.lowercased().contains), !found.contains(link) else { continue }
                    found.append(link)
                    fromThisPage += 1
                }
            }
        }
        return Array(found.prefix(8))
    }

    private struct Report {
        let index: Int
        let url: URL
        let title: String?
        let text: String
        let succeeded: Bool
    }

    private func runHelpers(urls: [URL], question: String, parentAgentID: String, allowsLocalHostForTests: Bool, model: String, jobID: String?) async -> [Report] {
        guard let agentsCenter = companionManager?.agentsCenter else { return [] }
        let jobs = urls.enumerated().map { (index: $0.offset + 1, url: $0.element) }
        return await withTaskGroup(of: Report.self) { group in
            for job in jobs {
                let helperTitle = "[\(job.index)] \(job.url.host ?? job.url.absoluteString)"
                let agentID = agentsCenter.begin(kind: .worker, title: helperTitle,
                                                 model: CompanionWorkerRunner.workerClaudeModel, parentID: parentAgentID)
                setHelper(agentID, title: helperTitle, isWorking: true)
                group.addTask { [weak self] in
                    defer { Task { @MainActor in self?.setHelper(agentID, title: helperTitle, isWorking: false) } }
                    var page = await Self.fetchReadableText(job.url, allowsLocalHostForTests: allowsLocalHostForTests)
                    // Blocked or a shell of a page: Researcher reads it in the owner's own browser, on a Studio tile.
                    let useBrowser = await MainActor.run { BrowserResearcher.shared.isReady && (BrowserResearchPolicy.needsBrowser(text: page?.text) || BrowserResearcher.alwaysForTests) }
                    if useBrowser {
                        switch await BrowserResearcher.shared.read(job.url) {
                        case .page(let title, let text):
                            page = (title, text)
                            await MainActor.run { agentsCenter.log(agentID, "read in your browser on a Studio screen") }
                        case .skipped(let reason):
                            await MainActor.run { agentsCenter.log(agentID, reason) }
                        }
                    }
                    guard let page, !page.text.isEmpty, !ReadableText.looksWalled(page.text), !BrowserResearchPolicy.isHumanCheck(title: page.title, text: page.text) else {
                        await MainActor.run { agentsCenter.finish(agentID, status: .failed, errorDescription: "couldn't read the page") }
                        return Report(index: job.index, url: job.url, title: page?.title, text: "unreadable (empty, blocked or a sign-in wall)", succeeded: false)
                    }
                    do {
                        let turn = try await Self.readPage(question: question, url: job.url, page: page, model: model)
                        await MainActor.run {
                            agentsCenter.log(agentID, turn.text)
                            agentsCenter.finish(agentID, status: .done, usage: turn.usageSummary)
                            BotsStore.shared.researchProgress(jobID, line: "**\(job.url.host ?? job.url.absoluteString)**: " + String(turn.text.prefix(280)))
                        }
                        return Report(index: job.index, url: job.url, title: page.title, text: turn.text, succeeded: true)
                    } catch {
                        let status: AgentStatus = Task.isCancelled ? .cancelled : .failed
                        await MainActor.run { agentsCenter.finish(agentID, status: status, errorDescription: "\(error)") }
                        return Report(index: job.index, url: job.url, title: page.title, text: "the helper failed", succeeded: false)
                    }
                }
            }
            var reports: [Report] = []
            for await report in group { reports.append(report) }
            return reports.sorted { $0.index < $1.index }
        }
    }

    /// One helper reading one page; a stalled helper gets one more try before the page counts as failed.
    private static func readPage(question: String, url: URL, page: (title: String?, text: String), model: String) async throws -> ClaudeTurnResult {
        let contentBlocks: [ClaudeContentBlock] = [.text(ResearchPrompts.workerPrompt(question: question, url: url, title: page.title, text: page.text))]
        do {
            return try await ClaudeCodeBridge(model: model).runTurn(
                systemPromptFileName: "research-worker-prompt.md", systemPrompt: ResearchPrompts.workerSystemPrompt, contentBlocks: contentBlocks)
        } catch ClaudeCodeBridgeError.claudeCodeStalled {
            try Task.checkCancellation()
            return try await ClaudeCodeBridge(model: model).runTurn(
                systemPromptFileName: "research-worker-prompt.md", systemPrompt: ResearchPrompts.workerSystemPrompt, contentBlocks: contentBlocks)
        }
    }

    private static func synthesize(question: String, reports: [Report], model: String) async -> String {
        let prompt = ResearchPrompts.synthesisPrompt(question: question, reports: reports.map { ($0.index, $0.url, $0.title, $0.text) })
        do {
            let turn = try await ClaudeCodeBridge(model: model).runTurn(systemPromptFileName: "research-synthesis-prompt.md",
                                                                           systemPrompt: ResearchPrompts.synthesisSystemPrompt,
                                                                           contentBlocks: [.text(prompt)])
            return turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            // Without the synthesis, the helpers' own summaries still make a brief.
            return reports.map { "[\($0.index)] \($0.text.split(separator: "\n").first.map(String.init) ?? "")" }.joined(separator: "\n")
        }
    }

    private func present(topic: String, question: String, brief: String, reports: [Report], parentAgentID: String, speaks: Bool) {
        guard let companionManager else { return }
        let items = reports.map { report in
            ArticleNoteItem(note: "[\(report.index)] \(report.title ?? report.url.host ?? "source")\(report.succeeded ? "" : " (unreadable)")",
                            quote: report.url.absoluteString)
        }
        let notes = ArticleNotes(title: "Research: \(topic)", url: nil, summary: brief, items: items)
        var savedPath: String?
        let directory = ArticleNotesFileNaming.defaultDirectory().appendingPathComponent("Research", isDirectory: true)
        if let result = try? ArticleNotesExport.save(notes, to: directory, ownedFileNames: [], savesPDF: ClickySettings.articleSavesPDF) {
            savedPath = result.markdownURL.path
        }
        companionManager.agentsCenter.log(parentAgentID, brief)
        companionManager.agentsCenter.finish(parentAgentID, status: .done)
        lastStatus = ["state": "done", "topic": topic, "brief": brief, "savedPath": savedPath ?? NSNull(),
                      "sources": reports.map { ["index": $0.index, "url": $0.url.absoluteString, "ok": $0.succeeded] }]
        researchTask = nil
        let sources = reports.filter(\.succeeded).map { "[\($0.index)] \($0.title ?? $0.url.host ?? "source"): \($0.url.absoluteString)" }.joined(separator: "\n")
        BotsStore.shared.researchEnded(teamJobID, text: brief + (sources.isEmpty ? "" : "\n\n" + sources), succeeded: true, savedPath: savedPath)
        teamJobID = nil
        // A research brief belongs to no article on screen: it opens on Theo's own display.
        companionManager.articleController.showNotes(notes, target: nil)
        companionManager.showHandsFreeStatusMessage("Research ready")
        // Spoken only when Clicky isn't mid-turn and Safari (his Netflix) isn't in front.
        let safariInFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.Safari"
        if companionManager.voiceState == .idle && !safariInFront { say("Your research is ready.", speaks: speaks) }
    }

    private func finish(_ agentID: String, status: AgentStatus, line: String, speaks: Bool) {
        companionManager?.agentsCenter.finish(agentID, status: status)
        lastStatus["state"] = status == .failed ? "failed" : "done"
        researchTask = nil
        BotsStore.shared.researchEnded(teamJobID, text: line, succeeded: status != .failed)
        teamJobID = nil
        say(line, speaks: speaks)
    }

    private func say(_ line: String, speaks: Bool) {
        guard let companionManager else { return }
        companionManager.showHandsFreeStatusMessage(line)
        if speaks { companionManager.speakCodeModeLine(line) }
    }

    // MARK: - Links and fetching

    static func shortTopic(from question: String) -> String {
        let words = question.split(separator: " ").prefix(6).joined(separator: " ")
        return words.isEmpty ? "links" : words
    }

    /// The visible links of the page in front (the browser window the article reader would pick).
    struct ScreenLinks {
        var candidates: [ResearchLinkCandidate]
        var windowFrame: CGRect
        var pageTitle: String?
        var pageURL: URL?
        var pickMethod = "model"
    }

    static func visibleLinksOnScreen(allowsLocalHostForTests: Bool) async -> ScreenLinks? {
        guard let target = ArticleReader.findArticleWindow(), let window = target.windowElement else { return nil }
        await BackgroundWebTree.waitUntilBuilt()
        // Walking a big page takes a while, so it stays off the main thread.
        let unchecked = UncheckedAXElement(element: window)
        func walk() async -> ([ResearchLinkCandidate], URL?) {
            await Task.detached(priority: .userInitiated) {
                pageLinks(in: unchecked.element, allowsLocalHostForTests: allowsLocalHostForTests)
            }.value
        }
        var (candidates, pageURL) = await walk()
        // Chrome fills in a fresh page's tree while it's being read: walk again until it stops growing.
        for _ in 0..<2 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let again = await walk()
            guard again.0.count > candidates.count else { break }
            (candidates, pageURL) = again
        }
        let visible = await resolvingRedirects(ResearchLinkPicker.onScreenCandidates(candidates, windowFrame: target.windowFrameCG))
        print("🔎 Research: \(candidates.count) links in the page, \(visible.count) visible")
        guard !visible.isEmpty else { return nil }
        return ScreenLinks(candidates: visible, windowFrame: target.windowFrameCG,
                           pageTitle: TypeForMeAccessibility.stringAttribute(kAXTitleAttribute, of: window), pageURL: pageURL)
    }

    /// Every link in the page, in reading order. A search page runs to tens of thousands of elements, most of them
    /// pictures and words that can't hold a link, so those are skipped. This runs in the background, so the time limit
    /// is generous: stopping early would leave out the results under a long AI answer.
    nonisolated private static func pageLinks(in window: AXUIElement, allowsLocalHostForTests: Bool) -> ([ResearchLinkCandidate], URL?) {
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        let leafRoles: Set<String> = ["AXStaticText", "AXImage", "AXButton", "AXCheckBox", "AXRadioButton", "AXTextField", "AXTextArea", "AXPopUpButton"]
        var stack: [AXUIElement] = [window]
        var candidates: [ResearchLinkCandidate] = []
        var pageURL: URL?
        while let element = stack.popLast(), ProcessInfo.processInfo.systemUptime < deadline, candidates.count < 400 {
            let role = TypeForMeAccessibility.stringAttribute(kAXRoleAttribute, of: element)
            if role == "AXWebArea", pageURL == nil {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &value) == .success {
                    pageURL = value as? URL ?? (value as? NSURL) as URL?
                }
            }
            if role == "AXLink" {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &value) == .success,
                   let rawURL = value as? URL ?? (value as? NSURL) as URL?,
                   let frame = TypeForMeAccessibility.frameCG(of: element) {
                    let url = ResearchLinkPicker.unwrapRedirect(rawURL)
                    if ResearchURLPolicy.isAllowed(url, allowsLocalHostForTests: allowsLocalHostForTests),
                       !ResearchURLPolicy.isSearchEngine(url) || ResearchLinkPicker.isOpaqueRedirect(url) {
                        candidates.append(ResearchLinkCandidate(url: url, text: linkText(element), frame: frame))
                    }
                }
                continue
            }
            if let role, leafRoles.contains(role) { continue }
            stack.append(contentsOf: TypeForMeAccessibility.elementArrayAttribute(kAXChildrenAttribute, of: element).reversed())
        }
        return (candidates, pageURL)
    }

    /// Google now writes every result as google.com/goto?url=<opaque>: only asking it says where one really goes.
    /// Done before choosing, so the picker sees real sites and the same page can't be chosen twice.
    static func resolvingRedirects(_ candidates: [ResearchLinkCandidate]) async -> [ResearchLinkCandidate] {
        let urls = await withTaskGroup(of: (Int, URL).self) { group in
            for (index, candidate) in candidates.enumerated() {
                group.addTask {
                    guard ResearchLinkPicker.isOpaqueRedirect(candidate.url) else { return (index, candidate.url) }
                    var request = URLRequest(url: candidate.url, timeoutInterval: 10)
                    request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140 Safari/537.36", forHTTPHeaderField: "User-Agent")
                    // The headers are enough: by then the redirects have been followed. A site that refuses us still says where it is.
                    let final = (try? await URLSession.shared.bytes(for: request))?.1.url
                    return (index, final ?? candidate.url)
                }
            }
            var resolved: [(Int, URL)] = []
            for await item in group { resolved.append(item) }
            return resolved.sorted { $0.0 < $1.0 }.map(\.1)
        }
        var seen = Set<URL>()
        return zip(candidates, urls).compactMap { candidate, url in
            // Google's links can carry a "#:~:text=" highlight: it's the same page.
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.fragment = nil
            let page = components?.url ?? url
            guard !ResearchURLPolicy.isSearchEngine(page), seen.insert(page).inserted else { return nil }
            return ResearchLinkCandidate(url: page, text: candidate.text, frame: candidate.frame)
        }
    }

    /// A link's words: its title or description, else the text inside it.
    nonisolated private static func linkText(_ element: AXUIElement) -> String {
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute] {
            if let text = TypeForMeAccessibility.stringAttribute(attribute, of: element)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return text
            }
        }
        var pieces: [String] = []
        var queue = TypeForMeAccessibility.elementArrayAttribute(kAXChildrenAttribute, of: element)
        var visited = 0
        while !queue.isEmpty, visited < 40, pieces.joined(separator: " ").count < 160 {
            let child = queue.removeFirst()
            visited += 1
            if let value = TypeForMeAccessibility.stringAttribute(kAXValueAttribute, of: child)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                pieces.append(value)
            }
            queue.append(contentsOf: TypeForMeAccessibility.elementArrayAttribute(kAXChildrenAttribute, of: child))
        }
        return pieces.joined(separator: " ")
    }

    /// The links he means: a quick Haiku call over the numbered visible links, else the heuristic.
    static func pickLinks(_ screenPage: ScreenLinks, request: String, count: Int) async -> [URL] {
        guard count > 0 else { return [] }
        let prompt = ResearchLinkPicker.pickerPrompt(request: request, count: count, pageTitle: screenPage.pageTitle, pageURL: screenPage.pageURL,
                                                     candidates: screenPage.candidates, windowFrame: screenPage.windowFrame)
        let pickTask = Task { () -> [Int] in
            guard let turn = try? await CompanionWorkerRunner.makeWorkerClaudeCodeBridge().runTurn(
                systemPromptFileName: "research-link-picker-prompt.md",
                systemPrompt: "You pick which links on a web page a person means. Reply with only a JSON array of numbers.",
                contentBlocks: [.text(prompt)]) else { return [] }
            return ResearchLinkPicker.parsePick(turn.text, candidateCount: screenPage.candidates.count)
        }
        let timeout = Task { try? await Task.sleep(nanoseconds: 25_000_000_000); pickTask.cancel() }
        let picked = await pickTask.value
        timeout.cancel()
        if !picked.isEmpty {
            print("🔎 Research: Haiku picked \(picked)")
            return picked.prefix(count).map { screenPage.candidates[$0 - 1].url }
        }
        print("🔎 Research: picker failed, using the heuristic")
        return ResearchLinkPicker.heuristicPick(screenPage.candidates, count: count, pageURL: screenPage.pageURL).map(\.url)
    }

    /// Search results with their titles (the board's links strip).
    static func searchResultPages(for topic: String, maximum: Int) async -> [(url: URL, title: String)] {
        guard let searchURL = ResearchSearchResults.searchURL(for: topic),
              let html = await fetchHTML(searchURL, allowsLocalHostForTests: false) else { return [] }
        return ResearchSearchResults.results(fromHTML: html, maximum: maximum)
    }

    static func searchResults(for topic: String, maximum: Int) async -> [URL] {
        guard let searchURL = ResearchSearchResults.searchURL(for: topic),
              let html = await fetchHTML(searchURL, allowsLocalHostForTests: false) else { return [] }
        return ResearchSearchResults.resultURLs(fromHTML: html, maximum: maximum)
    }

    static func fetchReadableText(_ url: URL, allowsLocalHostForTests: Bool) async -> (title: String?, text: String)? {
        guard let html = await fetchHTML(url, allowsLocalHostForTests: allowsLocalHostForTests) else { return nil }
        let extracted = ReadableText.extract(html: html)
        return (extracted.title, extracted.text)
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = ResearchURLPolicy.timeoutSeconds
        configuration.timeoutIntervalForResource = ResearchURLPolicy.timeoutSeconds * 2
        configuration.httpAdditionalHeaders = ["User-Agent": "Clicky/2 (research helper; macOS)", "Accept": "text/html,application/xhtml+xml"]
        return URLSession(configuration: configuration)
    }()

    static func fetchHTML(_ url: URL, allowsLocalHostForTests: Bool) async -> String? {
        guard ResearchURLPolicy.isAllowed(url, allowsLocalHostForTests: allowsLocalHostForTests) else { return nil }
        guard let (bytes, response) = try? await session.bytes(from: url),
              let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode),
              let finalURL = httpResponse.url, ResearchURLPolicy.isAllowed(finalURL, allowsLocalHostForTests: allowsLocalHostForTests) else { return nil }
        if let mimeType = httpResponse.mimeType, !mimeType.contains("html"), !mimeType.contains("text") { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= ResearchURLPolicy.maximumBytes { break }
            }
        } catch {
            if data.isEmpty { return nil }
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }
}
