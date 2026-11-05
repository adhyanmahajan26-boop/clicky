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

    private static func keys(of text: String) -> Set<String> {
        Set(text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    /// The same whatever order the lines are in, so two Macs holding the same lines don't keep asking each other.
    public static func digest(_ text: String) -> String {
        LinkCoding.digest(keys(of: text).sorted())
    }
}
