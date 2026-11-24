//
//  sign-eval: how well Sign to text reads, measured the way the app reads (Tools/signs/SPEC.md). Every clip goes
//  through the same Swift pipeline as the camera: `SignLiveReader` (where a sign starts and ends, 30 frames a
//  second, features, fitting) and the Core ML models (`SignCoreMLScorer`), frame by frame with the clip's own times.
//
//  sign-eval clips --manifest <manifest.csv> --clips <folder of .npy> --models <folder> --language asl|isl
//                  [--split test] [--whole-clip] [--limit N] [--stretch name=value ...]
//      Each clip of that language (and split) in the manifest is fed as if from the camera at the manifest's fps.
//      Prints how many clips were read as a word, how many of those were right, how many were right overall, how
//      many were "unclear", and the 20 most common mix-ups. --whole-clip reads each clip as one sign instead of
//      letting the reader find where signs start and end (how training measures), to see what the finder costs.
//
//  sign-eval stream --manifest … --clips … --models … --language asl|isl [--split test] [--streams 200] [--seed 1]
//      2 to 5 clips joined end to end with a short glide and no rest, read as one stream (Streams.swift): word error
//      rate of the reading the app does.
//
//  Both clips and stream read as the app does: when the models folder has a sentence model (SignSentencesASL|ISL), a
//  stretch it reads as two or more signs takes its words, else the word model's answer stands. --no-sentence-model
//  reads with the word model alone; --least-sentence-confidence sets when a sentence-model word counts.
//
//  sign-eval video <file> --models <folder> --language asl|isl
//      Reads a video through Apple Vision (`SignVisionReader`, the app's reader) and prints the line the app would
//      send, token by token with their times.
//
//  Nothing here ships in the app; the clips and videos stay where they are.
//

import ClickyCore
import Foundation

// MARK: - Arguments

struct EvaluationError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

func printUsageAndExit() -> Never {
    print("""
    usage: sign-eval clips --manifest <manifest.csv> --clips <folder of .npy> --models <folder> --language asl|isl [--split test] [--whole-clip] [--limit N]
           sign-eval video <file> --models <folder> --language asl|isl
           sign-eval stream --manifest <manifest.csv> --clips <folder> --models <folder> --language asl|isl [--split test]
                            [--streams 200] [--seed 1]
           (clips and stream use the sentence model when the folder has one: --no-sentence-model leaves it out,
            --least-sentence-confidence 0.5 sets when its words count)
    """)
    exit(2)
}

struct EvaluationOptions {
    var command: String
    var videoPath: String?
    var manifestPath: String?
    var clipsFolderPath: String?
    var modelsFolderPath: String
    var language: SignLanguage
    var split: String?
    var readsWholeClip: Bool
    var clipLimit: Int?
    /// `--stretch name=value` (repeatable) changes one of `SignStretchSettings`' numbers, to try settings without a build.
    var stretchSettings = SignStretchSettings()
    /// `stream`: how many streams to build, from which seed, and a sentence model to read them with too.
    var streamCount = 200
    var seed: UInt64 = 1
    /// The sentence model is used when the models folder has one, unless `--no-sentence-model`.
    var usesSentenceModel = true
    /// `--least-sentence-confidence x`: a sentence-model word under this becomes an unclear sign.
    var readingSettings = SignReadingSettings()
    /// `--reads <file>`: clips also writes, per clip, `clip_id<TAB>what was read` (words, ? for unclear), for
    /// measuring against labels sign-eval can't compare itself (an English sentence for a continuous clip).
    var readsOutputPath: String?
}

