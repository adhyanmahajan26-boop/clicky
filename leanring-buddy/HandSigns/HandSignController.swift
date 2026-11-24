//
//  HandSignController.swift
//  leanring-buddy
//
//  Hand signs: with Settings › Accessibility › Accessibility mode on, the camera watches for a hand
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
//  - Sign to text: signed words and finger-spelling on the move, read from the hands, body and face about 30
//    times a second (ClickyCore SignVisionReader) by ClickyCore's SignLiveReader (where a sign starts and ends,
//    features, the word and spelling models through SignScoringWorker, off the main thread). The words build a
//    line on the panel; Send (or the hands resting for a moment) passes it to Vello's chat, Pointer Assistant or
//    the app in front, like Spell to text. Models are found in the data folder's SignModels, then in the bundle
//    (SignToTextModels.swift); without them the mode still turns on and the panel says what's missing.
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
        static let signsLanguage = "v5.handSigns.signs.language"
        static let signsDestination = "v5.handSigns.signs.destination"
        static let signsAutoSendSeconds = "v5.handSigns.signs.autoSendSeconds"
    }

    /// Sign to text sends the line by itself once the hands have rested this long, unless the owner chose otherwise.
    static let defaultSignsAutoSendSeconds = 2.5

    static var savedSignLanguage: SignLanguage {
        get { UserDefaults.standard.string(forKey: Keys.signsLanguage).flatMap(SignLanguage.init(rawValue:)) ?? SignLanguage.defaultChoice(hasModels: SignModelFolders.hasModels(for:)) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Keys.signsLanguage) }
    }

    static var savedSignsDestination: SpelledTextDestination {
        get { UserDefaults.standard.string(forKey: Keys.signsDestination).flatMap(SpelledTextDestination.init(rawValue:)) ?? .vello }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Keys.signsDestination) }
    }

    /// 0 is off: the line waits for Send.
    static var savedSignsAutoSendSeconds: Double {
        get { (UserDefaults.standard.object(forKey: Keys.signsAutoSendSeconds) as? NSNumber)?.doubleValue ?? defaultSignsAutoSendSeconds }
        set { UserDefaults.standard.set(max(0, newValue), forKey: Keys.signsAutoSendSeconds) }
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
            if mode.needsPointerAssistant && !TheoProducts.isOn(.clicky) {
                problem = Self.pointerAssistantIsOffProblem
            } else if problem == Self.pointerAssistantIsOffProblem {
                problem = nil
            }
            holdTracker.reset()
            spellingSession.reset()
            seenSign = nil
            seenSpellingLabel = nil
            holdProgress = 0
            updateWhatTheCameraReads()
            prepareISLLetterModel()
            if mode == .signs {
                prepareSignReading()
            } else {
                resetSignReading()
            }
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
        didSet {
            Self.savedAlphabet = alphabet
            prepareISLLetterModel()
            updateWhatTheCameraReads()
        }
    }
    @Published var destination: SpelledTextDestination = HandSignController.savedDestination {
        didSet { Self.savedDestination = destination }
    }
    @Published private(set) var taughtSigns: TaughtSignBook = HandSignController.savedTaughtSigns
    /// While teaching: the sign being taught and how many examples were taken.
    @Published private(set) var teachingLabel: String?
    @Published private(set) var teachingExamplesTaken = 0
    @Published private(set) var teachingLine = ""

    // Sign to text.
    @Published var signLanguage: SignLanguage = HandSignController.savedSignLanguage {
        didSet {
            guard signLanguage != oldValue else { return }
            Self.savedSignLanguage = signLanguage
            // Another language is other models: a new reader, so a sign still being read in the old one is dropped.
            signModelsLoad = nil
            resetSignReading()
            if mode == .signs { prepareSignReading() }
        }
    }
    @Published var signsDestination: SpelledTextDestination = HandSignController.savedSignsDestination {
        didSet { Self.savedSignsDestination = signsDestination }
    }
    @Published var signsAutoSendSeconds: Double = HandSignController.savedSignsAutoSendSeconds {
        didSet {
            Self.savedSignsAutoSendSeconds = signsAutoSendSeconds
            signReader.setAutoSendSeconds(signsAutoSendSeconds)
        }
    }
    /// The line as it builds: words, spelled words and "?" for a sign that wasn't clear.
    @Published private(set) var signedEntries: [SignLiveLineEntry] = []
    /// A hand is up and a sign is being made right now.
    @Published private(set) var isMakingASign = false
    /// Signs that ended and are being read by the models.
    @Published private(set) var signReadingsInProgress = 0
    /// 0 to 1: how far through the wait before the line sends by itself.
    @Published private(set) var signsAutoSendProgress: Double = 0
    /// What the models are (or aren't), once loaded for the chosen language; nil while loading.
    @Published private(set) var signModelsLoad: SignModelLoadResult?
    @Published private(set) var isLoadingSignModels = false

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
    /// Sign to text's reading loop (no camera or Core ML in it) and the queue its models run on.
    private var signReader = HandSignController.makeSignReader(language: HandSignController.savedSignLanguage)
    private let signScoringWorker = SignScoringWorker()
    private var recentSignedLines: [(text: String, destination: String, date: Date)] = []
    /// The camera time stamps of the last frames, to tell how many frames a second Sign to text is getting.
    private var recentSignFrameTimes: [Double] = []
    private static let signFrameTimesKeptForTheRate = 60

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        camera.onHandPoses = { [weak self] handPoses in
            MainActor.assumeIsolated { self?.handle(handPoses) }
        }
        camera.onSignFrame = { [weak self] frame, frameTime, pictureWidth, pictureHeight in
            MainActor.assumeIsolated {
                self?.handleSignFrame(frame, at: frameTime, pictureWidth: pictureWidth, pictureHeight: pictureHeight)
            }
        }
        updateWhatTheCameraReads()
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
        guard !mode.needsPointerAssistant || TheoProducts.isOn(.clicky) else {
            problem = Self.pointerAssistantIsOffProblem
            return
        }
        // The test profile never opens the real camera; `handSigns {action: sign | signsFeed}` drives it instead.
        guard !TheoProfile.isTest else {
            problem = nil
            lastLine = Self.startingLine(for: mode)
            if mode == .signs { prepareSignReading() }
            prepareISLLetterModel()
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
        if mode == .signs { prepareSignReading() }
        prepareISLLetterModel()
        panelController.show()
    }

    static let pointerAssistantIsOffProblem = "Pointer Assistant is off. Turn it on in Settings › Products (Spell to text and Sign to text work without it)."

    private static func startingLine(for mode: HandSignMode) -> String {
        switch mode {
        case .control: return "Show an open palm to talk to me."
        case .speakForMe: return "Sign, and I'll say it."
        case .spell: return "Spell a word. Spread your open hand to send it."
        case .signs: return "Sign, then rest your hands. I'll write it down."
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
        resetSignReading()
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

    private func handleSpelling(_ handPoses: [HandPose], at now: CFTimeInterval, islModelLetter: FingerspellingReading? = nil) {
        let reading = FingerspellingReader.read(hands: handPoses, alphabet: alphabet, taughtSigns: taughtSigns, islModelLetter: islModelLetter)
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
        let target: SpelledTextDestination
        switch SpelledTextRouting.route(chosen: destination, velloIsOn: TheoProducts.isOn(.theo), pointerAssistantIsOn: TheoProducts.isOn(.clicky)) {
        case .send(let routedDestination):
            target = routedDestination
        case .refuse(let message):
            // Nothing is cleared: the spelled words stay for another place.
            lastLine = message
            return
        }
        spelledText.clear()
        spellingSession.reset()
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

    // MARK: - Sign to text

    private static func makeSignReader(language: SignLanguage) -> SignLiveReader {
        // The Mac camera's picture until the first frame says otherwise.
        SignLiveReader(language: language, pictureWidth: 640, pictureHeight: 480, autoSendSeconds: savedSignsAutoSendSeconds)
    }

    /// Loads the chosen language's models once (off the main thread). With none found the mode still runs: signs
    /// are seen, and the panel says what's missing.
    func prepareSignReading() {
        guard signModelsLoad?.language != signLanguage, !isLoadingSignModels else { return }
        isLoadingSignModels = true
        let languageBeingLoaded = signLanguage
        signScoringWorker.loadModels(
            language: languageBeingLoaded,
            searchFolders: SignModelFolders.searchFolders,
            compiledModelCacheFolder: SignModelFolders.compiledModelCacheFolder
        ) { [weak self] loadResult in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isLoadingSignModels = false
                guard loadResult.language == self.signLanguage else {
                    // The language changed while loading: load the one chosen now.
                    if self.mode == .signs { self.prepareSignReading() }
                    return
                }
                self.signModelsLoad = loadResult
                if loadResult.sentenceModelSummary != nil, self.mode == .signs, self.lastLine == Self.startingLine(for: .signs) {
                    self.lastLine = "Sign, one sign or several in a row, then rest your hands. I'll write it down."
                }
                // Said where it can be read in full; the camera chip only has room for a few words.
                if !loadResult.hasAnyModel, self.mode == .signs, let modelsProblem = self.signModelsProblem {
                    self.lastLine = modelsProblem
                }
            }
        }
    }

    /// The panel's words about the models: nil when both are ready.
    var signModelsProblem: String? {
        guard let signModelsLoad else { return isLoadingSignModels ? "Loading the sign models…" : nil }
        guard let problems = signModelsLoad.problems else { return nil }
        if !signModelsLoad.hasAnyModel {
            return signLanguage.notInThisBuildLine
        }
        return "Reads only part of \(signLanguage.rawValue.uppercased()): \(problems)."
    }

    /// A new, empty reader (another language, the camera off): anything still being read in the old one is dropped.
    private func resetSignReading() {
        signReader = Self.makeSignReader(language: signLanguage)
        recentSignFrameTimes = []
        publishSignState(at: nil)
    }

    private func handleSignFrame(_ frame: SignLandmarkFrame, at frameTime: Double, pictureWidth: Int, pictureHeight: Int) {
        guard isRunning, !isPausedForLockOrSleep else { return }
        if readsISLLettersWithTheModel {
            handleISLLetterFrame(frame, pictureWidth: pictureWidth, pictureHeight: pictureHeight, at: CACurrentMediaTime())
            return
        }
        guard mode == .signs else { return }
        let handIsInThePicture = SignFeatures.handIsSeen(in: frame, side: .right) || SignFeatures.handIsSeen(in: frame, side: .left)
        if handIsVisible != handIsInThePicture { handIsVisible = handIsInThePicture }
        recentSignFrameTimes.append(frameTime)
        if recentSignFrameTimes.count > Self.signFrameTimesKeptForTheRate {
            recentSignFrameTimes.removeFirst(recentSignFrameTimes.count - Self.signFrameTimesKeptForTheRate)
        }
        signReader.setPictureSize(width: Double(pictureWidth), height: Double(pictureHeight))
        observeSignFrame(frame, at: frameTime)
    }

    /// One frame into the reader, from the camera or `signsFeed`. A sign that ended goes to the models off the main
    /// thread; its words land on the line in order when they come back.
    private func observeSignFrame(_ frame: SignLandmarkFrame, at frameTime: Double) {
        let events = signReader.observe(frame, at: frameTime)
        for event in events {
            handleSignEvent(event)
        }
        publishSignState(at: frameTime)
    }

    private func handleSignEvent(_ event: SignLiveEvent) {
        switch event {
        case .signStarted:
            break
        case .tooShortToCount:
            break
        case .readingNeeded(let job):
            signScoringWorker.read(job, settings: signReader.readingSettings) { [weak self] outcome in
                MainActor.assumeIsolated { self?.finishSignReading(outcome) }
            }
        case .read(let entry):
            lastLine = entry.token == nil ? "I didn't catch that sign." : "Read: \(entry.displayText)"
        case .couldNotRead(let reason):
            lastLine = signModelsProblem ?? "Couldn't read that sign: \(reason)"
        case .timeToSend:
            sendSignedLine()
        }
    }

    private func finishSignReading(_ outcome: SignStretchOutcome) {
        for event in signReader.finishReading(outcome) {
            handleSignEvent(event)
        }
        publishSignState(at: signReader.lastFrameTime)
    }

    /// Copies what the panel shows out of the reader, writing only what changed (this runs 30 times a second).
    private func publishSignState(at frameTime: Double?) {
        if signedEntries != signReader.entries { signedEntries = signReader.entries }
        if isMakingASign != signReader.isSigning { isMakingASign = signReader.isSigning }
        if signReadingsInProgress != signReader.readingsInProgress { signReadingsInProgress = signReader.readingsInProgress }
        let progress = frameTime.map { signReader.autoSendProgress(at: $0) } ?? 0
        if abs(progress - signsAutoSendProgress) > 0.02 || (progress == 0) != (signsAutoSendProgress == 0) {
            signsAutoSendProgress = progress
        }
    }

    /// Frames a second the camera is giving Sign to text right now (0 before two frames came).
    var signFramesPerSecondSeen: Double {
        SignFrameRate.framesPerSecond(times: recentSignFrameTimes) ?? 0
    }

    /// The panel's buttons, and `handSigns`.
    func undoLastSign() {
        signReader.undoLast()
        publishSignState(at: signReader.lastFrameTime)
    }

    func clearSignedLine() {
        signReader.clear()
        publishSignState(at: signReader.lastFrameTime)
    }

    /// Sends the line to the chosen place and starts a new one. Vello and Pointer Assistant get the words with a note
    /// on how they were read (signing order, alternatives for unsure signs); the app in front gets the words only.
    func sendSignedLine() {
        // Decided before the line is taken, so words that can't go anywhere stay on the line.
        let target: SpelledTextDestination
        switch SpelledTextRouting.route(chosen: signsDestination, velloIsOn: TheoProducts.isOn(.theo), pointerAssistantIsOn: TheoProducts.isOn(.clicky)) {
        case .send(let routedDestination):
            target = routedDestination
        case .refuse(let message):
            lastLine = message
            return
        }
        guard let signedLine = signReader.takeLineForSending() else {
            lastLine = "Nothing signed yet."
            publishSignState(at: signReader.lastFrameTime)
            return
        }
        publishSignState(at: signReader.lastFrameTime)
        let plainText = signedLine.plainText
        let messageForBrain = signedLine.messageForBrain(language: signLanguage)
        switch target {
        case .vello:
            BotsStore.shared.send(messageForBrain, command: plainText, to: "theo")
            lastLine = "To Vello: \(plainText)"
        case .pointerAssistant:
            companionManager?.sendTranscriptToClaudeWithScreenshot(transcript: messageForBrain)
            lastLine = "To Pointer Assistant: \(plainText)"
        case .frontApp:
            lastLine = "Typing: \(plainText)"
            Task { [weak self] in
                let outcome = await DictationInserter.insert(plainText, into: .frontmost)
                self?.lastLine = outcome.didInsert ? "Typed: \(plainText)" : (outcome.message ?? "Couldn't type it.")
            }
        }
        recentSignedLines.append((plainText, target.rawValue, Date()))
        if recentSignedLines.count > 20 { recentSignedLines.removeFirst(recentSignedLines.count - 20) }
    }

    /// `handSigns {action: signsFeed, path}` (test profile only): a landmark `.npy` clip (at `framesPerSecond`,
    /// default 30, of a `pictureWidth × pictureHeight` picture, default unknown) or a video file, fed through the live
    /// reader as if from the camera, then a second of empty frames so its last sign ends. Answers once every sign
    /// in it has been read, with what was read.
    func feedSignClip(path: String, framesPerSecond: Double, pictureWidth: Double, pictureHeight: Double, completion: @escaping ([String: Any]?, String?) -> Void) {
        prepareSignReading()
        let fileURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let entriesBefore = signReader.entries.count
        if fileURL.pathExtension.lowercased() == "npy" {
            let frames: [SignLandmarkFrame]
            do {
                frames = try SignLandmarkClipFile.read(from: fileURL)
            } catch {
                completion(nil, "couldn't read \(fileURL.lastPathComponent): \(error)")
                return
            }
            let safeFramesPerSecond = framesPerSecond > 0 ? framesPerSecond : SignFrameRate.modelFramesPerSecond
            let timedFrames = frames.indices.map { frameIndex in (frames[frameIndex], Double(frameIndex) / safeFramesPerSecond) }
            feedTimedSignFrames(timedFrames, pictureWidth: pictureWidth, pictureHeight: pictureHeight, entriesBefore: entriesBefore, completion: completion)
            return
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let trackInfo = try await SignVideoLandmarks.loadTrackInfo(videoURL: fileURL)
                var timedFrames: [(SignLandmarkFrame, Double)] = []
                let visionReader = SignVisionReader(readsFace: SignVisionReader.cameraReadsFace)
                try SignVideoLandmarks.readFrames(trackInfo: trackInfo, visionReader: visionReader) { frame, frameTime in
                    timedFrames.append((frame, frameTime))
                }
                let framesToFeed = timedFrames
                let videoWidth = Double(trackInfo.uprightWidth)
                let videoHeight = Double(trackInfo.uprightHeight)
                await MainActor.run {
                    self?.feedTimedSignFrames(framesToFeed, pictureWidth: videoWidth, pictureHeight: videoHeight, entriesBefore: entriesBefore, completion: completion)
                }
            } catch {
                await MainActor.run { completion(nil, "couldn't read the video: \(error)") }
            }
        }
    }

    private func feedTimedSignFrames(
        _ timedFrames: [(SignLandmarkFrame, Double)],
        pictureWidth: Double,
        pictureHeight: Double,
        entriesBefore: Int,
        completion: @escaping ([String: Any]?, String?) -> Void
    ) {
        // Times carry on after the reader's last frame, so they keep rising as a camera's would.
        let firstFeedTime = (signReader.lastFrameTime ?? 0) + 1
        signReader.setPictureSize(width: pictureWidth, height: pictureHeight)
        var lastFeedTime = firstFeedTime
        for (frame, frameTime) in timedFrames {
            lastFeedTime = firstFeedTime + frameTime
            observeSignFrame(frame, at: lastFeedTime)
        }
        for restFrameNumber in 1...30 {
            observeSignFrame(SignLandmarkFrame(), at: lastFeedTime + Double(restFrameNumber) / 30)
        }
        // Wait for the models (they run on their own queue), at most a minute.
        Task { [weak self] in
            let waitStart = Date()
            while (self?.signReader.readingsInProgress ?? 0) > 0 && Date().timeIntervalSince(waitStart) < 60 {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard let self else { return }
            let newEntries = Array(self.signReader.entries.dropFirst(entriesBefore))
            completion([
                "framesFed": timedFrames.count,
                "read": newEntries.map { HandSignController.describe($0) },
                "line": self.signReader.line.plainText,
                "stillReading": self.signReader.readingsInProgress
            ], nil)
        }
    }

    /// One entry of the line for the debug inbox: what it shows, its kind and times, and what the models said.
    private static func describe(_ entry: SignLiveLineEntry) -> [String: Any] {
        var description: [String: Any] = [
            "text": entry.displayText,
            "kind": entry.kind.rawValue,
            "start": entry.startTime,
            "end": entry.endTime,
            "alternatives": entry.token?.alternativeTexts ?? [],
            "unclearGuesses": { () -> [[String: Any]] in
                guard case .unclear(guesses: let guesses)? = entry.token else { return [] }
                return guesses.map { ["label": $0.label, "probability": Double($0.probability)] as [String: Any] }
            }(),
            "wordGuesses": entry.wordGuesses.map { ["label": $0.label, "probability": Double($0.probability)] as [String: Any] }
        ]
        if let spelling = entry.spelling {
            description["spelling"] = ["text": spelling.text, "confidence": Double(spelling.confidence)] as [String: Any]
        }
        return description
    }

    /// `handSigns {action: signsState}` and the `signs` part of the state.
    func signsStatusSnapshot() -> [String: Any] {
        let dateFormatter = ISO8601DateFormatter()
        let signedLine = signReader.line
        var models: [String: Any] = [
            "loaded": signModelsLoad != nil,
            "folders": SignModelFolders.searchFolders.map { $0.path }
        ]
        if let signModelsLoad {
            models["wordModel"] = signModelsLoad.wordModelSummary.map { $0 as Any } ?? NSNull()
            models["spellingModel"] = signModelsLoad.spellingModelSummary.map { $0 as Any } ?? NSNull()
            // The sentence model reads a stretch of two or more signs; without it every stretch is one word.
            models["sentenceModel"] = signModelsLoad.sentenceModelSummary.map { $0 as Any } ?? NSNull()
            models["sentenceModelPath"] = signModelsLoad.found.sentenceModelURL.map { $0.path as Any } ?? NSNull()
            models["wordModelPath"] = signModelsLoad.found.wordModelURL.map { $0.path as Any } ?? NSNull()
            models["spellingModelPath"] = signModelsLoad.found.spellingModelURL.map { $0.path as Any } ?? NSNull()
            models["missing"] = signModelsLoad.problems.map { $0 as Any } ?? NSNull()
        }
        return [
            "language": signLanguage.rawValue,
            "destination": signsDestination.rawValue,
            "autoSendSeconds": signsAutoSendSeconds,
            "line": signedLine.plainText,
            "message": signedLine.isEmpty ? "" : signedLine.messageForBrain(language: signLanguage),
            "entries": signReader.entries.map { HandSignController.describe($0) },
            "signing": signReader.isSigning,
            "readingsInProgress": signReader.readingsInProgress,
            "autoSendProgress": signsAutoSendProgress,
            "framesPerSecondSeen": (signFramesPerSecondSeen * 10).rounded() / 10,
            "models": models,
            "modelsProblem": signModelsProblem.map { $0 as Any } ?? NSNull(),
            "sent": recentSignedLines.map { ["text": $0.text, "to": $0.destination, "at": dateFormatter.string(from: $0.date)] }
        ]
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
        // Sign to text reads with its models, not taught shapes, and its camera frames don't carry hand shapes.
        guard mode != .signs else {
            teachingLine = "Teaching is for Spell to text. Switch to it first."
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
        // A sign half made before the lock is not finished after it; the line itself is kept.
        signReader.forgetSignInProgress()
        publishSignState(at: nil)
    }

    private func resumeAfterLockOrSleep() {
        guard isRunning, isPausedForLockOrSleep else { return }
        isPausedForLockOrSleep = false
        try? camera.start()
    }

    // MARK: - Debug inbox

    // MARK: - ISL letters from the letter model (Spell to text)

    /// `SignSpellISL` (one frame in, a score per letter), when the models folder or the bundle has it.
    private var islLetterModel: SignModelRunner?
    /// "SignSpellISL, 26 letters"; nil without the model (then ISL in Spell to text reads taught signs only).
    @Published private(set) var islLetterModelSummary: String?
    private var isLoadingISLLetterModel = false

    /// Spell to text in ISL with the letter model: the camera then reads the 61 landmarks of every frame.
    private var readsISLLettersWithTheModel: Bool { mode == .spell && alphabet == .isl && islLetterModel != nil }

    private func updateWhatTheCameraReads() {
        camera.setReadsSignLanguage(mode == .signs || readsISLLettersWithTheModel)
    }

    /// Loads `SignSpellISL` off the main thread the first time Spell to text is in ISL. A model that reads more than one
    /// frame isn't a still-letter model and is left alone.
    func prepareISLLetterModel() {
        guard mode == .spell, alphabet == .isl, islLetterModel == nil, !isLoadingISLLetterModel else { return }
        isLoadingISLLetterModel = true
        let searchFolders = SignModelFolders.searchFolders
        let cacheFolder = SignModelFolders.compiledModelCacheFolder
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = SignModelFiles.find(in: searchFolders, language: .isl)
            let loadedModel = found.spellingModelURL.flatMap { try? SignModelRunner(modelURL: $0, compiledModelCacheFolder: cacheFolder) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isLoadingISLLetterModel = false
                    if let loadedModel, loadedModel.frameCount == 1 {
                        self.islLetterModel = loadedModel
                        self.islLetterModelSummary = "\(loadedModel.name), \(loadedModel.labels.count) letters"
                    }
                    self.updateWhatTheCameraReads()
                }
            }
        }
    }

    /// One camera frame in ISL Spell to text: the hands become hand poses (for delete, send and taught signs), the
    /// letter model reads the frame, and both go to the same spelling session as ASL's built-in shapes.
    private func handleISLLetterFrame(_ frame: SignLandmarkFrame, pictureWidth: Int, pictureHeight: Int, at now: CFTimeInterval) {
        let width = Double(pictureWidth), height = Double(pictureHeight)
        let handPoses = SignSide.allCases.compactMap { ISLLetterReading.handPose(in: frame, side: $0, pictureWidth: width, pictureHeight: height) }
        if teachingLabel != nil {
            takeTeachingExample(from: handPoses, at: now)
            return
        }
        handleSpelling(handPoses, at: now, islModelLetter: islLetterReading(of: frame, pictureWidth: width, pictureHeight: height))
    }

    private func islLetterReading(of frame: SignLandmarkFrame, pictureWidth: Double, pictureHeight: Double) -> FingerspellingReading? {
        guard let islLetterModel, SignFeatures.handIsSeen(in: frame, side: .right) || SignFeatures.handIsSeen(in: frame, side: .left) else { return nil }
        let fitted = SignFeatures.fitted(SignFeatures.featureClip(of: [frame], pictureWidth: pictureWidth, pictureHeight: pictureHeight), toFrameCount: 1)
        guard let scores = try? islLetterModel.scores(features: fitted.values, mask: fitted.mask).values else { return nil }
        // The model's own threshold (calibrated, in its .reading.json); 0.5 when it has none.
        return ISLLetterReading.reading(scores: scores, letters: islLetterModel.labels, leastProbability: islLetterModel.leastWordProbabilityOverride ?? 0.5)
    }

    /// `handSigns {action: spellFeed, path}` (test profile only): a landmark clip's first frame held to the "camera" for
    /// `seconds` at 30 frames a second, as ISL Spell to text with the letter model reads it. Answers the reading and
    /// the spelled text.
    func feedSpellingFrame(path: String, pictureWidth: Double, pictureHeight: Double, seconds: Double) -> ([String: Any]?, String?) {
        guard mode == .spell, alphabet == .isl else { return (nil, "set mode spell and alphabet isl first") }
        guard islLetterModel != nil else { return (nil, "no ISL letter model (SignSpellISL.mlpackage) loaded") }
        guard let frames = try? SignLandmarkClipFile.read(from: URL(fileURLWithPath: (path as NSString).expandingTildeInPath)),
              let frame = frames.first(where: { SignFeatures.handIsSeen(in: $0, side: .right) || SignFeatures.handIsSeen(in: $0, side: .left) }) ?? frames.first
        else { return (nil, "can't read \(path)") }
        let width = pictureWidth > 0 ? pictureWidth : 640, height = pictureHeight > 0 ? pictureHeight : 480
        let reading = islLetterReading(of: frame, pictureWidth: width, pictureHeight: height)
        let startTime = CACurrentMediaTime()
        let frameCount = max(1, Int(seconds * 30))
        for frameIndex in 0..<frameCount {
            handleISLLetterFrame(frame, pictureWidth: Int(width), pictureHeight: Int(height), at: startTime + Double(frameIndex) / 30)
        }
        // The hand leaves, so a letter held to the end counts as let go.
        handleSpelling([], at: startTime + Double(frameCount) / 30 + 0.05)
        return ([
            "modelLetter": reading.map { ["label": $0.label, "probability": 1 - $0.distance] as [String: Any] } ?? NSNull(),
            "spelledText": spelledText.text
        ], nil)
    }

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
            "signs": signsStatusSnapshot(),
            "spell": [
                "islLetterModel": islLetterModelSummary.map { $0 as Any } ?? NSNull(),
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
