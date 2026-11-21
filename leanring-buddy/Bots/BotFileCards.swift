//
//  BotFileCards.swift
//  leanring-buddy
//
//  Files a bot made, shown in its chat as attachment cards: the file's icon, name and size, Open, Show in Finder, Save to
//  Desktop or Downloads, and drag it out to Finder, Mail or anywhere else. A bot's [PDF:], [FILE:] and [SAVE FILE: … -> Desktop]
//  lines come here after its turn. The rules (tags, safe names, what never opens straight away) are ClickyCore `BotFileOrder`.
//

import AppKit
import ClickyCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - After a bot's turn

extension BotsStore {
    /// The PDFs it asked for, the files it attached and the copies it asked for, each said in the chat as a card or a plain note.
    /// A copy to the Desktop or Downloads only happens on a turn the owner's own words started.
    func carryOutFileOrders(pdfs: [String], attached: [String], saves: [BotFileOrder.SaveOrder], bot: NativeBot,
                            conversationID: String, fromOwner: Bool, exchangeID: String?) {
        let folder = BotMemory.file(botID: bot.id).deletingLastPathComponent()
        for name in pdfs {
            do {
                let pdf = try BotPDF.make(named: name, in: folder)
                postFileCard(text: "Vello made the PDF \(pdf.lastPathComponent) for \(bot.name).", file: pdf, conversationID: conversationID, exchangeID: exchangeID)
            } catch {
                post(BotChatMessage(author: Self.noteAuthor, text: "Vello couldn't make a PDF for \(bot.name): \(error.localizedDescription)", exchangeID: exchangeID), to: conversationID)
            }
        }
        for name in attached {
            guard let file = BotFileActions.fileInBotFolder(named: name, folder: folder) else {
                post(BotChatMessage(author: Self.noteAuthor, text: "\(bot.name) wanted to share \(name), but there's no file by that name in its memory folder.", exchangeID: exchangeID), to: conversationID)
                continue
            }
            postFileCard(text: "\(bot.name) shared \(file.lastPathComponent).", file: file, conversationID: conversationID, exchangeID: exchangeID)
        }
        for save in saves {
            guard fromOwner else {
                post(BotChatMessage(author: Self.noteAuthor, text: "\(bot.name) asked to copy \(save.file) to your \(save.place.folderName), but you didn't ask for that on this turn, so Vello didn't copy it.", exchangeID: exchangeID), to: conversationID)
                continue
            }
            guard let file = BotFileActions.fileInBotFolder(named: save.file, folder: folder) else {
                post(BotChatMessage(author: Self.noteAuthor, text: "Vello couldn't copy \(save.file) to your \(save.place.folderName): there's no file by that name in \(bot.name)'s memory folder.", exchangeID: exchangeID), to: conversationID)
                continue
            }
            do {
                let copy = try BotFileActions.saveCopy(of: file, to: save.place)
                postFileCard(text: "Vello put \(copy.lastPathComponent) on your \(save.place.folderName).", file: copy, conversationID: conversationID, exchangeID: exchangeID)
            } catch {
                post(BotChatMessage(author: Self.noteAuthor, text: "Vello couldn't copy \(file.lastPathComponent) to your \(save.place.folderName): \(error.localizedDescription)", exchangeID: exchangeID), to: conversationID)
            }
        }
    }

    private func postFileCard(text: String, file: URL, conversationID: String, exchangeID: String?) {
        var message = BotChatMessage(author: Self.noteAuthor, text: text, exchangeID: exchangeID)
        message.card = BotFileOrder.card(forPath: file.path)
        post(message, to: conversationID)
    }
}

// MARK: - The file actions

