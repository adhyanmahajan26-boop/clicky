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
        didSet { if mode != oldValue { Self.savedMode = mode; lastLine = mode.displayName } }
    }
    @Published var showsCameraPicture: Bool = HandSignController.showsCameraPicture {
        didSet { Self.showsCameraPicture = showsCameraPicture }
    }

    let camera = HandSignCamera()
    private weak var companionManager: CompanionManager?
    private var holdTracker = HandSignHoldTracker()
    private lazy var panelController = HandSignPanelController(controller: self)
    private var isPausedForLockOrSleep = false
    private var systemObservers: [(NotificationCenter, NSObjectProtocol)] = []
    /// The last few signs that counted, for `handSigns {action: state}`.
    private var recentSigns: [(sign: HandSign, line: String, date: Date)] = []

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        camera.onHandPose = { [weak self] handPose in
            MainActor.assumeIsolated { self?.handle(handPose) }
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
        lastLine = mode == .control ? "Show an open palm to talk to me." : "Sign, and I'll say it."
        panelController.show()
    }

    func turnOff() {
        camera.stop()
        isRunning = false
        holdTracker.reset()
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

    private func handle(_ handPose: HandPose?) {
        guard isRunning, !isPausedForLockOrSleep else { return }
        let now = CACurrentMediaTime()
        let sign = handPose.flatMap(HandSignClassifier.classify)
        if handIsVisible != (handPose != nil) { handIsVisible = handPose != nil }
        if seenSign != sign { seenSign = sign }
        let firedSign = holdTracker.observe(sign, at: now)
        let progress = holdTracker.holdProgress(at: now)
        if abs(progress - holdProgress) > 0.02 || (progress == 0) != (holdProgress == 0) { holdProgress = progress }
        if let firedSign { perform(firedSign) }
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
            "recent": recentSigns.map { ["sign": $0.sign.rawValue, "line": $0.line, "at": dateFormatter.string(from: $0.date)] }
        ]
    }
}
