//
//  ComposerDictation.swift
//  leanring-buddy
//
//  Dictating into a chat's composer: click the mic, or ⌥Space while the field is focused, or ⌘⇧D. Words stream in at the
//  cursor while the composer shows a live waveform and a timer; Stop keeps them, Cancel or Esc throws them away, and
//  a few seconds of silence stops it by itself. It never sends.
//
//  It runs on the same `DictationCapture` as system-wide dictation, with Apple's recognizer on this Mac for the live words.
//  When it stops, Sarvam (if its key is saved) and the clean-up get their say, exactly as they do for the chord. It holds
//  the mic claim on `AudioEngineHub` for as long as the mic is open, which is what makes the wake listener step aside.
//
//  It plays no sound and never asks for a permission: a missing one is a note in the composer with a way to Settings. The
//  test profile never opens the mic: `uiComposerDictation {action: feed}` sends a sound file down the same path.
//

import AppKit
import AVFoundation
import ClickyCore
import Combine
import Speech
import SwiftUI

enum ComposerDictationSettings {
    static let enabledKey = "v3.composerDictation.enabled"
    static let languageKey = "v3.composerDictation.language"
    static let autoStopKey = "v3.composerDictation.autoStop"
    static let silenceSecondsKey = "v3.composerDictation.silenceSeconds"
    static let shortcutKey = "v3.composerDictation.shortcut"

    @MainActor static var isEnabled: Bool { (UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true) && DeviceRoles.runsHere(.dictation) }
    static var autoStops: Bool { UserDefaults.standard.object(forKey: autoStopKey) as? Bool ?? true }
    static var silenceSeconds: Double {
        let saved = UserDefaults.standard.double(forKey: silenceSecondsKey)
        return saved > 0 ? saved : ComposerSilenceRule.defaultSeconds
    }
    static var shortcut: ComposerDictationShortcut {
        UserDefaults.standard.string(forKey: shortcutKey).flatMap(ComposerDictationShortcut.init(rawValue:)) ?? .optionSpace
    }
    /// "auto" follows this Mac's language.
    static var language: String { UserDefaults.standard.string(forKey: languageKey) ?? "auto" }
    static var currentLanguage: (id: String, title: String, sarvam: String, apple: String?) {
        DictationSettings.languages.first { $0.id == language } ?? DictationSettings.languages[0]
    }
}

/// What changes many times a second. Apart from the phase, so only the waveform and the text redraw for it.
@MainActor
final class ComposerDictationLive: ObservableObject {
    @Published fileprivate(set) var levels: [CGFloat] = Array(repeating: 0, count: ComposerDictationLive.barCount)
    @Published fileprivate(set) var seconds = 0
    @Published fileprivate(set) var draft = ComposerDictationDraft(text: "")
    static let barCount = 44
}

@MainActor
final class ComposerDictation: ObservableObject {
    static let shared = ComposerDictation()

    @Published private(set) var phase: ComposerDictationPhase = .idle
    /// The chat whose composer holds the dictation.
    @Published private(set) var ownerID: String?
    let live = ComposerDictationLive()

    /// One composer on screen: what dictation needs from it.
    struct Composer {
        let id: String
        let text: () -> String
        /// Puts the final text in the field, focused, with the cursor at this UTF-16 offset.
        let land: (String, Int) -> Void
    }

    private var machine = ComposerDictationMachine() { didSet { phase = machine.phase } }
    private var composers: [String: Composer] = [:]
    private var focusedID: String?
    private weak var anchor: NSView?
    private var capture: DictationCapture?
    private var silence = ComposerSilenceRule(seconds: nil, startedAt: 0)
    private var startedAt = Date()
    private var ticker: Task<Void, Never>?
    private var noteTimer: Task<Void, Never>?
    private var session = UUID()
    private var lastBarUpdate: TimeInterval = 0
    private var keyboard = ComposerDictationKeyboard()
    private var keyMonitor: Any?

    // For the test hook. Never the words outside it.
    private(set) var testLastLanded: (text: String, cursor: Int)?
    private(set) var testWordUpdates = 0
    private(set) var testPeakLevel: CGFloat = 0
    private(set) var testMicOpened = false
    var testPermissions: (microphone: ComposerDictationPermission?, speech: ComposerDictationPermission?) = (nil, nil)
    var testNoUsableMicrophone = false

    var isActive: Bool { machine.isActive }
    func isActive(for id: String) -> Bool { machine.isActive && ownerID == id }

    private init() {}

    // MARK: Composers

    func attach(_ composer: Composer) {
        composers[composer.id] = composer
        installKeysIfNeeded()
    }

