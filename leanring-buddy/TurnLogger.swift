//
//  TurnLogger.swift
//  leanring-buddy
//
//  Records every question-and-answer turn to
//  ~/Library/Logs/Clicky/turns/<yyyyMMdd-HHmmss>-<uuid8>/ so pointing accuracy
//  and latency can be measured instead of guessed: the exact screenshots
//  Claude saw (screen<n>.jpg) plus turn.json with the raw response, every tag
//  with both the model's pixel coordinate and where it landed on screen, and
//  the timing of each pipeline stage. Only the newest 50 turns are kept.
//

import AppKit
import ClickyCore
import Foundation

/// One turn's data. Coordinates in `cgPoint` / `boundsCG` / `cursorCG` are
/// CG global points (main display top-left origin, y down); `appKitPoint` is
/// what the legacy overlay uses (y up).
@MainActor
final class TurnRecord {
    struct ScreenEntry: Encodable {
        let n: Int
        let displayID: UInt32
        let boundsCG: [Double]
        let imageW: Int
        let imageH: Int
        let header: String
    }

    struct TagEntry: Encodable {
        let raw: String
        let screen: Int
        let modelPx: [Double]
        let appKitPoint: [Double]
        let cgPoint: [Double]
        /// v2: the resolved frame for marks (CG), how it was resolved and checked.
        var box: [Double]?
        var kind: String?
        var method: String?
        var confidence: Double?
        var elementID: Int?
        var verified: Bool?
        var occludedByPID: Int32?
        /// v2 P1c: what was actually drawn for a MARK.
        var drawn: DrawnEntry?
    }

    struct DrawnEntry: Encodable {
        struct RecheckEntry: Encodable {
            var ok: Bool
            var ms: Double
        }
        var kind: String
        var rectCG: [Double]
        var radius: Double
        var tip: [Double]?
        var tentative: Bool
        var recheck: RecheckEntry?
    }

    struct GroundingEntry: Encodable {
        var isWarm: Bool
        var keyUpToReadyMs: Double
        var prewarmReadyBeforeKeyUp: Bool?
        var registryCount: Int
        var badgedCount: Int
        var isBadged: Bool
        var droppedAXApplications: [String]
        var malformedTagCount: Int = 0
        var speechLeakCount: Int = 0
        var badgeMentionsInNarration: Int = 0
        var ocrLineCount: Int = 0
        var axWalks: [String] = []
    }

    struct SpeechEntry: Encodable {
        var engine: String?
        var fallback: Bool
    }

    let turnDirectoryURL: URL
    var transcript: String
    var cursorCG: [Double] = []
    var screens: [ScreenEntry] = []
    var rawResponse = ""
    var tags: [TagEntry] = []
    /// Unix timestamps (seconds) for keyUp, captureDone, handedToWriter,
    /// requestWritten, firstDelta, firstAudio, result, end.
    var timings: [String: Double] = [:]
    var speech = SpeechEntry(engine: nil, fallback: false)
    var errorDescription: String?
    var grounding: GroundingEntry?
    /// v2 P2: caption segments as spoken, and tags in the order they fired (each once).
    var segmentTexts: [String] = []
    var firedTagIndexes: [Int] = []

    /// The element lists exactly as sent, saved next to the screenshots.
    func recordElementLists(_ elementListTexts: [String]) {
        try? elementListTexts.joined(separator: "\n\n").write(to: turnDirectoryURL.appendingPathComponent("elements.txt"), atomically: true, encoding: .utf8)
    }

