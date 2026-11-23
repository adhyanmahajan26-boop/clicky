//
//  EngineMadeImages.swift
//  ClickyCore
//
//  Images a bot's engine made with its own image tool, brought into the chat. Codex's image tool saves each picture in
//  <Codex home>/generated_images/<thread id>/ and tells the model "the generated image is already displayed to the user",
//  which is true in Codex's own app but not in Vello: Vello only reads the reply's words, and a Codex bot runs read-only, so
//  it can't copy the picture into its memory folder and write [FILE:] itself. After a Codex turn Vello copies the pictures
//  made on that turn into the bot's memory folder and adds a [FILE:] line for each, so they arrive as attachment cards
//  through the usual `BotFileOrder` path. The app's side is `Harness/HarnessBotEngines.swift` (`runCodex`); Windows and
//  Linux: `crossplatform/crates/theo-core/src/files.rs` (`codex_images_made_this_turn`).
//

import Foundation

public enum EngineMadeImages {
    /// The kinds of picture an image tool saves. Anything else in its folder is left alone.
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "gif"]

    /// A file written a moment before the turn's clock started still counts (the two clocks are read separately).
    public static let startSlackSeconds: TimeInterval = 2

    /// Where Codex keeps the pictures of one thread: `<Codex home>/generated_images/<thread id>`. Nil for a thread id that
    /// could reach outside that folder.
    public static func codexFolder(codexHome: URL, threadID: String) -> URL? {
        let trimmed = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains("\\"), !trimmed.hasPrefix(".") else { return nil }
        return codexHome.appendingPathComponent("generated_images", isDirectory: true).appendingPathComponent(trimmed, isDirectory: true)
    }

    /// Codex's home: `CODEX_HOME` when it's set for the engine, else `.codex` in the home folder the engine sees.
    public static func codexHome(environment: [String: String], home: String) -> URL {
        if let set = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespaces), set.hasPrefix("/") {
            return URL(fileURLWithPath: set, isDirectory: true)
        }
        return URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".codex", isDirectory: true)
    }

    public struct ListedFile: Equatable, Sendable {
        public var name: String
        public var modified: Date

        public init(name: String, modified: Date) {
            self.name = name
            self.modified = modified
        }
    }

    /// The pictures in the folder that were written on this turn, oldest first, at most as many as one reply may attach.
    /// Earlier turns' pictures stay in the same thread's folder, so they're told apart by when they were written.
    public static func madeThisTurn(_ files: [ListedFile], turnStarted: Date) -> [String] {
        let earliest = turnStarted.addingTimeInterval(-startSlackSeconds)
        let pictures = files.filter { file in
            imageExtensions.contains(URL(fileURLWithPath: file.name).pathExtension.lowercased()) && file.modified >= earliest
        }
        let oldestFirst = pictures.sorted { first, second in
            first.modified == second.modified ? first.name < second.name : first.modified < second.modified
        }
        return Array(oldestFirst.map(\.name).prefix(BotFileOrder.maximumAttachedPerReply))
    }

    /// What the copy in the bot's memory folder is called: "image.png", then "image 2.png" and so on, so nothing there is replaced.
    public static func nameInBotFolder(forOriginal originalName: String, isTaken: (String) -> Bool) -> String {
        let fileExtension = URL(fileURLWithPath: originalName).pathExtension.lowercased()
        let plainName = fileExtension.isEmpty ? "image.png" : "image.\(fileExtension)"
        return BotFileOrder.freeName(for: plainName, isTaken: isTaken)
    }

    /// The reply with a [FILE:] line for each copied picture, unless the reply already names it.
    public static func reply(_ text: String, attaching copiedNames: [String]) -> String {
        let alreadyAttached = Set(BotFileOrder.extract(from: text).attached)
        let lines = copiedNames.filter { !alreadyAttached.contains($0) }.map { "[FILE: \($0)]" }
        guard !lines.isEmpty else { return text }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.isEmpty ? "" : trimmed + "\n\n") + lines.joined(separator: "\n")
    }
}
