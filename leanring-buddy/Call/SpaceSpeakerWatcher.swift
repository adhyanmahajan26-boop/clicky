//
//  SpaceSpeakerWatcher.swift
//  leanring-buddy
//
//  Who is talking in a Space joined on Vello's own X account. While someone talks, the bot's browser window is captured
//  with ScreenCaptureKit about three times a second (a picture of the window, as a person looking at the screen sees it),
//  X's speaking ring is found on it (ClickyCore `SpaceSpeakingIndicator`), and the name under it is read with Apple
//  Vision, all on this Mac. Nothing is saved, nothing on the page is clicked or read as a page, and nothing is captured
//  while the Space is quiet. The names go into `SpaceSpeakerVotes`, which labels each heard line.
//

import AppKit
import ClickyCore
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import Vision

@MainActor
final class SpaceSpeakerWatcher {
    private let browserBundleID: String
    private let handle: String
    private let botName: String
    private(set) var votes = SpaceSpeakerVotes()
    /// Everyone seen speaking this session: readings snap to it ("Prlya" → "Priya"), and it's who is on stage.
    private(set) var roster = SpaceSpeakerRoster()
    private var loop: Task<Void, Never>?
    private var isSpeechGoingOn = false
    private var previousFrame: RGBAFrame?
    private var window: SCWindow?
    private var windowFoundAt: Date?

    /// For `ownAccountStatus`: frames looked at, with a ring, with a name, and the last trouble.
    private(set) var framesLooked = 0
    private(set) var framesWithRing = 0
    private(set) var framesWithName = 0
    private(set) var lastProblem: String?
    private(set) var lastNames: [String] = []
    private(set) var windowTitle = ""
    /// How long the last window lookup, capture and reading took, for `ownAccountStatus`.
    private(set) var lookupSeconds = 0.0
    private(set) var captureSeconds = 0.0
    private(set) var analysisSeconds = 0.0
    /// Who's talking now changed: for the call window.
    var onCurrentSpeaker: ((String?) -> Void)?

    /// Frames a second while someone talks.
    nonisolated static let framesPerSecond = 3.0
    /// The picture's width for finding the ring: enough to see a 2-point ring on a big window.
    nonisolated static let analysisWidth = 900

    /// The bot account's display name on X, when it's set (its own tile shows that, not the handle).
    private var ownDisplayNames: [String] = []

    init(browserBundleID: String, handle: String, botName: String, displayName: String = "") {
        let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedDisplayName.isEmpty { ownDisplayNames = [trimmedDisplayName] }
        self.browserBundleID = browserBundleID
        self.handle = handle
        self.botName = botName
        AccurateTextReading.warmUp()
    }

    /// The Space's audio has a voice in it (the call's gate) or not. Frames are taken only while it does.
    func setSpeechGoingOn(_ on: Bool) {
        isSpeechGoingOn = on
        if on, loop == nil { startLoop() }
    }

    func stop() {
        isSpeechGoingOn = false
        loop?.cancel()
        loop = nil
    }

    /// The name seen most while the words just heard were said, or nil ("Someone").
    func speaker(from start: Date, to end: Date) -> String? { votes.speaker(from: start, to: end) }

    /// Who has been seen speaking more than once, in the order they first spoke.
    var onStage: [String] { roster.onStage }

