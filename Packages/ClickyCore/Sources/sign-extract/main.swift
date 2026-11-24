//
//  sign-extract: videos and photos to Apple Vision landmarks for Sign to text training (Tools/signs/SPEC.md).
//
//  sign-extract videos --list <file.tsv> --out <folder> [--face] [--pad-body] [--jobs N] [--max-fps 30]
//  sign-extract images --list <file.tsv> --out <folder> [--face] [--pad-body] [--jobs N]
//
//  --pad-body runs the body pose on the picture placed in a bigger canvas: needed for close head-and-shoulders
//  framing (phone selfies, laptop cameras), where Vision otherwise finds no body at all.
//
//  The list has `clip_id<TAB>absolute path` per line. Each clip becomes `<out>/<clip_id>.npy` ([T, 61, 3] float32)
//  and a row in `<out>/extract.csv`; a clip whose `.npy` already exists is skipped, so a stopped run just starts
//  again. A clip that fails goes to `<out>/failed.tsv` with the reason and the run carries on.
//
//  Nothing here ships in the app; the videos stay where they are.
//

import ClickyCore
import CoreImage
import Foundation
import Vision

enum ExtractionMode: String {
    case videos
    case images
}

struct ExtractionOptions {
    var mode: ExtractionMode
    var listPath: String
    var outputFolderPath: String
    var readsFace: Bool
    var padsPictureForBody: Bool
    var jobCount: Int
    var maximumFramesPerSecond: Double
}

struct ClipToExtract {
    var clipID: String
    var sourcePath: String
}

/// What one clip's row in extract.csv says.
struct ClipExtractionResult {
    var clipID: String
    var framesPerSecond: Double
    var uprightWidth: Int
    var uprightHeight: Int
    var frameCount: Int
    var framesWithRightHand: Int
    var framesWithLeftHand: Int
    var framesWithShoulders: Int
    var secondsTaken: Double

    var csvRow: String {
        [
            clipID,
            String(format: "%.3f", framesPerSecond),
            String(uprightWidth),
            String(uprightHeight),
            String(frameCount),
            String(framesWithRightHand),
            String(framesWithLeftHand),
            String(framesWithShoulders),
            String(format: "%.2f", secondsTaken)
        ].joined(separator: ",")
    }

    static let csvHeader = "clip_id,fps,width,height,frames,frames_with_right_hand,frames_with_left_hand,frames_with_shoulders,seconds_taken"
}

func printUsageAndExit() -> Never {
    print("""
    usage: sign-extract videos --list <file.tsv> --out <folder> [--face] [--pad-body] [--jobs N] [--max-fps 30]
           sign-extract images --list <file.tsv> --out <folder> [--face] [--pad-body] [--jobs N]
    The list has clip_id<TAB>absolute path per line.
    """)
    exit(2)
}

/// Performance cores minus 2 (the rest of the Mac stays usable), at least 1.
func defaultJobCount() -> Int {
    var performanceCoreCount: Int32 = 0
    var valueSize = MemoryLayout<Int32>.size
    if sysctlbyname("hw.perflevel0.physicalcpu", &performanceCoreCount, &valueSize, nil, 0) != 0 || performanceCoreCount <= 0 {
        performanceCoreCount = Int32(ProcessInfo.processInfo.activeProcessorCount)
    }
    return max(1, Int(performanceCoreCount) - 2)
}

func parseOptions(arguments: [String]) -> ExtractionOptions {
    guard let modeName = arguments.first, let mode = ExtractionMode(rawValue: modeName) else { printUsageAndExit() }
    var listPath: String?
    var outputFolderPath: String?
    var readsFace = false
    var padsPictureForBody = false
    var jobCount = defaultJobCount()
    var maximumFramesPerSecond = 30.0
    var argumentIndex = 1
    func nextValue() -> String {
        argumentIndex += 1
        guard argumentIndex < arguments.count else { printUsageAndExit() }
        return arguments[argumentIndex]
    }
    while argumentIndex < arguments.count {
        switch arguments[argumentIndex] {
        case "--list": listPath = nextValue()
        case "--out": outputFolderPath = nextValue()
        case "--face": readsFace = true
        case "--pad-body": padsPictureForBody = true
        case "--jobs":
            guard let parsedJobCount = Int(nextValue()), parsedJobCount > 0 else { printUsageAndExit() }
            jobCount = parsedJobCount
        case "--max-fps":
            guard let parsedRate = Double(nextValue()), parsedRate > 0 else { printUsageAndExit() }
            maximumFramesPerSecond = parsedRate
        default:
            print("unknown argument: \(arguments[argumentIndex])")
            printUsageAndExit()
        }
        argumentIndex += 1
    }
    guard let listPath, let outputFolderPath else { printUsageAndExit() }
    return ExtractionOptions(
        mode: mode,
        listPath: listPath,
        outputFolderPath: outputFolderPath,
        readsFace: readsFace,
        padsPictureForBody: padsPictureForBody,
        jobCount: jobCount,
        maximumFramesPerSecond: maximumFramesPerSecond
    )
}

