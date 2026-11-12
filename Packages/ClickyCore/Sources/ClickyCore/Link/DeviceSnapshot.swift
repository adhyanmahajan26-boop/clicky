//
//  DeviceSnapshot.swift
//  ClickyCore
//
//  What one Mac tells the other about itself over Theo Link: its project folders, which harnesses are ready and whether it has the
//  hidden screens. A run's folder, new folder and chat always come from the Mac it will run on, so the other Mac needs this to offer them.
//

import Foundation

public struct DeviceProject: Codable, Equatable, Sendable, Identifiable {
    public var name: String
    public var path: String
    public var modifiedAt: Date?
    public var id: String { path }

    public init(name: String, path: String, modifiedAt: Date? = nil) {
        self.name = name
        self.path = path
        self.modifiedAt = modifiedAt
    }
}

public struct DeviceSnapshot: Codable, Equatable, Sendable {
    /// The Mac's full name, as Theo Link knows it.
    public var name: String
    public var projectsFolder: String
    /// Newest first.
    public var projects: [DeviceProject]
    /// Harness or "api:<provider>" id: it can run on this Mac right now.
    public var harnesses: [String: Bool]
    public var hasScreens: Bool
    public var t3Version: String?
    /// This Mac fires routines, by its own setting.
    public var firesRoutines: Bool?

    public init(name: String, projectsFolder: String, projects: [DeviceProject], harnesses: [String: Bool], hasScreens: Bool, t3Version: String? = nil, firesRoutines: Bool? = nil) {
        self.name = name
        self.projectsFolder = projectsFolder
        self.projects = projects
        self.harnesses = harnesses
        self.hasScreens = hasScreens
        self.t3Version = t3Version
        self.firesRoutines = firesRoutines
    }
}

/// The folder menu on a run's card: the Mac's recent projects first, then the rest.
public enum ProjectFolderMenu {
    public static let maximumRecent = 5
    public static let maximumAll = 40

    /// `used`: the folders of recent runs on this Mac, newest first.
    public static func sections(projects: [DeviceProject], used: [String]) -> (recent: [DeviceProject], others: [DeviceProject]) {
        var recent: [DeviceProject] = []
        for path in used {
            if let project = projects.first(where: { $0.path == path }), !recent.contains(project) { recent.append(project) }
            if recent.count == maximumRecent { break }
        }
        let newest = projects.sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
        for project in newest where recent.count < maximumRecent && !recent.contains(project) { recent.append(project) }
        let others = projects.filter { !recent.contains($0) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return (recent, Array(others.prefix(maximumAll)))
    }
}

/// "Run it on the Studio", "build this on my MacBook Air": the Mac the owner named for a run. "studio" or "air", nil for anything else.
public enum CodingDeviceWords {
    public static func named(in text: String) -> String? {
        let words = CodingIntent.normalized(text).lowercased()
        let pattern = #"\b(?:on|to|from)\s+(?:the\s+|my\s+)?(mac\s?studio|studio|mac\s?book\s?air|mac\s?book|air)\b"#
        guard let range = words.range(of: pattern, options: .regularExpression) else { return nil }
        return words[range].contains("studio") ? "studio" : "air"
    }
}

/// A bot's memory on both Macs: each line once. A file stays exactly as it was, blank lines and all, and what only the other Mac has goes at its end.
public enum BotMemoryMerge {
    public static func union(_ mine: String, _ theirs: String) -> String {
        var seen = keys(of: mine)
        let theirKeys = keys(of: theirs)
        if seen == theirKeys { return mine }
        // Everything here is there too, and more: that file is the fuller one, and stays as it is.
        if seen.isSubset(of: theirKeys) { return theirs }
        var added: [String] = []
        for line in theirs.components(separatedBy: "\n") {
            let key = line.trimmingCharacters(in: .whitespaces)
            if !key.isEmpty, seen.insert(key).inserted { added.append(line) }
        }
        if added.isEmpty { return mine }
        return mine + (mine.hasSuffix("\n") ? "" : "\n") + added.joined(separator: "\n") + "\n"
    }

