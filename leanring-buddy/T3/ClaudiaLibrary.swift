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
        var items: [Item] = []
        func scan(_ directory: URL, kind: String, extensions: Set<String>, titlePrefix: String = "") {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
            for name in names {
                let url = directory.appendingPathComponent(name)
                guard extensions.contains(url.pathExtension.lowercased()),
                      let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                      let date = attributes[.modificationDate] as? Date else { continue }
                let title = titlePrefix + url.deletingPathExtension().lastPathComponent
                items.append(Item(id: id(for: url), kind: kind, title: title, date: date, url: url))
            }
        }
        scan(home.appendingPathComponent("Clicky Notes"), kind: "notes", extensions: ["md"])
        scan(home.appendingPathComponent("Clicky Notes/Research"), kind: "research", extensions: ["md"])
        scan(home.appendingPathComponent("Pictures/Clicky"), kind: "whiteboard", extensions: ["png"])
        scan(home.appendingPathComponent("Desktop/\(SnapshotCapture.screenshotsFolderName)"), kind: "screenshot", extensions: ["png"])
        return Array(items.sorted { $0.date > $1.date }.prefix(200))
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
        var text = "# Notes from Theo\n\nThe owner picked these notes for this task.\n"
        for note in notes {
            let body = (try? String(contentsOf: note.url, encoding: .utf8)) ?? ""
            text += "\n\n---\n\n## \(note.title)\n\n\(body)"
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("theo-notes-\(UUID().uuidString.prefix(8)).md")
        return (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil ? url : nil
    }
}
