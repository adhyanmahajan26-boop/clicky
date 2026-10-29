import CoreGraphics
import Testing
@testable import ClickyCore

private let probeTruths = [
    CGPoint(x: 100, y: 200),
    CGPoint(x: 300, y: 400),
    CGPoint(x: 2500, y: 90),
    CGPoint(x: 1200, y: 800),
]

@Test func perfectAnswersPassTheProbe() throws {
    let verdict = try #require(TierProbeMath.evaluate(answers: probeTruths, truths: probeTruths, sentLongEdge: 2576))

    #expect(verdict.passes)
    #expect(abs(verdict.scaleRatio - 1) < 1e-9)
    #expect(verdict.maximumErrorInPixels == 0)
    #expect(verdict.suggestedEffectiveMaxEdge == nil)
}

@Test func uniformlyShrunkAnswersFailAndSuggestACap() throws {
    let scaled = probeTruths.map { CGPoint(x: $0.x * 0.776, y: $0.y * 0.776) }
    let verdict = try #require(TierProbeMath.evaluate(answers: scaled, truths: probeTruths, sentLongEdge: 2576))

    #expect(!verdict.passes)
    #expect(abs(verdict.scaleRatio - 0.776) < 1e-9)
    #expect(verdict.suggestedEffectiveMaxEdge == 1999)

    let capped = ClaudeImageSizing.capLongEdge(PixelSize(width: 2576, height: 1078), cap: 1999)
    #expect(capped == PixelSize(width: 1999, height: 837))
}

@Test func answerOffByFifteenPixelsFailsOnMaximumError() throws {
    let truths = [CGPoint(x: 1000, y: 1000), CGPoint(x: 2000, y: 500)]
    let answers = [CGPoint(x: 1015, y: 1000), CGPoint(x: 2000, y: 500)]
    let verdict = try #require(TierProbeMath.evaluate(answers: answers, truths: truths, sentLongEdge: 2576))

    // The ratio is essentially 1, so only the pixel error can cause the failure.
    #expect(abs(verdict.scaleRatio - 1) <= TierProbeMath.ratioTolerance)
    #expect(abs(verdict.maximumErrorInPixels - 15) < 1e-9)
    #expect(!verdict.passes)
}

@Test func mismatchedOrEmptyAnswersYieldNoVerdict() {
    #expect(TierProbeMath.evaluate(answers: [], truths: [], sentLongEdge: 2576) == nil)
    #expect(TierProbeMath.evaluate(answers: [CGPoint(x: 1, y: 1)], truths: probeTruths, sentLongEdge: 2576) == nil)
}

@Test func parsePointsReadsTheFirstPointListInAReply() throws {
    let points = try #require(TierProbeMath.parsePoints(fromReply: "sure: [[10, 20],[30.5,40],[2500,90]] done"))

    #expect(points.count == 3)
    #expect(points[0] == CGPoint(x: 10, y: 20))
    #expect(points[1] == CGPoint(x: 30.5, y: 40))
    #expect(points[2] == CGPoint(x: 2500, y: 90))
}

@Test func parsePointsReturnsNilWhenThereIsNoList() {
    #expect(TierProbeMath.parsePoints(fromReply: "no list") == nil)
}
