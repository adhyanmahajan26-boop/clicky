//
//  BotRichText.swift
//  leanring-buddy
//
//  A finished bot reply, laid out like a chat app does it: paragraphs,
//  headings, bullet and numbered lists, and fenced code as its own card with
//  a copy button. Theo's final ```prompt block reads as "Prompt for T3
//  Code". Inline bold, italics, code and links come from BotMarkdown.
//

import AppKit
import SwiftUI

enum BotBlock: Equatable {
    case paragraph(String)
    case heading(String, level: Int)
    case bullet(String, marker: String)
    case code(String, language: String)
    case table(header: [String], rows: [[String]])
    case quote(String)
}

enum BotBlocks {
    static func parse(_ text: String) -> [BotBlock] {
        var blocks: [BotBlock] = []
        var paragraph: [String] = []
        var code: [String]?
        var language = ""
        var depth = 0

        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraph = []
        }

        let lines = text.components(separatedBy: "\n")
        var skipUntil = 0
        for (index, rawLine) in lines.enumerated() where index >= skipUntil {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if var open = code {
                if line == "```" && depth == 0 {
                    blocks.append(.code(open.joined(separator: "\n"), language: language))
                    code = nil
                } else {
                    // Fences inside the block (a prompt quoting code) stay part of it.
                    if line == "```" { depth -= 1 } else if line.hasPrefix("```") { depth += 1 }
                    open.append(rawLine)
                    code = open
                }
                continue
            }
            if line.hasPrefix("```") {
                flushParagraph()
                language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                code = []
            } else if line.hasPrefix("|"), index + 1 < lines.count, isTableRule(lines[index + 1]) {
                // A Markdown table: a header row, a |---|---| rule, then rows until the pipes stop.
                flushParagraph()
                var rows: [[String]] = []
                var next = index + 2
                while next < lines.count, lines[next].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(tableCells(lines[next]))
                    next += 1
                }
                skipUntil = next
                blocks.append(.table(header: tableCells(line), rows: rows))
            } else if line.hasPrefix(">") {
                flushParagraph()
                let words = line.dropFirst().trimmingCharacters(in: .whitespaces)
                if case .quote(let earlier)? = blocks.last {
                    blocks[blocks.count - 1] = .quote(earlier + "\n" + words)
                } else {
                    blocks.append(.quote(words))
                }
            } else if line.hasPrefix("#") {
                flushParagraph()
                let level = line.prefix { $0 == "#" }.count
                blocks.append(.heading(line.dropFirst(level).trimmingCharacters(in: .whitespaces), level: level))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                flushParagraph()
                blocks.append(.bullet(String(line.dropFirst(2)), marker: "•"))
            } else if let match = line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression), startsOrContinuesList(line[match], after: blocks.last, pendingParagraph: paragraph) {
                flushParagraph()
                let marker = line[match].trimmingCharacters(in: .whitespaces)
                blocks.append(.bullet(String(line[match.upperBound...]), marker: marker))
            } else if line.isEmpty {
                flushParagraph()
            } else {
                paragraph.append(line)
            }
        }
        // An unclosed fence (a reply still streaming) still shows as code.
        if let open = code { blocks.append(.code(open.joined(separator: "\n"), language: language)) }
        flushParagraph()
        return blocks
    }

    /// "1. First" starts a list and "2. Next" carries one on. A reply that opens "47. That's your number" is a sentence.
    private static func startsOrContinuesList(_ marker: Substring, after previous: BotBlock?, pendingParagraph: [String]) -> Bool {
        if marker.hasPrefix("1.") || marker.hasPrefix("1)") { return true }
        if case .bullet? = previous, pendingParagraph.isEmpty { return true }
        return false
    }

    private static func isTableRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("|") && trimmed.contains("-") && trimmed.allSatisfy { "|-: ".contains($0) }
    }

    private static func tableCells(_ line: String) -> [String] {
        var cells = line.trimmingCharacters(in: .whitespaces).components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        if cells.first?.isEmpty == true { cells.removeFirst() }
        if cells.last?.isEmpty == true { cells.removeLast() }
        return cells
    }
}

/// One chat text style, for a finished reply and one still typing, so nothing re-wraps when typing ends.
enum ChatText {
    static let size: CGFloat = 14
    static let lineSpacing: CGFloat = 4
    /// A comfortable line length, about 75 characters.
    static let measure: CGFloat = 640
    static let font = Font.system(size: size)
}

struct BotRichText: View {
    let text: String

