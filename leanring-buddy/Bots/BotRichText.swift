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
struct T3ResultCard: View {
    let run: T3Run

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: run.phase == "failed" ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                .foregroundColor(run.phase == "failed" ? DS.Colors.warning : DS.Colors.success)
            if let pr = run.pullRequest, let url = URL(string: pr) {
                chip("Open pull request", "arrow.triangle.pull") { NSWorkspace.shared.open(url) }
            }
            chip("Open in T3 Code", "arrow.up.forward.app") { BotsT3.openInApp(run) }
            chip("Show folder", "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: run.folder)])
            }
            if run.repo == nil, let page = BotsT3.page(of: run) {
                chip("Open page", "safari") { NSWorkspace.shared.open(page) }
            }
            Spacer(minLength: 0)
        }
    }

    private func chip(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 11.5, weight: .medium))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(0.08)))
                .overlay(Capsule().stroke(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .foregroundColor(DS.Colors.textPrimary)
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
