//
//  CodingPlacement.swift
//  ClickyCore
//
//  Where a coding run does its work. An existing git repo always gets its own branch and worktree, so the owner's
//  checkout is never changed; only a repo with a remote is then pushed with a draft pull request. A folder that isn't a
//  git repo is worked on in place, with no branch. No folder at all means a new project.
//

import Foundation

public enum CodingPlacement: Equatable, Sendable {
    /// A folder that isn't a git repo: the agent edits it where it is, with no branch and no commits.
    case inPlace
    /// An existing git repo: a branch of its own in its own worktree. `publishes` is false for a repo with no remote:
    /// the branch stays on this Mac, and nothing is pushed or opened as a pull request.
    case ownBranch(publishes: Bool)
    /// No folder named: a new project folder of its own.
    case newProject

    public static func decide(folderNamed: Bool, isGitRepo: Bool, hasRemote: Bool) -> CodingPlacement {
        guard folderNamed else { return .newProject }
        guard isGitRepo else { return .inPlace }
        return .ownBranch(publishes: hasRemote)
    }

    /// Whether Theo pushes the branch and opens a draft pull request when the run ends.
    public var publishes: Bool {
        if case .ownBranch(let publishes) = self { return publishes }
        return false
    }

    public var hasOwnBranch: Bool {
        if case .ownBranch = self { return true }
        return false
    }

    /// Said on the run card and in the chat when a run on a repo with no remote ends.
    public static func localBranchWords(branch: String) -> String {
        "The work is on branch \(branch). Nothing was pushed because the repo has no remote."
    }

    /// Said in the chat when such a run starts.
    public static let noRemoteStartWords = "nothing will be pushed because the repo has no remote"
}
