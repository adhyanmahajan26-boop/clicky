//
//  RunChoices.swift
//  leanring-buddy
//
//  The card under a bot's finished build prompt: which harness, which Mac, which folder, which chat, and Start. The folder and chat always
//  come from the Mac chosen, so it's impossible to pick a folder on one Mac and run on the other. Also the chip a run's card wears for where it's going on.
//

import AppKit
import ClickyCore
import SwiftUI

/// A bot's finished build prompt, ready to go.
struct T3HandoffButton: View {
    let text: String
    var room: String = BotsStore.teamID
    let prominent: Bool
    var alreadySent = false
    /// The harness of the run this prompt started. Nil with a run means T3 Code.
    var sentRunHarness: String? = nil
    @ObservedObject private var center = HarnessCenter.shared
    @ObservedObject private var keys = ProviderKeys.shared
    @ObservedObject private var link = TheoLink.shared
    @State private var sentHere = false
    @State private var harness = HarnessPrefs.codingTarget
    /// The Mac picked here. Nil: where this chat's coding goes.
    @State private var pickedMac: String?
    @State private var folder: URL?
    @State private var chats: [HarnessChat] = []
    @State private var chat: HarnessChat?
    @State private var isLoadingChats = false
    @State private var isNamingFolder = false
    @State private var newFolderName = ""
    @State private var isMakingFolder = false
    @State private var problem: String?
    /// Which of the card's choices is open.
    @State private var openChoice: RunChoice?
    private var sent: Bool { sentHere || alreadySent }

    private enum RunChoice { case mac, folder, chat }

    private func isOpen(_ choice: RunChoice) -> Binding<Bool> {
        Binding(get: { openChoice == choice }, set: { if !$0, openChoice == choice { openChoice = nil } })
    }

    private var mac: String { pickedMac ?? BotsStore.shared.runMac(named: ProjectWords.labeled("Mac", in: text), room: room) }
    private var isHere: Bool { mac == TheoLink.localName }
    private var macLabel: String { RunMacChip.label(forMac: mac) }

    /// The folder the message itself names, when it's on the Mac chosen.
    private var namedFolder: URL? { BotsT3.targetRepo(answer: text, pitch: "", mustExist: isHere) }
    private var target: URL? { folder ?? namedFolder }

