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

        for rawLine in text.components(separatedBy: "\n") {
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
            } else if line.hasPrefix("#") {
                flushParagraph()
                let level = line.prefix { $0 == "#" }.count
                blocks.append(.heading(line.dropFirst(level).trimmingCharacters(in: .whitespaces), level: level))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                flushParagraph()
                blocks.append(.bullet(String(line.dropFirst(2)), marker: "•"))
            } else if let match = line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
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
}

struct BotRichText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(BotBlocks.parse(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let words):
                    Text(BotMarkdown.attributed(words)).lineSpacing(3)
                case .heading(let words, let level):
                    Text(BotMarkdown.attributed(words))
                        .font(.system(size: level <= 1 ? 17 : level == 2 ? 15.5 : 14.5, weight: .semibold))
                        .padding(.top, 4)
                case .bullet(let words, let marker):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(marker).foregroundColor(DS.Colors.textTertiary).frame(minWidth: 12, alignment: .trailing)
                        Text(BotMarkdown.attributed(words)).lineSpacing(3)
                    }
                case .code(let body, let language):
                    BotCodeCard(code: body, language: language)
                }
            }
        }
        .font(.system(size: 14))
        .foregroundColor(DS.Colors.textPrimary)
        .textSelection(.enabled)
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
        case "prompt": return "Prompt for T3 Code"
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
            .background(Color.white.opacity(0.04))
            Divider().overlay(Color.white.opacity(0.06))
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
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(12)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.28)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.08)))
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
                    Text(detailLine).font(TheoType.caption).foregroundColor(DS.Colors.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 8)
                StatusPill(text: isStopped ? "Stopped" : run.phase == "failed" ? "Failed" : run.pullRequest != nil ? "Draft PR" : "Done",
                           tone: isStopped ? .neutral : run.phase == "failed" ? .bad : .good)
            }
            if !files.isEmpty { fileList }
            if let tests = run.tests {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: tests.hasPrefix("passed") ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 12)).foregroundColor(tests.hasPrefix("passed") ? DS.Colors.success : DS.Colors.destructiveText)
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
                    Button { NSWorkspace.shared.open(url) } label: { Label("Open PR", systemImage: "arrow.triangle.pull") }.buttonStyle(.theo(.primary, .small))
                }
                Button { BotsT3.openInApp(run) } label: {
                    Label(run.harness == nil ? "Open in T3" : run.harness == CursorCloud.harnessID ? "Open in Cursor" : "Open terminal", systemImage: run.harness == nil ? "arrow.up.forward.app" : "terminal")
                }
                .buttonStyle(.theo(.secondary, .small))
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: run.worktree ?? run.folder)])
                } label: { Label("Open folder", systemImage: "folder") }.buttonStyle(.theo(.secondary, .small))
                if run.repo == nil, let page = BotsT3.page(of: run) {
                    Button { NSWorkspace.shared.open(page) } label: { Label("Open page", systemImage: "safari") }.buttonStyle(.theo(.secondary, .small))
                }
                Spacer(minLength: 0)
                if run.phase == "failed", !isStopped, let prompt = run.prompt {
                    Menu {
                        ForEach(HarnessCenter.shared.readyHarnesses.filter { $0.id != (run.harness ?? "t3") }, id: \.id) { info in
                            Button(info.label) {
                                BotsStore.shared.submitToT3(prompt: prompt, title: run.title, repo: run.repo.map { URL(fileURLWithPath: $0, isDirectory: true) },
                                                            room: run.room ?? BotsStore.teamID, harness: info.id)
                            }
                        }
                    } label: { Label("Try on another harness", systemImage: "arrow.triangle.2.circlepath") }
                        .menuStyle(.borderlessButton).fixedSize()
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Colors.surface1))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
    }

    private var detailLine: String {
        var parts = [engine]
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
