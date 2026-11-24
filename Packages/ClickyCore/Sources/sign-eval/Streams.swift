//
//  Streams.swift
//  sign-eval
//
//  `sign-eval stream`: 2 to 5 test clips joined end to end as one stream, the way a fluent signer goes from one sign
//  to the next without resting, then read like the camera's frames. Each later clip is moved onto the first clip's
//  body (same shoulder centre and width, so the signer doesn't jump), and a short glide (points seen at the end of one
//  clip and the start of the next slide in a straight line) joins them. Each clip keeps only its signing part: from
//  the first to the last frame with a wrist above the rest line (`SignStretchSettings`), so the hands never drop to
//  rest between signs. (Python's built sentences trim only frames with no hand at all, which in INCLUDE leaves the
//  hands resting at the sides at both ends of every clip.) Numbers here are on built streams, not real fluent signing.
//
//  Read two ways: today's pipeline (stretches, the word model on each), and, with --sentence-model, the sentence
//  model on each stretch (CTC over the word list, greedy). Word error rate = word edits / words signed.
//

import ClickyCore
import Foundation

/// A small seeded random source (SplitMix64), so the same --seed always builds the same streams.
struct SeededRandomSource: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

/// Word edits between two word lists (insertions, deletions and substitutions all count one).
func wordEditDistance(_ readWords: [String], _ signedWords: [String]) -> Int {
    if readWords.isEmpty { return signedWords.count }
    if signedWords.isEmpty { return readWords.count }
    var previousRow = Array(0...signedWords.count)
    for (readIndex, readWord) in readWords.enumerated() {
        var currentRow = [readIndex + 1] + [Int](repeating: 0, count: signedWords.count)
        for (signedIndex, signedWord) in signedWords.enumerated() {
            let substitutionCost = readWord == signedWord ? 0 : 1
            currentRow[signedIndex + 1] = min(previousRow[signedIndex + 1] + 1, currentRow[signedIndex] + 1, previousRow[signedIndex] + substitutionCost)
        }
        previousRow = currentRow
    }
    return previousRow[signedWords.count]
}

/// Where a clip's body is: the median shoulder midpoint and shoulder width, x counted in picture heights. Nil when
/// the shoulders are never seen.
private func bodyPlacement(of frames: [SignLandmarkFrame], widthOverHeight: Float) -> (centreX: Float, centreY: Float, width: Float)? {
    var centreXs: [Float] = [], centreYs: [Float] = [], widths: [Float] = []
    for frame in frames {
        let left = frame[SignBodyPoint.leftShoulder], right = frame[SignBodyPoint.rightShoulder]
        guard left.isSeen, right.isSeen else { continue }
        centreXs.append((left.x + right.x) / 2 * widthOverHeight)
        centreYs.append((left.y + right.y) / 2)
        let horizontal = (left.x - right.x) * widthOverHeight, vertical = left.y - right.y
        widths.append((horizontal * horizontal + vertical * vertical).squareRoot())
    }
    guard !widths.isEmpty else { return nil }
    func median(_ values: [Float]) -> Float { values.sorted()[values.count / 2] }
    return (median(centreXs), median(centreYs), median(widths))
}

/// The frames from the first to the last with a wrist (the hand's own, else the body pose's) above the rest line,
/// `restLineBelowShouldersInShoulderWidths` shoulder widths under the shoulders' midpoint. The clip as it is when
/// the shoulders are never seen or no wrist is ever raised.
private func signingPart(of frames: [SignLandmarkFrame], placement: (centreX: Float, centreY: Float, width: Float)?,
                         settings: SignStretchSettings) -> [SignLandmarkFrame] {
    guard let placement else { return frames }
    let restLineY = placement.centreY + Float(settings.restLineBelowShouldersInShoulderWidths) * placement.width
    func hasARaisedWrist(_ frame: SignLandmarkFrame) -> Bool {
        for side in SignSide.allCases {
            let wrist = SignFeatures.handIsSeen(in: frame, side: side)
                ? frame.handJoint(side: side, joint: .wrist)
                : frame[side == .right ? SignBodyPoint.rightWrist : SignBodyPoint.leftWrist]
            if wrist.isSeen && wrist.y < restLineY { return true }
        }
        return false
    }
    guard let first = frames.firstIndex(where: hasARaisedWrist), let last = frames.lastIndex(where: hasARaisedWrist) else { return frames }
    return Array(frames[first...last])
}

