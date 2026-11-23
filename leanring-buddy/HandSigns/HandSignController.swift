//
//  HandSignController.swift
//  leanring-buddy
//
//  Hand signs: with Settings › Pointer Assistant › Hand signs on, the camera watches for a hand
//  (HandSignCamera), ClickyCore's HandSignClassifier reads each frame's shape, HandSignHoldTracker
//  makes a held sign count once, and this does what it means (HandSignActions):
//
//  - Control Pointer Assistant: open palm starts a hands-free session (it listens, you talk, it answers),
//    fist is Escape, thumbs up / down answer the step waiting for a yes, one finger up asks what's on
//    screen, and the other signs say their phrase.
//  - Speak for me: every sign is said out loud as its phrase (the owner's own words, Settings) and
//    shown big on the camera panel, so someone who signs can talk to the people around them.
//  - Spell to text: finger-spelled letters (ClickyCore Fingerspelling.swift: ASL's still letters built in,
//    and any sign the owner taught, one hand or two, which is how ISL is read) become text on the panel.
//    Hand out of the picture ends a word, thumbs down deletes, the spread open hand sends it to Vello's
//    chat (which can pass it to Pointer Assistant or Cursor), straight to Pointer Assistant, or types it
//    into the app in front.
//
//  The camera panel (HandSignPanel) is up whenever the camera is on, so it's never on unseen. The
//  camera stops while the screen is locked or asleep. Nothing is recorded: frames become joints and go.
//

import AppKit
import AVFoundation
import ClickyCore
import Combine
import QuartzCore

final class HandSignController: ObservableObject {
    enum Keys {
        static let enabled = "v5.handSigns.enabled"
        static let mode = "v5.handSigns.mode"
        static let phrases = "v5.handSigns.phrases"
        static let showsCameraPicture = "v5.handSigns.showsCameraPicture"
        static let spellAlphabet = "v5.handSigns.spell.alphabet"
        static let spellDestination = "v5.handSigns.spell.destination"
        static let taughtSigns = "v5.handSigns.taughtSigns"
    }