    /// A v2 tag after resolution and verification.
    @discardableResult
    func recordResolvedTag(raw rawTag: String, kind: String, screenNumber: Int, modelPixel: CGPoint?, target: ResolvedTarget) -> Int {
        let appKitPoint = ScreenTopology.appKit(fromCG: target.pointCG, flipH: TurnLogger.mainDisplayHeight)
        let hasBox = target.frameCG.width > 0 && target.frameCG.height > 0
        tags.append(TagEntry(
            raw: rawTag,
            screen: screenNumber,
            modelPx: modelPixel.map { [$0.x, $0.y] } ?? [],
            appKitPoint: [appKitPoint.x, appKitPoint.y],
            cgPoint: [target.pointCG.x, target.pointCG.y],
            box: (hasBox && kind == "mark") ? [target.frameCG.minX, target.frameCG.minY, target.frameCG.width, target.frameCG.height] : nil,
            kind: kind,
            method: target.method.rawValue,
            confidence: target.confidence,
            elementID: target.elementID,
            verified: target.verified,
            occludedByPID: target.occludedByPID
        ))
        return tags.count - 1
    }

    func recordDrawn(tagIndex: Int, drawn: DrawnEntry) {
        guard tags.indices.contains(tagIndex) else { return }
        let previousRecheck = tags[tagIndex].drawn?.recheck
        tags[tagIndex].drawn = drawn
        if drawn.recheck == nil { tags[tagIndex].drawn?.recheck = previousRecheck }
    }

    func recordRecheck(tagIndex: Int, isPassing: Bool, milliseconds: Double, isTentative: Bool) {
        guard tags.indices.contains(tagIndex) else { return }
        tags[tagIndex].drawn?.recheck = DrawnEntry.RecheckEntry(ok: isPassing, ms: (milliseconds * 10).rounded() / 10)
        tags[tagIndex].drawn?.tentative = isTentative
        if !isPassing { tags[tagIndex].confidence = tags[tagIndex].confidence.map { max(0, $0 - 0.3) } }
    }

    /// One line of <turn>/marks.jsonl (tracking events).
    func appendMarkEvent(_ event: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(event),
              var lineData = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) else { return }
        lineData.append(0x0A)
        let fileURL = turnDirectoryURL.appendingPathComponent("marks.jsonl")
        if let fileHandle = try? FileHandle(forWritingTo: fileURL) {
            fileHandle.seekToEndOfFile()
            fileHandle.write(lineData)
            try? fileHandle.close()
        } else {
            try? lineData.write(to: fileURL)
        }
    }

    fileprivate init(turnDirectoryURL: URL, transcript: String) {
        self.turnDirectoryURL = turnDirectoryURL
        self.transcript = transcript
    }

    /// Records a stage's timestamp the first time it happens (later calls
    /// for the same stage are ignored, e.g. every text delta after the first).
    func markTiming(_ stageName: String, at stageDate: Date = Date()) {
        guard timings[stageName] == nil else { return }
        timings[stageName] = stageDate.timeIntervalSince1970
    }

    func recordScreens(_ screenCaptures: [ScreenCapture]) {
        screens = screenCaptures.map { screenCapture in
            let boundsCG = screenCapture.frame.regionCG
            return ScreenEntry(
                n: screenCapture.screenNumber,
                displayID: screenCapture.displayID,
                boundsCG: [boundsCG.minX, boundsCG.minY, boundsCG.width, boundsCG.height],
                imageW: screenCapture.frame.modelSize.width,
                imageH: screenCapture.frame.modelSize.height,
                header: screenCapture.header
            )
        }
        for screenCapture in screenCaptures {
            try? screenCapture.modelJPEGData.write(to: turnDirectoryURL.appendingPathComponent("screen\(screenCapture.screenNumber).jpg"))
        }
    }

    /// Every POINT / MARK records the model's pixel coordinate, its SCREEN
    /// n, where it landed in CG, and the AppKit point the legacy overlay uses
    /// (derived here, in one place, via ScreenTopology).
    func recordTag(raw rawTag: String, screenNumber: Int, modelPixel: CGPoint, cgPoint: CGPoint) {
        let appKitPoint = ScreenTopology.appKit(fromCG: cgPoint, flipH: TurnLogger.mainDisplayHeight)
        tags.append(TagEntry(
            raw: rawTag,
            screen: screenNumber,
            modelPx: [modelPixel.x, modelPixel.y],
            appKitPoint: [appKitPoint.x, appKitPoint.y],
            cgPoint: [cgPoint.x, cgPoint.y]
        ))
    }
}