/// Sets one stretch-finding number by name, as `--stretch` gives it. Unknown names stop the run.
func applyStretchSetting(_ assignment: String, to settings: inout SignStretchSettings) {
    let parts = assignment.split(separator: "=", maxSplits: 1).map(String.init)
    guard parts.count == 2, let value = Double(parts[1]) else {
        print("--stretch needs name=value, got \(assignment)")
        exit(2)
    }
    switch parts[0] {
    case "restLineBelowShouldersInShoulderWidths": settings.restLineBelowShouldersInShoulderWidths = value
    case "framesToStart": settings.framesToStart = Int(value)
    case "endGapSeconds": settings.endGapSeconds = value
    case "leadInFrames": settings.leadInFrames = Int(value)
    case "leadOutFrames": settings.leadOutFrames = Int(value)
    case "shortestStretchSeconds": settings.shortestStretchSeconds = value
    case "longestStretchSeconds": settings.longestStretchSeconds = value
    case "stillSeconds": settings.stillSeconds = value
    case "stillDistanceInShoulderWidths": settings.stillDistanceInShoulderWidths = value
    default:
        print("unknown stretch setting \(parts[0])")
        exit(2)
    }
}

func parseOptions(arguments: [String]) -> EvaluationOptions {
    guard let command = arguments.first, ["clips", "video", "stream"].contains(command) else { printUsageAndExit() }
    var videoPath: String?
    var manifestPath: String?
    var clipsFolderPath: String?
    var modelsFolderPath: String?
    var language: SignLanguage?
    var split: String?
    var readsWholeClip = false
    var clipLimit: Int?
    var stretchSettings = SignStretchSettings()
    var streamCount = 200
    var seed: UInt64 = 1
    var usesSentenceModel = true
    var readingSettings = SignReadingSettings()
    var readsOutputPath: String?
    var argumentIndex = 1
    func nextValue() -> String {
        argumentIndex += 1
        guard argumentIndex < arguments.count else { printUsageAndExit() }
        return arguments[argumentIndex]
    }
    while argumentIndex < arguments.count {
        let argument = arguments[argumentIndex]
        switch argument {
        case "--manifest": manifestPath = nextValue()
        case "--clips": clipsFolderPath = nextValue()
        case "--models": modelsFolderPath = nextValue()
        case "--language":
            guard let parsedLanguage = SignLanguage(rawValue: nextValue().lowercased()) else { printUsageAndExit() }
            language = parsedLanguage
        case "--split": split = nextValue()
        case "--whole-clip": readsWholeClip = true
        case "--stretch": applyStretchSetting(nextValue(), to: &stretchSettings)
        case "--streams":
            guard let parsedCount = Int(nextValue()), parsedCount > 0 else { printUsageAndExit() }
            streamCount = parsedCount
        case "--seed":
            guard let parsedSeed = UInt64(nextValue()) else { printUsageAndExit() }
            seed = parsedSeed
        case "--no-sentence-model": usesSentenceModel = false
        case "--reads": readsOutputPath = nextValue()
        case "--least-sentence-confidence":
            guard let parsedConfidence = Float(nextValue()) else { printUsageAndExit() }
            readingSettings.leastSentenceWordConfidence = parsedConfidence
        case "--limit":
            guard let parsedLimit = Int(nextValue()), parsedLimit > 0 else { printUsageAndExit() }
            clipLimit = parsedLimit
        default:
            if command == "video" && videoPath == nil && !argument.hasPrefix("--") {
                videoPath = argument
            } else {
                print("unknown argument: \(argument)")
                printUsageAndExit()
            }
        }
        argumentIndex += 1
    }
    guard let modelsFolderPath, let language else { printUsageAndExit() }
    if (command == "clips" || command == "stream") && (manifestPath == nil || clipsFolderPath == nil) { printUsageAndExit() }
    if command == "video" && videoPath == nil { printUsageAndExit() }
    return EvaluationOptions(
        command: command,
        videoPath: videoPath,
        manifestPath: manifestPath,
        clipsFolderPath: clipsFolderPath,
        modelsFolderPath: modelsFolderPath,
        language: language,
        split: split,
        readsWholeClip: readsWholeClip,
        clipLimit: clipLimit,
        stretchSettings: stretchSettings,
        streamCount: streamCount,
        seed: seed,
        usesSentenceModel: usesSentenceModel,
        readingSettings: readingSettings,
        readsOutputPath: readsOutputPath
    )
}