    func noteAnchor(_ view: NSView) { anchor = view }

    func detach(_ id: String) {
        composers[id] = nil
        if focusedID == id { focusedID = nil }
        if ownerID == id {
            cancel()
            if case .problem = phase { machine.handle(.dismiss) }
            ownerID = nil
        }
    }

    func noteFocus(_ id: String, focused: Bool) {
        if focused { focusedID = id } else if focusedID == id { focusedID = nil }
    }

    // MARK: Start and stop

    /// The mic button.
    func toggle(_ id: String) {
        guard ComposerDictationSettings.isEnabled else { return }
        if isActive(for: id) { stop() } else if !isActive { start(id) }
    }

    func start(_ id: String) {
        guard ComposerDictationSettings.isEnabled, !machine.isActive, let composer = composers[id],
              let manager = CompanionManager.current else { return }
        noteTimer?.cancel()
        ownerID = id
        // No Sarvam key is fine: Apple's recognizer on this Mac does the listening.
        if manager.dictationController.isBlocked() || manager.dictationController.isCapturing {
            refuse(.busy)
            return
        }
        if let problem = ComposerDictationPermissions.problem(microphone: microphonePermission, speech: speechPermission, hasCloudEars: DictationSettings.usesSarvam) {
            refuse(problem)
            return
        }
        let capture = DictationCapture()
        capture.onLevel = { [weak self] level in self?.noteLevel(level) }
        capture.onWords = { [weak self] words in self?.noteWords(words) }
        let language = ComposerDictationSettings.currentLanguage
        let phrases = ["Theo", "Clicky", "Claude", "Sarvam"] + DictationSettings.dictionary.words
        let hasRecognizer = capture.startRecognizer(localeIdentifier: language.apple, phrases: phrases)
        guard hasRecognizer || DictationSettings.usesSarvam else {
            refuse(.noRecognizer)
            return
        }
        session = UUID()
        testLastLanded = nil
        testWordUpdates = 0
        testPeakLevel = 0
        testMicOpened = false
        let text = composer.text()
        live.draft = ComposerDictationDraft(text: text, selection: selection(in: text))
        live.levels = Array(repeating: 0, count: ComposerDictationLive.barCount)
        live.seconds = 0
        // The mic comes first: with none to open, Clicky's voice and the wake listener are left alone. The test profile
        // has no mic: its sound comes from `feed`.
        capture.pretendsNoUsableMicrophone = testNoUsableMicrophone
        if !TheoProfile.isTest || testNoUsableMicrophone {
            do {
                try capture.startMicrophone()
                testMicOpened = true
            } catch {
                capture.cancel()
                refuse(ComposerDictationProblem(micStartError: error))
                return
            }
        }
        startedAt = Date()
        silence = ComposerSilenceRule(seconds: ComposerDictationSettings.autoStops ? ComposerDictationSettings.silenceSeconds : nil,
                                      startedAt: startedAt.timeIntervalSinceReferenceDate)
        self.capture = capture
        // Claiming the mic is what pauses "hey Theo"; it comes back on release.
        manager.speechOutputClient.audioEngineHub.claimMicrophone(for: .dictation)
        // Clicky talking over the dictation would end up in it.
        manager.speechOutputClient.stopVoicesNow()
        machine.handle(.start)
        manager.dictationController.warmCleanerForComposer()
        startTicker()
    }

    /// Keeps the words. The mic shuts straight away, then the last ones come in.
    func stop() {
        guard let capture, machine.handle(.stop) else { return }
        self.capture = nil
        ticker?.cancel()
        let session = self.session
        Task { @MainActor [weak self] in
            await capture.finish()
            guard let self, let manager = CompanionManager.current else { return }
            manager.speechOutputClient.audioEngineHub.releaseMicrophone(for: .dictation)
            guard self.session == session else { return }
            let language = ComposerDictationSettings.currentLanguage
            let words = await manager.dictationController.composerWords(heard: self.live.draft.spoken, tape: capture.tape, language: language)
            guard self.session == session, self.machine.phase == .finishing else { return }
            guard !words.isEmpty else {
                self.restoreField()
                self.machine.handle(.failed(.nothingHeard))
                self.hideNoteSoon()
                return
            }
            self.live.draft.settle(words)
            let draft = self.live.draft
            self.testLastLanded = (draft.text, draft.cursorAfterWords)
            if let ownerID = self.ownerID { self.composers[ownerID]?.land(draft.text, draft.cursorAfterWords) }
            self.machine.handle(.wordsLanded)
            self.ownerID = nil
        }
    }

