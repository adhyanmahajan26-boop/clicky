//
//  TierProbeMath.swift
//  ClickyCore
//
//  Does the model really see an image at the size we send? The tier probe
//  draws dots at known pixels and asks for their coordinates. If the
//  answers are uniformly scaled by r, the model saw the image shrunk by r,
//  and images get capped to round(r x long edge).
//

import CoreGraphics
import Foundation

public enum TierProbeMath {
    public struct Verdict: Equatable, Sendable {
        /// Median of answer/truth over every coordinate.
        public let scaleRatio: Double
        /// Largest |answer − truth| in pixels.
        public let maximumErrorInPixels: Double
        public let passes: Bool
        /// Set when it fails: the long edge the model actually sees.
        public let suggestedEffectiveMaxEdge: Int?
    }

    public static let ratioTolerance = 0.02
    public static let maximumAllowedErrorInPixels = 12.0

    public static func evaluate(answers: [CGPoint], truths: [CGPoint], sentLongEdge: Int) -> Verdict? {
        guard answers.count == truths.count, !truths.isEmpty else { return nil }
        var ratios: [Double] = []
        var maximumError = 0.0
        for (answer, truth) in zip(answers, truths) {
            if truth.x > 0 { ratios.append(Double(answer.x / truth.x)) }
            if truth.y > 0 { ratios.append(Double(answer.y / truth.y)) }
            maximumError = max(maximumError, Double(abs(answer.x - truth.x)), Double(abs(answer.y - truth.y)))
        }
        guard !ratios.isEmpty else { return nil }
        let sortedRatios = ratios.sorted()
        let middleIndex = sortedRatios.count / 2
        let medianRatio = sortedRatios.count % 2 == 1
            ? sortedRatios[middleIndex]
            : (sortedRatios[middleIndex - 1] + sortedRatios[middleIndex]) / 2
        let passes = abs(medianRatio - 1) <= ratioTolerance && maximumError <= maximumAllowedErrorInPixels
        return Verdict(
            scaleRatio: medianRatio,
            maximumErrorInPixels: maximumError,
            passes: passes,
            suggestedEffectiveMaxEdge: passes ? nil : Int((medianRatio * Double(sentLongEdge)).rounded())
        )
    }

    /// Parses "[[x,y],[x,y],[x,y]]" anywhere in the reply.
    public static func parsePoints(fromReply replyText: String) -> [CGPoint]? {
        guard let listRange = replyText.range(of: #"\[\s*\[[^\]]*\](\s*,\s*\[[^\]]*\])*\s*\]"#, options: .regularExpression),
              let listData = String(replyText[listRange]).data(using: .utf8),
              let pairs = try? JSONSerialization.jsonObject(with: listData) as? [[Double]] else { return nil }
        let points = pairs.compactMap { pair in pair.count == 2 ? CGPoint(x: pair[0], y: pair[1]) : nil }
        return points.count == pairs.count ? points : nil
    }
}
