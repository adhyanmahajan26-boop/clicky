import AppKit
import Foundation
import SwiftUI
import Testing
@testable import ClickyCore

// MARK: - Mocks

@MainActor
final class MockSpeechEngine: SpeechEngine {
    let name: String
    var callbacks = SpeechEngineCallbacks()
    var log: [String] = []
    var queued: [CaptionSegment] = []
    var sharedLog: SharedLog?

    init(name: String, sharedLog: SharedLog? = nil) {
        self.name = name
        self.sharedLog = sharedLog
    }

    func begin(epoch: Int) { log.append("begin\(epoch)"); queued = [] }
    func enqueue(_ segment: CaptionSegment) { log.append("enqueue\(segment.id)"); queued.append(segment) }
    func endOfAnswer() { log.append("end") }
    func stopNow() { log.append("stop"); sharedLog?.entries.append("\(name).stopNow"); queued = [] }
    func pause() {}
    func resume() {}

    /// Plays the next queued segment fully, reporting progress word by word.
    func playNext() {
        guard !queued.isEmpty else { return }
        let segment = queued.removeFirst()
        callbacks.onSegmentStart(segment.id)
        for wordRange in segment.wordRanges {
            callbacks.onProgress(segment.id, wordRange.upperBound, wordRange.upperBound, true)
        }
        callbacks.onSegmentEnd(segment.id)
        if queued.isEmpty { callbacks.onAllPlayed() }
    }
}

@MainActor
final class SharedLog {
    var entries: [String] = []
}

@MainActor
final class MockCoordinatorHost: SpeechCoordinatorHost {
    let sharedLog: SharedLog
    var firedTags: [Int] = []
    var droppedTags: [Int] = []
    var history: String?
    var wasInterrupted = false
    var captions: [CaptionState] = []

    init(sharedLog: SharedLog) { self.sharedLog = sharedLog }

    func cancelClaudeAndWorkers() { sharedLog.entries.append("cancelClaude") }
    func fireTag(index: Int) { firedTags.append(index) }
    func dropUnfiredTags(_ tagIndexes: [Int]) { droppedTags = tagIndexes; sharedLog.entries.append("dropTags") }
    func captionDidChange(_ caption: CaptionState) { captions.append(caption) }
    func answerDidFinish(historyText: String, wasInterrupted: Bool) {
        history = historyText
        self.wasInterrupted = wasInterrupted
        sharedLog.entries.append("history")
    }
    func speakApology(_ text: String) {}
    func log(_ event: String) {}
}

@MainActor
private func makeCoordinator() -> (SpeechCoordinator, MockSpeechEngine, MockSpeechEngine, MockCoordinatorHost) {
    let sharedLog = SharedLog()
    let qwen = MockSpeechEngine(name: "qwen", sharedLog: sharedLog)
    let apple = MockSpeechEngine(name: "apple", sharedLog: sharedLog)
    let host = MockCoordinatorHost(sharedLog: sharedLog)
    let coordinator = SpeechCoordinator(primaryEngine: qwen, fallbackEngine: apple, host: host)
    return (coordinator, qwen, apple, host)
}

private func segment(_ text: String, id: Int, firstTagIndex: Int = 0) -> CaptionSegment {
    CaptionParser.parse(text, id: id, firstTagIndex: firstTagIndex)
}

// MARK: - Coordinator

@MainActor
@Test func tagsFireOnTheirWordsExactlyOnce() {
    let (coordinator, qwen, _, host) = makeCoordinator()
    coordinator.beginAnswer()
    coordinator.registerTag(index: 0, isPoint: false)
    coordinator.registerTag(index: 1, isPoint: true)
    coordinator.enqueue(segment("click share \u{E000} then export it \u{E000}", id: 1))
    #expect(host.firedTags.isEmpty)
    qwen.playNext()
    #expect(host.firedTags == [0, 1])
    coordinator.streamDidFinish(spawnedWorkers: false)
    #expect(host.history == "click share  then export it")
    #expect(Set(coordinator.firedTagIndexes).count == coordinator.firedTagIndexes.count)
}

@MainActor
@Test func bargeInRunsInTheDocumentedOrder() {
    let (coordinator, qwen, _, host) = makeCoordinator()
    coordinator.beginAnswer()
    coordinator.registerTag(index: 0, isPoint: false)
    coordinator.enqueue(segment("first part is spoken. ", id: 1))
    coordinator.enqueue(segment("second part \u{E000} never.", id: 2))
    qwen.playNext()
    let epochBefore = coordinator.epoch
    coordinator.bargeIn(.pushToTalk)
    #expect(coordinator.epoch == epochBefore + 1)
    #expect(coordinator.bargeInOrder == ["epoch", "cancelClaude", "stopVoice", "freezeCaption", "dropTags", "history"])
    #expect(host.sharedLog.entries.prefix(4) == ["cancelClaude", "qwen.stopNow", "apple.stopNow", "dropTags"])
    #expect(host.droppedTags == [0])
    #expect(host.history == "first part is spoken. [interrupted]")
    #expect(host.wasInterrupted)
    #expect(coordinator.caption.isFrozen)
}