// MARK: - Models

/// Loads the language's models from the folder (an `.mlpackage` is compiled once into a cache in the temporary
/// folder) and says what was found.
func loadScorer(options: EvaluationOptions) -> SignCoreMLScorer {
    let modelsFolderURL = URL(fileURLWithPath: (options.modelsFolderPath as NSString).expandingTildeInPath, isDirectory: true)
    var files = SignModelFiles.find(in: [modelsFolderURL], language: options.language)
    if !options.usesSentenceModel { files.sentenceModelURL = nil }
    let cacheFolderURL = FileManager.default.temporaryDirectory.appendingPathComponent("sign-eval-compiled-models", isDirectory: true)
    let scorer = SignCoreMLScorer(files: files, compiledModelCacheFolder: cacheFolderURL)
    let wordModelWords = scorer.wordModel.map { "\($0.name), \($0.labels.count) words, \($0.frameCount) frames" } ?? "none"
    let spellingModelWords = scorer.spellingModel.map { "\($0.name), \($0.labels.count) characters, \($0.frameCount) frames" } ?? "none"
    let sentenceModelWords = scorer.sentenceModel.map { "\($0.name), \($0.labels.count) words, \($0.frameCount) frames (runs of 2+ signs)" } ?? "none"
    print("models: words \(wordModelWords); spelling \(spellingModelWords); sentences \(sentenceModelWords)")
    if let problems = scorer.problems {
        print("  missing or failed: \(problems)")
    }
    guard scorer.hasAnyModel else {
        print("no model to read with in \(modelsFolderURL.path)")
        exit(1)
    }
    return scorer
}

// MARK: - Manifest

struct ManifestRow {
    var clipID: String
    var language: String
    var label: String
    var split: String
    var framesPerSecond: Double
    var width: Double
    var height: Double
}

/// One CSV line into its fields: commas split fields, a field in double quotes may hold commas, and "" inside quotes
/// is one quote (how Python's csv module writes them).
func csvFields(of line: String) -> [String] {
    var fields: [String] = []
    var currentField = ""
    var isInsideQuotes = false
    var characters = Array(line)
    if characters.last == "\r" { characters.removeLast() }
    var characterIndex = 0
    while characterIndex < characters.count {
        let character = characters[characterIndex]
        if isInsideQuotes {
            if character == "\"" {
                if characterIndex + 1 < characters.count && characters[characterIndex + 1] == "\"" {
                    currentField.append("\"")
                    characterIndex += 1
                } else {
                    isInsideQuotes = false
                }
            } else {
                currentField.append(character)
            }
        } else if character == "\"" {
            isInsideQuotes = true
        } else if character == "," {
            fields.append(currentField)
            currentField = ""
        } else {
            currentField.append(character)
        }
        characterIndex += 1
    }
    fields.append(currentField)
    return fields
}

func readManifest(path: String) throws -> [ManifestRow] {
    let manifestText = try String(contentsOfFile: (path as NSString).expandingTildeInPath, encoding: .utf8)
    let lines = manifestText.split(whereSeparator: \.isNewline).map(String.init)
    guard let headerLine = lines.first else { throw EvaluationError("the manifest is empty") }
    let columnNames = csvFields(of: headerLine)
    func columnIndex(_ columnName: String) throws -> Int {
        guard let index = columnNames.firstIndex(of: columnName) else { throw EvaluationError("the manifest has no \(columnName) column") }
        return index
    }
    let clipIDColumn = try columnIndex("clip_id")
    let languageColumn = try columnIndex("language")
    let labelColumn = try columnIndex("label")
    let splitColumn = try columnIndex("split")
    let framesPerSecondColumn = try columnIndex("fps")
    let widthColumn = try columnIndex("width")
    let heightColumn = try columnIndex("height")
    let neededColumnCount = [clipIDColumn, languageColumn, labelColumn, splitColumn, framesPerSecondColumn, widthColumn, heightColumn].max()! + 1

    var rows: [ManifestRow] = []
    for line in lines.dropFirst() {
        let fields = csvFields(of: line)
        guard fields.count >= neededColumnCount else { continue }
        rows.append(ManifestRow(
            clipID: fields[clipIDColumn],
            language: fields[languageColumn],
            label: fields[labelColumn],
            split: fields[splitColumn],
            framesPerSecond: Double(fields[framesPerSecondColumn]) ?? 0,
            width: Double(fields[widthColumn]) ?? 0,
            height: Double(fields[heightColumn]) ?? 0
        ))
    }
    return rows
}