    private var projects: [DeviceProject] { isHere ? BotsT3.projects() : (BotsStore.shared.peerDevice?.projects ?? []) }
    private var menu: (recent: [DeviceProject], others: [DeviceProject]) {
        ProjectFolderMenu.sections(projects: projects, used: BotsStore.shared.t3Runs.reversed().filter { !$0.isRemote == isHere }.map(\.folder))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if sent {
                Label("Sent to \(HarnessCatalog.label(SentEngine.resolve(hasMatchingRun: alreadySent && !sentHere, runHarness: sentRunHarness, chosen: harness)))", systemImage: "checkmark").font(TheoType.caption).foregroundColor(DS.Colors.textSecondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        BrandLogo(id: harness, name: HarnessCatalog.label(harness), size: 24)
                        Picker("Run on", selection: Binding(get: { harness }, set: { harness = $0; chat = nil })) {
                            ForEach(HarnessCatalog.codingTargets, id: \.id) { info in
                                let status = center.status(for: info.id)
                                Text(info.label + (status.installed ? "" : " (not installed)")).tag(info.id)
                            }
                            if keys.hasKey(for: "cursor") { Text("Cursor cloud agent").tag(CursorCloud.harnessID) }
                        }
                        .labelsHidden().frame(width: 180)
                        if link.isPaired { macMenu }
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 8) {
                        folderMenu
                        if harness != CursorCloud.harnessID { chatMenu }
                        Spacer(minLength: 0)
                        Button { start() } label: { Label(chat != nil ? "Continue chat" : target == nil ? "Start as a new project" : "Start run", systemImage: "play.fill") }
                            .buttonStyle(.theo(.primary, .small))
                    }
                    if let problem { Text(problem).font(TheoType.caption).foregroundColor(DS.Colors.warningText).fixedSize(horizontal: false, vertical: true) }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Colors.surface1))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
            }
        }
        .padding(.leading, 38)
        .onAppear {
            center.refresh()
            // What this card shows stays what it shows, whatever else happens to this chat's turns meanwhile.
            if pickedMac == nil { pickedMac = mac }
        }
        .task(id: "\(harness)|\(mac)|\(target?.path ?? "")") { await loadChats() }
        .sheet(isPresented: $isNamingFolder) { newFolderSheet }
    }

    // MARK: The Mac

    private var macMenu: some View {
        RunChoiceChip(symbol: "laptopcomputer", text: macLabel, help: "The Mac this runs on. Its folders and chats are the ones you can pick.") { openChoice = .mac }
            .popover(isPresented: isOpen(.mac), arrowEdge: .bottom) {
                RunChoiceList {
                    RunChoiceRow(title: "This \(TheoLink.shortName(TheoLink.localName))", isChosen: isHere) { choose(mac: TheoLink.localName) }
                    if let peer = link.peerName ?? link.knownPeerName {
                        RunChoiceRow(title: TheoLink.shortName(peer), detail: link.isConnected ? nil : "Not connected", isChosen: !isHere) { choose(mac: peer) }
                    }
                }
                .frame(width: 240)
            }
    }

    /// Another Mac means another set of folders and chats: nothing picked for one carries over.
    private func choose(mac newMac: String) {
        openChoice = nil
        guard newMac != mac else { return }
        pickedMac = newMac
        folder = nil
        chat = nil
        problem = nil
    }

    // MARK: The folder

    private var folderMenu: some View {
        RunChoiceChip(symbol: "folder", text: isMakingFolder ? "Making it\u{2026}" : target?.lastPathComponent ?? "Choose a folder\u{2026}",
                      help: target?.path ?? "Where this runs. A git repo gets its own branch and a draft PR. A plain folder is edited in place.") { openChoice = .folder }
            .popover(isPresented: isOpen(.folder), arrowEdge: .bottom) {
                let sections = menu
                RunChoiceList {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            if sections.recent.isEmpty {
                                RunChoiceNote(text: "No projects in ~/Projects on \(isHere ? "this \(TheoLink.shortName(mac))" : TheoLink.shortName(mac)) yet.")
                            } else {
                                RunChoiceHeader(text: "On \(isHere ? "this \(TheoLink.shortName(mac))" : TheoLink.shortName(mac))")
                                ForEach(sections.recent) { project in
                                    RunChoiceRow(title: project.name, isChosen: target?.path == project.path) { pick(project) }
                                }
                            }
                            if !sections.others.isEmpty {
                                RunChoiceHeader(text: "All folders")
                                ForEach(sections.others) { project in
                                    RunChoiceRow(title: project.name, isChosen: target?.path == project.path) { pick(project) }
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 280)
                    RowDivider().padding(.vertical, 4)
                    RunChoiceRow(title: isHere ? "New folder\u{2026}" : "New folder on \(TheoLink.shortName(mac))\u{2026}", symbol: "folder.badge.plus") {
                        openChoice = nil
                        newFolderName = ""
                        isNamingFolder = true
                    }
                    // A folder picked with the system's panel can only be on this Mac.
                    if isHere {
                        RunChoiceRow(title: "Choose a folder\u{2026}", symbol: "ellipsis.circle") {
                            openChoice = nil
                            DispatchQueue.main.async { chooseWithPanel() }
                        }
                    }
                }
                .frame(width: 280)
            }
    }

    private func pick(_ project: DeviceProject) {
        openChoice = nil
        folder = URL(fileURLWithPath: project.path, isDirectory: true)
        chat = nil
        problem = nil
    }

    private func chooseWithPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use this folder"
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        folder = chosen
        chat = nil
        problem = nil
    }

    private var newFolderSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isHere ? "New folder" : "New folder on \(TheoLink.shortName(mac))").font(.system(size: 16, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
            Text("It goes in ~/Projects on \(isHere ? "this \(TheoLink.shortName(mac))" : "your \(TheoLink.shortName(mac))"), with git and an empty first commit.")
                .font(TheoType.caption).foregroundColor(DS.Colors.textSecondary)
            TextField("moon-site", text: $newFolderName).textFieldStyle(.roundedBorder).frame(width: 320).onSubmit(makeFolder)
            HStack {
                Spacer()
                Button("Cancel") { isNamingFolder = false }.keyboardShortcut(.cancelAction)
                Button("Create", action: makeFolder).keyboardShortcut(.defaultAction)
                    .disabled(newFolderName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
    }

    private func makeFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        isNamingFolder = false
        isMakingFolder = true
        problem = nil
        let onMac = mac
        Task {
            defer { isMakingFolder = false }
            if onMac == TheoLink.localName {
                switch await BotsT3.makeProject(named: name) {
                case .made(let made), .alreadyThere(let made):
                    folder = made
                    chat = nil
                case .failed(let reason):
                    problem = "Couldn't make that folder: \(reason)"
                }
                return
            }
            guard let answer = await TheoLink.shared.ask("mkdir", ["name": name]) else {
                problem = "Your \(TheoLink.shortName(onMac)) isn't connected, so that folder wasn't made."
                return
            }
            if let path = answer["path"], !path.isEmpty {
                folder = URL(fileURLWithPath: path, isDirectory: true)
                chat = nil
            } else {
                problem = "Couldn't make that folder: \(answer["problem"] ?? "no reason given")"
            }
        }
    }

    // MARK: The chat

    private var chatMenu: some View {
        RunChoiceChip(symbol: "bubble.left.and.bubble.right", text: chat.map { "Continuing \($0.title)" } ?? (isLoadingChats ? "Looking for chats\u{2026}" : "New chat"),
                      help: "Carry on a chat this harness already has in this folder, or start a new one.") { openChoice = .chat }
            .frame(maxWidth: 260, alignment: .leading)
            .popover(isPresented: isOpen(.chat), arrowEdge: .bottom) {
                RunChoiceList {
                    RunChoiceRow(title: "New chat", isChosen: chat == nil) {
                        openChoice = nil
                        chat = nil
                    }
                    RowDivider().padding(.vertical, 4)
                    if target == nil {
                        RunChoiceNote(text: "Pick a folder to see its chats.")
                    } else if chats.isEmpty {
                        RunChoiceNote(text: !isHere && !link.isConnected ? "Your \(TheoLink.shortName(mac)) isn't reachable, so its chats can't be listed." : harness == "t3" && isHere && !HarnessChats.isT3ServerUp ? "Open T3 Code to see its threads." : isLoadingChats ? "Looking\u{2026}" : "No earlier \(HarnessCatalog.label(harness)) chats in this folder.")
                    } else {
                        RunChoiceHeader(text: "In \(target?.lastPathComponent ?? "this folder")")
                        ScrollView {
                            VStack(alignment: .leading, spacing: 1) {
                                ForEach(chats) { found in
                                    RunChoiceRow(title: found.title, detail: HarnessChatText.age(of: found.updatedAt), isChosen: chat?.id == found.id) {
                                        openChoice = nil
                                        chat = found
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: 280)
                    }
                }
                .frame(width: 320)
            }
    }

    private func loadChats() async {
        chats = []
        // A chat holds many of these cards, and a sent one has nothing left to choose.
        guard !sent, let path = target?.path, harness != CursorCloud.harnessID else { return }
        isLoadingChats = true
        defer { isLoadingChats = false }
        let onMac = mac
        let found: [HarnessChat]
        if onMac == TheoLink.localName {
            found = await HarnessChats.list(harness: harness, folder: path)
        } else {
            let answer = await TheoLink.shared.ask("listChats", ["harness": harness, "folder": path])
            found = answer?["chats"].flatMap { try? LinkCoding.decoder.decode([HarnessChat].self, from: Data($0.utf8)) } ?? []
        }
        guard !Task.isCancelled else { return }
        chats = found
        // The bot's prompt can already say which chat it carries on.
        if chat == nil, let named = ProjectWords.chatToContinue(in: text) { chat = HarnessChatChoice(idOrTitle: named).match(in: found) }
    }

    // MARK: Start

    private func start() {
        let prompt = BotsT3.promptBlock(in: text) ?? text
        if isHere, let target, !FileManager.default.fileExists(atPath: target.path) {
            problem = "There's no folder at \(target.path) on this \(TheoLink.shortName(mac))."
            return
        }
        BotsStore.shared.submitToT3(prompt: prompt, title: BotsT3.projectTitle(in: text, prompt: prompt), repo: target, room: room, harness: harness, macName: mac,
                                    continuing: chat.map { HarnessChatChoice(idOrTitle: $0.id, title: $0.title) })
        sentHere = true
    }
}

/// One of the card's small choices: an icon, what's picked, and a chevron that says it opens.
struct RunChoiceChip: View {
    let symbol: String
    let text: String
    var help: String = ""
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary)
                Text(text).font(.system(size: 12)).foregroundColor(DS.Colors.textPrimary).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)).foregroundColor(DS.Colors.textTertiary)
            }
            .padding(.horizontal, 9).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? DS.Colors.hover : DS.Colors.selected))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointerCursor()
        .help(help)
    }
}

