import CoreGraphics
import Foundation
import Testing
@testable import ClickyCore

// MARK: - Helpers

/// Deterministic pseudo-random generator (LCG) so the fuzz-style cases are reproducible.
private struct LinearCongruentialGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next(below bound: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 33) % UInt64(bound))
    }
}

// MARK: - 1. Target forms

@Test func elementTargetWithoutHint() throws {
    let tag = try #require(MarkTagParser.parse("[POINT:#57]"))
    #expect(tag.kind == .point)
    #expect(tag.target == .element(id: 57, hint: nil))
    #expect(tag.name == nil)
}

@Test func elementTargetWithHintAndName() throws {
    let tag = try #require(MarkTagParser.parse("[POINT:#57@1203,788:Share]"))
    #expect(tag.target == .element(id: 57, hint: CGPoint(x: 1203, y: 788)))
    #expect(tag.name == "Share")
}

@Test func elementSpanTarget() throws {
    let tag = try #require(MarkTagParser.parse("[MARK:box:#3-#6:rows]"))
    #expect(tag.kind == .mark)
    #expect(tag.style == .box)
    #expect(tag.target == .span(fromID: 3, toID: 6))
    #expect(tag.name == "rows")
}

@Test func quotedTextTargetWithLabel() throws {
    let tag = try #require(MarkTagParser.parse(#"[MARK:circle:"Save as…":save]"#))
    #expect(tag.style == .circle)
    #expect(tag.target == .text("Save as…", occurrence: nil, scopeID: nil))
    #expect(tag.name == "save")
}

@Test func quotedTextTargetWithOccurrence() throws {
    let tag = try #require(MarkTagParser.parse(#"[POINT:"Cancel"~2]"#))
    #expect(tag.target == .text("Cancel", occurrence: 2, scopeID: nil))
}

@Test func quotedTextTargetScopedToElement() throws {
    let tag = try #require(MarkTagParser.parse(#"[POINT:"Delete" in #12]"#))
    #expect(tag.target == .text("Delete", occurrence: nil, scopeID: 12))
}

@Test func quotedTextTargetWithOccurrenceAndScope() throws {
    let tag = try #require(MarkTagParser.parse(#"[POINT:"Run"~1 in #4]"#))
    #expect(tag.target == .text("Run", occurrence: 1, scopeID: 4))
}

@Test func pointTargetFromTwoCoordinates() throws {
    let tag = try #require(MarkTagParser.parse("[POINT:400,300]"))
    #expect(tag.target == .point(CGPoint(x: 400, y: 300)))
}

@Test func legacyCircleCoordinatesBecomeBoundingBox() throws {
    let tag = try #require(MarkTagParser.parse("[MARK:circle:400,300,25]"))
    #expect(tag.target == .box(CGRect(x: 375, y: 275, width: 50, height: 50)))
}

@Test func boxCoordinatesAreXYWidthHeight() throws {
    let tag = try #require(MarkTagParser.parse("[MARK:box:10,20,30,40]"))
    #expect(tag.target == .box(CGRect(x: 10, y: 20, width: 30, height: 40)))
}

@Test func pointNoneHasNoTarget() throws {
    let tag = try #require(MarkTagParser.parse("[POINT:none]"))
    #expect(tag.kind == .point)
    #expect(tag.target == MarkTarget.none)
}

@Test func decimalCoordinatesAreRounded() throws {
    let tag = try #require(MarkTagParser.parse("[POINT:400.6,299.4]"))
    #expect(tag.target == .point(CGPoint(x: 401, y: 299)))
}

@Test func screenDefaultsToOne() throws {
    let tag = try #require(MarkTagParser.parse("[POINT:400,300]"))
    #expect(tag.effectiveScreenNumber == 1)
}

// MARK: - 2. Styles

@Test func namedStylesParse() throws {
    let cases: [(String, MarkStyle)] = [
        ("circle", .circle),
        ("box", .box),
        ("arrow", .arrow),
        ("underline", .underline),
        ("spot", .spot),
    ]
    for (styleText, expectedStyle) in cases {
        let tag = try #require(MarkTagParser.parse("[MARK:\(styleText):#5]"))
        #expect(tag.style == expectedStyle, "style \(styleText)")
        #expect(tag.target == .element(id: 5, hint: nil))
    }
}

