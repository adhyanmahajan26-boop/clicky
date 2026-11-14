import Foundation
import Testing
@testable import ClickyCore

/// Nothing about where things are on the original developer's Mac: the projects folder is a setting, Theo's own
/// source is known by its contents, the PATH comes from the owner's own shell, and coding goes to a harness they have.
@Suite struct ProjectsFolderSettingTests {
    let home = "/Users/someone"

    @Test func defaultIsProjectsInTheHomeFolder() {
        #expect(ProjectsFolder.resolvedPath(setting: nil, homeDirectory: home) == "/Users/someone/Projects")
        #expect(ProjectsFolder.resolvedPath(setting: "", homeDirectory: home) == "/Users/someone/Projects")
        #expect(ProjectsFolder.resolvedPath(setting: "   ", homeDirectory: home) == "/Users/someone/Projects")
        #expect(ProjectsFolder.resolvedPath(setting: ProjectsFolder.defaultSetting, homeDirectory: home) == "/Users/someone/Projects")
    }

    @Test func otherFoldersResolveAgainstTheHomeFolder() {
        #expect(ProjectsFolder.resolvedPath(setting: "~/Code", homeDirectory: home) == "/Users/someone/Code")
        #expect(ProjectsFolder.resolvedPath(setting: "~/dev/src/", homeDirectory: home + "/") == "/Users/someone/dev/src")
        #expect(ProjectsFolder.resolvedPath(setting: "Code", homeDirectory: home) == "/Users/someone/Code")
        #expect(ProjectsFolder.resolvedPath(setting: "/Volumes/Work/repos/", homeDirectory: home) == "/Volumes/Work/repos")
        #expect(ProjectsFolder.resolvedPath(setting: "~", homeDirectory: home) == "/Users/someone")
    }

    @Test func wordsUseTheTildeInsideTheHomeFolder() {
        #expect(ProjectsFolder.words(forPath: "/Users/someone/Projects", homeDirectory: home) == "~/Projects")
        #expect(ProjectsFolder.words(forPath: "/Users/someone/Code/", homeDirectory: home) == "~/Code")
        #expect(ProjectsFolder.words(forPath: "/Volumes/Work/repos", homeDirectory: home) == "/Volumes/Work/repos")
        // A folder that only starts with the same letters isn't inside the home folder.
        #expect(ProjectsFolder.words(forPath: "/Users/someoneelse/Projects", homeDirectory: home) == "/Users/someoneelse/Projects")
        #expect(ProjectsFolder.words(forOtherMacPath: "/Users/other/Code") == "~/Code")
        #expect(ProjectsFolder.words(forOtherMacPath: "/Volumes/Work/repos") == "/Volumes/Work/repos")
    }

    @Test func aChosenFolderIsSavedRelativeToHome() {
        #expect(ProjectsFolder.setting(forChosenPath: "/Users/someone/Code", homeDirectory: home) == "~/Code")
        #expect(ProjectsFolder.setting(forChosenPath: "/Volumes/Work", homeDirectory: home) == "/Volumes/Work")
    }

    @Test func settingIsListedWithItsDefault() {
        #expect(ClickySettings.Keys.projectsFolder == "v2.code.projectsFolder")
        let entry = ClickySettingsCatalog.entries.first { $0.key == ClickySettings.Keys.projectsFolder }
        #expect(entry?.kind == .text(defaultValue: "~/Projects"))
    }
}

@Suite struct CodeRepoRootsTests {
    let home = "/Users/someone"

    @Test func scratchFolderIsNotADefault() {
        #expect(!ClickySettings.defaultCodeRepoRoots.contains("~/jstest"))
        #expect(CodeRepoRoots.defaultRoots(projectsFolderSetting: nil, homeDirectory: home) == ClickySettings.defaultCodeRepoRoots)
    }

    @Test func aMovedProjectsFolderIsScannedFirst() {
        #expect(CodeRepoRoots.defaultRoots(projectsFolderSetting: "~/Code", homeDirectory: home) == ["~/Code"] + ClickySettings.defaultCodeRepoRoots)
        // Already one of the defaults: not listed twice.
        #expect(CodeRepoRoots.defaultRoots(projectsFolderSetting: "~/Developer", homeDirectory: home) == ClickySettings.defaultCodeRepoRoots)
    }

    @Test func aMacThatHadTheOldDefaultKeepsIt() {
        #expect(CodeRepoRoots.rootsToKeepEarlierDefault(savedRoots: nil, retiredRootExists: true) == ClickySettings.defaultCodeRepoRoots + ["~/jstest"])
        // No such folder, or the owner's own list: nothing changes.
        #expect(CodeRepoRoots.rootsToKeepEarlierDefault(savedRoots: nil, retiredRootExists: false) == nil)
        #expect(CodeRepoRoots.rootsToKeepEarlierDefault(savedRoots: ["~/Code"], retiredRootExists: true) == nil)
    }
}

@Suite struct OwnSourceCheckTests {
    static func fileSystem(existing: Set<String>, gitFiles: [String: String] = [:]) -> RepoFileSystem {
        RepoFileSystem(exists: { existing.contains($0) || gitFiles[$0] != nil },
                       isDirectory: { existing.contains($0) && gitFiles[$0] == nil },
                       readText: { gitFiles[$0] })
    }