    /// Throws the words away. The field was never touched, so it still says what it said.
    func cancel() {
        guard machine.isActive else { return }
        session = UUID()
        ticker?.cancel()
        if let capture {
            capture.cancel()
            self.capture = nil
            CompanionManager.current?.speechOutputClient.audioEngineHub.releaseMicrophone(for: .dictation)
        }
        restoreField()
        machine.handle(.cancel)
        ownerID = nil
    }

    /// The field comes back as it was, focused, with the cursor where it started.
    private func restoreField() {
        guard let ownerID else { return }
        composers[ownerID]?.land(live.draft.original, live.draft.cursor)
    }

    func dismissNote() {
        noteTimer?.cancel()
        machine.handle(.dismiss)
        if !machine.isActive { ownerID = nil }
    }

    private func refuse(_ problem: ComposerDictationProblem) {
        machine.handle(.refused(problem))
        if problem.isBrief { hideNoteSoon() }
    }

    private func hideNoteSoon() {
        noteTimer?.cancel()
        noteTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.dismissNote()
        }
    }

    /// The note's link: System Settings if macOS has already asked, else Theo's own page, which can ask.
    func openPermissionSettings() {
        if case .problem(let problem) = phase, problem.opensKeySettings {
            BotsSelection.shared.openSettings(.dictation)
            return
        }
        guard case .problem(let problem) = phase, problem.needsPermission else { return }
        if problem.isUndecided {
            BotsSelection.shared.openSettings(.permissions)
            return
        }
        guard !TheoProfile.isTest else { return }
        let page = problem == .speechDenied ? "Privacy_SpeechRecognition" : "Privacy_Microphone"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(page)") { NSWorkspace.shared.open(url) }
    }

    // MARK: While listening

    private func noteLevel(_ level: CGFloat) {
        guard phase == .listening else { return }
        silence.note(level: Double(level), at: Date().timeIntervalSinceReferenceDate)
        testPeakLevel = max(testPeakLevel, level)
        // Lively moves at 20 frames a second and Calm at 8. Off leaves the bars still; the timer shows it's running.
        let motion = DS.Motion.level
        guard motion != .off else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastBarUpdate >= (motion == .lively ? 0.05 : 0.125) else { return }
        lastBarUpdate = now
        live.levels = Array(live.levels.dropFirst()) + [level]
    }

    private func noteWords(_ words: String) {
        guard phase == .listening else { return }
        let before = live.draft.spoken
        live.draft.hear(words)
        if live.draft.spoken != before {
            testWordUpdates += 1
            silence.noteWords(at: Date().timeIntervalSinceReferenceDate)
        }
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled, let self, self.phase == .listening else { return }
                let seconds = Int(Date().timeIntervalSince(self.startedAt))
                if seconds != self.live.seconds { self.live.seconds = seconds }
                if self.silence.shouldStop(at: Date().timeIntervalSinceReferenceDate) {
                    self.stop()
                    return
                }
            }
        }
    }

    // MARK: Permissions, read only

    private var microphonePermission: ComposerDictationPermission {
        if let forced = testPermissions.microphone { return forced }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .undecided
        default: return .denied
        }
    }

    private var speechPermission: ComposerDictationPermission {
        if let forced = testPermissions.speech { return forced }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .granted
        case .notDetermined: return .undecided
        default: return .denied
        }
    }

    // MARK: The cursor

    /// The field's selection, if the field is what has focus. The field editor is the one holding the same text.
    private func selection(in text: String) -> (location: Int, length: Int)? {
        guard let editor = anchor?.window?.firstResponder as? NSTextView, editor.string == text else { return nil }
        let range = editor.selectedRange()
        return (range.location, range.length)
    }

    /// Puts the field editor's cursor at this offset once the field is back.
    func placeCursor(_ offset: Int) {
        guard let editor = anchor?.window?.firstResponder as? NSTextView else { return }
        let length = (editor.string as NSString).length
        editor.setSelectedRange(NSRange(location: min(offset, length), length: 0))
    }

    // MARK: Keys

    private func installKeysIfNeeded() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    /// True when the key was ours.
    @discardableResult
    func handleKey(_ event: NSEvent) -> Bool {
        guard ComposerDictationSettings.isEnabled, let key = Self.key(of: event) else { return false }
        // Only in the window with the composer: not a sheet, the call window or anything else of Theo's.
        guard let window = anchor?.window, event.window === window, window.attachedSheet == nil else { return false }
        let target = ownerID ?? focusedID ?? composers.keys.first
        guard let target, composers[target] != nil else { return false }
        let action = keyboard.handle(key, phase: phase, composerFocused: focusedID != nil, shortcut: ComposerDictationSettings.shortcut,
                                     at: ProcessInfo.processInfo.systemUptime)
        switch action {
        case .pass: return false
        case .swallow: break
        case .start: start(target)
        case .keep: stop()
        case .cancel: cancel()
        case .dismiss: dismissNote()
        }
        return true
    }

    private static func key(of event: NSEvent) -> ComposerDictationKeyboard.Key? {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let spaceCode: UInt16 = 49, dCode: UInt16 = 2, escapeCode: UInt16 = 53, returnCode: UInt16 = 36, enterCode: UInt16 = 76
        if event.type == .keyUp { return event.keyCode == spaceCode ? .spaceUp : nil }
        guard event.type == .keyDown else { return nil }
        switch event.keyCode {
        case spaceCode where flags == .option: return event.isARepeat ? .optionSpaceRepeat : .optionSpace
        case dCode where flags == [.command, .shift]: return event.isARepeat ? nil : .commandShiftD
        case escapeCode where flags.isEmpty: return .escape
        case returnCode where flags.isEmpty, enterCode where flags.isEmpty: return .enter
        default: return nil
        }
    }

    // MARK: Test hook

    /// `uiComposerDictation {action: feed}`: a sound file down the same path as the mic, at the pace of speech.
    func feed(fileURL: URL, realTime: Bool, stopAtEnd: Bool) -> Bool {
        guard phase == .listening, let capture, let file = try? AVAudioFile(forReading: fileURL) else { return false }
        let session = self.session
        Task { @MainActor [weak self] in
            let blockFrames = AVAudioFrameCount(file.processingFormat.sampleRate * 0.05)
            while file.framePosition < file.length {
                guard self?.session == session, self?.phase == .listening,
                      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: blockFrames),
                      (try? file.read(into: buffer, frameCount: blockFrames)) != nil, buffer.frameLength > 0 else { return }
                capture.feed(buffer)
                if realTime { try? await Task.sleep(nanoseconds: 50_000_000) } else { await Task.yield() }
            }
            if stopAtEnd, self?.session == session { self?.stop() }
        }
        return true
    }

    func testReport() -> [String: Any] {
        var problem: Any = NSNull()
        if case .problem(let found) = phase { problem = found.message }
        return ["phase": String(describing: phase), "problem": problem, "owner": ownerID as Any? ?? NSNull(),
                "original": live.draft.original, "cursor": live.draft.cursor, "spoken": live.draft.spoken, "text": live.draft.text,
                "seconds": live.seconds, "wordUpdates": testWordUpdates, "peakLevel": testPeakLevel, "micOpened": testMicOpened,
                "landed": testLastLanded.map { ["text": $0.text, "cursor": $0.cursor] as [String: Any] } as Any? ?? NSNull(),
                "barsMoving": live.levels.contains { $0 > 0 },
                "micClaims": CompanionManager.current?.speechOutputClient.audioEngineHub.exclusiveMicrophoneUsers.map(\.rawValue) ?? [],
                "fieldCursor": (anchor?.window?.firstResponder as? NSTextView)?.selectedRange().location as Any? ?? NSNull(),
                "fieldText": (anchor?.window?.firstResponder as? NSTextView)?.string as Any? ?? NSNull(),
                "focused": focusedID as Any? ?? NSNull(), "isTestProfile": TheoProfile.isTest]
    }

    /// Runs a real key event through the same handling as the monitor.
    func testKey(_ name: String, isUp: Bool) -> Bool {
        let (code, flags, characters): (UInt16, NSEvent.ModifierFlags, String)
        switch name {
        case "optionSpace": (code, flags, characters) = (49, .option, " ")
        case "commandShiftD": (code, flags, characters) = (2, [.command, .shift], "d")
        case "escape": (code, flags, characters) = (53, [], "\u{1B}")
        case "return": (code, flags, characters) = (36, [], "\r")
        default: return false
        }
        guard let event = NSEvent.keyEvent(with: isUp ? .keyUp : .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: anchor?.window?.windowNumber ?? 0, context: nil, characters: characters,
                                           charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { return false }
        return handleKey(event)
    }

    func testMoveCursor(_ offset: Int) -> Bool {
        guard let editor = anchor?.window?.firstResponder as? NSTextView else { return false }
        editor.setSelectedRange(NSRange(location: offset, length: 0))
        return true
    }
}