@Test func numberedStepsOneToNine() throws {
    for stepNumber in 1...9 {
        let tag = try #require(MarkTagParser.parse("[MARK:\(stepNumber):#5]"))
        #expect(tag.style == .step(stepNumber), "step \(stepNumber)")
    }
}

@Test func unknownStyleFallsBackToCircle() throws {
    let tag = try #require(MarkTagParser.parse("[MARK:squiggle:#5]"))
    #expect(tag.style == .circle)
    #expect(tag.target == .element(id: 5, hint: nil))
}

@Test func targetInStyleSlotMeansCircle() throws {
    let tag = try #require(MarkTagParser.parse("[MARK:#57:Share]"))
    #expect(tag.style == .circle)
    #expect(tag.target == .element(id: 57, hint: nil))
    #expect(tag.name == "Share")
}

// MARK: - 3. Labels, display text and screens

@Test func labelWithNoteSplitsOnPipe() throws {
    let tag = try #require(MarkTagParser.parse("[POINT:#5:Share|click here]"))
    #expect(tag.name == "Share")
    #expect(tag.note == "click here")
    #expect(tag.displayText == "click here")
}

@Test func arrowDisplayTextIsName() throws {
    let tag = try #require(MarkTagParser.parse("[MARK:arrow:#5:Share]"))
    #expect(tag.displayText == "Share")
}

@Test func stepDisplayTextIsName() throws {
    let tag = try #require(MarkTagParser.parse("[MARK:2:#5:Next]"))
    #expect(tag.style == .step(2))
    #expect(tag.displayText == "Next")
}

@Test func circleDisplayTextIsNilWithoutNote() throws {
    let tag = try #require(MarkTagParser.parse("[MARK:circle:#5:Share]"))
    #expect(tag.name == "Share")
    #expect(tag.displayText == nil)
}

@Test func trailingScreenNumberIsParsedAndCut() throws {
    let tag = try #require(MarkTagParser.parse("[POINT:#5:Share:screen2]"))
    #expect(tag.screenNumber == 2)
    #expect(tag.effectiveScreenNumber == 2)
    #expect(tag.name == "Share")
    #expect(tag.target == .element(id: 5, hint: nil))
}

@Test func screenNumberWithoutLabel() throws {
    let tag = try #require(MarkTagParser.parse("[MARK:circle:500,600:screen2]"))
    #expect(tag.screenNumber == 2)
    #expect(tag.name == nil)
    #expect(tag.target == .point(CGPoint(x: 500, y: 600)))
}

@Test func legacyLabelWithSpaceAfterCoordinates() throws {
    let tag = try #require(MarkTagParser.parse("[POINT:1100,42:color inspector]"))
    #expect(tag.target == .point(CGPoint(x: 1100, y: 42)))
    #expect(tag.name == "color inspector")
}

@Test func labelContainingColonKeepsColon() throws {
    let tag = try #require(MarkTagParser.parse("[POINT:#5:Time: 10:30]"))
    #expect(tag.target == .element(id: 5, hint: nil))
    #expect(tag.name == "Time: 10:30")
}

@Test func labelIsTruncatedToEightyCharacters() throws {
    let longLabel = String(repeating: "a", count: 100)
    let tag = try #require(MarkTagParser.parse("[POINT:#5:\(longLabel)]"))
    #expect(tag.name?.count == MarkTagParser.maximumLabelLength)
    #expect(tag.name == String(repeating: "a", count: 80))
}

// MARK: - 4. Case, spacing and CLEAR

@Test func keywordsAndFieldsIgnoreSpacesAndCase() throws {
    let tag = try #require(MarkTagParser.parse("[ point : #5 : Share ]"))
    #expect(tag.kind == .point)
    #expect(tag.target == .element(id: 5, hint: nil))
    #expect(tag.name == "Share")
}

@Test func markKeywordAndStyleAreCaseInsensitive() throws {
    let tag = try #require(MarkTagParser.parse("[Mark:Circle:#5]"))
    #expect(tag.kind == .mark)
    #expect(tag.style == .circle)
    #expect(tag.target == .element(id: 5, hint: nil))
}