    var body: some View {
        let blocks = BotBlocks.parse(text)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                content(of: block).padding(.top, index == 0 ? 0 : gap(before: block, after: blocks[index - 1]))
            }
        }
        .font(ChatText.font)
        .foregroundColor(DS.Colors.textPrimary)
        .textSelection(.enabled)
    }

    @ViewBuilder private func content(of block: BotBlock) -> some View {
        switch block {
        case .paragraph(let words):
            Text(BotMarkdown.attributed(words)).lineSpacing(ChatText.lineSpacing)
        case .heading(let words, let level):
            Text(BotMarkdown.attributed(words))
                .font(.system(size: level <= 1 ? 19 : level == 2 ? 17 : 15, weight: .semibold))
        case .bullet(let words, let marker):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker).foregroundColor(DS.Colors.textSecondary).frame(minWidth: 14, alignment: .trailing)
                Text(BotMarkdown.attributed(words)).lineSpacing(ChatText.lineSpacing)
            }
        case .code(let body, let language):
            if language.lowercased() == "routine", let routine = RoutineChatCard.parse(body) {
                RoutineChatCard(name: routine.name, when: routine.when)
            } else {
                BotCodeCard(code: body, language: language)
            }
        case .table(let header, let rows):
            BotTable(header: header, rows: rows)
        case .quote(let words):
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 1).fill(DS.Colors.borderStrong).frame(width: 2)
                Text(BotMarkdown.attributed(words)).lineSpacing(ChatText.lineSpacing).foregroundColor(DS.Colors.textSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func gap(before block: BotBlock, after previous: BotBlock) -> CGFloat {
        switch (previous, block) {
        case (.bullet, .bullet): return 6
        case (.heading, _): return 8
        case (_, .heading): return 20
        default: return 14
        }
    }
}

/// A Markdown table, in the chat's own type: a quiet header row and hairlines, scrolling sideways if it's wide.
struct BotTable: View {
    let header: [String]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        Text(BotMarkdown.attributed(cell)).font(.system(size: 13, weight: .semibold)).foregroundColor(DS.Colors.textSecondary)
                            .padding(.vertical, 8)
                    }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Rectangle().fill(DS.Colors.borderSubtle).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(Array(header.indices), id: \.self) { column in
                            Text(BotMarkdown.attributed(column < row.count ? row[column] : "")).font(.system(size: 14)).lineSpacing(3)
                                .frame(maxWidth: 320, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.vertical, 8)
                        }
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 4)
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Colors.surface1))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DS.Colors.borderSubtle))
    }
}

/// A schedule a bot just set, instead of the JSON it wrote to set it.
struct RoutineChatCard: View {
    let name: String
    let when: String
    @ObservedObject private var store = BotsStore.shared

    static func parse(_ body: String) -> (name: String, when: String)? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
              let name = object["name"] as? String, let when = object["when"] as? String else { return nil }
        return (name, when)
    }

    private var routine: BotRoutine? { store.routines.first { $0.name == name } }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath").font(.system(size: 13, weight: .medium)).foregroundColor(DS.Colors.textSecondary)
                .frame(width: 28, height: 28).background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(DS.Colors.hover))
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 13, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                Text(routine?.schedule.label ?? when).font(TheoType.caption).foregroundColor(DS.Colors.textSecondary)
            }
            Spacer(minLength: 8)
            if let routine {
                Button(routine.paused ? "Resume" : "Pause") { store.setPaused(!routine.paused, routineID: routine.id) }.buttonStyle(.theo(.ghost, .small))
                Button("Run now") { store.runRoutineNow(routine.id) }.buttonStyle(.theo(.secondary, .small))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Colors.surface1))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DS.Colors.borderSubtle))
    }
}

/// Fenced code as a card: a label, the code in mono, and a copy button.
struct BotCodeCard: View {
    let code: String
    let language: String
    @State private var copied = false
    @State private var expanded = false

    private var isProse: Bool { language == "prompt" || language == "followup" }
    private var lines: [Substring] { code.split(separator: "\n", omittingEmptySubsequences: false) }
    private var isLong: Bool { lines.count > 14 }
    private var preview: String { lines.prefix(10).joined(separator: "\n") + "\n…" }

    private var label: String {
        switch language.lowercased() {
        case "prompt": return "Prompt for \(HarnessCatalog.label(HarnessPrefs.codingTarget))"
        case "followup": return "Change for the coding agent"
        case "routine": return "Schedule for Theo to run"
        case "": return "Code"
        default: return language
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: language == "prompt" ? "doc.text.fill" : "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 10.5))
                Text(label).font(.system(size: 11.5, weight: .semibold))
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc").font(.system(size: 11))
                }
                .buttonStyle(.plain)
            }
            .foregroundColor(DS.Colors.textSecondary)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(DS.Colors.hover)
            Divider().overlay(DS.Colors.hover)
            if isProse {
                // A prompt wraps like text, and a long one folds to its opening lines until opened.
                Text(expanded || !isLong ? code : preview)
                    .font(.system(size: 13)).foregroundColor(DS.Colors.textPrimary).lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                if isLong {
                    Button(expanded ? "Show less" : "Show the whole prompt (\(lines.count) lines)") {
                        withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() }
                    }
                    .buttonStyle(.plain).font(.system(size: 11.5, weight: .medium)).foregroundColor(DS.Colors.accentText)
                    .padding(.horizontal, 12).padding(.bottom, 10)
                }
            } else {
                ScrollView(.horizontal) {
                    Text(code)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(12)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Colors.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(DS.Colors.borderSubtle))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Under a bot's finished reply: copy it.
struct BotMessageActions: View {
    let text: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 14) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help("Copy")
        }
        .foregroundColor(DS.Colors.textTertiary)
    }
}