    private func startLoop() {
        callLog("📞 Space: looking for who's talking")
        loop = Task { @MainActor [weak self] in
            // A little after the voice stops still counts: X's ring lags the sound.
            var lastSpeechAt = Date()
            while !Task.isCancelled {
                guard let self else { return }
                if self.isSpeechGoingOn { lastSpeechAt = Date() }
                if !self.isSpeechGoingOn, Date().timeIntervalSince(lastSpeechAt) > 0.7 {
                    callLog("📞 Space: stopped looking (\(self.framesLooked) frames so far, \(self.framesWithName) with a name)")
                    self.loop = nil
                    self.previousFrame = nil
                    self.onCurrentSpeaker?(nil)
                    return
                }
                let started = Date()
                await self.lookOnce()
                let spent = Date().timeIntervalSince(started)
                let wait = max(0.05, 1 / Self.framesPerSecond - spent)
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
    }

    /// One frame: capture the window, find the rings, read the names under them, vote.
    /// `savingTo`: test use only (`ownAccountLook {path}`), the frame is also written there as a PNG.
    func lookOnce(savingTo fileURL: URL? = nil) async {
        let capturedAt = Date()
        guard let image = await captureWindow() else { return }
        if let fileURL, let destination = CGImageDestinationCreateWithURL(fileURL as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
        captureSeconds = Date().timeIntervalSince(capturedAt)
        framesLooked += 1
        let analysisStarted = Date()
        defer { analysisSeconds = Date().timeIntervalSince(analysisStarted) }
        let previous = previousFrame
        let handle = self.handle, botName = self.botName, ownDisplayNames = self.ownDisplayNames
        let result = await Task.detached(priority: .userInitiated) { () -> (RGBAFrame?, [String], Bool) in
            guard let frame = Self.frame(from: image, width: Self.analysisWidth) else { return (nil, [], false) }
            let rings = SpaceSpeakingIndicator.rings(in: frame, previous: previous)
            guard !rings.isEmpty else { return (frame, [], false) }
            let lines = Self.readText(in: image, near: rings)
            return (frame, SpaceSpeakerLayout.speakingNames(rings: rings, lines: lines, handle: handle, botName: botName,
                                                                     ownDisplayNames: ownDisplayNames), true)
        }.value
        previousFrame = result.0
        if result.2 { framesWithRing += 1 }
        if !result.1.isEmpty { framesWithName += 1 }
        // Each reading as the roster knows it, so the votes count one person once however it was misread.
        let names = result.1.map { roster.observe($0, at: capturedAt) }
        lastNames = names
        votes.record(names: names, at: capturedAt)
        onCurrentSpeaker?(votes.current(at: Date()))
    }

    // MARK: Capture

    /// The bot's browser's window: the one whose title says Space if there is one, else its biggest on screen. Kept
    /// until a capture of it fails, and looked up again in the background every half minute in case another opened:
    /// listing the screen's windows can take seconds, far longer than a frame.
    private func botBrowserWindow() async -> SCWindow? {
        if let window, let windowFoundAt {
            if Date().timeIntervalSince(windowFoundAt) > 30, !isLookingUpWindow {
                Task { @MainActor [weak self] in _ = await self?.lookUpWindow() }
            }
            return window
        }
        return await lookUpWindow()
    }

    private var isLookingUpWindow = false

    private func lookUpWindow() async -> SCWindow? {
        isLookingUpWindow = true
        let started = Date()
        defer {
            isLookingUpWindow = false
            lookupSeconds = Date().timeIntervalSince(started)
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let windows = content.windows.filter { $0.owningApplication?.bundleIdentifier == browserBundleID && $0.windowLayer == 0 && $0.frame.width > 200 }
            let chosen = windows.first { ($0.title ?? "").localizedCaseInsensitiveContains("space") }
                ?? windows.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
            window = chosen
            windowFoundAt = Date()
            windowTitle = chosen?.title ?? ""
            if chosen == nil { lastProblem = "The bot's browser has no window on screen." }
            return chosen
        } catch {
            lastProblem = "Screen recording isn't allowed, so Vello can't see who's talking (\(error.localizedDescription))."
            return nil
        }
    }

    private func captureWindow() async -> CGImage? {
        guard let window = await botBrowserWindow() else { return nil }
        let configuration = SCStreamConfiguration()
        // Twice the window's points, at most 2,400 wide: names are small text.
        let scale = min(2.0, 2400 / max(window.frame.width, 1))
        configuration.width = Int(window.frame.width * scale)
        configuration.height = Int(window.frame.height * scale)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration)
            lastProblem = nil
            return image
        } catch {
            self.window = nil
            lastProblem = "Couldn't capture the bot's browser window (\(error.localizedDescription))."
            return nil
        }
    }

    // MARK: Pixels and text

    /// The picture, `width` pixels wide, as RGBA.
    nonisolated static func frame(from image: CGImage, width targetWidth: Int) -> RGBAFrame? {
        let width = min(targetWidth, image.width)
        let height = max(1, Int(Double(image.height) * Double(width) / Double(image.width)))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? RGBAFrame(width: width, height: height, pixels: pixels) : nil
    }

    /// The lines of text around the rings, read with Vision, in boxes on the whole picture: under each ring (a speaker
    /// grid) and beside it (a list). Each strip is read on its own, doubled in size, with the ring's colour painted out:
    /// the fast reader misread "Priya" as "Prly" and "Prlya" with the ring's edge touching the name.
    nonisolated static func readText(in image: CGImage, near rings: [SpaceSpeakingRing]) -> [SpaceTextLine] {
        var lines: [SpaceTextLine] = []
        for ring in rings.prefix(3) {
            let box = ring.box
            let below = SpaceBox(x: max(0, box.x - box.width * 0.8), y: min(1, box.maxY - box.height * 0.2),
                                 width: min(1, box.maxX + box.width * 0.8) - max(0, box.x - box.width * 0.8), height: box.height * 1.4)
            let beside = SpaceBox(x: min(1, box.maxX + box.width * 0.05), y: box.y, width: box.width * 2.6, height: box.height)
            for region in [below, beside] {
                lines += read(region: region, of: image)
            }
        }
        return lines
    }

    private nonisolated static func read(region: SpaceBox, of image: CGImage) -> [SpaceTextLine] {
        let pixelRect = CGRect(x: region.x * Double(image.width), y: region.y * Double(image.height),
                               width: region.width * Double(image.width), height: region.height * Double(image.height))
            .integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard pixelRect.width > 8, pixelRect.height > 8, let crop = image.cropping(to: pixelRect) else { return [] }
        let enlarged = doubledWithoutVividColour(crop) ?? crop
        let request = VNRecognizeTextRequest()
        // The accurate reader once it's loaded: the fast one read "Priya" as "Prlya" every time (Studio, 25 Nov).
        request.recognitionLevel = AccurateTextReading.isReady ? .accurate : .fast
        request.usesLanguageCorrection = false
        // Latin scripts first: with automatic languages the reader wrote "@KPKPKP9828" in Cyrillic look-alikes.
        request.automaticallyDetectsLanguage = false
        request.recognitionLanguages = latinFirstLanguages(for: request)
        try? VNImageRequestHandler(cgImage: enlarged, options: [:]).perform([request])
        // The crop as it really was, after clipping to the picture.
        let cropBox = SpaceBox(x: pixelRect.minX / Double(image.width), y: pixelRect.minY / Double(image.height),
                               width: pixelRect.width / Double(image.width), height: pixelRect.height / Double(image.height))
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let rect = observation.boundingBox
            // Vision's boxes are 0...1 of the crop from the bottom left; these are 0...1 of the picture from the top left.
            return SpaceTextLine(text: text, box: SpaceBox(x: cropBox.x + rect.minX * cropBox.width, y: cropBox.y + (1 - rect.maxY) * cropBox.height,
                                                           width: rect.width * cropBox.width, height: rect.height * cropBox.height))
        }
    }