@Test func clearTagParses() throws {
    #expect(try #require(MarkTagParser.parse("[CLEAR]")).kind == .clear)
    #expect(try #require(MarkTagParser.parse("[ clear ]")).kind == .clear)
}

// MARK: - 5. Quotes and invalid input

@Test func escapedQuoteInsideText() throws {
    let tag = try #require(MarkTagParser.parse(#"[POINT:"a \" b: c"]"#))
    #expect(tag.target == .text(#"a " b: c"#, occurrence: nil, scopeID: nil))
}

@Test func bracketInsideQuotesDoesNotCloseTag() throws {
    let tag = try #require(MarkTagParser.parse(#"[POINT:"items[0]"]"#))
    #expect(tag.target == .text("items[0]", occurrence: nil, scopeID: nil))
}

@Test func invalidElementIDIsRejected() {
    #expect(MarkTagParser.parse("[POINT:#abc]") == nil)
}

@Test func unclosedQuoteIsRejected() {
    #expect(MarkTagParser.parse(#"[POINT:"x]"#) == nil)
}

@Test func unclosedTagAtEndIsRemovedFromSpeechAndCountedMalformed() {
    let extraction = MarkTagParser.extractAll("Hello [POINT:#5 there")
    #expect(extraction.tags.isEmpty)
    #expect(extraction.malformedTagCount == 1)
    #expect(extraction.speechText == "Hello")
}

// MARK: - 6. extractAll ordering and speech

@Test func extractAllReturnsTagsInOrderAndTidiesSpeech() {
    let extraction = MarkTagParser.extractAll(
        "Click Share [MARK:circle:#57:Share] then Done. [POINT:#2:Done]"
    )
    #expect(extraction.tags.count == 2)
    #expect(extraction.tags[0].kind == .mark)
    #expect(extraction.tags[0].target == .element(id: 57, hint: nil))
    #expect(extraction.tags[1].kind == .point)
    #expect(extraction.tags[1].target == .element(id: 2, hint: nil))
    #expect(extraction.speechText == "Click Share then Done.")
    #expect(extraction.malformedTagCount == 0)
}

@Test func textWithoutTagsIsUnchanged() {
    let answer = "Open the settings panel and pick a theme."
    let extraction = MarkTagParser.extractAll(answer)
    #expect(extraction.tags.isEmpty)
    #expect(extraction.speechText == answer)
    #expect(extraction.malformedTagCount == 0)
}

@Test func unrelatedBracketsAreLeftInSpeech() {
    let extraction = MarkTagParser.extractAll("Use [WORKER:x:y] and items[0] as-is.")
    #expect(extraction.tags.isEmpty)
    #expect(extraction.malformedTagCount == 0)
    #expect(extraction.speechText == "Use [WORKER:x:y] and items[0] as-is.")
}

// MARK: - 7. Malformed tags

@Test func fixedMalformedTagsAreDroppedAndNeverSpoken() {
    let badTags = [
        "[POINT:]",
        "[MARK:circle]",
        "[MARK:]",
        "[POINT:#]",
        "[POINT:#5-]",
        "[POINT:1,2,3,4,5]",
        "[POINT:a,b]",
        "[POINT:#5@1]",
        "[POINT:\"\"]",
        "[MARK:box:-5,5,-1,4]",
    ]
    for badTag in badTags {
        #expect(MarkTagParser.parse(badTag) == nil, "\(badTag) should not parse")

        let extraction = MarkTagParser.extractAll("Before \(badTag) after")
        #expect(extraction.tags.isEmpty, "\(badTag) produced a tag")
        #expect(extraction.malformedTagCount == 1, "\(badTag) not counted as malformed")
        #expect(extraction.speechText == "Before after", "\(badTag) leaked into speech")
    }
}