/// Moves and scales every seen point of `frames` so their body sits where `target` is.
private func moved(_ frames: [SignLandmarkFrame], from source: (centreX: Float, centreY: Float, width: Float),
                   to target: (centreX: Float, centreY: Float, width: Float), widthOverHeight: Float) -> [SignLandmarkFrame] {
    let scale = target.width / max(source.width, 1e-6)
    return frames.map { frame in
        var movedFrame = frame
        for pointIndex in 0..<SignLandmarkLayout.pointCount {
            let point = frame[pointIndex]
            guard point.isSeen else { continue }
            let x = (point.x * widthOverHeight - source.centreX) * scale + target.centreX
            let y = (point.y - source.centreY) * scale + target.centreY
            movedFrame[pointIndex] = SignLandmarkPoint(x: x / widthOverHeight, y: y, confidence: point.confidence)
        }
        return movedFrame
    }
}

/// `count` frames from `last` to `first`: a point seen in both slides along a straight line, every other point unseen.
private func glide(from last: SignLandmarkFrame, to first: SignLandmarkFrame, count: Int) -> [SignLandmarkFrame] {
    (1...max(count, 1)).map { step in
        let fraction = Float(step) / Float(count + 1)
        var frame = SignLandmarkFrame()
        for pointIndex in 0..<SignLandmarkLayout.pointCount {
            let start = last[pointIndex], end = first[pointIndex]
            guard start.isSeen, end.isSeen else { continue }
            frame[pointIndex] = SignLandmarkPoint(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction,
                                                  confidence: min(start.confidence, end.confidence))
        }
        return frame
    }
}

/// Greedy CTC over a row-major `[rows × (words + 1)]` score array, blank first: the best class per row, repeats
/// joined, blanks dropped.
func greedyCTCWords(scores: [Float], rowCount: Int, usedRowCount: Int, labels: [String]) -> [String] {
    let classCount = labels.count + 1
    var words: [String] = []
    var previousClass = -1
    for row in 0..<min(usedRowCount, rowCount) {
        let rowStart = row * classCount
        var bestClass = 0
        var bestScore = -Float.greatestFiniteMagnitude
        for classNumber in 0..<classCount where scores[rowStart + classNumber] > bestScore {
            bestScore = scores[rowStart + classNumber]
            bestClass = classNumber
        }
        if bestClass != previousClass && bestClass != 0 {
            words.append(labels[bestClass - 1])
        }
        previousClass = bestClass
    }
    return words
}

