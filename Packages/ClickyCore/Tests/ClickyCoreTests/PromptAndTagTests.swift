import Foundation
import Testing
@testable import ClickyCore

// MARK: - Helpers

/// True when every element of `needles` appears in `haystack`, in that order (not necessarily adjacent).
private func containsInOrder(_ needles: [String], in haystack: [String]) -> Bool {
    var searchIndex = haystack.startIndex
    for needle in needles {
        guard let foundIndex = haystack[searchIndex...].firstIndex(of: needle) else { return false }
        searchIndex = haystack.index(after: foundIndex)
    }
    return true
}

// MARK: - 1. Screen header words

@Test func cursorScreenHeaderNamesPositionAndPixelSize() {
    let header = ElementListFormatter.header(
        screenNumber: 1,
        displayName: "DELL S3425DW",
        positionDescription: "main",
        isCursorScreen: true,
        imageSize: PixelSize(width: 2576, height: 1078)
    )
    #expect(header == #"SCREEN 1 "DELL S3425DW" (main, cursor here) image 2576x1078 px"#)
}

@Test func nonCursorScreenHeaderOmitsCursorWording() {
    let header = ElementListFormatter.header(
        screenNumber: 2,
        displayName: "DELL S2725QC (2)",
        positionDescription: "left of main",
        isCursorScreen: false,
        imageSize: PixelSize(width: 1456, height: 819)
    )
    #expect(header == #"SCREEN 2 "DELL S2725QC (2)" (left of main) image 1456x819 px"#)
    #expect(!header.contains("cursor here"))
}

@Test func headerReplacesDoubleQuotesInDisplayNameWithSingleQuotes() {
    let header = ElementListFormatter.header(
        screenNumber: 3,
        displayName: #"Studio "Main" Display"#,
        positionDescription: "right of main",
        isCursorScreen: false,
        imageSize: PixelSize(width: 1920, height: 1080)
    )
    #expect(header == #"SCREEN 3 "Studio 'Main' Display" (right of main) image 1920x1080 px"#)
    #expect(!header.contains(#"Studio "Main""#))
}

// MARK: - 2. History tag stripping

@Test func pointTagWithScreenBecomesPointedAtWords() {
    let rewritten = HistoryTagRewriter.wordsForHistory("click share now. [POINT:1203,788:Share:screen1]")
    #expect(rewritten == "click share now. (pointed at Share)")
}

@Test func pointNoneIsRemoved() {
    #expect(HistoryTagRewriter.wordsForHistory("here [POINT:none]") == "here")
}

@Test func marksAndPointsKeepOnlyLabels() {
    let input = "first this [MARK:1:100,200:file menu] then that [MARK:circle:5,6:save:screen2] [POINT:100,200:file menu]"
    let rewritten = HistoryTagRewriter.wordsForHistory(input)
    #expect(rewritten == "first this (marked file menu) then that (marked save) (pointed at file menu)")
}

@Test func unlabeledMarkAndPointUseFallbackWords() {
    #expect(HistoryTagRewriter.wordsForHistory("[MARK:arrow:7,8]") == "(marked something)")
    #expect(HistoryTagRewriter.wordsForHistory("[POINT:10,20]") == "(pointed)")
}

@Test func workerTagIsRemoved() {
    #expect(HistoryTagRewriter.wordsForHistory("on it [WORKER:Swift pricing:look it up]") == "on it")
}

@Test func rewrittenHistoryContainsNoCoordinatesOrScreenIds() {
    let rewritten = HistoryTagRewriter.wordsForHistory("click share now. [POINT:1203,788:Share:screen1]")
    #expect(!rewritten.contains("1203"))
    #expect(!rewritten.contains("788"))
    #expect(!rewritten.lowercased().contains("screen"))
}

// MARK: - 3. Prompt gating

@Test func legacyPromptIncludesAllLegacySections() {
    let prompt = SystemPromptBuilder.mainSystemPrompt(features: .legacy)
    #expect(prompt.contains("element pointing:"))
    #expect(prompt.contains("live marks:"))
    #expect(prompt.contains("helper workers:"))
    #expect(prompt.contains("SCREEN header"))
}