/// When a T3 Code run ends: where the work is, one click away.
/// A finished run: what happened, what changed, the tests and the pull request, with the ways in.
struct T3ResultCard: View {
    let run: T3Run
    @State private var showsAllFiles = false
    @State private var showsTerminal = false
    @State private var showsReport = false
    @ObservedObject private var terminals = TerminalSessions.shared
    @ObservedObject private var store = BotsStore.shared

    private var session: TerminalSession? { terminals.session(for: run.id) }
    private var isLatestInChat: Bool { store.latestRun(in: run.room ?? BotsStore.teamID)?.id == run.id }
    private var pullRequestNumber: String? { run.pullRequest?.split(separator: "/").last.map { "#\($0)" } }
    private var engine: String { run.harness.map(HarnessCatalog.label) ?? "T3 Code" }
    private var isStopped: Bool { run.stoppedByOwner == true }
    private var files: [RunFileChange] { run.changedFiles ?? [] }
    private var added: Int { files.map(\.added).reduce(0, +) }
    private var removed: Int { files.map(\.removed).reduce(0, +) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                BrandLogo(id: run.harness ?? "t3", name: engine, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(run.title).font(TheoType.bodyMedium).foregroundColor(DS.Colors.textPrimary).lineLimit(1)
                    HStack(spacing: 6) {
                        RunMacChip(run: run)
                        Text(detailLine).font(TheoType.caption).foregroundColor(DS.Colors.textTertiary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                StatusPill(text: isStopped ? "Stopped" : run.phase == "failed" ? "Failed" : run.pullRequest != nil ? "Draft PR" : "Done",
                           tone: isStopped ? .neutral : run.phase == "failed" ? .bad : .good)
            }
            if !isStopped, run.phase != "failed", run.branch != nil || run.pullRequest != nil { doneSteps }
            if !files.isEmpty { fileList }
            if let tests = run.tests {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: tests.hasPrefix("passed") ? "checkmark.circle.fill" : tests.hasPrefix("failed") ? "xmark.circle.fill" : "questionmark.circle")
                        .font(.system(size: 12)).foregroundColor(tests.hasPrefix("passed") ? DS.Colors.success : tests.hasPrefix("failed") ? DS.Colors.destructiveText : DS.Colors.textTertiary)
                    Text("Tests (Theo's own run): \(tests)").font(TheoType.caption).foregroundColor(DS.Colors.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let problem = run.pullRequestProblem {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundColor(DS.Colors.warning)
                    Text(problem).font(TheoType.caption).foregroundColor(DS.Colors.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 6) {
                if let pr = run.pullRequest, let url = URL(string: pr) {
                    Button { NSWorkspace.shared.open(url) } label: { Label("Open PR \(pullRequestNumber ?? "")", systemImage: "arrow.triangle.pull") }.buttonStyle(.theo(.primary, .small))
                }
                if session != nil {
                    Button {
                        withAnimation(DS.Motion.hover) { showsTerminal.toggle() }
                        NotificationCenter.default.post(name: .theoScrollChatToEnd, object: nil)
                    } label: { Label(showsTerminal ? "Hide terminal" : "Show terminal", systemImage: "terminal") }
                        .buttonStyle(.theo(.secondary, .small))
                } else if run.isRemote {
                    RemoteRunBadge(run: run, showsTerminal: $showsTerminal)
                } else {
                    Button { BotsT3.openInApp(run) } label: {
                        Label(run.harness == nil ? "Open in T3" : run.harness == CursorCloud.harnessID ? "Open in Cursor" : "Show terminal", systemImage: run.harness == nil ? "arrow.up.forward.app" : "terminal")
                    }
                    .buttonStyle(.theo(.secondary, .small))
                }
                if !run.isRemote {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: run.worktree ?? run.folder)])
                    } label: { Label("Open folder", systemImage: "folder") }.buttonStyle(.theo(.secondary, .small))
                }
                if run.repo == nil, let page = BotsT3.page(of: run) {
                    Button { NSWorkspace.shared.open(page) } label: { Label("Open page", systemImage: "safari") }.buttonStyle(.theo(.secondary, .small))
                }
                Spacer(minLength: 0)
                if run.phase == "failed", !isStopped, let prompt = run.prompt {
                    Menu {
                        ForEach(HarnessCenter.shared.readyHarnesses.filter { $0.id != (run.harness ?? "t3") }, id: \.id) { info in
                            Button(info.label) {
                                // A plain folder has no repo on the run, but it's still the owner's folder.
                                BotsStore.shared.submitToT3(prompt: prompt, title: run.title, repo: (run.repo ?? (run.baseCommit == nil ? run.folder : nil)).map { URL(fileURLWithPath: $0, isDirectory: true) },
                                                            room: run.room ?? BotsStore.teamID, harness: info.id, macName: run.origin)
                            }
                        }
                    } label: { Label("Try on another harness", systemImage: "arrow.triangle.2.circlepath") }
                        .menuStyle(.borderlessButton).fixedSize()
                }
            }
            if showsTerminal, run.isRemote { RemoteRunTerminal(run: run) }
            if showsTerminal, let session {
                TerminalPanel(session: session)
                    .frame(height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
            }
            if let report = run.fullReport, report.count > 60 {
                Button {
                    withAnimation(DS.Motion.hover) { showsReport.toggle() }
                    NotificationCenter.default.post(name: .theoScrollChatToEnd, object: nil)
                } label: {
                    Label(showsReport ? "Hide the agent's report" : "Show the agent's report", systemImage: showsReport ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.theo(.ghost, .small))
                if showsReport { BotRichText(text: report).font(.system(size: 13)) }
            }
            if isLatestInChat, run.phase == "done" || isStopped {
                RunFollowupBox(run: run, placeholder: isStopped ? "Carry on, or ask for something else" : "Ask for a change")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Colors.surface1))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
    }

    /// What Theo did after the agent finished, at a glance.
    private var doneSteps: some View {
        HStack(spacing: 6) {
            if let tests = run.tests, tests.hasPrefix("passed") { doneChip("Tests passed") }
            if run.pullRequest != nil { doneChip("Saved and pushed") }
            if let number = pullRequestNumber { doneChip("Draft pull request \(number)") }
            Spacer(minLength: 0)
        }
    }

    private func doneChip(_ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
            Text(text).font(.system(size: 11.5, weight: .medium))
        }
        .foregroundColor(DS.Colors.successText)
        .padding(.horizontal, 8).frame(height: 22)
        .background(Capsule().fill(DS.Colors.success.opacity(0.12)))
    }

