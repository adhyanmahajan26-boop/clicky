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
final class ResearchController {
    private weak var companionManager: CompanionManager?
    private var researchTask: Task<Void, Never>?
    private var parentAgentID: String?
    /// For researchStatus (tests): the last run's outcome.
    private(set) var lastStatus: [String: Any] = ["state": "idle"]

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
    }

    var isRunning: Bool { researchTask != nil }

    /// A research request or "cancel research" in the owner's words; true when handled here.
    func handleSpokenTranscript(_ transcript: String, speaks: Bool) -> Bool {
        if ResearchTrigger.isCancel(transcript) {
            say(cancel() ? "Research cancelled." : "No research is running.", speaks: speaks)
            return true
        }
        guard let request = ResearchTrigger.parse(transcript) else { return false }
        start(request, speaks: speaks)
        return true
    }

    @discardableResult
    func cancel() -> Bool {
        guard let researchTask else { return false }
        researchTask.cancel()
        self.researchTask = nil
        companionManager?.agentsCenter.finish(parentAgentID, status: .cancelled)
        lastStatus["state"] = "cancelled"
        return true
    }

    /// `allowsLocalHostForTests`: the debug inbox's researchStart may use 127.0.0.1 test pages.
    func start(_ request: ResearchRequest, speaks: Bool, allowsLocalHostForTests: Bool = false) {
        guard let companionManager else { return }
        cancel()
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
        let screenLinks: [URL]
        if case .links(let count) = request.source, request.namedURLs.count < count {
            screenLinks = Self.linksOnScreen(maximum: count, allowsLocalHostForTests: allowsLocalHostForTests)
        } else {
            screenLinks = []
        }

        researchTask = Task { [weak self] in
            guard let self else { return }
            var urls = request.namedURLs
            switch request.source {
            case .links(let count):
                for url in screenLinks where !urls.contains(url) && urls.count < count { urls.append(url) }
            case .topic(let text):
                urls += await Self.searchResults(for: text, maximum: 3)
            }
            guard !urls.isEmpty else {
                self.finish(parentAgentID, status: .failed, line: "I couldn't find any links to research.", speaks: speaks)
                return
            }
            self.say("Researching \(urls.count) link\(urls.count == 1 ? "" : "s") in the background.", speaks: speaks)
            self.lastStatus = ["state": "reading", "topic": topic, "urls": urls.map(\.absoluteString)]
            agentsCenter.log(parentAgentID, "links: " + urls.map(\.absoluteString).joined(separator: ", "))

            let reports = await self.runHelpers(urls: Array(urls.prefix(ResearchTrigger.maximumLinks)), question: request.question,
                                                parentAgentID: parentAgentID, allowsLocalHostForTests: allowsLocalHostForTests)
            guard !Task.isCancelled else { return }
            self.lastStatus["state"] = "writing"
            let brief = await Self.synthesize(question: request.question, reports: reports)
            guard !Task.isCancelled else { return }
            self.present(topic: topic, question: request.question, brief: brief, reports: reports, parentAgentID: parentAgentID, speaks: speaks)
        }
    }

    // MARK: - Helpers

    private struct Report {
        let index: Int
        let url: URL
        let title: String?
        let text: String
        let succeeded: Bool
    }

    private func runHelpers(urls: [URL], question: String, parentAgentID: String, allowsLocalHostForTests: Bool) async -> [Report] {
        guard let agentsCenter = companionManager?.agentsCenter else { return [] }
        let jobs = urls.enumerated().map { (index: $0.offset + 1, url: $0.element) }
        return await withTaskGroup(of: Report.self) { group in
            for job in jobs {
                let agentID = agentsCenter.begin(kind: .worker, title: "[\(job.index)] \(job.url.host ?? job.url.absoluteString)",
                                                 model: CompanionWorkerRunner.workerClaudeModel, parentID: parentAgentID)
                group.addTask {
                    let page = await Self.fetchReadableText(job.url, allowsLocalHostForTests: allowsLocalHostForTests)
                    guard let page, !page.text.isEmpty, !ReadableText.looksWalled(page.text) else {
                        await MainActor.run { agentsCenter.finish(agentID, status: .failed, errorDescription: "couldn't read the page") }
                        return Report(index: job.index, url: job.url, title: page?.title, text: "unreadable (empty, blocked or a sign-in wall)", succeeded: false)
                    }
                    do {
                        let turn = try await CompanionWorkerRunner.makeWorkerClaudeCodeBridge().runTurn(
                            systemPromptFileName: "research-worker-prompt.md",
                            systemPrompt: ResearchPrompts.workerSystemPrompt,
                            contentBlocks: [.text(ResearchPrompts.workerPrompt(question: question, url: job.url, title: page.title, text: page.text))])
                        await MainActor.run {
                            agentsCenter.log(agentID, turn.text)
                            agentsCenter.finish(agentID, status: .done, usage: turn.usageSummary)
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

    private static func synthesize(question: String, reports: [Report]) async -> String {
        let prompt = ResearchPrompts.synthesisPrompt(question: question, reports: reports.map { ($0.index, $0.url, $0.title, $0.text) })
        do {
            let turn = try await ClaudeCodeBridge(model: ClickyModels.main).runTurn(systemPromptFileName: "research-synthesis-prompt.md",
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
        companionManager.articleController.showNotes(notes, target: ArticleReader.findArticleWindow())
        companionManager.showHandsFreeStatusMessage("Research ready")
        // Spoken only when Clicky isn't mid-turn and Safari (his Netflix) isn't in front.
        let safariInFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.Safari"
        if companionManager.voiceState == .idle && !safariInFront { say("Your research is ready.", speaks: speaks) }
    }

    private func finish(_ agentID: String, status: AgentStatus, line: String, speaks: Bool) {
        companionManager?.agentsCenter.finish(agentID, status: status)
        lastStatus["state"] = status == .failed ? "failed" : "done"
        researchTask = nil
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

    /// Links on the page in front (the browser window the article reader would pick), in page order,
    /// one per site, search engines and non-public addresses skipped.
    static func linksOnScreen(maximum: Int, allowsLocalHostForTests: Bool) -> [URL] {
        guard let window = ArticleReader.findArticleWindow()?.windowElement else { return [] }
        var queue: [AXUIElement] = [window]
        var visited = 0
        var seenHosts = Set<String>()
        var urls: [URL] = []
        while !queue.isEmpty, visited < 6000, urls.count < maximum {
            let element = queue.removeFirst()
            visited += 1
            if TypeForMeAccessibility.stringAttribute(kAXRoleAttribute, of: element) == "AXLink" {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &value) == .success, let url = value as? URL ?? (value as? NSURL) as URL?,
                   ResearchURLPolicy.isAllowed(url, allowsLocalHostForTests: allowsLocalHostForTests), !ResearchURLPolicy.isSearchEngine(url),
                   let host = url.host?.lowercased(), allowsLocalHostForTests || seenHosts.insert(host).inserted {
                    if !urls.contains(url) { urls.append(url) }
                }
                continue
            }
            queue.append(contentsOf: TypeForMeAccessibility.elementArrayAttribute(kAXChildrenAttribute, of: element))
        }
        return urls
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