// MARK: - Comparing

/// Letters and digits only, lower case: "thank you", "thankyou" and "Thank-You" are the same answer.
func comparableText(_ text: String) -> String {
    String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
}

/// Feeds landmark frames through a fresh reader as if from the camera (frame k at k / fps), then a second of empty
/// frames so the last sign ends, and returns what went on the line.
func readClipLikeTheCamera(
    frames: [SignLandmarkFrame],
    framesPerSecond: Double,
    pictureWidth: Double,
    pictureHeight: Double,
    language: SignLanguage,
    scorer: SignCoreMLScorer,
    stretchSettings: SignStretchSettings = SignStretchSettings(),
    readingSettings: SignReadingSettings = SignReadingSettings()
) -> [SignLiveLineEntry] {
    var reader = SignLiveReader(language: language, pictureWidth: pictureWidth, pictureHeight: pictureHeight, autoSendSeconds: 0,
                                stretchSettings: stretchSettings, readingSettings: readingSettings)
    var frameNumber = 0
    for frame in frames {
        _ = reader.observeAndReadNow(frame, at: Double(frameNumber) / framesPerSecond, scoring: scorer)
        frameNumber += 1
    }
    let restFrameCount = Int(framesPerSecond.rounded(.up))
    for _ in 0..<restFrameCount {
        _ = reader.observeAndReadNow(SignLandmarkFrame(), at: Double(frameNumber) / framesPerSecond, scoring: scorer)
        frameNumber += 1
    }
    return reader.entries
}

/// The whole clip as one sign, with no stretch finding (how training measures).
func readWholeClip(
    frames: [SignLandmarkFrame],
    framesPerSecond: Double,
    pictureWidth: Double,
    pictureHeight: Double,
    language: SignLanguage,
    scorer: SignCoreMLScorer
) -> [SignLiveLineEntry] {
    let readerIdentifier = UUID()
    let job = SignStretchJob(
        readerIdentifier: readerIdentifier,
        sequenceNumber: 0,
        frames: frames,
        frameTimes: frames.indices.map { Double($0) / framesPerSecond },
        pictureWidth: pictureWidth,
        pictureHeight: pictureHeight
    )
    let outcome = SignLiveReader.read(job, scoring: scorer, settings: SignReadingSettings())
    guard outcome.couldNotRead == nil else { return [] }
    return [SignLiveLineEntry(token: outcome.token, startTime: outcome.startTime, endTime: outcome.endTime, wordGuesses: outcome.wordGuesses, spelling: outcome.spelling)]
}

// MARK: - clips

