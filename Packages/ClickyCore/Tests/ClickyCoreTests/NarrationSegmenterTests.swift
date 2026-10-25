import Foundation
import Testing
@testable import ClickyCore

private let P = "\u{E000}"

private func segmentWhole(_ text: String) -> [String] {
    var segmenter = NarrationSegmenter()
    return segmenter.feed(text) + segmenter.finish()
}

private func segmentCharByChar(_ text: String) -> [String] {
    var segmenter = NarrationSegmenter()
    var segments: [String] = []
    for character in text { segments += segmenter.feed(String(character)) }
    return segments + segmenter.finish()
}

/// Narration as the router would emit it (tags already placeholders).
private func narration(_ answer: String) -> String {
    var router = ResponseRouter()
    var text = ""
    for output in router.feed(answer) + router.finish() {
        if case .narration(let chunk) = output { text += chunk }
    }
    return text
}

let segmenterVectors: [String] = [
    "Open the menu, e.g. the File menu, and pick Save. Then you're done with it all.",
    "The total is 1,284.50 dollars this month. That's up from last month by a lot.",
    "Open main.swift and README.md in the sidebar. Both are in the project root folder.",
    "Wait for it… there it is, the build finished fine. Now you can run it right away.",
    "Click Share. \(P) Then pick Export as PDF from the menu that opens up there.",
    "\(P)",
    "```\nlet x = 1\n```",
    "Here's the fix for that problem you saw earlier.\n```\nlet x = 1\n```\nThat should do it for the crash you were seeing.",
    "This first sentence is quite long because it explains a lot of things, and it keeps going with more and more detail until the end.",
    "Sure. Click run. Then stop it when you're done testing everything here.",
    "Dr. Smith said the U.S. office opens at 9 a.m. tomorrow. Bring your badge with you to get in.",
    "Point here \(P) and here \(P). Done with both of those now for sure.",
    "a git rebase replays your commits on top of another branch. instead of a merge commit, it rewrites them so the history is one line. that's why you shouldn't rebase shared branches, e.g. main.",
    "the build broke at step 3. fix the import, then rerun it. mr. smith wrote that part."
]

@Test func segmenterCharByCharEqualsWhole() {
    for vector in segmenterVectors {
        let whole = segmentWhole(vector)
        #expect(segmentCharByChar(vector) == whole, "differs for: \(vector)\nwhole: \(whole)\nchars: \(segmentCharByChar(vector))")
        #expect(whole.joined() == vector, "lost text for: \(vector)")
    }
}

@Test func segmenterRouterPipelineIsSplitInvariant() {
    // A tag split across chunks ("[PO" + "INT:#57]") reaches the segmenter whole.
    let answer = "Click Share. [POINT:#57:Share] Then export it as a PDF file from the menu."
    var router = ResponseRouter()
    var segmenter = NarrationSegmenter()
    var segments: [String] = []
    for character in answer {
        for output in router.feed(String(character)) {
            if case .narration(let chunk) = output { segments += segmenter.feed(chunk) }
        }
    }
    for output in router.finish() {
        if case .narration(let chunk) = output { segments += segmenter.feed(chunk) }
    }
    segments += segmenter.finish()
    #expect(segments == segmentWhole(narration(answer)))
    // The placeholder joins "Click Share." (it was preceded only by a space in its sentence).
    #expect(segments.first?.contains(P) == true)
    #expect(segments.first?.hasPrefix("Click Share.") == true)
}

@Test func segmenterRules() {
    // Lone tag: one segment, no speech (fires at once).
    #expect(segmentWhole(P) == [P])
    // Lone fence: one speechless segment.
    #expect(segmentWhole("```\nlet x = 1\n```").count == 1)
    // A fence between sentences never gets cut inside.
    for segment in segmentWhole(segmenterVectors[7]) {
        #expect(segment.components(separatedBy: "```").count % 2 == 1, "fence cut: \(segment)")
    }
    // Long first sentence cut at its first ", " ≥ 24 characters in.
    let long = segmentWhole(segmenterVectors[8])
    #expect(long.first == "This first sentence is quite long because it explains a lot of things, ")
    // Short first sentence released alone; later short ones merge forward.
    let short = segmentWhole(segmenterVectors[9])
    #expect(short.first == "Sure. ")
    #expect(short.dropFirst().allSatisfy { NarrationSegmenter.speechLength(of: $0) >= 24 || $0 == short.last })
    // Decimals and abbreviations don't split sentences.
    #expect(segmentWhole(segmenterVectors[1]).first?.contains("1,284.50 dollars") == true)
}

@Test func lowercaseSentencesAreSplit() {
    let segments = segmentWhole("a git rebase replays your commits on top of another branch. instead of a merge commit, it rewrites them so the history is one line. that's why you shouldn't rebase shared branches, e.g. main.")
    #expect(segments.count >= 3, "\(segments)")
    #expect(segments.contains { $0.contains("e.g. main") })
}

@Test func qwenFirstSegmentIsCappedAtAWordBoundary() {
    let text = "one button i can see is the share button in the toolbar at the top right of the window. then more."
    var whole = NarrationSegmenter(options: .qwen)
    let wholeSegments = whole.feed(text) + whole.finish()
    var streamed = NarrationSegmenter(options: .qwen)
    var streamedSegments: [String] = []
    for character in text { streamedSegments += streamed.feed(String(character)) }
    streamedSegments += streamed.finish()
    #expect(wholeSegments == streamedSegments)
    #expect(wholeSegments.first!.count <= 32)
    #expect(wholeSegments.first!.hasSuffix(" "))
    #expect(wholeSegments.joined() == text)
}