func loadClipList(listPath: String) throws -> [ClipToExtract] {
    let listText = try String(contentsOfFile: listPath, encoding: .utf8)
    var clips: [ClipToExtract] = []
    for line in listText.split(whereSeparator: \.isNewline) {
        let columns = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        guard columns.count == 2 else { continue }
        let clipID = columns[0].trimmingCharacters(in: .whitespaces)
        let sourcePath = String(columns[1])
        guard !clipID.isEmpty, !sourcePath.isEmpty else { continue }
        clips.append(ClipToExtract(clipID: clipID, sourcePath: sourcePath))
    }
    return clips
}

/// Counts what a finished clip saw, for extract.csv.
func summarize(frames: [SignLandmarkFrame]) -> (rightHand: Int, leftHand: Int, shoulders: Int) {
    var framesWithRightHand = 0, framesWithLeftHand = 0, framesWithShoulders = 0
    for frame in frames {
        if frame.seenJointCount(side: .right) > 0 { framesWithRightHand += 1 }
        if frame.seenJointCount(side: .left) > 0 { framesWithLeftHand += 1 }
        if frame[SignBodyPoint.leftShoulder].isSeen && frame[SignBodyPoint.rightShoulder].isSeen { framesWithShoulders += 1 }
    }
    return (framesWithRightHand, framesWithLeftHand, framesWithShoulders)
}

/// Opens a log file for appending, writing its header only when this call creates the file (O_EXCL makes exactly
/// one of several processes starting together do that).
func openForAppending(fileURL: URL, headerLine: String) throws -> FileHandle {
    let createdFileDescriptor = open(fileURL.path, O_WRONLY | O_CREAT | O_EXCL | O_APPEND, 0o644)
    if createdFileDescriptor >= 0 {
        let createdHandle = FileHandle(fileDescriptor: createdFileDescriptor, closeOnDealloc: true)
        createdHandle.write(Data((headerLine + "\n").utf8))
        return createdHandle
    }
    let existingFileDescriptor = open(fileURL.path, O_WRONLY | O_APPEND)
    guard existingFileDescriptor >= 0 else { throw ExtractionError("can't open \(fileURL.path) for appending") }
    return FileHandle(fileDescriptor: existingFileDescriptor, closeOnDealloc: true)
}

/// Shared between the workers: what is left to do, the output files and the counters. Everything behind one lock;
/// the work under it is tiny next to a Vision frame.
final class ExtractionProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var nextClipIndex = 0
    private let clips: [ClipToExtract]
    private let extractCSVHandle: FileHandle
    private let failedTSVHandle: FileHandle
    private(set) var clipsFinished = 0
    private(set) var clipsFailed = 0
    private(set) var framesRead = 0
    private(set) var totalVideoSeconds = 0.0

    init(clips: [ClipToExtract], extractCSVURL: URL, failedTSVURL: URL) throws {
        self.clips = clips
        // Several sign-extract processes (each with a slice of one list) share one output folder, so the files are
        // opened in append mode: every row lands at the end in one write and no process overwrites another's rows.
        extractCSVHandle = try openForAppending(fileURL: extractCSVURL, headerLine: ClipExtractionResult.csvHeader)
        failedTSVHandle = try openForAppending(fileURL: failedTSVURL, headerLine: "clip_id\tpath\treason")
    }

    func takeNextClip() -> ClipToExtract? {
        lock.lock()
        defer { lock.unlock() }
        guard nextClipIndex < clips.count else { return nil }
        let clip = clips[nextClipIndex]
        nextClipIndex += 1
        return clip
    }

    func addFramesRead(_ frameCount: Int) {
        lock.lock()
        framesRead += frameCount
        lock.unlock()
    }

    func recordFinished(_ result: ClipExtractionResult) {
        lock.lock()
        defer { lock.unlock() }
        clipsFinished += 1
        if result.framesPerSecond > 0 { totalVideoSeconds += Double(result.frameCount) / result.framesPerSecond }
        extractCSVHandle.write(Data((result.csvRow + "\n").utf8))
    }

    func recordFailed(_ clip: ClipToExtract, reason: String) {
        lock.lock()
        defer { lock.unlock() }
        clipsFailed += 1
        let cleanReason = reason.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
        failedTSVHandle.write(Data("\(clip.clipID)\t\(clip.sourcePath)\t\(cleanReason)\n".utf8))
    }

    func snapshot() -> (finished: Int, failed: Int, frames: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (clipsFinished, clipsFailed, framesRead)
    }

    func close() {
        try? extractCSVHandle.close()
        try? failedTSVHandle.close()
    }
}