func evaluateClips(options: EvaluationOptions, scorer: SignCoreMLScorer) throws {
    let allRows = try readManifest(path: options.manifestPath!)
    var rows = allRows.filter { row in
        row.language.lowercased() == options.language.rawValue && (options.split == nil || row.split == options.split)
    }
    if let clipLimit = options.clipLimit { rows = Array(rows.prefix(clipLimit)) }
    let clipsFolderURL = URL(fileURLWithPath: (options.clipsFolderPath! as NSString).expandingTildeInPath, isDirectory: true)
    print("clips: \(rows.count) of \(allRows.count) in the manifest (\(options.language.rawValue)\(options.split.map { ", split \($0)" } ?? "")), \(options.readsWholeClip ? "each read whole" : "read as from the camera")")

    var clipsRead = 0
    var clipsReadAsSomething = 0
    var clipsRightWhenRead = 0
    var clipsUnclear = 0
    var clipsWithNothingSeen = 0
    var clipsMissing = 0
    var clipsReadAsMoreThanOneSign = 0
    var mixUpCounts: [String: Int] = [:]
    var readLines: [String] = []
    let startTime = Date()

    for row in rows {
        let clipURL = clipsFolderURL.appendingPathComponent("\(row.clipID).npy")
        guard let frames = try? SignLandmarkClipFile.read(from: clipURL), !frames.isEmpty else {
            clipsMissing += 1
            continue
        }
        clipsRead += 1
        // A dataset without a rate is taken as 30 a second, the rate the models read.
        let framesPerSecond = row.framesPerSecond > 0 ? row.framesPerSecond : SignFrameRate.modelFramesPerSecond
        let entries = options.readsWholeClip
            ? readWholeClip(frames: frames, framesPerSecond: framesPerSecond, pictureWidth: row.width, pictureHeight: row.height, language: options.language, scorer: scorer)
            : readClipLikeTheCamera(frames: frames, framesPerSecond: framesPerSecond, pictureWidth: row.width, pictureHeight: row.height, language: options.language, scorer: scorer, stretchSettings: options.stretchSettings, readingSettings: options.readingSettings)

        let line = SignedLine(tokens: entries.compactMap { $0.token })
        readLines.append("\(row.clipID)\t\(entries.map { $0.displayText }.joined(separator: " "))")
        if entries.count > 1 { clipsReadAsMoreThanOneSign += 1 }
        if line.isEmpty {
            if entries.isEmpty {
                clipsWithNothingSeen += 1
            } else {
                clipsUnclear += 1
            }
            continue
        }
        clipsReadAsSomething += 1
        let expectedText = SignWordNames.displayText(for: row.label)
        if comparableText(line.plainText) == comparableText(expectedText) {
            clipsRightWhenRead += 1
        } else {
            mixUpCounts["\(expectedText) → \(line.plainText)", default: 0] += 1
        }
    }

    if let readsOutputPath = options.readsOutputPath {
        try (readLines.joined(separator: "\n") + "\n").write(toFile: (readsOutputPath as NSString).expandingTildeInPath, atomically: true, encoding: .utf8)
    }
    func share(_ count: Int, of total: Int) -> String {
        total > 0 ? String(format: "%.1f%%", 100 * Double(count) / Double(total)) : "-"
    }
    let elapsedSeconds = Date().timeIntervalSince(startTime)
    print("")
    print("clips read:                 \(clipsRead)\(clipsMissing > 0 ? " (\(clipsMissing) listed but no .npy)" : "")")
    print("read as a word:             \(clipsReadAsSomething)  \(share(clipsReadAsSomething, of: clipsRead))")
    print("right when read:            \(clipsRightWhenRead)  \(share(clipsRightWhenRead, of: clipsReadAsSomething))")
    print("right overall:              \(clipsRightWhenRead)  \(share(clipsRightWhenRead, of: clipsRead))")
    print("unclear (\"?\"):              \(clipsUnclear)  \(share(clipsUnclear, of: clipsRead))")
    print("no sign found:              \(clipsWithNothingSeen)  \(share(clipsWithNothingSeen, of: clipsRead))")
    print("read as more than one sign: \(clipsReadAsMoreThanOneSign)  \(share(clipsReadAsMoreThanOneSign, of: clipsRead))")
    print(String(format: "time: %.1f s (%.1f clips a second)", elapsedSeconds, Double(clipsRead) / max(elapsedSeconds, 0.001)))

    let commonestMixUps = mixUpCounts.sorted { first, second in
        first.value != second.value ? first.value > second.value : first.key < second.key
    }.prefix(20)
    if !commonestMixUps.isEmpty {
        print("")
        print("most common mix-ups (signed → read):")
        for (mixUp, count) in commonestMixUps {
            print(String(format: "  %5d  %@", count, mixUp))
        }
    }
}

// MARK: - video