@MainActor
@Test func workersKeepTheAnswerOpenAcrossStreams() {
    let (coordinator, qwen, _, host) = makeCoordinator()
    coordinator.beginAnswer()
    coordinator.enqueue(segment("on it, checking those.", id: 1))
    coordinator.streamDidFinish(spawnedWorkers: true)
    qwen.playNext()
    #expect(host.history == nil)
    #expect(coordinator.caption.statusText == SpeechCoordinator.workerStatusText)
    #expect(!qwen.log.contains("end"))
    // Follow-up stream (same epoch).
    coordinator.registerTag(index: 0, isPoint: false)
    coordinator.enqueue(segment("the second plan is cheapest \u{E000}.", id: 2))
    #expect(coordinator.caption.statusText == nil)
    coordinator.streamDidFinish(spawnedWorkers: false)
    qwen.playNext()
    #expect(host.history == "on it, checking those.the second plan is cheapest .")
    #expect(host.firedTags == [0])
}

@MainActor
@Test func spokenWaitDoesNotStopItself() {
    let (coordinator, qwen, _, host) = makeCoordinator()
    var clock = Date(timeIntervalSince1970: 1000)
    coordinator.now = { clock }
    coordinator.beginAnswer()
    coordinator.enqueue(segment("wait for the build to finish first.", id: 1))
    coordinator.enqueue(segment("then run the tests again.", id: 2))
    // Play segment 1 only (the mic hears "wait" from the speaker).
    let first = qwen.queued.removeFirst()
    qwen.callbacks.onSegmentStart(first.id)
    clock = clock.addingTimeInterval(1)
    #expect(!coordinator.heardWhileSpeaking("wait"))
    #expect(host.history == nil)
    // The user says "stop" (not in recent speech) → barge-in.
    #expect(coordinator.heardWhileSpeaking("clicky stop"))
    #expect(host.wasInterrupted)
    // And "wait" is accepted again once it's older than 4 s.
    var guardState = EchoGuard()
    guardState.recordSpoken("wait for the build", at: Date(timeIntervalSince1970: 0))
    #expect(!guardState.accepts("wait", at: Date(timeIntervalSince1970: 3)))
    #expect(guardState.accepts("wait", at: Date(timeIntervalSince1970: 5)))
}

@MainActor
@Test func qwenFailureFallsBackToAppleThenReturns() {
    let (coordinator, qwen, apple, host) = makeCoordinator()
    coordinator.beginAnswer()
    let first = segment("first sentence here.", id: 1)
    let second = segment("second sentence here.", id: 2)
    coordinator.enqueue(first)
    qwen.queued.removeAll()
    qwen.callbacks.onFailure([first], false)
    #expect(apple.queued.map(\.id) == [1])
    coordinator.enqueue(second)
    #expect(qwen.queued.isEmpty) // held until Apple finishes
    apple.playNext()
    #expect(qwen.queued.map(\.id) == [2])
    coordinator.streamDidFinish(spawnedWorkers: false)
    qwen.playNext()
    #expect(host.history == "first sentence here.second sentence here.")
}

@MainActor
@Test func silentAnswersFireTagsAtOnce() {
    let (coordinator, _, _, host) = makeCoordinator()
    coordinator.isSilent = true
    coordinator.beginAnswer()
    coordinator.registerTag(index: 0, isPoint: true)
    coordinator.enqueue(segment("here \u{E000}", id: 1))
    #expect(host.firedTags == [0])
}

// MARK: - BubblePlacer

private struct SeededPlacerRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

