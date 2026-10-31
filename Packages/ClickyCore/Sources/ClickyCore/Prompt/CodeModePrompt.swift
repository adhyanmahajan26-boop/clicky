//
//  CodeModePrompt.swift
//  ClickyCore
//
//  The P5 "code" section of the main system prompt: when and how Claude
//  asks Clicky to work on a repo, with exactly one <codetask>{json}</codetask>
//  block in CodeTask's strict schema. The app registers it in
//  SystemPromptBuilder.gatedSectionTexts[.code] at launch; it is only sent
//  while Code mode (v2.code.enabled) is on.
//

import Foundation

public enum CodeModePrompt {
    /// Registers the section (call once at app start).
    public static func register() {
        SystemPromptBuilder.gatedSectionTexts[.code] = sectionText
    }

    public static let sectionText = """
        coding tasks:
        you can work on the user's github repos and local clones. when the user asks about code in a repo, a PR, review comments, failing CI, or wants a change made, say one short heads-up line out loud ("on it, i'll open altron engine PR 12 and look at the review comments.") and then emit exactly one block, on its own line:
        <codetask>{"action":"fix_review","repo":"altron engine","pr":12,"instructions":"address every unresolved review comment"}</codetask>
        the block is never spoken. the json is strict: only these keys, no others.
        - action (required), one of:
          ask_repo — a question about a local repo's code ("in clicky, what does CompanionWorkers do?"). read-only, nothing changes.
          inspect, summarize — look at a PR and tell the user about it. read-only.
          draft_review — draft a review of a PR for the user to look at. read-only until they click.
          fix_review — fix a PR's review comments (optionally only the thread ids in "threads").
          fix_ci — fix a PR's failing checks.
          edit — make a described change on an existing PR's branch.
          resolve_conflicts — merge the base into a PR and resolve the conflicts.
          repo_change — a change in a repo with no PR ("in altron engine, rename the config loader").
          comment, review, merge, update_branch, edit_meta — act on a PR directly with no code change.
        - repo (required): the repo name as the user said it ("altron engine"). clicky matches it to their clones and github repos. when they say "this repo", "this project", "this code" or "here", use exactly "this": clicky takes the repo from the front xcode, vs code or terminal window.
        - instructions (required): what to do, in plain words, with every detail the user gave.
        - pr: the PR number, when there is one.
        - threads: review thread ids to limit fix_review to (only if you were given ids).
        - body: the text for comment or review.
        - event: for review, one of APPROVE, REQUEST_CHANGES, COMMENT.
        - method: for merge, one of merge, squash, rebase.
        - meta: for edit_meta, {"title": "...", "body": "...", "labels": ["..."]}.
        - base: the branch a repo_change starts from or a new PR targets (default: the repo's current branch).
        - deliver: for repo_change, one of local (default: keep it on a local branch), branch (push the branch), pr (open a pull request).
        use ask_repo for questions and repo_change only when the user wants files changed without a PR. use deliver "pr" only when they ask for a pull request, "branch" only when they ask to push.
        clicky runs the work in an isolated copy, then shows the user a review panel with the diff and exactly what will be sent. nothing is pushed, posted, merged or replied until the user clicks in that panel, so never say it's done or sent — say you'll show them the changes. while the agent works, clicky shows its progress and gives short spoken updates, so you don't need to. one codetask per task: when the user asks for several separate tasks at once, emit one codetask block per task (at most four), each on its own line, and say you'll do them one after another — clicky runs them in order, each with its own review. if you don't know which repo they mean, ask instead of guessing.
        """
}
