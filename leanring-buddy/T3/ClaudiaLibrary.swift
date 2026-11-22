//
//  ClaudiaLibrary.swift
//  leanring-buddy
//
//  Claudia's notes library, shown in the Notes tab of her T3 Code section:
//  article notes (~/Clicky Notes), research briefs (~/Clicky Notes/Research),
//  whiteboards (~/Pictures/Clicky) and marked screenshots
//  (~/Desktop/Clicky Screenshots). The owner ticks items to "use in code";
//  a code task (Claudia's Claude Code mode, or any T3 Code agent through the
//  claudia_attachments tool) then gets those notes and screenshots.
//

import ClickyCore
import Foundation

enum ClaudiaLibrary {
    struct Item {
        let id: String
        let kind: String
        let title: String
        let date: Date
        let url: URL

        var isImage: Bool { ["png", "jpg", "jpeg"].contains(url.pathExtension.lowercased()) }

        var dictionary: [String: Any] {
            ["id": id, "kind": kind, "title": title, "date": ISO8601DateFormatter().string(from: date),
             "isImage": isImage, "selected": ClaudiaLibrary.selectedIDs.contains(id)]
        }
    }

    private static let selectionKey = "v2.library.selectedForCode"

    static var selectedIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: selectionKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: selectionKey) }
    }

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Every item, newest first (at most 200).
    static func items() -> [Item] {
        items(from: scanFiles(homePath: home.path, screenshotsFolderName: SnapshotCapture.screenshotsFolderName))
    }

    /// The same, with the folder scan run off the main thread: the Notes tab looks again every 2 s, and the scan used to
    /// run on the main thread (the app's default actor isolation kept its Task.detached there), costing clicks and scrolls.
    static func itemsWithoutBlocking() async -> [Item] {
        items(from: await scanFilesOffMainThread(homePath: home.path, screenshotsFolderName: SnapshotCapture.screenshotsFolderName))
    }

    private static func items(from scannedFiles: [ScannedFile]) -> [Item] {
        scannedFiles.map { scannedFile in
            let url = URL(fileURLWithPath: scannedFile.path)
            return Item(id: id(for: url), kind: scannedFile.kind, title: scannedFile.title, date: scannedFile.date, url: url)
        }
    }

    /// A file the scan found, as plain values so the scan can run on any thread.
    nonisolated struct ScannedFile: Sendable {
        let kind: String
        let title: String
        let date: Date
        let path: String
    }

    @concurrent nonisolated private static func scanFilesOffMainThread(homePath: String, screenshotsFolderName: String) async -> [ScannedFile] {
        scanFiles(homePath: homePath, screenshotsFolderName: screenshotsFolderName)
    }

    /// The library's folders, newest first, at most 200 files.
    nonisolated private static func scanFiles(homePath: String, screenshotsFolderName: String) -> [ScannedFile] {
        let home = URL(fileURLWithPath: homePath, isDirectory: true)
        var scannedFiles: [ScannedFile] = []
        func scan(_ directory: URL, kind: String, extensions: Set<String>) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
            for name in names {
                let url = directory.appendingPathComponent(name)
                guard extensions.contains(url.pathExtension.lowercased()),
                      let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                      let date = attributes[.modificationDate] as? Date else { continue }
                scannedFiles.append(ScannedFile(kind: kind, title: url.deletingPathExtension().lastPathComponent, date: date, path: url.path))
            }
        }
        scan(home.appendingPathComponent("Clicky Notes"), kind: "notes", extensions: ["md"])
        scan(home.appendingPathComponent("Clicky Notes/Research"), kind: "research", extensions: ["md"])
        scan(home.appendingPathComponent("Pictures/Clicky"), kind: "whiteboard", extensions: ["png"])
        scan(home.appendingPathComponent("Desktop/\(screenshotsFolderName)"), kind: "screenshot", extensions: ["png"])
        return Array(scannedFiles.sorted { $0.date > $1.date }.prefix(200))
    }

    static func item(id: String) -> Item? { items().first { $0.id == id } }

    /// A stable id for a file: its path, URL-safe.
    static func id(for url: URL) -> String {
        Data(url.path.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "=", with: "")
    }

    static var selectedItems: [Item] {
        let selected = selectedIDs
        return items().filter { selected.contains($0.id) }
    }

    /// The selected notes as one Markdown file (for a code task's attachments).
    static func writeSelectedNotesBundle() -> URL? {
        let notes = selectedItems.filter { !$0.isImage }
        guard !notes.isEmpty else { return nil }
        var text = "# Notes from Vello\n\nThe owner picked these notes for this task.\n"
        for note in notes {
            let body = (try? String(contentsOf: note.url, encoding: .utf8)) ?? ""
            text += "\n\n---\n\n## \(note.title)\n\n\(body)"
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("theo-notes-\(UUID().uuidString.prefix(8)).md")
        return (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil ? url : nil
    }
}