func evaluateStreams(options: EvaluationOptions, scorer: SignCoreMLScorer) throws {
    let allRows = try readManifest(path: options.manifestPath!)
    let wordSet = Set(scorer.wordLabels)
    let rows = allRows.filter { row in
        row.language.lowercased() == options.language.rawValue && (options.split == nil || row.split == options.split) && wordSet.contains(row.label)
    }
    guard rows.count >= 5 else { throw EvaluationError("fewer than 5 clips to build streams from") }
    let clipsFolderURL = URL(fileURLWithPath: (options.clipsFolderPath! as NSString).expandingTildeInPath, isDirectory: true)

    var sentenceModel: SignModelRunner?
    if let sentenceModelPath = options.sentenceModelPath {
        let cacheFolderURL = FileManager.default.temporaryDirectory.appendingPathComponent("sign-eval-compiled-models", isDirectory: true)
        sentenceModel = try SignModelRunner(modelURL: URL(fileURLWithPath: (sentenceModelPath as NSString).expandingTildeInPath), compiledModelCacheFolder: cacheFolderURL)
        print("sentence model: \(sentenceModel!.name), \(sentenceModel!.labels.count) words, \(sentenceModel!.frameCount) frames")
    }

    var random = SeededRandomSource(seed: options.seed)
    var signedWordTotal = 0
    var wordPipelineEdits = 0
    var sentencePipelineEdits = 0
    var editsBySignCount: [Int: (words: Int, wordPipeline: Int, sentencePipeline: Int, streams: Int)] = [:]
    var examples: [String] = []
    let glideFrameCount = 6

    for streamNumber in 0..<options.streamCount {
        let signCount = Int.random(in: 2...5, using: &random)
        let chosenRows = (0..<signCount).map { _ in rows[Int.random(in: 0..<rows.count, using: &random)] }
        let framesPerSecond = chosenRows[0].framesPerSecond > 0 ? chosenRows[0].framesPerSecond : SignFrameRate.modelFramesPerSecond
        let pictureWidth = chosenRows[0].width, pictureHeight = chosenRows[0].height
        let widthOverHeight = Float(pictureWidth > 0 && pictureHeight > 0 ? pictureWidth / pictureHeight : 1)

        var stream: [SignLandmarkFrame] = []
        var firstPlacement: (centreX: Float, centreY: Float, width: Float)?
        for row in chosenRows {
            guard let clipFrames = try? SignLandmarkClipFile.read(from: clipsFolderURL.appendingPathComponent("\(row.clipID).npy")) else { continue }
            let clipPlacement = bodyPlacement(of: clipFrames, widthOverHeight: widthOverHeight)
            var signFrames = signingPart(of: clipFrames, placement: clipPlacement, settings: options.stretchSettings)
            if let placement = clipPlacement {
                if let firstPlacement {
                    signFrames = moved(signFrames, from: placement, to: firstPlacement, widthOverHeight: widthOverHeight)
                } else {
                    firstPlacement = placement
                }
            }
            if let lastFrame = stream.last, let firstFrame = signFrames.first {
                stream += glide(from: lastFrame, to: firstFrame, count: glideFrameCount)
            }
            stream += signFrames
        }
        let signedWords = chosenRows.map { comparableText(SignWordNames.displayText(for: $0.label)) }

        // Today's pipeline: stretches, the word model on each.
        let entries = readClipLikeTheCamera(frames: stream, framesPerSecond: framesPerSecond, pictureWidth: pictureWidth, pictureHeight: pictureHeight,
                                            language: options.language, scorer: scorer, stretchSettings: options.stretchSettings)
        let wordPipelineWords = entries.compactMap { $0.token }.map { comparableText($0.text) }.filter { !$0.isEmpty }
        let wordPipelineEditCount = wordEditDistance(wordPipelineWords, signedWords)

        // The sentence model on each stretch the same finder finds.
        var sentencePipelineWords: [String] = []
        if let sentenceModel {
            var finder = SignStretchFinder(settings: options.stretchSettings, pictureWidth: pictureWidth, pictureHeight: pictureHeight)
            var stretches: [SignStretch] = []
            let restFrames = [SignLandmarkFrame](repeating: SignLandmarkFrame(), count: Int(framesPerSecond.rounded(.up)))
            for (frameIndex, frame) in (stream + restFrames).enumerated() {
                if case .ended(let stretch)? = finder.observe(frame, at: Double(frameIndex) / framesPerSecond) {
                    stretches.append(stretch)
                }
            }
            for stretch in stretches {
                let atModelRate = SignFrameRate.broughtTo30(frames: stretch.frames, times: stretch.frameTimes)
                let keptFrames = SignFeatures.trimmingFramesWithoutHands(atModelRate.frames)
                let featureClip = SignFeatures.featureClip(of: keptFrames, pictureWidth: pictureWidth, pictureHeight: pictureHeight)
                let fitted = SignFeatures.fitted(featureClip, toFrameCount: sentenceModel.frameCount)
                let usedFrameCount = Int(fitted.mask.reduce(0, +))
                let scores = try sentenceModel.scores(features: fitted.values, mask: fitted.mask)
                let rowCount = scores.shape.count >= 2 ? scores.shape[scores.shape.count - 2] : sentenceModel.frameCount / 2
                let usedRowCount = (usedFrameCount + 1) / 2
                sentencePipelineWords += greedyCTCWords(scores: scores.values, rowCount: rowCount, usedRowCount: usedRowCount, labels: sentenceModel.labels)
                    .map { comparableText(SignWordNames.displayText(for: $0)) }
            }
        }
        let sentencePipelineEditCount = wordEditDistance(sentencePipelineWords, signedWords)

        signedWordTotal += signedWords.count
        wordPipelineEdits += wordPipelineEditCount
        sentencePipelineEdits += sentencePipelineEditCount
        var bySignCount = editsBySignCount[signCount] ?? (0, 0, 0, 0)
        bySignCount.words += signedWords.count
        bySignCount.wordPipeline += wordPipelineEditCount
        bySignCount.sentencePipeline += sentencePipelineEditCount
        bySignCount.streams += 1
        editsBySignCount[signCount] = bySignCount
        if streamNumber < 8 {
            examples.append("signed: \(signedWords.joined(separator: " "))\n  words model: \(wordPipelineWords.joined(separator: " "))"
                + (sentenceModel != nil ? "\n  sentence model: \(sentencePipelineWords.joined(separator: " "))" : ""))
        }
    }

    func rate(_ edits: Int, _ words: Int) -> String { words > 0 ? String(format: "%.1f%%", 100 * Double(edits) / Double(words)) : "-" }
    print("streams: \(options.streamCount) of 2–5 \(options.split ?? "") clips each (seed \(options.seed)), \(signedWordTotal) signed words")
    print("word error rate, word model on each stretch:     \(rate(wordPipelineEdits, signedWordTotal))")
    if sentenceModel != nil {
        print("word error rate, sentence model on each stretch: \(rate(sentencePipelineEdits, signedWordTotal))")
    }
    for signCount in editsBySignCount.keys.sorted() {
        let counts = editsBySignCount[signCount]!
        print("  \(signCount) signs (\(counts.streams) streams): word model \(rate(counts.wordPipeline, counts.words))"
            + (sentenceModel != nil ? ", sentence model \(rate(counts.sentencePipeline, counts.words))" : ""))
    }
    print("")
    for example in examples { print(example) }
}