@MainActor
enum BotFileActions {
    /// A file the bot named, only inside its own memory folder, and only a file (not a folder).
    static func fileInBotFolder(named name: String, folder: URL) -> URL? {
        guard let file = BotPDFOrder.file(named: name, in: folder) else { return nil }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isFolder), !isFolder.boolValue else { return nil }
        return file
    }

    /// The owner's Desktop or Downloads. In a test profile the home folder is the profile's own, so tests never touch the real ones.
    static func folder(for place: BotFileOrder.Place) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(place.folderName, isDirectory: true)
    }

    /// Copies the file into the Desktop or Downloads under a name that isn't taken yet, and returns the copy.
    static func saveCopy(of file: URL, to place: BotFileOrder.Place) throws -> URL {
        let destinationFolder = folder(for: place)
        try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        let name = BotFileOrder.freeName(for: file.lastPathComponent) { candidate in
            FileManager.default.fileExists(atPath: destinationFolder.appendingPathComponent(candidate).path)
        }
        let copy = destinationFolder.appendingPathComponent(name)
        try FileManager.default.copyItem(at: file, to: copy)
        return copy
    }

    /// Opens it in its own app. Something that would run a program (an app, a script, an installer) is shown in Finder instead.
    static func open(_ file: URL) {
        guard BotFileOrder.opensDirectly(fileName: file.lastPathComponent) else {
            showInFinder(file)
            return
        }
        if TheoProfile.isTest {
            TheoOpen.record("open:" + file.path)
            return
        }
        NSWorkspace.shared.open(file)
    }

    static func showInFinder(_ file: URL) {
        if TheoProfile.isTest {
            TheoOpen.record("reveal:" + file.path)
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }
}

// MARK: - The card

/// A file in the chat: icon, name, kind and size, Open, Show in Finder and Save to. Drag it anywhere to copy it out.
struct BotFileCard: View {
    let path: String
    @State private var savedTo: [BotFileOrder.Place: URL] = [:]
    @State private var problem: String?
    @State private var hovering = false

    private var file: URL { URL(fileURLWithPath: path) }

    var body: some View {
        let exists = FileManager.default.fileExists(atPath: path)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 36, height: 36)
                    .opacity(exists ? 1 : 0.4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.lastPathComponent)
                        .font(TheoType.bodyMedium)
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(exists ? detailLine : "This file isn't on this Mac any more.")
                        .font(TheoType.micro)
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if exists {
                    Button("Open") { BotFileActions.open(file) }
                        .buttonStyle(.theo(.primary, .small))
                        .pointerCursor()
                        .help("Open \(file.lastPathComponent)")
                }
            }
            if exists {
                HStack(spacing: 6) {
                    Button("Show in Finder") { BotFileActions.showInFinder(file) }
                        .buttonStyle(.theo(.ghost, .small))
                        .pointerCursor()
                    ForEach(BotFileOrder.Place.allCases, id: \.self) { place in
                        if let copy = savedTo[place] {
                            Button("Saved to \(place.folderName)") { BotFileActions.showInFinder(copy) }
                                .buttonStyle(.theo(.ghost, .small))
                                .pointerCursor()
                                .help("Show the copy in Finder")
                        } else {
                            Button("Save to \(place.folderName)") { save(to: place) }
                                .buttonStyle(.theo(.secondary, .small))
                                .pointerCursor()
                                .help("Copy \(file.lastPathComponent) to your \(place.folderName)")
                        }
                    }
                    Spacer(minLength: 0)
                    Text("Drag to copy")
                        .font(TheoType.micro)
                        .foregroundColor(DS.Colors.textTertiary)
                        .opacity(hovering ? 1 : 0)
                }
            }
            if let problem {
                Text(problem).font(TheoType.micro).foregroundColor(DS.Colors.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: 460, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Colors.surface1))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(hovering && exists ? DS.Colors.borderStrong : DS.Colors.borderSubtle, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hovering = $0 }
        // Dragged out it's the file itself, so Finder copies it and Mail or a browser attaches it.
        .onDrag {
            guard FileManager.default.fileExists(atPath: path) else { return NSItemProvider() }
            let provider = NSItemProvider(contentsOf: file) ?? NSItemProvider()
            provider.suggestedName = file.lastPathComponent
            return provider
        }
        .contextMenu {
            if exists {
                Button("Open") { BotFileActions.open(file) }
                Button("Show in Finder") { BotFileActions.showInFinder(file) }
                ForEach(BotFileOrder.Place.allCases, id: \.self) { place in
                    Button("Save to \(place.folderName)") { save(to: place) }
                }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                }
            }
        }
        .padding(.leading, 36)
    }

    /// "PDF document · 182 KB".
    private var detailLine: String {
        let kind = (try? file.resourceValues(forKeys: [.localizedTypeDescriptionKey]).localizedTypeDescription) ?? file.pathExtension.uppercased()
        let bytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        return [kind, size].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func save(to place: BotFileOrder.Place) {
        do {
            savedTo[place] = try BotFileActions.saveCopy(of: file, to: place)
            problem = nil
        } catch {
            problem = "Couldn't save it to your \(place.folderName): \(error.localizedDescription)"
        }
    }
}