@Test func currentPromptUsesGroundingInsteadOfLegacySections() {
    let prompt = SystemPromptBuilder.mainSystemPrompt(features: .current)
    #expect(!prompt.contains("element pointing:"))
    #expect(!prompt.contains("live marks:"))
    #expect(prompt.contains("helper workers:"))
    // Describes exactly the lines sent.
    #expect(prompt.contains(#"SCREEN 1 "DELL S3425DW" (main, cursor here) image 2000x837 px"#))
    #expect(prompt.contains("cursor 1203,788 over #57; focus #2"))
    #expect(prompt.contains(#"window "<title>" (<app>)"#))
    #expect(prompt.contains("57 btn \"Share\" 1188,776,30,28"))
    #expect(prompt.contains("top-left corner"))
    #expect(prompt.contains("the centre you see"))
    #expect(prompt.contains("magenta number tags"))
    // Worker scope wording.
    #expect(prompt.contains("helpers see only your task text plus the element lists; they have no internet, files or GitHub."))
    #expect(prompt.contains("say you can't look that up yet"))
    #expect(prompt.contains("never say ids"))
}

@Test func badgesOffPromptDoesNotMentionTags() {
    let prompt = SystemPromptBuilder.mainSystemPrompt(features: [.grounding, .helperWorkers])
    #expect(!prompt.contains("magenta number tags"))
}

@Test func emptyFeaturesPromptHasNoTagSyntax() {
    let prompt = SystemPromptBuilder.mainSystemPrompt(features: [])
    #expect(!prompt.contains("[POINT"))
    #expect(!prompt.contains("[MARK"))
    #expect(!prompt.contains("[WORKER"))
}

@Test func pointingOnlyPromptHasPointButNoMarksOrWorkers() {
    let prompt = SystemPromptBuilder.mainSystemPrompt(features: [.pointing])
    #expect(prompt.contains("[POINT"))
    #expect(!prompt.contains("[MARK:kind"))
    #expect(!prompt.contains("[WORKER"))
}

@Test func pointingTextUsesScreenHeaderNotFixedSize() {
    let prompt = SystemPromptBuilder.mainSystemPrompt(features: [.pointing])
    #expect(!prompt.contains("image label"))
    #expect(!prompt.contains("1280"))
}

// MARK: - 4. Claude CLI arguments

@Test func baseArgumentsAreIsolatedAndExact() {
    let args = ClaudeArgs(model: "sonnet", systemPromptFileURL: URL(fileURLWithPath: "/tmp/p.md"))
    let expected = [
        "-p",
        "--input-format", "stream-json",
        "--output-format", "stream-json",
        "--verbose",
        "--include-partial-messages",
        "--model", "sonnet",
        "--system-prompt-file", "/tmp/p.md",
        "--tools", "",
        "--strict-mcp-config",
        "--disable-slash-commands",
        "--no-session-persistence",
        "--setting-sources", "user",
        "--settings", #"{"disableAllHooks":true}"#
    ]
    #expect(args.arguments == expected)
    #expect(containsInOrder(
        ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
         "--include-partial-messages", "--model", "sonnet", "--system-prompt-file", "/tmp/p.md",
         "--tools", "", "--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence",
         "--setting-sources", "user", "--settings", #"{"disableAllHooks":true}"#],
        in: args.arguments
    ))
    #expect(!args.arguments.contains("--effort"))
}

@Test func effortLevelAppendsEffortFlagAtEnd() {
    let args = ClaudeArgs(model: "sonnet", systemPromptFileURL: URL(fileURLWithPath: "/tmp/p.md"), effortLevel: "high")
    #expect(Array(args.arguments.suffix(2)) == ["--effort", "high"])
}

@Test func persistentSessionIdentifierUsesSessionIdInsteadOfNoPersistence() {
    let args = ClaudeArgs(
        model: "sonnet",
        systemPromptFileURL: URL(fileURLWithPath: "/tmp/p.md"),
        persistentSessionIdentifier: "abc"
    )
    #expect(containsInOrder(["--session-id", "abc"], in: args.arguments))
    #expect(!args.arguments.contains("--no-session-persistence"))
}

@Test func inlineSystemPromptReplacesPromptFileFlag() {
    let args = ClaudeArgs(
        model: "sonnet",
        systemPromptFileURL: URL(fileURLWithPath: "/tmp/p.md"),
        inlineSystemPrompt: "hi"
    )
    #expect(containsInOrder(["--system-prompt", "hi"], in: args.arguments))
    #expect(!args.arguments.contains("--system-prompt-file"))
}
