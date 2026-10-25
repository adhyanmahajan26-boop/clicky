import CoreGraphics
import Foundation
import Testing
@testable import ClickyCore

// MARK: - [SNAP:…] parsing

@Test func snapScreenTarget() throws {
    let tag = try #require(MarkTagParser.parse("[SNAP:screen]"))
    #expect(tag.kind == .snap)
    #expect(tag.snapshot == SnapshotRequest(target: .screen, includesClickyOverlay: false))
    #expect(tag.target == .none)
    #expect(tag.style == nil)
}

@Test func snapWindowTarget() throws {
    let tag = try #require(MarkTagParser.parse("[SNAP:window]"))
    #expect(tag.snapshot == SnapshotRequest(target: .window, includesClickyOverlay: false))
}

@Test func snapMarksTarget() throws {
    let tag = try #require(MarkTagParser.parse("[SNAP:marks]"))
    #expect(tag.snapshot == SnapshotRequest(target: .marks, includesClickyOverlay: false))
}

@Test func snapPlusMarksKeepsClickyOverlay() throws {
    let windowTag = try #require(MarkTagParser.parse("[SNAP:window+marks]"))
    #expect(windowTag.snapshot == SnapshotRequest(target: .window, includesClickyOverlay: true))
    let screenTag = try #require(MarkTagParser.parse("[SNAP:screen+marks]"))
    #expect(screenTag.snapshot == SnapshotRequest(target: .screen, includesClickyOverlay: true))
}

@Test func snapKeywordAndTargetAreCaseInsensitive() throws {
    let tag = try #require(MarkTagParser.parse("[snap:Window+Marks]"))
    #expect(tag.snapshot == SnapshotRequest(target: .window, includesClickyOverlay: true))
    let shouty = try #require(MarkTagParser.parse("[SNAP:SCREEN]"))
    #expect(shouty.snapshot == SnapshotRequest(target: .screen))
}

@Test func snapAllowsSpacesAroundTheParts() throws {
    let spaced = try #require(MarkTagParser.parse("[ SNAP : window + marks ]"))
    #expect(spaced.snapshot == SnapshotRequest(target: .window, includesClickyOverlay: true))
    let padded = try #require(MarkTagParser.parse("[SNAP:  marks  ]"))
    #expect(padded.snapshot == SnapshotRequest(target: .marks))
}

@Test func snapMarksWithOverlayIsAllowed() throws {
    let tag = try #require(MarkTagParser.parse("[SNAP:marks+marks]"))
    #expect(tag.snapshot == SnapshotRequest(target: .marks, includesClickyOverlay: true))
}

@Test func invalidSnapTagsDoNotParse() {
    let invalidTags = [
        "[SNAP]",                       // no target
        "[SNAP:]",                      // empty target
        "[SNAP:desktop]",               // unknown target
        "[SNAP:screen+lines]",          // unknown flag
        "[SNAP:screen+]",               // flag missing
        "[SNAP:+marks]",                // target missing
        "[SNAP:screen+marks+marks]",    // too many parts
        "[SNAP:screen:2]",              // a screen number isn't a snap option
        "[SNAP screen]",                // no colon
        "[SNAP:screen",                 // unclosed
        "SNAP:screen",                  // no brackets
    ]
    for invalidTag in invalidTags {
        #expect(MarkTagParser.parse(invalidTag) == nil, "\(invalidTag) should not parse")
    }
}

@Test func extractAllRemovesSnapTagsFromSpeech() {
    let extraction = MarkTagParser.extractAll("here it is [SNAP:window+marks] and the rest [SNAP] done")
    #expect(extraction.tags.count == 1)
    #expect(extraction.tags.first?.snapshot == SnapshotRequest(target: .window, includesClickyOverlay: true))
    #expect(extraction.malformedTagCount == 1)
    #expect(extraction.speechText == "here it is and the rest done")
}

// MARK: - Router