@Test func randomMalformedTagsNeverCrashOrLeak() {
    let alphabet = Array("#@,:\"|][ 0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-.\\")
    var generator = LinearCongruentialGenerator(seed: 0x5EED_CAFE)

    for caseIndex in 0..<200 {
        let prefix = caseIndex.isMultiple(of: 2) ? "[POINT:" : "[MARK:"
        let garbageLength = generator.next(below: 24)
        var garbage = ""
        for _ in 0..<garbageLength {
            garbage.append(alphabet[generator.next(below: alphabet.count)])
        }
        let input = prefix + garbage

        let extraction = MarkTagParser.extractAll("Answer \(input) end")
        #expect(!extraction.speechText.lowercased().contains("[point"), "speech leaked POINT for \(input)")
        #expect(!extraction.speechText.lowercased().contains("[mark"), "speech leaked MARK for \(input)")

        if let parsed = MarkTagParser.parse(input) {
            #expect([ParsedTag.Kind.point, .mark, .clear].contains(parsed.kind), "invalid kind for \(input)")
        }
    }
}

// MARK: - 8. LabelSimilarity

@Test func similarityIgnoresCase() {
    #expect(LabelSimilarity.similarity("Share", "share") == 1)
}

@Test func similarityNormalisesEllipsis() {
    #expect(LabelSimilarity.similarity("Save As…", "save as...") == 1)
}

@Test func similarityUsesTokenDiceForReorderedWords() {
    #expect(LabelSimilarity.similarity("Build Settings", "Settings Build") >= 0.99)
}

@Test func unrelatedLabelsAreDissimilar() {
    #expect(LabelSimilarity.similarity("Cancel", "Archive") < 0.5)
}

@Test func exactOccurrenceIsNotFuzzy() throws {
    let matches = LabelSimilarity.findOccurrences(of: "rate limit", in: "Error: rate limit exceeded (429)")
    #expect(matches.count == 1)
    let match = try #require(matches.first)
    #expect(match.isFuzzy == false)
    // Normalised text "error: rate limit exceeded (429)": "rate limit" starts at character 7.
    #expect(match.range == 7..<17)
}

@Test func typoWithinEditBudgetIsFuzzyMatch() throws {
    // "exceeded" has 8 characters, so 8 / 6 = 1 edit is allowed.
    let matches = LabelSimilarity.findOccurrences(of: "exceeded", in: "rate limit exceded")
    #expect(matches.count == 1)
    #expect(matches.first?.isFuzzy == true)
}

@Test func shortQueryAllowsNoEdits() {
    // "Run" has 3 characters, so 3 / 6 = 0 edits: "Ran" must not match.
    #expect(LabelSimilarity.findOccurrences(of: "Run", in: "Ran").isEmpty)
}

// MARK: - 9. SpeechSafetyNet

@Test func liveElementIDIsStrippedFromSpeech() {
    let result = SpeechSafetyNet.clean("Click #57 now", liveElementIDs: [57])
    #expect(result.speechText == "Click now")
    #expect(result.leakCount == 1)
}

@Test func pullRequestNumberIsProtected() {
    let text = "Open PR #12 please"
    let result = SpeechSafetyNet.clean(text, liveElementIDs: [12])
    #expect(result.speechText == text)
    #expect(result.leakCount == 0)
}

@Test func issueNumberIsProtected() {
    let text = "Look at issue #3 today"
    let result = SpeechSafetyNet.clean(text, liveElementIDs: [3])
    #expect(result.speechText == text)
    #expect(result.leakCount == 0)
}

@Test func numberWordPrefixIsProtected() {
    let text = "Pick number #4 from the list"
    let result = SpeechSafetyNet.clean(text, liveElementIDs: [4])
    #expect(result.speechText == text)
    #expect(result.leakCount == 0)
}

@Test func nonLiveIDIsUnchanged() {
    let text = "Click #99 now"
    let result = SpeechSafetyNet.clean(text, liveElementIDs: [57])
    #expect(result.speechText == text)
    #expect(result.leakCount == 0)
}

@Test func badgeMentionsAreCounted() {
    let count = SpeechSafetyNet.countBadgeMentions(in: "see badge #5 in the element list", liveElementIDs: [5])
    #expect(count == 3)
    // An on-screen list is not a leak.
    #expect(SpeechSafetyNet.countBadgeMentions(in: "row 9 is in the list on the left", liveElementIDs: [9]) == 0)
}
