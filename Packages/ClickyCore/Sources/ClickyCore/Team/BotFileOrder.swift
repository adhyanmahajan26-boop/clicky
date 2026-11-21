//
//  BotFileOrder.swift
//  ClickyCore
//
//  Files a bot made, shown in the chat as attachment cards, and copies of them on the owner's Desktop or in Downloads.
//  A bot writes the file in its memory folder and adds a line:
//    [FILE: report.md]                       the file goes in the chat as a card (open, Show in Finder, drag out, save).
//    [SAVE FILE: report.pdf -> Desktop]      Vello copies it to the Desktop (or Downloads), only when the owner asked.
//  Bots can't write outside their memory folder, so this is how a file reaches the owner. The app's side is
//  `Bots/BotFileCards.swift`; Windows and Linux: `crossplatform/crates/theo-core/src/files.rs`.
//

import Foundation

public enum BotFileOrder {
    public static let maximumAttachedPerReply = 5
    public static let maximumSavedPerReply = 5

    /// Where a copy can go. Only these two: a bot never picks any other folder on the owner's computer.
    public enum Place: String, CaseIterable, Equatable, Sendable {
        case desktop
        case downloads

        /// The folder's name inside the home folder, and what the owner sees.
        public var folderName: String {
            switch self {
            case .desktop: return "Desktop"
            case .downloads: return "Downloads"
            }
        }

        /// "Desktop", "desktop", "my desktop", "the Downloads folder", "downloads".
        public static func named(_ words: String) -> Place? {
            let lowered = words.lowercased()
            if lowered.contains("desktop") { return .desktop }
            if lowered.contains("download") { return .downloads }
            return nil
        }
    }

    public struct SaveOrder: Equatable, Sendable {
        public var file: String
        public var place: Place

        public init(file: String, place: Place) {
            self.file = file
            self.place = place
        }
    }

    private static let attachTag = try! NSRegularExpression(pattern: #"(?i)\[\s*FILE\s*:\s*([^\]\n]{1,240}?)\s*\]"#)
    private static let saveTag = try! NSRegularExpression(pattern: #"(?i)\[\s*SAVE\s+FILE\s*:\s*([^\]\n]{1,280}?)\s*\]"#)

    /// The reply without its [FILE:] and [SAVE FILE:] lines, the files to show, and the copies asked for.
    public static func extract(from text: String) -> (text: String, attached: [String], saves: [SaveOrder]) {
        let saved = BotTagWords.take(saveTag, from: text)
        let attached = BotTagWords.take(attachTag, from: saved.text)
        let saves = saved.bodies.compactMap(saveOrder(from:))
        return (attached.text, Array(attached.bodies.prefix(maximumAttachedPerReply)), Array(saves.prefix(maximumSavedPerReply)))
    }

    /// "report.pdf -> Desktop", "report.pdf to Downloads", "report.pdf: desktop". Nil without a place Vello knows.
    static func saveOrder(from body: String) -> SaveOrder? {
        let separators = ["->", "→", "=>", " to ", ":"]
        for separator in separators {
            guard let range = body.range(of: separator, options: [.caseInsensitive, .backwards]) else { continue }
            let file = body[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let placeWords = body[range.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !file.isEmpty, let place = Place.named(placeWords) else { continue }
            return SaveOrder(file: file, place: place)
        }
        return nil
    }

    // MARK: The chat card

    /// A chat message whose `card` is this shows the file as an attachment card.
    public static let cardPrefix = "file|"

    public static func card(forPath path: String) -> String { cardPrefix + path }

    /// The file a message's card holds, or for a note from before the cards ("Vello made the PDF x.pdf for Ada: …\n/path/x.pdf"),
    /// the path on its last line.
    public static func path(card: String?, noteText: String?) -> String? {
        if let card, card.hasPrefix(cardPrefix) {
            let path = String(card.dropFirst(cardPrefix.count))
            return path.hasPrefix("/") ? path : nil
        }
        guard let noteText, noteText.hasPrefix("Vello made the PDF ") else { return nil }
        let lastLine = noteText.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return lastLine.hasPrefix("/") && lastLine.lowercased().hasSuffix(".pdf") ? lastLine : nil
    }

    /// An old PDF note without its link and path lines, which the card now shows.
    public static func noteWithoutPath(_ text: String) -> String {
        guard text.hasPrefix("Vello made the PDF "), let firstLine = text.split(separator: "\n").first else { return text }
        let line = String(firstLine)
        guard let colon = line.range(of: ": [") else { return line }
        return String(line[..<colon.lowerBound]) + "."
    }

    // MARK: Copies

    /// A name that isn't taken in the folder yet: "report.pdf", then "report 2.pdf", "report 3.pdf". Nothing already there is replaced.
    public static func freeName(for name: String, isTaken: (String) -> Bool) -> String {
        guard isTaken(name) else { return name }
        let url = URL(fileURLWithPath: name)
        let fileExtension = url.pathExtension
        let stem = fileExtension.isEmpty ? name : String(name.dropLast(fileExtension.count + 1))
        for number in 2...999 {
            let candidate = fileExtension.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(fileExtension)"
            if !isTaken(candidate) { return candidate }
        }
        return "\(stem) \(UUID().uuidString.prefix(8))" + (fileExtension.isEmpty ? "" : ".\(fileExtension)")
    }

    /// Files that would run something when opened (an app, a script, an installer, a shortcut to somewhere else). Open shows
    /// these in Finder instead, so a file a bot was talked into writing can't start a program with one click.
    public static let runsWhenOpenedExtensions: Set<String> = [
        "app", "command", "tool", "sh", "zsh", "bash", "csh", "ksh", "fish", "py", "rb", "pl", "php", "js", "jxa", "scpt", "scptd",
        "applescript", "workflow", "action", "pkg", "mpkg", "dmg", "terminal", "jar", "exe", "bat", "cmd", "ps1", "msi", "vbs",
        "webloc", "inetloc", "fileloc", "url", "desktop", "shortcut", "prefpane", "kext", "plugin", "bundle", "osax", "saver",
        "mobileconfig", "configprofile", "service", "appex"
    ]

    public static func opensDirectly(fileName: String) -> Bool {
        let fileExtension = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        return !runsWhenOpenedExtensions.contains(fileExtension)
    }

    // MARK: What bots are told

    public static func howTo(owner: String) -> String {
        "To give \(owner) a file you made, write it in your memory folder and put a line [FILE: file name] in your reply: " +
        "Vello shows it in the chat as an attachment \(owner) can open, drag out or save. " +
        "When \(owner) asks for a file on the Desktop or in Downloads, add a line [SAVE FILE: file name -> Desktop] (or -> Downloads): " +
        "Vello copies it there from your memory folder, so don't hand that to Pointer Assistant or tell \(owner) to copy it by hand. " +
        "A PDF you asked for with [PDF:] is in your memory folder too, under its own name ending .pdf. " +
        "Say a file is there only once Vello's line says so."
    }
}