@Test func routerEmitsSnapTagAsPlaceholderAndTag() {
    var router = ResponseRouter()
    let outputs = router.feed("take a look [SNAP:marks] there") + router.finish()
    let snapTags = outputs.compactMap { output -> ParsedTag? in
        if case .tag(_, let tag) = output { return tag }
        return nil
    }
    #expect(snapTags.count == 1)
    #expect(snapTags.first?.snapshot == SnapshotRequest(target: .marks))
    let spokenText = outputs.compactMap { output -> String? in
        if case .narration(let text) = output { return text }
        return nil
    }.joined()
    #expect(!spokenText.contains("SNAP"))
    #expect(!spokenText.contains("["))
}

@Test func routerDropsInvalidSnapTagsInsteadOfSpeakingThem() {
    var router = ResponseRouter()
    let outputs = router.feed("look [SNAP:nothing] now") + router.finish()
    let spokenText = outputs.compactMap { output -> String? in
        if case .narration(let text) = output { return text }
        return nil
    }.joined()
    #expect(!spokenText.contains("SNAP"))
    #expect(outputs.contains { output in
        if case .dropped = output { return true }
        return false
    })
}

// MARK: - Region math

@Test func marksRegionIsOneRectGrownByTheMargin() throws {
    let markRect = CGRect(x: 100, y: 200, width: 50, height: 30)
    let region = try #require(SnapshotRegion.marksRegion(markRectsCG: [markRect]))
    #expect(region == CGRect(x: 76, y: 176, width: 98, height: 78))
    #expect(SnapshotRegion.marksMarginPoints == 24)
}

@Test func marksRegionIsTheUnionOfAllMarksPlusMargin() throws {
    let firstMarkRect = CGRect(x: 100, y: 200, width: 50, height: 30)
    let secondMarkRect = CGRect(x: 400, y: 50, width: 20, height: 20)
    let region = try #require(SnapshotRegion.marksRegion(markRectsCG: [firstMarkRect, secondMarkRect]))
    // Union: x 100...420, y 50...230, then 24 pt each side.
    #expect(region == CGRect(x: 76, y: 26, width: 368, height: 228))
    #expect(region.contains(firstMarkRect.insetBy(dx: 24, dy: 24)))
    #expect(region.contains(secondMarkRect))
}

@Test func marksRegionOrderDoesNotMatter() {
    let firstMarkRect = CGRect(x: 10, y: 10, width: 5, height: 5)
    let secondMarkRect = CGRect(x: 300, y: 120, width: 40, height: 10)
    #expect(SnapshotRegion.marksRegion(markRectsCG: [firstMarkRect, secondMarkRect])
        == SnapshotRegion.marksRegion(markRectsCG: [secondMarkRect, firstMarkRect]))
}

@Test func marksRegionIsNilWithoutMarks() {
    #expect(SnapshotRegion.marksRegion(markRectsCG: []) == nil)
    #expect(SnapshotRegion.marksRegion(markRectsCG: [.null]) == nil)
}

@Test func marksRegionIgnoresNullRects() throws {
    let markRect = CGRect(x: 0, y: 0, width: 10, height: 10)
    let region = try #require(SnapshotRegion.marksRegion(markRectsCG: [.null, markRect]))
    #expect(region == CGRect(x: -24, y: -24, width: 58, height: 58))
}

@Test func clampedRegionIsCutToTheDisplay() throws {
    let display = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let region = CGRect(x: 950, y: 100, width: 200, height: 50)
    let clamped = try #require(SnapshotRegion.clamped(region, to: display))
    #expect(clamped == CGRect(x: 950, y: 100, width: 50, height: 50))
}

@Test func clampedRegionInsideTheDisplayIsUnchanged() throws {
    let display = CGRect(x: 1000, y: 0, width: 1920, height: 1080)
    let region = CGRect(x: 1100, y: 100, width: 300, height: 200)
    #expect(SnapshotRegion.clamped(region, to: display) == region)
}

@Test func clampedRegionOffTheDisplayIsNil() {
    let display = CGRect(x: 0, y: 0, width: 1000, height: 800)
    #expect(SnapshotRegion.clamped(CGRect(x: 2000, y: 0, width: 100, height: 100), to: display) == nil)
    #expect(SnapshotRegion.clamped(CGRect(x: 1000, y: 0, width: 100, height: 100), to: display) == nil)
}

@Test func snapshotTargetRawValuesMatchTheTagWords() {
    #expect(SnapshotTarget.allCases.map(\.rawValue) == ["screen", "window", "marks"])
}