@Test func bubbleAlwaysInsideAndClearWhenASlotIsFree() {
    var generator = SeededPlacerRandom(state: 5)
    for _ in 0..<3000 {
        // 1–3 screens, some at negative origins, one with a notch-sized top inset.
        let screenCount = Int.random(in: 1...3, using: &generator)
        var visibleFrames: [CGRect] = []
        var originX = CGFloat.random(in: -4000...0, using: &generator)
        for screenIndex in 0..<screenCount {
            let width = CGFloat.random(in: 1280...3440, using: &generator)
            let height = CGFloat.random(in: 800...1440, using: &generator)
            let topInset: CGFloat = screenIndex == 0 ? 38 : 25
            visibleFrames.append(CGRect(x: originX, y: CGFloat.random(in: -300...300, using: &generator) + topInset, width: width, height: height - topInset - 70))
            originX += width
        }
        let screen = visibleFrames.randomElement(using: &generator)!
        let companion = CGRect(x: CGFloat.random(in: screen.minX...(screen.maxX - 28), using: &generator),
                               y: CGFloat.random(in: screen.minY...(screen.maxY - 28), using: &generator), width: 28, height: 28)
        let size = CGSize(width: CGFloat.random(in: 120...360, using: &generator), height: CGFloat.random(in: 30...100, using: &generator))
        let obstacles = (0..<Int.random(in: 0...3, using: &generator)).map { _ in
            CGRect(x: companion.midX + CGFloat.random(in: -300...300, using: &generator), y: companion.midY + CGFloat.random(in: -300...300, using: &generator),
                   width: CGFloat.random(in: 20...200, using: &generator), height: CGFloat.random(in: 20...80, using: &generator))
        }
        let input = BubblePlacer.Input(companionRect: companion, bubbleSize: size, visibleFrames: visibleFrames, obstacles: obstacles)
        let placement = BubblePlacer.place(input)
        let allowed = screen.insetBy(dx: BubblePlacer.screenInset, dy: BubblePlacer.screenInset).insetBy(dx: -1e-6, dy: -1e-6)
        #expect(allowed.contains(placement.rect), "bubble \(placement.rect) outside \(screen)")
        let avoided = obstacles + [companion.insetBy(dx: -4, dy: -4)]
        let anySlotFree = [BubbleSlot.rightBelow, .rightAbove, .leftBelow, .leftAbove].contains { slot in
            let candidate = BubblePlacer.rect(for: slot, size: size, companion: companion)
            return screen.insetBy(dx: 8, dy: 8).contains(candidate) && !avoided.contains { $0.intersects(candidate) }
        }
        if anySlotFree {
            #expect(placement.slot != .dockedTop)
            #expect(!avoided.contains { $0.intersects(placement.rect) })
        }
    }
}

@Test func bubbleDoesNotHopWhenTheCompanionJitters() {
    var generator = SeededPlacerRandom(state: 11)
    let visible = [CGRect(x: 0, y: 25, width: 1920, height: 985)]
    let size = CGSize(width: 300, height: 70)
    var previous: BubblePlacement?
    var switches = 0
    let base = CGPoint(x: 900, y: 500)
    for _ in 0..<200 {
        let companion = CGRect(x: base.x + CGFloat.random(in: -3...3, using: &generator), y: base.y + CGFloat.random(in: -3...3, using: &generator), width: 28, height: 28)
        let placement = BubblePlacer.place(.init(companionRect: companion, bubbleSize: size, visibleFrames: visible, previous: previous))
        if let previous, previous.slot != placement.slot { switches += 1 }
        previous = placement
    }
    #expect(switches <= 1)
    // While flying it doesn't move at all.
    let flying = BubblePlacer.place(.init(companionRect: CGRect(x: 10, y: 600, width: 28, height: 28), bubbleSize: size, visibleFrames: visible,
                                          isCompanionFlying: true, previous: previous))
    #expect(flying == previous)
}

// MARK: - Prompt

@Test func promptVariantsAreByteStable() {
    let variants: [SystemPromptFeatures] = [.current, [.grounding, .helperWorkers], .legacy, [.grounding, .badges, .helperWorkers, .whiteboard]]
    for variant in variants {
        #expect(SystemPromptBuilder.mainSystemPrompt(features: variant) == SystemPromptBuilder.mainSystemPrompt(features: variant))
    }
    let current = SystemPromptBuilder.mainSystemPrompt(features: .current)
    #expect(current.contains("never a board."))
    #expect(current.contains("MODE lines are hints; the user's words win."))
    #expect(current.contains("Command-Shift-P"))
    #expect(current.contains("For a repo, PR or file not on screen, say you can't look that up yet."))
    #expect(current.contains("you can't draw on a whiteboard, run coding tasks, or type for the user yet."))
    // A gate without its section text changes nothing.
    #expect(SystemPromptBuilder.mainSystemPrompt(features: [.grounding, .badges, .helperWorkers, .whiteboard]) == current)
}