func extractOneClip(
    _ clip: ClipToExtract,
    options: ExtractionOptions,
    landmarkReader: VisionLandmarkReader,
    progress: ExtractionProgress
) throws -> ClipExtractionResult {
    let startTime = Date()
    let sourceURL = URL(fileURLWithPath: clip.sourcePath)
    guard FileManager.default.fileExists(atPath: sourceURL.path) else { throw ExtractionError("file not found") }
    var frames: [SignLandmarkFrame] = []
    let framesPerSecond: Double
    let uprightWidth: Int
    let uprightHeight: Int

    switch options.mode {
    case .videos:
        var framesSinceLastReport = 0
        let summary = try readVideoFrames(videoURL: sourceURL, maximumFramesPerSecond: options.maximumFramesPerSecond) { pixelBuffer, orientation, uprightWidthOverHeight in
            let requestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
            let uprightPicture = options.padsPictureForBody ? CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation) : nil
            frames.append(try landmarkReader.readLandmarks(requestHandler: requestHandler, pictureWidthOverHeight: uprightWidthOverHeight, uprightPictureForPaddedBody: uprightPicture))
            framesSinceLastReport += 1
            if framesSinceLastReport == 30 {
                progress.addFramesRead(framesSinceLastReport)
                framesSinceLastReport = 0
            }
        }
        progress.addFramesRead(framesSinceLastReport)
        guard summary.keptFrameCount > 0 else { throw ExtractionError("no frames could be read") }
        framesPerSecond = summary.keptFrameRate
        uprightWidth = summary.uprightWidth
        uprightHeight = summary.uprightHeight
    case .images:
        let photo = try loadStillPhoto(photoURL: sourceURL)
        let requestHandler = VNImageRequestHandler(cgImage: photo.image, orientation: photo.orientation, options: [:])
        let uprightWidthOverHeight = Float(photo.uprightWidth) / Float(max(1, photo.uprightHeight))
        let uprightPicture = options.padsPictureForBody ? CIImage(cgImage: photo.image).oriented(photo.orientation) : nil
        frames.append(try landmarkReader.readLandmarks(requestHandler: requestHandler, pictureWidthOverHeight: uprightWidthOverHeight, uprightPictureForPaddedBody: uprightPicture))
        progress.addFramesRead(1)
        // A photo is a one-frame clip with no rate.
        framesPerSecond = 0
        uprightWidth = photo.uprightWidth
        uprightHeight = photo.uprightHeight
    }

    let outputURL = URL(fileURLWithPath: options.outputFolderPath).appendingPathComponent("\(clip.clipID).npy")
    try SignLandmarkClipFile.write(frames: frames, to: outputURL)
    let counts = summarize(frames: frames)
    return ClipExtractionResult(
        clipID: clip.clipID,
        framesPerSecond: framesPerSecond,
        uprightWidth: uprightWidth,
        uprightHeight: uprightHeight,
        frameCount: frames.count,
        framesWithRightHand: counts.rightHand,
        framesWithLeftHand: counts.leftHand,
        framesWithShoulders: counts.shoulders,
        secondsTaken: Date().timeIntervalSince(startTime)
    )
}

// MARK: - Run

let options = parseOptions(arguments: Array(CommandLine.arguments.dropFirst()))
let fileManager = FileManager.default
do {
    try fileManager.createDirectory(atPath: options.outputFolderPath, withIntermediateDirectories: true)
} catch {
    print("can't make the output folder: \(error)")
    exit(1)
}