    @Test func theoSourceIsDeniedWhereverItIsCloned() {
        let files = Self.fileSystem(existing: ["/Volumes/Work/theo/leanring-buddy.xcodeproj", "/tmp/core-only/Packages/ClickyCore/Package.swift"])
        #expect(CodeRepoDenylist.isDeniedLocalRoot("/Volumes/Work/theo", fileSystem: files))
        #expect(CodeRepoDenylist.isDeniedLocalRoot("/tmp/core-only", fileSystem: files))
    }

    @Test func aFolderNamedClickyWithoutTheoInsideIsAllowed() {
        let files = Self.fileSystem(existing: ["/Users/someone/Projects/clicky", "/Users/someone/Projects/clicky/.git"])
        #expect(!CodeRepoDenylist.isDeniedLocalRoot("/Users/someone/Projects/clicky", homeDirectory: "/Users/someone", fileSystem: files))
    }

    @Test func aWorktreeOfTheoSourceIsDenied() {
        let files = Self.fileSystem(existing: ["/src/theo/leanring-buddy.xcodeproj", "/src/theo-fix"],
                                    gitFiles: ["/src/theo-fix/.git": "gitdir: /src/theo/.git/worktrees/theo-fix\n"])
        #expect(CodeRepoDenylist.isDeniedLocalRoot("/src/theo-fix", fileSystem: files))
    }
}

@Suite struct LoginShellTests {
    @Test func usesTheOwnersShell() {
        let isExecutable: (String) -> Bool = { _ in true }
        #expect(LoginShell.shellPath(environment: ["SHELL": "/bin/bash"], systemRecordedShellPath: "/bin/zsh", isExecutableFile: isExecutable) == "/bin/bash")
        #expect(LoginShell.shellPath(environment: ["SHELL": "/opt/homebrew/bin/fish"], systemRecordedShellPath: nil, isExecutableFile: isExecutable) == "/opt/homebrew/bin/fish")
        // No $SHELL (some launchd starts): the one in the account record.
        #expect(LoginShell.shellPath(environment: [:], systemRecordedShellPath: "/bin/bash", isExecutableFile: isExecutable) == "/bin/bash")
    }

    @Test func fallsBackToZsh() {
        let isExecutable: (String) -> Bool = { _ in true }
        #expect(LoginShell.shellPath(environment: [:], systemRecordedShellPath: nil, isExecutableFile: isExecutable) == "/bin/zsh")
        // A shell that doesn't take POSIX-style -c or print PATH with colons, or one that isn't there.
        #expect(LoginShell.shellPath(environment: ["SHELL": "/opt/homebrew/bin/nu"], systemRecordedShellPath: nil, isExecutableFile: isExecutable) == "/bin/zsh")
        #expect(LoginShell.shellPath(environment: ["SHELL": "/bin/bash"], systemRecordedShellPath: nil, isExecutableFile: { _ in false }) == "/bin/zsh")
        #expect(LoginShell.shellPath(environment: ["SHELL": "bash"], systemRecordedShellPath: nil, isExecutableFile: isExecutable) == "/bin/zsh")
    }

    @Test func argumentsRunOneCommand() {
        #expect(LoginShell.arguments(forCommand: "echo hi", interactive: false) == ["-l", "-c", "echo hi"])
        #expect(LoginShell.arguments(forCommand: "echo hi", interactive: true) == ["-l", "-i", "-c", "echo hi"])
    }
}

@Suite struct CodingTargetDefaultTests {
    let order = ["t3", "claude", "codex", "cursor", "opencode", "grok", "gemini"]

    @Test func onlyCodexInstalledMeansCodex() {
        #expect(CodingTargetDefault.choose(orderedHarnessIDs: order, readyHarnessIDs: ["codex"], installedHarnessIDs: ["codex"], fallback: "claude") == "codex")
    }

    @Test func signedInBeatsInstalled() {
        #expect(CodingTargetDefault.choose(orderedHarnessIDs: order, readyHarnessIDs: ["gemini"], installedHarnessIDs: ["claude", "gemini"], fallback: "claude") == "gemini")
        #expect(CodingTargetDefault.choose(orderedHarnessIDs: order, readyHarnessIDs: [], installedHarnessIDs: ["opencode"], fallback: "claude") == "opencode")
    }

    @Test func t3CodeOnlyWhenItsThere() {
        #expect(CodingTargetDefault.choose(orderedHarnessIDs: order, readyHarnessIDs: ["t3", "claude"], installedHarnessIDs: ["t3", "claude"], fallback: "claude") == "t3")
        #expect(CodingTargetDefault.choose(orderedHarnessIDs: order, readyHarnessIDs: ["claude"], installedHarnessIDs: ["claude"], fallback: "codex") == "claude")
        #expect(CodingTargetDefault.choose(orderedHarnessIDs: order, readyHarnessIDs: [], installedHarnessIDs: [], fallback: "opencode") == "opencode")
    }
}