    private var detailLine: String {
        var parts = [engine]
        if let chat = run.continuedChat { parts.append("Continuing \(chat)") }
        if run.chatUnknown == true { parts.append("Couldn't tell which chat it made") }
        if let branch = run.branch { parts.append(branch) }
        if let finished = run.finishedAt {
            let minutes = max(1, Int((finished.timeIntervalSince(run.startedAt) / 60).rounded()))
            parts.append("\(minutes) min")
        }
        return parts.joined(separator: " · ")
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("\(files.count) file\(files.count == 1 ? "" : "s") changed").font(TheoType.caption).foregroundColor(DS.Colors.textSecondary)
                Text("+\(added)").font(TheoType.mono).foregroundColor(DS.Colors.success)
                Text("\u{2212}\(removed)").font(TheoType.mono).foregroundColor(DS.Colors.destructiveText)
            }
            ForEach(showsAllFiles ? files : Array(files.prefix(5))) { file in
                HStack(spacing: 6) {
                    Text(file.path).font(.system(size: 11.5, design: .monospaced)).foregroundColor(DS.Colors.textTertiary).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text("+\(file.added)").font(.system(size: 11, design: .monospaced)).foregroundColor(DS.Colors.success.opacity(0.85))
                    Text("\u{2212}\(file.removed)").font(.system(size: 11, design: .monospaced)).foregroundColor(DS.Colors.destructiveText.opacity(0.85))
                }
            }
            if files.count > 5 {
                Button(showsAllFiles ? "Show less" : "Show all \(files.count)") { showsAllFiles.toggle() }.buttonStyle(.theo(.ghost, .small))
            }
        }
    }
}

extension NativeBot {
    /// The bot's role at a glance, drawn on its avatar.
    var symbol: String {
        switch id {
        case "theo": return "crown.fill"
        case "project-manager": return "list.bullet.clipboard.fill"
        case "design-critic": return "paintbrush.pointed.fill"
        case "code-improver": return "chevron.left.forwardslash.chevron.right"
        case "reel-editor": return "film.fill"
        case "gmail-reader": return "envelope.fill"
        case "researcher": return "magnifyingglass"
        case "clicky": return "cursorarrow.rays"
        default:
            if apps.contains("gmail") { return "envelope.fill" }
            if apps.contains("studio") { return "film.fill" }
            return "sparkles"
        }
    }
}