@MainActor
enum TurnLogger {
    static let maximumTurnsKept = 50

    static var turnsDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Clicky/turns", isDirectory: true)
    }

    /// Height of the main display (screens[0], never NSScreen.main), the
    /// flip height every AppKit <-> CG conversion uses.
    static var mainDisplayHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    /// The commit this build was made from, stamped into Info.plist by the
    /// "Stamp Git SHA" build phase.
    static var buildGitSHA: String {
        Bundle.main.object(forInfoDictionaryKey: "ClickyGitSHA") as? String ?? "unknown"
    }

    static func beginTurn(transcript: String, keyUpDate: Date) -> TurnRecord? {
        let timestampFormatter = DateFormatter()
        timestampFormatter.dateFormat = "yyyyMMdd-HHmmss"
        timestampFormatter.locale = Locale(identifier: "en_US_POSIX")
        let shortUniqueSuffix = UUID().uuidString.prefix(8).lowercased()
        let turnDirectoryURL = turnsDirectoryURL
            .appendingPathComponent("\(timestampFormatter.string(from: Date()))-\(shortUniqueSuffix)", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: turnDirectoryURL, withIntermediateDirectories: true)
        } catch {
            print("⚠️ TurnLogger: couldn't create \(turnDirectoryURL.path): \(error)")
            return nil
        }

        let turnRecord = TurnRecord(turnDirectoryURL: turnDirectoryURL, transcript: transcript)
        turnRecord.markTiming("keyUp", at: keyUpDate)
        let cursorCG = ScreenTopology.cg(fromAppKit: NSEvent.mouseLocation, flipH: mainDisplayHeight)
        turnRecord.cursorCG = [cursorCG.x, cursorCG.y]
        pruneOldTurns()
        return turnRecord
    }

    /// Writes turn.json atomically (temp file + rename).
    static func finishTurn(_ turnRecord: TurnRecord) {
        turnRecord.markTiming("end")

        struct TurnFile: Encodable {
            let sha: String
            let transcript: String
            let cursorCG: [Double]
            let screens: [TurnRecord.ScreenEntry]
            let rawResponse: String
            let tags: [TurnRecord.TagEntry]
            let timings: [String: Double]
            let speech: TurnRecord.SpeechEntry
            let error: String?
            let grounding: TurnRecord.GroundingEntry?
            let segments: [String]
            let firedTags: [Int]
        }

        let turnFile = TurnFile(
            sha: buildGitSHA,
            transcript: turnRecord.transcript,
            cursorCG: turnRecord.cursorCG,
            screens: turnRecord.screens,
            rawResponse: turnRecord.rawResponse,
            tags: turnRecord.tags,
            timings: turnRecord.timings,
            speech: turnRecord.speech,
            error: turnRecord.errorDescription,
            grounding: turnRecord.grounding,
            segments: turnRecord.segmentTexts,
            firedTags: turnRecord.firedTagIndexes
        )

        let jsonEncoder = JSONEncoder()
        jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let turnJSONData = try jsonEncoder.encode(turnFile)
            try turnJSONData.write(to: turnRecord.turnDirectoryURL.appendingPathComponent("turn.json"), options: .atomic)
        } catch {
            print("⚠️ TurnLogger: couldn't write turn.json: \(error)")
        }
    }

    private static func pruneOldTurns() {
        guard let turnDirectoryURLs = try? FileManager.default.contentsOfDirectory(
            at: turnsDirectoryURL,
            includingPropertiesForKeys: nil
        ) else { return }

        // Directory names start with yyyyMMdd-HHmmss, so name order is age order.
        let sortedTurnDirectoryURLs = turnDirectoryURLs
            .filter { $0.hasDirectoryPath }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let excessTurnCount = sortedTurnDirectoryURLs.count - maximumTurnsKept
        guard excessTurnCount > 0 else { return }
        for oldTurnDirectoryURL in sortedTurnDirectoryURLs.prefix(excessTurnCount) {
            try? FileManager.default.removeItem(at: oldTurnDirectoryURL)
        }
    }
}