@Test func modeHints() {
    #expect(ModeHint.detect("draw me a diagram of this") == ModeHint(line: "MODE: whiteboard", effort: "medium"))
    #expect(ModeHint.detect("can you visualise it on the white board") == ModeHint(line: "MODE: whiteboard", effort: "medium"))
    #expect(ModeHint.detect("explain it, no whiteboard please") == ModeHint(line: "MODE: answer", effort: nil))
    #expect(ModeHint.detect("show me how to search then open build settings") == ModeHint(line: nil, effort: nil))
}

// MARK: - Qwen word timing on real (offline) WAVs

@Test func qwenWordTimesOnRealWAVs() throws {
    let fixtures = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Clicky/qwen-fixtures")
    let wavFiles = ((try? FileManager.default.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "wav" }
    guard !wavFiles.isEmpty else { return } // synthesized offline only when mlx-serve was running
    for wavFile in wavFiles {
        let audio = try #require(PCMAudio(wavData: try Data(contentsOf: wavFile)))
        let text = try String(contentsOf: wavFile.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8)
        let segment = CaptionParser.parse(text, id: 0, firstTagIndex: 0)
        let times = WordTiming.wordTimes(speech: segment.speech, wordRanges: segment.wordRanges, audio: audio)
        let total = times.ends.last! - times.starts.first!
        #expect(abs(total - (audio.duration - times.lead - times.tail)) <= 0.001, "\(wavFile.lastPathComponent)")
        #expect(times.starts == times.starts.sorted())
        #expect(times.lead < 1 && times.tail < 1.5)
        print("qwen \(wavFile.lastPathComponent): \(String(format: "%.2f", audio.duration)) s, lead \(String(format: "%.3f", times.lead)), tail \(String(format: "%.3f", times.tail)), pauses \(WordTiming.pauses(audio).count)")
    }
}

// MARK: - Bubble renders

@MainActor
@Test func bubbleRendersAtEveryRevealWithTheSameSize() throws {
    let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Clicky/renders/p2", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let previous = CaptionParser.parse("Open the Share menu in the toolbar.", id: 1, firstTagIndex: 0)
    let current = CaptionParser.parse("Then pick Export as PDF, and choose where to save it.\n```\n~/Documents\n```", id: 2, firstTagIndex: 0)
    var sizes: [CGSize] = []
    for percent in [0, 50, 100] {
        var caption = CaptionState()
        caption.previous = previous
        caption.current = current
        caption.isVisible = true
        caption.revealedDisplayCharacters = current.display.count * percent / 100
        let renderer = ImageRenderer(content: CaptionBubbleView(caption: caption, maxWidth: 360, maxLines: 4).padding(10).background(Color(white: 0.85)))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        sizes.append(CGSize(width: image.width, height: image.height))
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("bubble-\(percent).png"))
    }
    #expect(Set(sizes.map { "\($0.width)x\($0.height)" }).count == 1, "sizes \(sizes)")
    var status = CaptionState()
    status.statusText = SpeechCoordinator.workerStatusText
    let statusRenderer = ImageRenderer(content: CaptionBubbleView(caption: status, maxWidth: 360, maxLines: 4).padding(10).background(Color(white: 0.85)))
    statusRenderer.scale = 2
    try NSBitmapImageRep(cgImage: try #require(statusRenderer.cgImage)).representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("bubble-status.png"))
}

// MARK: - One voice per answer

@MainActor
@Test func aSlowSegmentStaysOnTheSameVoice() {
    // Qwen takes its time on segment 2 (no failure): nothing goes to Apple.
    let (coordinator, qwen, apple, host) = makeCoordinator()
    coordinator.beginAnswer()
    coordinator.enqueue(segment("first part here.", id: 1))
    coordinator.enqueue(segment("second part, which is slow to make.", id: 2))
    coordinator.streamDidFinish(spawnedWorkers: false)
    qwen.playNext()
    #expect(apple.queued.isEmpty)
    qwen.playNext()
    #expect(apple.log.filter { $0.hasPrefix("enqueue") }.isEmpty)
    #expect(!coordinator.didUseFallback)
    #expect(host.history == "first part here.second part, which is slow to make.")
}

@MainActor
@Test func aDeadServerHandsTheWholeRestToAppleNeverBack() {
    let (coordinator, qwen, apple, host) = makeCoordinator()
    coordinator.beginAnswer()
    let first = segment("first part here.", id: 1)
    coordinator.enqueue(first)
    qwen.queued.removeAll()
    qwen.callbacks.onFailure([first], true)
    coordinator.enqueue(segment("second part arrives later.", id: 2))
    coordinator.streamDidFinish(spawnedWorkers: false)
    #expect(qwen.queued.isEmpty)
    #expect(apple.queued.map(\.id) == [1, 2])
    apple.playNext()
    apple.playNext()
    #expect(host.history == "first part here.second part arrives later.")
}