let allClips: [ClipToExtract]
do {
    allClips = try loadClipList(listPath: options.listPath)
} catch {
    print("can't read the list: \(error)")
    exit(1)
}

// A clip id becomes a file name, so one with a slash (or a leading dot, which would hide the file) is refused.
var clipsToDo: [ClipToExtract] = []
var clipsAlreadyDone = 0
var clipsWithBadIDs: [ClipToExtract] = []
var clipIDsSeen = Set<String>()
for clip in allClips {
    if clip.clipID.contains("/") || clip.clipID.hasPrefix(".") {
        clipsWithBadIDs.append(clip)
        continue
    }
    // The same id twice would have two workers writing one file; the first one listed is kept.
    guard clipIDsSeen.insert(clip.clipID).inserted else { continue }
    let outputPath = (options.outputFolderPath as NSString).appendingPathComponent("\(clip.clipID).npy")
    if fileManager.fileExists(atPath: outputPath) {
        clipsAlreadyDone += 1
    } else {
        clipsToDo.append(clip)
    }
}

let outputFolderURL = URL(fileURLWithPath: options.outputFolderPath)
let progress: ExtractionProgress
do {
    progress = try ExtractionProgress(
        clips: clipsToDo,
        extractCSVURL: outputFolderURL.appendingPathComponent("extract.csv"),
        failedTSVURL: outputFolderURL.appendingPathComponent("failed.tsv")
    )
} catch {
    print("can't open extract.csv / failed.tsv: \(error)")
    exit(1)
}
for clip in clipsWithBadIDs {
    progress.recordFailed(clip, reason: "clip id can't be a file name")
}

let jobCount = min(options.jobCount, max(1, clipsToDo.count))
print("sign-extract \(options.mode.rawValue): \(allClips.count) listed, \(clipsAlreadyDone) already done, \(clipsToDo.count) to do, \(jobCount) jobs, face \(options.readsFace ? "on" : "off"), padded body \(options.padsPictureForBody ? "on" : "off")"
    + (options.mode == .videos ? ", max \(Int(options.maximumFramesPerSecond)) fps" : ""))

let runStartTime = Date()
let allWorkersFinished = DispatchGroup()
for _ in 0..<jobCount {
    allWorkersFinished.enter()
    let workerThread = Thread {
        // Each worker has its own Vision requests: they are not safe to share between threads.
        let landmarkReader = VisionLandmarkReader(readsFace: options.readsFace)
        while let clip = progress.takeNextClip() {
            autoreleasepool {
                do {
                    let result = try extractOneClip(clip, options: options, landmarkReader: landmarkReader, progress: progress)
                    progress.recordFinished(result)
                } catch {
                    progress.recordFailed(clip, reason: String(describing: error))
                }
            }
        }
        allWorkersFinished.leave()
    }
    workerThread.stackSize = 8 << 20
    workerThread.start()
}

func printProgressLine(prefix: String) {
    let snapshot = progress.snapshot()
    let elapsedSeconds = Date().timeIntervalSince(runStartTime)
    let framesPerSecond = elapsedSeconds > 0 ? Double(snapshot.frames) / elapsedSeconds : 0
    print(String(
        format: "%@ %d/%d clips done (%d failed), %d frames, %.0f frames/s, %.0f s",
        prefix, snapshot.finished + snapshot.failed, clipsToDo.count, snapshot.failed, snapshot.frames, framesPerSecond, elapsedSeconds
    ))
    fflush(stdout)
}

while allWorkersFinished.wait(timeout: .now() + 10) == .timedOut {
    printProgressLine(prefix: "  progress:")
}
progress.close()
printProgressLine(prefix: "done:")
if progress.totalVideoSeconds > 0 {
    let elapsedSeconds = Date().timeIntervalSince(runStartTime)
    print(String(format: "  %.0f s of video in %.0f s (%.1fx real time)", progress.totalVideoSeconds, elapsedSeconds, progress.totalVideoSeconds / max(elapsedSeconds, 0.001)))
}
if progress.clipsFailed > 0 || !clipsWithBadIDs.isEmpty {
    print("  failures are listed in \(outputFolderURL.appendingPathComponent("failed.tsv").path)")
}