    static var savedAlphabet: FingerspellingAlphabet {
        get { UserDefaults.standard.string(forKey: Keys.spellAlphabet).flatMap(FingerspellingAlphabet.init(rawValue:)) ?? .asl }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Keys.spellAlphabet) }
    }

    static var savedDestination: SpelledTextDestination {
        get { UserDefaults.standard.string(forKey: Keys.spellDestination).flatMap(SpelledTextDestination.init(rawValue:)) ?? .vello }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Keys.spellDestination) }
    }

    static var savedTaughtSigns: TaughtSignBook {
        get { TaughtSignBook.decode(UserDefaults.standard.string(forKey: Keys.taughtSigns)) }
        set { UserDefaults.standard.set(newValue.encode(), forKey: Keys.taughtSigns) }
    }

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: Keys.enabled) }

    static var savedMode: HandSignMode {
        get { UserDefaults.standard.string(forKey: Keys.mode).flatMap(HandSignMode.init(rawValue:)) ?? .control }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Keys.mode) }
    }

    static var phrases: [HandSign: String] {
        get { HandSignPhrases.decode(UserDefaults.standard.string(forKey: Keys.phrases)) }
        set { UserDefaults.standard.set(HandSignPhrases.encode(newValue), forKey: Keys.phrases) }
    }

    static var showsCameraPicture: Bool {
        get { UserDefaults.standard.object(forKey: Keys.showsCameraPicture) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Keys.showsCameraPicture) }
    }

    /// The camera is on and reading.
    @Published private(set) var isRunning = false
    /// A hand is in the picture right now.
    @Published private(set) var handIsVisible = false
    /// The sign the current frame shows, before it's been held long enough.
    @Published private(set) var seenSign: HandSign?
    /// 0 to 1: how far through its hold the current sign is.
    @Published private(set) var holdProgress: Double = 0
    /// The last sign that counted, and what was done or said for it.
    @Published private(set) var lastFiredSign: HandSign?
    @Published private(set) var lastLine = ""
    /// Why the camera isn't on, in words for the owner.
    @Published private(set) var problem: String?
    @Published var mode: HandSignMode = HandSignController.savedMode {
        didSet {
            guard mode != oldValue else { return }
            Self.savedMode = mode
            lastLine = Self.startingLine(for: mode)
            holdTracker.reset()
            spellingSession.reset()
            seenSign = nil
            seenSpellingLabel = nil
            holdProgress = 0
        }
    }
    @Published var showsCameraPicture: Bool = HandSignController.showsCameraPicture {
        didSet { Self.showsCameraPicture = showsCameraPicture }
    }

    // Spell to text.
    /// The text spelled so far, shown on the panel until it's sent.
    @Published private(set) var spelledText = SpelledText()
    /// The letter (or taught sign) the current frame shows, before it's held long enough.
    @Published private(set) var seenSpellingLabel: String?
    @Published var alphabet: FingerspellingAlphabet = HandSignController.savedAlphabet {
        didSet { Self.savedAlphabet = alphabet }
    }
    @Published var destination: SpelledTextDestination = HandSignController.savedDestination {
        didSet { Self.savedDestination = destination }
    }
    @Published private(set) var taughtSigns: TaughtSignBook = HandSignController.savedTaughtSigns
    /// While teaching: the sign being taught and how many examples were taken.
    @Published private(set) var teachingLabel: String?
    @Published private(set) var teachingExamplesTaken = 0
    @Published private(set) var teachingLine = ""

    let camera = HandSignCamera()
    private weak var companionManager: CompanionManager?
    private var holdTracker = HandSignHoldTracker()
    private var spellingSession = FingerspellingSession()
    private var lastTeachingExampleAt: CFTimeInterval = 0
    /// Examples are taken this far apart, so they differ a little (the hand moves) and teach more.
    private static let secondsBetweenTeachingExamples: CFTimeInterval = 0.35
    private var recentSpelledTexts: [(text: String, destination: String, date: Date)] = []
    private lazy var panelController = HandSignPanelController(controller: self)
    private var isPausedForLockOrSleep = false
    private var systemObservers: [(NotificationCenter, NSObjectProtocol)] = []
    /// The last few signs that counted, for `handSigns {action: state}`.
    private var recentSigns: [(sign: HandSign, line: String, date: Date)] = []

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        camera.onHandPoses = { [weak self] handPoses in
            MainActor.assumeIsolated { self?.handle(handPoses) }
        }
    }

    /// At launch: watch for lock and sleep, and turn the camera on if it was left on.
    func startIfEnabled() {
        observeLockAndSleep()
        // The test profile never opens the real camera by itself; `handSigns {action: sign}` drives it instead.
        guard Self.isEnabled, !TheoProfile.isTest else { return }
        Task { await turnOn() }
    }

    /// The Settings switch.
    func setEnabled(_ isOn: Bool) {
        UserDefaults.standard.set(isOn, forKey: Keys.enabled)
        if isOn {
            Task { await turnOn() }
        } else {
            turnOff()
        }
    }

    func turnOn() async {
        guard TheoProducts.isOn(.clicky) else {
            problem = "Pointer Assistant is off. Turn it on in Settings › Products."
            return
        }
        guard await HandSignCamera.requestAccess() else {
            problem = HandSignCamera.CameraProblem.notAllowed.errorDescription
            return
        }
        // Switched off again while macOS was asking.
        guard Self.isEnabled else { return }
        do {
            try camera.start()
        } catch {
            problem = error.localizedDescription
            return
        }
        problem = nil
        isRunning = true
        isPausedForLockOrSleep = false
        holdTracker.reset()
        spellingSession.reset()
        lastLine = Self.startingLine(for: mode)
        panelController.show()
    }

    private static func startingLine(for mode: HandSignMode) -> String {
        switch mode {
        case .control: return "Show an open palm to talk to me."
        case .speakForMe: return "Sign, and I'll say it."
        case .spell: return "Spell a word. Spread your open hand to send it."
        }
    }

    func turnOff() {
        camera.stop()
        isRunning = false
        holdTracker.reset()
        spellingSession.reset()
        stopTeaching()
        seenSpellingLabel = nil
        handIsVisible = false
        seenSign = nil
        holdProgress = 0
        panelController.hide()
    }

    /// The panel's close button: off, and stays off.
    func switchOffFromPanel() {
        setEnabled(false)
    }

    // MARK: - Frames

    private func handle(_ handPoses: [HandPose]) {
        guard isRunning, !isPausedForLockOrSleep else { return }
        let now = CACurrentMediaTime()
        if teachingLabel != nil {
            takeTeachingExample(from: handPoses, at: now)
            return
        }
        if mode == .spell {
            handleSpelling(handPoses, at: now)
            return
        }
        let handPose = handPoses.first
        let sign = handPose.flatMap(HandSignClassifier.classify)
        if handIsVisible != (handPose != nil) { handIsVisible = handPose != nil }
        if seenSign != sign { seenSign = sign }
        let firedSign = holdTracker.observe(sign, at: now)
        let progress = holdTracker.holdProgress(at: now)
        if abs(progress - holdProgress) > 0.02 || (progress == 0) != (holdProgress == 0) { holdProgress = progress }
        if let firedSign { perform(firedSign) }
    }

    // MARK: - Spell to text

    private func handleSpelling(_ handPoses: [HandPose], at now: CFTimeInterval) {
        let reading = FingerspellingReader.read(hands: handPoses, alphabet: alphabet, taughtSigns: taughtSigns)
        if handIsVisible != !handPoses.isEmpty { handIsVisible = !handPoses.isEmpty }
        if seenSpellingLabel != reading?.label { seenSpellingLabel = reading?.label }
        let event = spellingSession.observe(label: reading?.label, handIsVisible: !handPoses.isEmpty, at: now)
        let progress = spellingSession.holdProgress(at: now)
        if abs(progress - holdProgress) > 0.02 || (progress == 0) != (holdProgress == 0) { holdProgress = progress }
        guard let event else { return }
        if event == .send {
            sendSpelledText()
        } else {
            spelledText.apply(event)
        }
    }

    /// The panel's buttons, and `handSigns {action: spell}`.
    func addSpaceToSpelledText() { spelledText.endWord() }
    func deleteLastSpelledLetter() { spelledText.deleteLast() }
    func clearSpelledText() { spelledText.clear() }
    func replaceSpelledText(with text: String) { spelledText = SpelledText(text: text) }

    /// Sends what's been spelled to the chosen place, and starts a new line.
    func sendSpelledText() {
        let text = spelledText.textToSend
        guard !text.isEmpty else {
            lastLine = "Nothing spelled yet."
            return
        }
        spelledText.clear()
        spellingSession.reset()
        var target = destination
        // Vello's chat needs the Vello product; without it the words go to Pointer Assistant.
        if target == .vello && !TheoProducts.isOn(.theo) { target = .pointerAssistant }
        switch target {
        case .vello:
            BotsStore.shared.send(SpelledTextMessage.forVello(text), command: text, to: "theo")
            lastLine = "To Vello: \(text)"
        case .pointerAssistant:
            companionManager?.sendTranscriptToClaudeWithScreenshot(transcript: text)
            lastLine = "To Pointer Assistant: \(text)"
        case .frontApp:
            lastLine = "Typing: \(text)"
            Task { [weak self] in
                let outcome = await DictationInserter.insert(text, into: .frontmost)
                self?.lastLine = outcome.didInsert ? "Typed: \(text)" : (outcome.message ?? "Couldn't type it.")
            }
        }
        recentSpelledTexts.append((text, target.rawValue, Date()))
        if recentSpelledTexts.count > 20 { recentSpelledTexts.removeFirst(recentSpelledTexts.count - 20) }
    }

    // MARK: - Teaching a sign

    /// Starts taking examples of a sign from the camera: hold it still and it's taken a few times over two seconds.
    func startTeaching(label: String) {
        let cleanedLabel = TaughtSignBook.cleanLabel(label)
        guard !cleanedLabel.isEmpty else {
            teachingLine = "Write the letter or word first."
            return
        }
        guard isRunning else {
            teachingLine = "Turn on Read hand signs first, so the camera can see the sign."
            return
        }
        teachingLabel = cleanedLabel
        teachingExamplesTaken = 0
        lastTeachingExampleAt = 0
        teachingLine = "Show \"\(cleanedLabel)\" to the camera and hold it."
    }

    func stopTeaching() {
        teachingLabel = nil
        teachingExamplesTaken = 0
    }

    func forgetTaughtSign(label: String) {
        taughtSigns.forget(label: label)
        Self.savedTaughtSigns = taughtSigns
    }

    private func takeTeachingExample(from handPoses: [HandPose], at now: CFTimeInterval) {
        guard let teachingLabel else { return }
        if handIsVisible != !handPoses.isEmpty { handIsVisible = !handPoses.isEmpty }
        guard !handPoses.isEmpty, now - lastTeachingExampleAt >= Self.secondsBetweenTeachingExamples else { return }
        guard taughtSigns.addExample(label: teachingLabel, hands: handPoses) else { return }
        lastTeachingExampleAt = now
        teachingExamplesTaken += 1
        let handWords = handPoses.count >= 2 ? "two hands" : "one hand"
        teachingLine = "\"\(teachingLabel)\" with \(handWords): \(teachingExamplesTaken) of \(TaughtSignBook.examplesWhenTeaching)"
        holdProgress = Double(teachingExamplesTaken) / Double(TaughtSignBook.examplesWhenTeaching)
        if teachingExamplesTaken >= TaughtSignBook.examplesWhenTeaching {
            Self.savedTaughtSigns = taughtSigns
            teachingLine = "Learned \"\(teachingLabel)\" (\(handWords)). Teach it again from another angle to make it surer."
            holdProgress = 0
            stopTeaching()
        }
    }

    // MARK: - Doing what a sign means

    /// A sign that counted (from the camera, or `handSigns {action: sign}`).
    func perform(_ sign: HandSign) {
        let action = HandSignActions.action(for: sign, mode: mode, phrases: Self.phrases)
        lastFiredSign = sign
        let line = run(action)
        if !line.isEmpty { lastLine = line }
        recentSigns.append((sign, line, Date()))
        if recentSigns.count > 20 { recentSigns.removeFirst(recentSigns.count - 20) }
    }

    /// Does it and returns the line the panel shows.
    private func run(_ action: HandSignAction) -> String {
        guard let companionManager else { return "" }
        switch action {
        case .nothing:
            return ""
        case .startListening:
            if companionManager.isHandsFreeSessionActive { return "Already listening. Talk to me." }
            companionManager.startHandsFreeSession()
            return action.panelLine
        case .stopEverything:
            companionManager.stopEverythingLikeEscape()
            return action.panelLine
        case .answer(let yes):
            if companionManager.actionTaskController.answerConfirmation(withWords: yes ? "yes" : "no") {
                return yes ? "Yes. Going ahead." : "No. Stopped that step."
            }
            return "Nothing is waiting for a yes or no."
        case .ask(let words):
            companionManager.sendTranscriptToClaudeWithScreenshot(transcript: words)
            return words
        case .speak(let words):
            Task { try? await companionManager.speechOutputClient.speakText(words) }
            return words
        }
    }

    // MARK: - Lock and sleep

    private func observeLockAndSleep() {
        guard systemObservers.isEmpty else { return }
        let distributedCenter = DistributedNotificationCenter.default()
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let pauses: [(NotificationCenter, Notification.Name)] = [
            (distributedCenter, Notification.Name("com.apple.screenIsLocked")),
            (workspaceCenter, NSWorkspace.screensDidSleepNotification)
        ]
        let resumes: [(NotificationCenter, Notification.Name)] = [
            (distributedCenter, Notification.Name("com.apple.screenIsUnlocked")),
            (workspaceCenter, NSWorkspace.screensDidWakeNotification)
        ]
        for (center, name) in pauses {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.pauseForLockOrSleep() }
            }
            systemObservers.append((center, observer))
        }
        for (center, name) in resumes {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resumeAfterLockOrSleep() }
            }
            systemObservers.append((center, observer))
        }
    }

    private func pauseForLockOrSleep() {
        guard isRunning, !isPausedForLockOrSleep else { return }
        isPausedForLockOrSleep = true
        camera.stop()
        holdTracker.reset()
    }

    private func resumeAfterLockOrSleep() {
        guard isRunning, isPausedForLockOrSleep else { return }
        isPausedForLockOrSleep = false
        try? camera.start()
    }

    // MARK: - Debug inbox

    func statusSnapshot() -> [String: Any] {
        let cameraAccess: String
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: cameraAccess = "authorized"
        case .denied: cameraAccess = "denied"
        case .restricted: cameraAccess = "restricted"
        case .notDetermined: cameraAccess = "notDetermined"
        @unknown default: cameraAccess = "unknown"
        }
        let dateFormatter = ISO8601DateFormatter()
        return [
            "enabled": Self.isEnabled,
            "running": isRunning,
            "pausedForLockOrSleep": isPausedForLockOrSleep,
            "cameraAccess": cameraAccess,
            "mode": mode.rawValue,
            "handVisible": handIsVisible,
            "seenSign": seenSign.map { $0.rawValue as Any } ?? NSNull(),
            "lastSign": lastFiredSign.map { $0.rawValue as Any } ?? NSNull(),
            "lastLine": lastLine,
            "problem": problem.map { $0 as Any } ?? NSNull(),
            "showsCameraPicture": showsCameraPicture,
            "spell": [
                "alphabet": alphabet.rawValue,
                "destination": destination.rawValue,
                "text": spelledText.text,
                "seen": seenSpellingLabel.map { $0 as Any } ?? NSNull(),
                "teaching": teachingLabel.map { $0 as Any } ?? NSNull(),
                "taught": taughtSigns.signs.map { ["label": $0.label, "hands": $0.handCount, "examples": $0.examples.count] as [String: Any] },
                "sent": recentSpelledTexts.map { ["text": $0.text, "to": $0.destination, "at": dateFormatter.string(from: $0.date)] }
            ] as [String: Any],
            "recent": recentSigns.map { ["sign": $0.sign.rawValue, "line": $0.line, "at": dateFormatter.string(from: $0.date)] }
        ]
    }
}