    /// The strip at twice the size, with every vivid pixel (the speaking ring, a badge) painted the strip's background
    /// colour, so only the name's plain text is left to read.
    /// English and the other Latin-script languages Vision reads, English first.
    private nonisolated static func latinFirstLanguages(for request: VNRecognizeTextRequest) -> [String] {
        let supported = (try? request.supportedRecognitionLanguages()) ?? ["en-US"]
        let wanted = ["en-US", "en-GB", "fr-FR", "de-DE", "es-ES", "it-IT", "pt-BR", "nl-NL", "id-ID", "ms-MY", "tr-TR", "vi-VT", "pl-PL"]
        let chosen = wanted.filter(supported.contains)
        return chosen.isEmpty ? ["en-US"] : chosen
    }

    private nonisolated static func doubledWithoutVividColour(_ image: CGImage) -> CGImage? {
        let width = image.width * 2, height = image.height * 2
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = context.data else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        // The background: the most common colour along the strip's top and bottom rows, roughly.
        var tally: [UInt32: Int] = [:]
        for y in [0, height - 1] {
            for x in Swift.stride(from: 0, to: width, by: 3) {
                let offset = (y * width + x) * 4
                let key = UInt32(pixels[offset] >> 4) << 8 | UInt32(pixels[offset + 1] >> 4) << 4 | UInt32(pixels[offset + 2] >> 4)
                tally[key, default: 0] += 1
            }
        }
        let background = tally.max { $0.value < $1.value }?.key ?? 0
        let fill = (UInt8((background >> 8) & 0xF) << 4 | 0x8, UInt8((background >> 4) & 0xF) << 4 | 0x8, UInt8(background & 0xF) << 4 | 0x8)
        for index in 0..<(width * height) {
            let offset = index * 4
            let red = Double(pixels[offset]), green = Double(pixels[offset + 1]), blue = Double(pixels[offset + 2])
            let brightest = max(red, green, blue), darkest = min(red, green, blue)
            guard brightest > 0, (brightest - darkest) / brightest >= 0.42, brightest / 255 >= 0.32 else { continue }
            pixels[offset] = fill.0; pixels[offset + 1] = fill.1; pixels[offset + 2] = fill.2
        }
        return context.makeImage()
    }

    func report() -> [String: Any] {
        ["framesLooked": framesLooked, "framesWithRing": framesWithRing, "framesWithName": framesWithName, "lastNames": lastNames, "onStage": roster.onStage,
         "problem": lastProblem ?? "", "window": windowTitle, "current": votes.current(at: Date()) ?? "",
         "accurateReading": AccurateTextReading.isReady, "lookupSeconds": lookupSeconds, "captureSeconds": captureSeconds, "analysisSeconds": analysisSeconds]
    }
}

/// Vision's accurate text reader. Its very first use on a Mac took 34 s (Studio, 25 Nov; a second process loaded it in
/// 0.14 s), and every reading waits while it loads, so it's loaded in the background when a Space starts and names are
/// read with the fast one until then.
enum AccurateTextReading {
    private static let state = AccurateTextReadingState()
    static var isReady: Bool { state.isReady }

    static func warmUp() {
        guard state.begin() else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let started = Date()
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            if let context = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let image = context.makeImage() {
                try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            }
            state.finished()
            callLog("📞 Space: the name reader is ready (\(String(format: "%.1f", Date().timeIntervalSince(started))) s)")
        }
    }
}

private final class AccurateTextReadingState: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var ready = false
    var isReady: Bool { lock.withLock { ready } }
    func begin() -> Bool { lock.withLock { if started { return false }; started = true; return true } }
    func finished() { lock.withLock { ready = true } }
}
