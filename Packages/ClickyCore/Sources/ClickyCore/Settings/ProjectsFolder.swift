//
//  ProjectsFolder.swift
//  ClickyCore
//
//  Where Theo makes new project folders and lists the owner's projects
//  (`v2.code.projectsFolder`). The default is ~/Projects, but plenty of people
//  keep their code in ~/Code, ~/Developer or ~/src, so it's a setting. Nothing
//  here touches the disk: the folder is only made when the first project needs it.
//

import Foundation

public enum ProjectsFolder {
    /// What the setting holds when the owner never changed it.
    public static let defaultSetting = "~/Projects"

    /// The folder as an absolute path, from what the setting holds.
    /// Empty or missing: ~/Projects. "~/x": inside the home folder. A bare name ("Code"): inside the home folder too.
    public static func resolvedPath(setting: String?, homeDirectory: String) -> String {
        let trimmedSetting = (setting ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let chosenSetting = trimmedSetting.isEmpty ? defaultSetting : trimmedSetting
        let homeWithoutTrailingSlash = withoutTrailingSlashes(homeDirectory)
        let absolutePath: String
        if chosenSetting == "~" {
            absolutePath = homeWithoutTrailingSlash
        } else if chosenSetting.hasPrefix("~/") {
            absolutePath = homeWithoutTrailingSlash + "/" + String(chosenSetting.dropFirst(2))
        } else if chosenSetting.hasPrefix("/") {
            absolutePath = chosenSetting
        } else {
            absolutePath = homeWithoutTrailingSlash + "/" + chosenSetting
        }
        return withoutTrailingSlashes((absolutePath as NSString).standardizingPath)
    }

    /// How the folder is written to the owner and to agents: "~/Projects" when it's in the home folder, else the full path.
    /// Agents' shells expand "~", and it reads the same on any Mac.
    public static func words(forPath folderPath: String, homeDirectory: String) -> String {
        let folder = withoutTrailingSlashes(folderPath)
        let home = withoutTrailingSlashes(homeDirectory)
        if folder == home { return "~" }
        if folder.hasPrefix(home + "/") { return "~" + String(folder.dropFirst(home.count)) }
        return folder
    }

    /// The same for a folder on another Mac, whose home folder this Mac doesn't know: "/Users/<name>/x" reads as "~/x".
    public static func words(forOtherMacPath folderPath: String) -> String {
        let components = withoutTrailingSlashes(folderPath).split(separator: "/", omittingEmptySubsequences: true)
        guard components.count >= 2, components[0] == "Users" else { return folderPath }
        let homeDirectory = "/Users/" + String(components[1])
        return words(forPath: folderPath, homeDirectory: homeDirectory)
    }

    /// What to save for a folder the owner picked: "~/x" for a folder in the home folder, so the setting survives a new
    /// user name on a new Mac, else the full path.
    public static func setting(forChosenPath chosenPath: String, homeDirectory: String) -> String {
        words(forPath: chosenPath, homeDirectory: homeDirectory)
    }

    static func withoutTrailingSlashes(_ path: String) -> String {
        var result = path
        while result.count > 1, result.hasSuffix("/") { result.removeLast() }
        return result
    }
}

/// The folders scanned for local clones when the owner hasn't listed their own.
public enum CodeRepoRoots {
    /// The folder an earlier build scanned by default. It was the original developer's own scratch folder, so it's
    /// no longer a default, but a Mac that already has it keeps scanning it (see `rootsToKeepEarlierDefault`).
    public static let retiredDefaultRoot = "~/jstest"

    /// The defaults, with the projects folder first when the owner moved it somewhere the defaults don't cover.
    public static func defaultRoots(projectsFolderSetting: String?, homeDirectory: String) -> [String] {
        let baseRoots = ClickySettings.defaultCodeRepoRoots
        let projectsFolderPath = ProjectsFolder.resolvedPath(setting: projectsFolderSetting, homeDirectory: homeDirectory)
        let projectsFolderWords = ProjectsFolder.words(forPath: projectsFolderPath, homeDirectory: homeDirectory)
        let alreadyCovered = baseRoots.contains { ProjectsFolder.resolvedPath(setting: $0, homeDirectory: homeDirectory) == projectsFolderPath }
        return alreadyCovered ? baseRoots : [projectsFolderWords] + baseRoots
    }

    /// Run once on a Mac upgrading from the build that scanned ~/jstest by default: if the owner never listed their own
    /// roots and that folder exists, the old list is saved as their own so nothing they had disappears.
    /// Nil: nothing to save.
    public static func rootsToKeepEarlierDefault(savedRoots: [String]?, retiredRootExists: Bool) -> [String]? {
        guard savedRoots == nil, retiredRootExists else { return nil }
        return ClickySettings.defaultCodeRepoRoots + [retiredDefaultRoot]
    }
}

/// Where coding hand-offs go when the owner hasn't picked: a harness they actually have.
public enum CodingTargetDefault {
    /// The first harness (in the catalog's order) that's installed and signed in, else the first installed one,
    /// else `fallback` (Setup then shows how to install one).
    public static func choose(orderedHarnessIDs: [String], readyHarnessIDs: Set<String>, installedHarnessIDs: Set<String>, fallback: String) -> String {
        if let firstReady = orderedHarnessIDs.first(where: { readyHarnessIDs.contains($0) }) { return firstReady }
        if let firstInstalled = orderedHarnessIDs.first(where: { installedHarnessIDs.contains($0) }) { return firstInstalled }
        return fallback
    }
}