    /// The memory after hearing the other Mac's copy, when the copy heard from it last time (`lastTheirs`) is known: what that Mac
    /// dropped since is dropped here too, what it added since is added at the end, and what only this Mac has, or dropped, stays so.
    /// A tidy-up or a rewrite on either Mac then sticks, where a union would bring every old line back. Never heard before: the union.
    public static func merged(mine: String, theirs: String, lastTheirs: String?) -> String {
        guard let lastTheirs else { return union(mine, theirs) }
        let mineKeys = keys(of: mine), theirKeys = keys(of: theirs), lastKeys = keys(of: lastTheirs)
        if mineKeys == theirKeys { return mine }
        // Nothing changed here since that Mac's last copy: only it changed, and its file is taken as it is, layout and all.
        if mineKeys == lastKeys { return theirs }
        let dropped = lastKeys.subtracting(theirKeys)
        var seen = Set<String>()
        var kept: [String] = []
        for line in mine.components(separatedBy: "\n") {
            let key = line.trimmingCharacters(in: .whitespaces)
            if !key.isEmpty, dropped.contains(key) { continue }
            if !key.isEmpty { seen.insert(key) }
            kept.append(line)
        }
        var added: [String] = []
        for line in theirs.components(separatedBy: "\n") {
            let key = line.trimmingCharacters(in: .whitespaces)
            if !key.isEmpty, !lastKeys.contains(key), seen.insert(key).inserted { added.append(line) }
        }
        var text = kept.joined(separator: "\n")
        // Lines taken out can leave blank runs behind: two blank lines at most, and none at the start.
        while text.contains("\n\n\n") { text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        while text.hasPrefix("\n") { text.removeFirst() }
        if keys(of: text).isEmpty { text = "" }
        guard !added.isEmpty else { return text }
        return text + (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + added.joined(separator: "\n") + "\n"
    }

    private static func keys(of text: String) -> Set<String> {
        Set(text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    /// The same whatever order the lines are in, so two Macs holding the same lines don't keep asking each other.
    public static func digest(_ text: String) -> String {
        LinkCoding.digest(keys(of: text).sorted())
    }
}

/// One skill's SKILL.md as it travels over Theo Link. The key is "shared/<folder>" or "<bot id>/<folder>".
public struct SkillCopy: Codable, Equatable, Sendable {
    public var text: String
    public var modifiedAt: Date
    public init(text: String, modifiedAt: Date) {
        self.text = text
        self.modifiedAt = modifiedAt
    }
}

/// Skills on both Macs. `lastTheirs` is the set of skills the other Mac had when last heard from: one it has dropped since
/// is dropped here, one dropped here stays dropped, a new one on either side is kept, and an edit on both keeps the newer.
public enum BotSkillSync {
    /// The largest SKILL.md that travels: a skill is a page of steps, and the link carries everything in one message.
    public static let maximumBytes = 64_000

    /// A skill's key, or nil for a name that could reach outside its folder.
    public static func key(owner: String, folder: String) -> String? {
        let ok: (String) -> Bool = { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\\") && !$0.hasPrefix(".") }
        return ok(owner) && ok(folder) ? "\(owner)/\(folder)" : nil
    }

    public static func merged(mine: [String: SkillCopy], theirs: [String: SkillCopy], lastTheirs: Set<String>?) -> (write: [String: SkillCopy], delete: [String]) {
        let last = lastTheirs ?? []
        var write: [String: SkillCopy] = [:]
        var delete: [String] = []
        for (key, copy) in theirs {
            if let here = mine[key] {
                if here.text != copy.text, copy.modifiedAt > here.modifiedAt { write[key] = copy }
            } else if !last.contains(key) || lastTheirs == nil {
                // New there. (Had there before and gone here means it was dropped here: it stays dropped.)
                write[key] = copy
            }
        }
        for key in mine.keys where theirs[key] == nil && last.contains(key) { delete.append(key) }
        return (write, delete.sorted())
    }

    /// The same for the same skills and words, whatever order they were read in.
    public static func digest(_ skills: [String: SkillCopy]) -> String {
        LinkCoding.digest(skills.keys.sorted().map { "\($0)\n\(skills[$0]!.text)" })
    }
}