/// Waits on an async load from top-level code (AVFoundation's loading is async only).
final class AsyncResultBox<ResultType>: @unchecked Sendable {
    var result: Result<ResultType, Error>?
}

func waitForAsyncResult<ResultType>(_ operation: @escaping @Sendable () async throws -> ResultType) throws -> ResultType {
    let resultBox = AsyncResultBox<ResultType>()
    let finishedSignal = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            resultBox.result = .success(try await operation())
        } catch {
            resultBox.result = .failure(error)
        }
        finishedSignal.signal()
    }
    finishedSignal.wait()
    return try resultBox.result!.get()
}

func describe(_ entry: SignLiveLineEntry) -> String {
    let timeWords = String(format: "%6.2f–%6.2f s", entry.startTime, entry.endTime)
    switch entry.token {
    case .word(guesses: let guesses)?:
        let guessWords = guesses.map { String(format: "%@ %.2f", SignWordNames.displayText(for: $0.label), $0.probability) }
        return "\(timeWords)  word     \(entry.displayText)   (\(guessWords.joined(separator: ", ")))"
    case .spelled(text: let spelledText, confidence: let confidence)?:
        let letterWords = spelledText.uppercased().map(String.init).joined(separator: "-")
        return "\(timeWords)  spelled  \(letterWords)   (\(String(format: "%.2f", confidence)))"
    case .unclear?, nil:
        let bestGuess = entry.wordGuesses.first.map { String(format: "best word %@ %.2f", SignWordNames.displayText(for: $0.label), $0.probability) } ?? "no word"
        return "\(timeWords)  unclear  ?   (\(bestGuess))"
    }
}

func evaluateVideo(options: EvaluationOptions, scorer: SignCoreMLScorer) throws {
    let videoURL = URL(fileURLWithPath: (options.videoPath! as NSString).expandingTildeInPath)
    let trackInfo = try waitForAsyncResult { try await SignVideoLandmarks.loadTrackInfo(videoURL: videoURL) }
    print("video: \(videoURL.lastPathComponent), \(trackInfo.uprightWidth)×\(trackInfo.uprightHeight), \(String(format: "%.1f", trackInfo.nominalFramesPerSecond)) frames a second")

    let visionReader = SignVisionReader(readsFace: SignVisionReader.cameraReadsFace)
    var reader = SignLiveReader(
        language: options.language,
        pictureWidth: Double(trackInfo.uprightWidth),
        pictureHeight: Double(trackInfo.uprightHeight),
        autoSendSeconds: 0
    )
    var lastFrameTime = 0.0
    let framesRead = try SignVideoLandmarks.readFrames(trackInfo: trackInfo, visionReader: visionReader) { frame, frameTime in
        lastFrameTime = frameTime
        for event in reader.observeAndReadNow(frame, at: frameTime, scoring: scorer) {
            switch event {
            case .read(let entry): print(describe(entry))
            case .couldNotRead(let reason): print("couldn't read a sign: \(reason)")
            default: break
            }
        }
    }
    // A second of nothing after the video, so a sign still going at its end is read too.
    for restFrameNumber in 1...30 {
        for event in reader.observeAndReadNow(SignLandmarkFrame(), at: lastFrameTime + Double(restFrameNumber) / 30, scoring: scorer) {
            if case .read(let entry) = event { print(describe(entry)) }
        }
    }
    print("")
    print("\(framesRead) frames read")
    let line = reader.line
    if line.isEmpty {
        print("nothing to send")
    } else {
        print("line: \(line.plainText)")
        print("")
        print("what Vello would be sent:")
        print(line.messageForBrain(language: options.language))
    }
}

// MARK: - Run

let options = parseOptions(arguments: Array(CommandLine.arguments.dropFirst()))
let scorer = loadScorer(options: options)
do {
    switch options.command {
    case "clips": try evaluateClips(options: options, scorer: scorer)
    case "stream": try evaluateStreams(options: options, scorer: scorer)
    default: try evaluateVideo(options: options, scorer: scorer)
    }
} catch {
    print("sign-eval: \(error)")
    exit(1)
}
