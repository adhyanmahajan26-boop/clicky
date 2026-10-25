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
    }

    struct TagEntry: Encodable {
        let raw: String
        let screen: Int
        let modelPx: [Double]
        let appKitPoint: [Double]
        let cgPoint: [Double]
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

    func recordScreens(_ screenCaptures: [CompanionScreenCapture]) {
        let mainDisplayHeight = TurnLogger.mainDisplayHeight
        screens = screenCaptures.enumerated().map { screenIndex, screenCapture in
            let boundsCG = ScreenTopology.cg(fromAppKit: screenCapture.displayFrame, flipH: mainDisplayHeight)
            return ScreenEntry(
                n: screenIndex + 1,
                displayID: screenCapture.displayID,
                boundsCG: [boundsCG.minX, boundsCG.minY, boundsCG.width, boundsCG.height],
                imageW: screenCapture.screenshotWidthInPixels,
                imageH: screenCapture.screenshotHeightInPixels
            )
        }
        for (screenIndex, screenCapture) in screenCaptures.enumerated() {
            try? screenCapture.imageData.write(to: turnDirectoryURL.appendingPathComponent("screen\(screenIndex + 1).jpg"))
        }
    }

    /// The legacy hook: every POINT / MARK records the model's pixel
    /// coordinate, its screen, and where it landed, converting to CG in this
    /// one place via ScreenTopology.
    func recordTag(raw rawTag: String, screenNumber: Int, modelPixel: CGPoint, appKitPoint: CGPoint) {
        let cgPoint = ScreenTopology.cg(fromAppKit: appKitPoint, flipH: TurnLogger.mainDisplayHeight)
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
            error: turnRecord.errorDescription
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