/// The list inside one of the card's choices.
private struct RunChoiceList<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 1) { content }.padding(6)
    }
}

private struct RunChoiceHeader: View {
    let text: String

    var body: some View {
        Text(text).font(TheoType.caption).foregroundColor(DS.Colors.textTertiary).lineLimit(1)
            .padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 2)
    }
}

private struct RunChoiceNote: View {
    let text: String

    var body: some View {
        Text(text).font(TheoType.caption).foregroundColor(DS.Colors.textSecondary).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8).padding(.vertical, 6)
    }
}

private struct RunChoiceRow: View {
    let title: String
    var detail: String? = nil
    var symbol: String? = nil
    var isChosen = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 11)).foregroundColor(DS.Colors.textSecondary).frame(width: 12)
                } else {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundColor(DS.Colors.textPrimary).frame(width: 12).opacity(isChosen ? 1 : 0)
                }
                Text(title).font(.system(size: 13)).foregroundColor(DS.Colors.textPrimary).lineLimit(1)
                Spacer(minLength: 8)
                if let detail { Text(detail).font(TheoType.caption).foregroundColor(DS.Colors.textTertiary).lineLimit(1).fixedSize() }
            }
            .padding(.horizontal, 8).frame(height: 28).contentShape(Rectangle())
        }
        .buttonStyle(SidebarButtonStyle(isSelected: false))
        .pointerCursor()
    }
}

/// Where a run is going on: "This MacBook Air" or "Mac Studio".
struct RunMacChip: View {
    let run: T3Run

    static func label(forMac name: String) -> String {
        name == TheoLink.localName ? "This \(TheoLink.shortName(name))" : TheoLink.shortName(name)
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "laptopcomputer").font(.system(size: 9.5))
            Text(Self.label(forMac: run.origin ?? TheoLink.localName)).font(.system(size: 11, weight: .medium)).lineLimit(1)
        }
        .foregroundColor(DS.Colors.textSecondary)
        .padding(.horizontal, 7).frame(height: 20)
        .background(Capsule().fill(DS.Colors.selected))
        .fixedSize()
    }
}