// MARK: - Views

/// Finds the composer's window.
struct ComposerDictationAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> AnchorView { AnchorView() }
    func updateNSView(_ view: AnchorView, context: Context) {}

    final class AnchorView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { ComposerDictation.shared.noteAnchor(self) }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// The message field while dictating: what was typed, the words so far in the accent, and where they're going.
struct ComposerDictationField: View {
    @ObservedObject var live: ComposerDictationLive
    let isFinishing: Bool

    var body: some View {
        // As tall as the words, like the field it stands in for, up to about 8 lines; then it follows the newest.
        ComposerCappedHeight(cap: 136) {
            ScrollView(showsIndicators: false) {
                words.frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)
        }
        .padding(.horizontal, 4).padding(.top, 2).padding(.bottom, 2)
    }

    private var words: some View {
        let draft = live.draft
        let isEmpty = draft.text.isEmpty
        let caret = isFinishing ? Text("") : Text("|").foregroundColor(DS.Colors.accent)
        let typedBefore = Text(draft.leading).foregroundColor(DS.Colors.textPrimary)
        let spoken = Text(draft.spoken).foregroundColor(DS.Colors.accentText)
        let typedAfter = Text(draft.trailing).foregroundColor(DS.Colors.textPrimary)
        let hint = isEmpty && !isFinishing ? Text("Listening\u{2026}").foregroundColor(DS.Colors.textTertiary) : Text("")
        return (typedBefore + spoken + caret + hint + typedAfter).font(.system(size: 14)).textSelection(.disabled)
    }
}

/// Takes its content's height, up to a limit.
private struct ComposerCappedHeight: Layout {
    let cap: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let ideal = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? ideal.width, height: min(ideal.height, cap))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// The composer's bottom row while dictating: the lit mic, the waveform, the timer, Cancel and Stop.
struct ComposerDictationBar: View {
    @ObservedObject var live: ComposerDictationLive
    let isFinishing: Bool
    let onCancel: () -> Void
    let onKeep: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            HairlineIcon(name: "mic", size: 18, color: DS.Colors.textPrimary, selected: true)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(DS.Colors.accentSoft))
            if isFinishing {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 16, height: 16)
                Text("Finishing\u{2026}").font(.system(size: 12.5)).foregroundColor(DS.Colors.textSecondary)
                Spacer(minLength: 0)
            } else {
                ComposerWaveform(levels: live.levels).frame(height: 26).frame(maxWidth: .infinity)
                Text(ComposerDictationTimer.text(seconds: live.seconds))
                    .font(.system(size: 12, design: .monospaced)).foregroundColor(DS.Colors.textSecondary)
            }
            Button(action: onCancel) {
                HairlineIcon(name: "close", size: 16, color: DS.Colors.textSecondary)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(DS.Colors.surface))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(DS.Colors.borderStrong, lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Cancel: throw these words away (Esc)")
            Button(action: onKeep) {
                HairlineIcon(name: "check", size: 18, color: isFinishing ? DS.Colors.textTertiary : DS.Colors.textOnAccent)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isFinishing ? DS.Colors.surface : DS.Colors.accent))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(isFinishing).help("Stop and keep the words")
        }
    }
}

/// Accent bars from the real input level, newest on the right. Motion and Reduce Motion are handled where levels arrive.
struct ComposerWaveform: View {
    let levels: [CGFloat]

    var body: some View {
        Canvas { context, size in
            let count = CGFloat(levels.count)
            let step = size.width / max(count, 1)
            let width = min(2.5, step * 0.6)
            for (index, level) in levels.enumerated() {
                let height = max(2.5, level * size.height)
                let rect = CGRect(x: CGFloat(index) * step, y: (size.height - height) / 2, width: width, height: height)
                let age = 0.3 + 0.7 * Double(index) / Double(max(levels.count - 1, 1))
                context.fill(Path(roundedRect: rect, cornerRadius: width / 2), with: .color(DS.Colors.accent.opacity(age)))
            }
        }
        .accessibilityLabel("Input level")
    }
}

/// A missing permission or a short problem, inside the composer. Never a prompt.
struct ComposerDictationNote: View {
    let problem: ComposerDictationProblem
    let onOpenSettings: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            HairlineIcon(name: problem.needsPermission ? "lock" : problem.opensKeySettings ? "key" : "mic", size: 15, color: DS.Colors.textSecondary)
            Text(problem.message).font(.system(size: 12.5)).foregroundColor(DS.Colors.textSecondary).lineLimit(1)
            if problem.needsPermission || problem.opensKeySettings {
                Button(action: onOpenSettings) {
                    Text(problem.opensKeySettings ? "Add key" : "Open Settings").font(.system(size: 12.5, weight: .medium)).foregroundColor(DS.Colors.accentText).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                HairlineIcon(name: "close", size: 13, color: DS.Colors.textTertiary).frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Dismiss")
        }
        .padding(.leading, 9).padding(.trailing, 5).frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(DS.Colors.selected))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
    }
}
