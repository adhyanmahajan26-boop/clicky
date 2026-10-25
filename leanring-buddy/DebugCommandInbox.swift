//
//  DebugCommandInbox.swift
//  leanring-buddy
//
//  Debug builds only. Lets tools (Tools/clickyctl.sh, the grounding eval)
//  drive the running app without touching the keyboard or mic: drop
//  `<id>.json` into ~/.clicky/debug-inbox and the reply appears as
//  `<id>.json` in ~/.clicky/debug-outbox. Only a fixed set of commands is
//  understood (no shell, no arbitrary code):
//
//    ping                     → exe, sha, pid, ax, screen, voiceEngine, handsFree
//    ask {text, speak=true}   → runs the full answer pipeline; replies at turn end
//    marks {tags}             → fresh capture, parse/map/draw the tags (legacy parser)
//    say {text}, stop, clear, reset, handsfree {on}, selftest {name}
//    wakeStatus               → wake word: armed, paused reason, restarts, wakes, false wakes,
//                               last wake latency, CPU % over the last minute (Clicky and the
//                               on-device speech service)
//    perfStatus               → idle-CPU guard: overlay/notch body evaluations, cursor-loop
//                               ticks and state writes per second (last 5 s), loop mode
//    wakeFeed {path}          → a WAV/CAF through the wake recognizer + matcher at real-time pace
//                               (no mic, no speaker): detections with times and latency
//    snap {target, marks}     → the [SNAP:…] path: target screen|window|marks, marks=true keeps
//                               Clicky's overlay in the shot; replies with the saved path
//    codeTask {task | json}   → runs a CodeTask through the CodeModeController
//                               (the review panel still needs a real click)
//    codeState                → Code mode's preflight, phase, review and recent events
//    codeStatus               → the current code task, its live progress (step, files
//                               changed, elapsed), the queue and the panel mode
//    codeToggle {on, transcript} → as if Claude said [CODEMODE:on|off] for that transcript
//    projectSend {transcript, speak=true} → the "send this to my project …" trigger + outbox
//                               write, as for a spoken transcript: {sent, id, path} or {sent:false, reason}
//    projectStatus            → the Agents dashboard's project tasks (phase, note, link) and the bridge's settings
//    voiceGallery             → the voice gallery's entries (number, id, engine, pitch, files, enabled) and the active one
//    voiceSelect {index | id} → chooses a gallery voice exactly like "Use this voice", without speaking
//    (codeTask also takes {frontWindow: {bundle, title, document, terminalCwd}} to stand
//     in for the front window when task.repo is "this")
//    board {path}             → a .jsonl board or a raw answer file, drawn and narrated as if Claude said it
//    boardCtl {action}        → next | back | replay | pause | export | close | state
//    axfind {bundle, role, title, nth, …} → frameCG [x,y,w,h] of another app's
//                               element from a plain AX walk (eval ground truth;
//                               see AXFindWalker for every field)
//    actionsStatus            → P7: the current action task (goal, steps with outcomes,
//                               tier decisions, pending confirm, phase) and the last one
//    actionsCancel {reason?}  → ends the current action task
//    actionsRun {steps, goal?, done=true, transcript?, dryRun=true}
//                             → a step list as if Claude sent it, on a fresh capture;
//                               dryRun returns every step's tier decision and facts
//                               without running anything
//    articleRead {scroll=false}  → P8: reads the front browser's article now (AX, or with
//                               scroll: true also the scroll + OCR fallback): {length, title,
//                               url, source AX|OCR, runs, milliseconds, preview}
//    notesStatus              → P8: notes panel visible, items, linked highlights (lines,
//                               method, source), dock side/frame, saved paths
//    notesSave                → P8: "save my notes" without speaking: {line, savedPaths}
//    axSetPosition {bundle, windowIndex|windowTitle, x, y [, w, h], dryRun?}
//                             → TEST ONLY: AXPosition/AXSize of a TextEdit or Notes
//                               window (CG top-left coords); dryRun lists the windows
//    axPerform {bundle, role, title, action: press|delete}
//                             → TEST ONLY: AXPress the first exact (role, title) in that
//                               app's front window, or Notes' Edit ▸ Delete; never types
//                               (both: TextEdit / Notes only; Safari and Clicky refused)
//
//  Replies are `{ok, result, error, turnDir}` written to `<id>.json.tmp` then
//  renamed, so a reader never sees a half-written file.
//

#if DEBUG

import AppKit
import ApplicationServices
import ClickyCore
import Foundation

@MainActor
final class DebugCommandInbox {
    private let companionManager: CompanionManager
    private let inboxDirectoryURL: URL
    private let outboxDirectoryURL: URL
    private var inboxDirectoryWatcher: DispatchSourceFileSystemObject?
    private var handledCommandIdentifiers: Set<String> = []

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        let clickyDirectoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".clicky", isDirectory: true)
        inboxDirectoryURL = clickyDirectoryURL.appendingPathComponent("debug-inbox", isDirectory: true)
        outboxDirectoryURL = clickyDirectoryURL.appendingPathComponent("debug-outbox", isDirectory: true)
    }

    func start() {
        for directoryURL in [inboxDirectoryURL, outboxDirectoryURL] {
            try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        }

        let inboxFileDescriptor = open(inboxDirectoryURL.path, O_EVTONLY)
        guard inboxFileDescriptor >= 0 else {
            print("⚠️ DebugCommandInbox: couldn't watch \(inboxDirectoryURL.path)")
            return
        }
        let inboxDirectoryWatcher = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: inboxFileDescriptor,
            eventMask: [.write, .rename],
            queue: .main
        )
        inboxDirectoryWatcher.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.scanInbox()
            }
        }
        inboxDirectoryWatcher.setCancelHandler {
            close(inboxFileDescriptor)
        }
        inboxDirectoryWatcher.resume()
        self.inboxDirectoryWatcher = inboxDirectoryWatcher

        // Commands written before the app launched are answered too.
        scanInbox()
        print("🧪 DebugCommandInbox: watching \(inboxDirectoryURL.path)")
    }

    // MARK: - Inbox

    /// Picks up every `<id>.json` (never `.tmp` files still being written),
    /// handles each id once, and deletes the request.
    private func scanInbox() {
        guard let inboxFileNames = try? FileManager.default.contentsOfDirectory(atPath: inboxDirectoryURL.path) else { return }

        for inboxFileName in inboxFileNames {
            guard inboxFileName.range(of: #"^[A-Za-z0-9_-]+\.json$"#, options: .regularExpression) != nil else { continue }
            let commandIdentifier = String(inboxFileName.dropLast(".json".count))
            guard !handledCommandIdentifiers.contains(commandIdentifier) else { continue }
            handledCommandIdentifiers.insert(commandIdentifier)

            let requestFileURL = inboxDirectoryURL.appendingPathComponent(inboxFileName)
            let requestData = try? Data(contentsOf: requestFileURL)
            try? FileManager.default.removeItem(at: requestFileURL)

            guard let requestData,
                  let commandObject = try? JSONSerialization.jsonObject(with: requestData) as? [String: Any],
                  let commandName = commandObject["cmd"] as? String else {
                reply(commandIdentifier: commandIdentifier, isSuccess: false, result: nil, errorMessage: "invalid request: expected a JSON object with \"cmd\"")
                continue
            }

            handleCommand(commandName: commandName, commandObject: commandObject, commandIdentifier: commandIdentifier)
        }
    }

    private func reply(commandIdentifier: String, isSuccess: Bool, result: Any?, errorMessage: String?, turnDirectoryURL: URL? = nil) {
        var replyObject: [String: Any] = ["ok": isSuccess]
        replyObject["result"] = result ?? NSNull()
        replyObject["error"] = errorMessage ?? NSNull()
        replyObject["turnDir"] = turnDirectoryURL?.path ?? NSNull()

        guard JSONSerialization.isValidJSONObject(replyObject),
              let replyData = try? JSONSerialization.data(withJSONObject: replyObject, options: [.sortedKeys]) else {
            print("⚠️ DebugCommandInbox: reply for \(commandIdentifier) isn't valid JSON")
            return
        }
        let temporaryReplyURL = outboxDirectoryURL.appendingPathComponent("\(commandIdentifier).json.tmp")
        let finalReplyURL = outboxDirectoryURL.appendingPathComponent("\(commandIdentifier).json")
        do {
            try replyData.write(to: temporaryReplyURL)
            try? FileManager.default.removeItem(at: finalReplyURL)
            try FileManager.default.moveItem(at: temporaryReplyURL, to: finalReplyURL)
        } catch {
            print("⚠️ DebugCommandInbox: couldn't write reply \(commandIdentifier): \(error)")
        }
    }

    // MARK: - Commands

    private func handleCommand(commandName: String, commandObject: [String: Any], commandIdentifier: String) {
        switch commandName {
        case "ping":
            reply(commandIdentifier: commandIdentifier, isSuccess: true, result: pingResult(), errorMessage: nil)

        case "ask":
            guard let questionText = commandObject["text"] as? String, !questionText.isEmpty else {
                reply(commandIdentifier: commandIdentifier, isSuccess: false, result: nil, errorMessage: "ask needs \"text\"")
                return
            }
            let speaksResponse = commandObject["speak"] as? Bool ?? true
            // prewarmMs simulates holding the hotkey that long before key-up.
            if let prewarmMilliseconds = commandObject["prewarmMs"] as? Int, prewarmMilliseconds > 0 {
                companionManager.groundingCoordinator.prewarm()
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(prewarmMilliseconds) * 1_000_000)
                    self.startAsk(questionText: questionText, speaksResponse: speaksResponse, commandIdentifier: commandIdentifier)
                }
            } else {
                startAsk(questionText: questionText, speaksResponse: speaksResponse, commandIdentifier: commandIdentifier)
            }

        case "marks":
            guard let tagText = commandObject["tags"] as? String else {
                reply(commandIdentifier: commandIdentifier, isSuccess: false, result: nil, errorMessage: "marks needs \"tags\"")
                return
            }
            Task {
                do {
                    let markResult = try await self.presentTagsOnFreshCapture(tagText: tagText, transcript: "debug marks")
                    self.reply(commandIdentifier: commandIdentifier, isSuccess: true, result: markResult.tags, errorMessage: nil, turnDirectoryURL: markResult.turnDirectoryURL)
                } catch {
                    self.reply(commandIdentifier: commandIdentifier, isSuccess: false, result: nil, errorMessage: String(describing: error))
                }
            }

        case "markState":
            // Where each live mark is right now (tracking checks).
            let markObjects: [[String: Any]] = companionManager.markController.marks.map { mark in
                ["rectCG": [mark.rectCG.minX, mark.rectCG.minY, mark.rectCG.width, mark.rectCG.height],
                 "hidden": mark.isHidden, "opacity": mark.opacity, "source": mark.source.rawValue,
                 "tracked": mark.ax != nil, "label": mark.originalLabel ?? NSNull()]
            }
            reply(commandIdentifier: commandIdentifier, isSuccess: true, result: markObjects, errorMessage: nil)

        case "snap":
            guard let targetName = commandObject["target"] as? String, let snapshotTarget = SnapshotTarget(rawValue: targetName),
                  snapshotTarget != .board else {
                reply(commandIdentifier: commandIdentifier, isSuccess: false, result: nil, errorMessage: "snap needs \"target\": screen, window or marks (a board is saved with boardCtl export)")
                return
            }
            let includesClickyOverlay = commandObject["marks"] as? Bool ?? false
            let snapshotRequest = SnapshotRequest(target: snapshotTarget, includesClickyOverlay: includesClickyOverlay)
            let markRectsCG = companionManager.markController.marks.map(\.rectCG)
            let turnRecordForSnap = TurnLogger.beginTurn(transcript: "debug snap \(targetName)\(includesClickyOverlay ? "+marks" : "")", keyUpDate: Date())
            Task {
                do {
                    let snapshotResult = try await SnapshotCapture.capture(request: snapshotRequest, markRectsCG: markRectsCG)
                    turnRecordForSnap?.recordSnapshot(snapshotResult)
                    if let turnRecordForSnap { TurnLogger.finishTurn(turnRecordForSnap) }
                    let snapResult: [String: Any] = [
                        "path": snapshotResult.fileURL.path,
                        "target": snapshotResult.target.rawValue,
                        "includesClickyOverlay": snapshotResult.includesClickyOverlay,
                        "width": snapshotResult.pixelWidth,
                        "height": snapshotResult.pixelHeight,
                    ]
                    self.reply(commandIdentifier: commandIdentifier, isSuccess: true, result: snapResult, errorMessage: nil, turnDirectoryURL: turnRecordForSnap?.turnDirectoryURL)
                } catch {
                    self.reply(commandIdentifier: commandIdentifier, isSuccess: false, result: nil, errorMessage: error.localizedDescription)
                }
            }

        case "bargeIn":
            // Barge-in exactly as a trigger would (escape | pushToTalk | voiceCommand).
            let trigger = SpeechCoordinator.BargeInTrigger(rawValue: commandObject["trigger"] as? String ?? "") ?? .voiceCommand
            let wasSpeaking = companionManager.speechOutputClient.activeCoordinator?.isSpeaking ?? false
            if trigger == .escape { companionManager.handleEscapeKeyPressedForDebug() } else { companionManager.speechOutputClient.activeCoordinator?.bargeIn(trigger) }
            reply(commandIdentifier: commandIdentifier, isSuccess: true, result: ["wasSpeaking": wasSpeaking], errorMessage: nil)

        case "heard":
            // Words the open mic heard while Clicky talks (EchoGuard decides).
            let heardText = commandObject["text"] as? String ?? ""
            let accepted = companionManager.speechOutputClient.activeCoordinator?.heardWhileSpeaking(heardText) ?? false
            reply(commandIdentifier: commandIdentifier, isSuccess: true, result: ["bargedIn": accepted], errorMessage: nil)

        case "speechState":
            let caption = companionManager.captionState
            reply(commandIdentifier: commandIdentifier, isSuccess: true, result: [
                "isPlaying": companionManager.speechOutputClient.isPlaying,
                "isSpeaking": companionManager.speechOutputClient.activeCoordinator?.isSpeaking ?? false,
                "captionVisible": caption.isVisible,
                "captionFrozen": caption.isFrozen,
                "captionCurrent": caption.current?.display ?? NSNull(),
                "captionRevealed": caption.revealedDisplayCharacters,
                "captionLegend": caption.markLegend.map { "\($0.number) \($0.text)" },
                "lastHistory": companionManager.lastHistoryEntryForDebug ?? NSNull()
            ], errorMessage: nil)

        case "ttsToFile":
            // The app's real Qwen request (model, reference clip, lexicon) → WAV files; no playback.
            let texts = commandObject["texts"] as? [String] ?? []
            let directoryPath = ((commandObject["dir"] as? String) ?? "~/Library/Logs/Clicky/tts-check") as NSString
            let directoryURL = URL(fileURLWithPath: directoryPath.expandingTildeInPath, isDirectory: true)
            Task {
                try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                let client = self.companionManager.speechOutputClient.qwenLocalVoiceClient
                var written: [[String: Any]] = []
                for (index, text) in texts.enumerated() {
                    let start = Date()
                    do {
                        let audioData = try await client.synthesizeSpeech(for: text)
                        let fileURL = directoryURL.appendingPathComponent("app-\(index + 1).wav")
                        try audioData.write(to: fileURL)
                        written.append(["path": fileURL.path, "ms": (Date().timeIntervalSince(start) * 1000).rounded()])
                    } catch {
                        written.append(["error": String(describing: error)])
                    }
                }
                self.reply(commandIdentifier: commandIdentifier, isSuccess: true, result: [
                    "model": client.modelIdentifier, "usesReferenceClip": client.referenceClipBase64 != nil, "files": written
                ], errorMessage: nil)
            }

        case "say":
            let sayText = commandObject["text"] as? String ?? ""
            Task {
                do {
                    try await self.companionManager.speechOutputClient.speakText(sayText)
                    self.reply(
                        commandIdentifier: commandIdentifier,
                        isSuccess: true,
                        result: ["engine": self.companionManager.speechOutputClient.lastSpeechEngineName ?? "none"],
                        errorMessage: nil
                    )
                } catch {
                    self.reply(commandIdentifier: commandIdentifier, isSuccess: false, result: nil, errorMessage: String(describing: error))
                }
            }

        case "stop":
            companionManager.stopBuddySpeechAndCancelResponse()
            companionManager.endHandsFreeSession()
            reply(commandIdentifier: commandIdentifier, isSuccess: true, result: nil, errorMessage: nil)

        case "reset":
            companionManager.resetConversation()
            reply(commandIdentifier: commandIdentifier, isSuccess: true, result: nil, errorMessage: nil)

        case "clear":
            companionManager.clearLiveScreenMarks()
            companionManager.clearDetectedElementLocation()
            reply(commandIdentifier: commandIdentifier, isSuccess: true, result: nil, errorMessage: nil)

        case "handsfree":
            let shouldBeOn = commandObject["on"] as? Bool ?? false
            if shouldBeOn {
                companionManager.startHandsFreeSession()
            } else {
                companionManager.endHandsFreeSession()
            }
            reply(commandIdentifier: commandIdentifier, isSuccess: true, result: ["handsFree": companionManager.isHandsFreeSessionActive], errorMessage: nil)

        case "perfStatus":
            // Idle-CPU guard: per-second rates over the last 5 s of overlay /
            // notch body evaluations, cursor-loop ticks and state writes, plus
            // the cursor loop's mode. Pointer still + nothing animating should
            // read ~10 ticks/s (idle poll) and ~0 for everything else.
            var perfResult = OverlayPerfMonitor.shared.snapshot()
            let cursorLoopStatus = CursorFollowDriver.shared.statusSnapshot()
            perfResult["cursorLoop"] = cursorLoopStatus
            perfResult["frameLoopRunning"] = CursorFollowDriver.shared.isRunning && CursorFollowDriver.shared.mode == .fast
            reply(commandIdentifier: commandIdentifier, isSuccess: true, result: perfResult, errorMessage: nil)

        case "wakeStatus":
            reply(commandIdentifier: commandIdentifier, isSuccess: true, result: companionManager.wakeWordController.statusSnapshot(), errorMessage: nil)

        case "wakeFeed":
            // A WAV/CAF through the wake recognizer + matcher at real-time pace (no mic, no speaker).
            guard let filePath = commandObject["path"] as? String, !filePath.isEmpty else {
                reply(commandIdentifier: commandIdentifier, isSuccess: false, result: nil, errorMessage: "wakeFeed needs \"path\"")
                return
            }
            let fileURL = URL(fileURLWithPath: (filePath as NSString).expandingTildeInPath)
            Task {
                let (isSuccess, result, errorMessage) = await companionManager.wakeWordController.feedFile(at: fileURL)
                reply(commandIdentifier: commandIdentifier, isSuccess: isSuccess, result: result, errorMessage: errorMessage)
            }

        case "selftest":
            let selfTestName = commandObject["name"] as? String ?? ""
            let selfTestMode = commandObject["mode"] as? String
            Task {
                let (isPassing, selfTestResult) = await self.runSelfTest(named: selfTestName, mode: selfTestMode)
                self.reply(commandIdentifier: commandIdentifier, isSuccess: isPassing, result: selfTestResult, errorMessage: isPassing ? nil : "selftest \(selfTestName) failed")
            }

        case "codeTask":
            let blockBody: String?
            if let taskObject = commandObject["task"], JSONSerialization.isValidJSONObject(taskObject),
               let taskData = try? JSONSerialization.data(withJSONObject: taskObject) {
                blockBody = String(decoding: taskData, as: UTF8.self)
            } else {
                blockBody = commandObject["json"] as? String
            }
            guard let blockBody, let codeTask = try? CodeTask.decode(blockBody: blockBody) else {
                reply(commandIdentifier: commandIdentifier, isSuccess: false, result: nil, errorMessage: "codeTask needs a valid \"task\" object or \"json\" string")
                return
            }
            var codeContext = CodeTurnContext(transcript: commandObject["transcript"] as? String ?? "debug codeTask")
            if let frontWindowObject = commandObject["frontWindow"] as? [String: Any] {
                codeContext.frontWindow = FrontWindowContext(bundleIdentifier: frontWindowObject["bundle"] as? String, windowTitle: frontWindowObject["title"] as? String,
                                                             documentURL: frontWindowObject["document"] as? String,
                                                             terminalWorkingDirectory: frontWindowObject["terminalCwd"] as? String)
            }
            companionManager.codeModeController.start(codeTask, context: codeContext)
            reply(commandIdentifier: commandIdentifier, isSuccess: true, result: ["started": companionManager.codeModeController.isBusy,
                                                                                  "action": codeTask.action.rawValue], errorMessage: nil)

        case "codeState":
            reply(commandIdentifier: commandIdentifier, isSuccess: true, result: companionManager.codeModeController.stateSnapshot(), errorMessage: nil)

        case "codeStatus":
            reply(commandIdentifier: commandIdentifier, isSuccess: true, result: companionManager.codeModeController.statusSnapshot(), errorMessage: nil)

        case "agentsStatus":
            // The Agents dashboard's store as saved (running + history), plus usage totals. Opens nothing.
            let agentsStore = companionManager.agentsCenter.store
            let storeObject = (try? agentsStore.encoded()).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? NSNull()
            let usageTotals = agentsStore.usageTotals()
            reply(commandIdentifier: commandIdentifier, isSuccess: true, result: [
                "store": storeObject,
                "running": agentsStore.runningRecords.map(\.id),
                "windowVisible": companionManager.agentsWindowController.isVisible,
                "totals": ["agents": usageTotals.agentCount, "tokens": usageTotals.usage.totalTokens, "costUSD": usageTotals.usage.costUSD ?? NSNull()] as [String: Any]
            ], errorMessage: nil)

        case "codeToggle":
            guard let isOn = commandObject["on"] as? Bool else {
                reply(commandIdentifier: commandIdentifier, isSuccess: false, result: nil, errorMessage: "codeToggle needs \"on\" (true/false)")
                return
            }
            let transcript = commandObject["transcript"] as? String ?? (isOn ? "turn on code mode" : "turn off code mode")
            let decision = companionManager.codeModeController.handleSpokenToggle(isOn: isOn, transcript: transcript)
            reply(commandIdentifier: commandIdentifier, isSuccess: true, result: ["decision": String(describing: decision),
                                                                                  "enabled": companionManager.codeModeController.isEnabled], errorMessage: nil)
        case "projectSend":
            guard let transcript = commandObject["transcript"] as? String else {
                reply(commandIdentifier: commandIdentifier, isSuccess: false, result: nil, errorMessage: "projectSend needs \"transcript\"")
                return
            }
            let speaksResponse = commandObject["speak"] as? Bool ?? true
            let outcome = companionManager.projectBridge.handleSpokenTranscript(transcript, speaks: speaksResponse)
            let result: [String: Any]
            switch outcome {
            case .sent(let taskID, let path): result = ["sent": true, "id": taskID, "path": path]
            case .notTriggered: result = ["sent": false, "reason": "no trigger phrase in the transcript"]
            case .disabled: result = ["sent": false, "reason": "v2.project.enabled is off"]
            case .askedForTask: result = ["sent": false, "reason": "no task after the trigger phrase (asked what to send)"]
            case .namedProject: result = ["sent": false, "namedProject": true, "reason": "a named other project (or its offer / pick answer): see projectStatus.namedProject"]
            case .failed(let reason): result = ["sent": false, "reason": reason]
            }
            reply(commandIdentifier: commandIdentifier, isSuccess: true, result: result, errorMessage: nil)

        case "projectStatus":
            reply(commandIdentifier: commandIdentifier, isSuccess: true, result: companionManager.projectBridge.statusSnapshot(), errorMessage: nil)

        case "voiceGallery":
            reply(commandIdentifier: commandIdentifier, isSuccess: true, result: companionManager.voiceGalleryController.debugSnapshot(), errorMessage: nil)

        case "voiceSelect":
            // {index: N} (1-based, as the gallery shows it) or {id: "voice3" | "apple:<identifier>"}. Never speaks.
            let requestedNumber = (commandObject["index"] as? Int) ?? (commandObject["index"] as? String).flatMap(Int.init)
            let requestedEntryID = commandObject["id"] as? String
            guard requestedNumber != nil || requestedEntryID != nil else {
                reply(commandIdentifier: commandIdentifier, isSuccess: false, result: nil, errorMessage: "voiceSelect needs \"index\" or \"id\"")
                return
            }
            let (chosenEntry, failureReason) = companionManager.voiceGalleryController.debugSelect(number: requestedNumber, entryID: requestedEntryID)
            var result = companionManager.voiceGalleryController.debugSnapshot()
            result["selected"] = failureReason == nil ? (chosenEntry?.id ?? NSNull()) : NSNull()
            reply(commandIdentifier: commandIdentifier, isSuccess: failureReason == nil, result: result, errorMessage: failureReason)

        case "codeCloseReview":
            // Test only: the review panel's Close (nothing outward; worktree and branch stay).
            reply(commandIdentifier: commandIdentifier, isSuccess: true,
                  result: ["closed": companionManager.codeModeController.closeReviewForTest()], errorMessage: nil)

        case "markRegion":
            // Test-only: drop marks outside this CG rect ({"rectCG": [x, y, w, h]}) or allow all again ({"clear": true}).
            if commandObject["clear"] as? Bool == true {
                MarkController.debugAllowedRegionCG = nil
            } else if let values = commandObject["rectCG"] as? [Double], values.count == 4 {
                MarkController.debugAllowedRegionCG = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
            } else {
                reply(commandIdentifier: commandIdentifier, isSuccess: false, result: nil, errorMessage: "markRegion needs \"rectCG\" [x,y,w,h] or \"clear\"")
                return
            }
            reply(commandIdentifier: commandIdentifier, isSuccess: true,
                  result: ["rectCG": MarkController.debugAllowedRegionCG.map { [$0.minX, $0.minY, $0.width, $0.height] as Any } ?? NSNull()], errorMessage: nil)

        case "boardDisplay":
            // Test-only: open boards on this display ({"displayID": n}) or back to the mouse's ({"clear": true}).
            if commandObject["clear"] as? Bool == true {
                WhiteboardPanel.debugForcedDisplayID = nil
            } else if let displayID = commandObject["displayID"] as? Int {
                WhiteboardPanel.debugForcedDisplayID = CGDirectDisplayID(displayID)
            } else {
                reply(commandIdentifier: commandIdentifier, isSuccess: false, result: nil, errorMessage: "boardDisplay needs \"displayID\" or \"clear\"")
                return
            }
            reply(commandIdentifier: commandIdentifier, isSuccess: true,
                  result: ["displayID": WhiteboardPanel.debugForcedDisplayID.map { Int($0) as Any } ?? NSNull()], errorMessage: nil)

        case "board":
            guard let path = commandObject["path"] as? String, !path.isEmpty else {
                reply(commandIdentifier: commandIdentifier, isSuccess: false, result: nil, errorMessage: "board needs \"path\"")
                return
            }
            let fileURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard let answerText = try? String(contentsOf: fileURL, encoding: .utf8) else {
                reply(commandIdentifier: commandIdentifier, isSuccess: false, result: nil, errorMessage: "can't read \(fileURL.path)")
                return
            }
            Task {
                let turnDirectoryURL = await self.companionManager.playDebugAnswer(answerText, speaks: commandObject["speak"] as? Bool ?? true)
                self.reply(commandIdentifier: commandIdentifier, isSuccess: self.companionManager.boardController.hasBoard,
                           result: self.companionManager.boardController.stateSummary(),
                           errorMessage: self.companionManager.boardController.hasBoard ? nil : "no board was drawn",
                           turnDirectoryURL: turnDirectoryURL)
            }

        case "boardCtl":
            let action = commandObject["action"] as? String ?? "state"
            let boardController = companionManager.boardController
            var result = boardController.stateSummary()
            switch action {
            case "next": boardController.next()
            case "back": boardController.back()
            case "replay": boardController.replay()
            case "pause": boardController.togglePause()
            case "export": result["exported"] = boardController.exportBoard()?.path ?? NSNull()
            case "close": boardController.close()
            case "state": break
            default:
                reply(commandIdentifier: commandIdentifier, isSuccess: false, result: nil,
                      errorMessage: "unknown boardCtl action \(action); known: next, back, replay, pause, export, close, state")
                return
            }
            if action != "state" && action != "export" { result = boardController.stateSummary() }
            reply(commandIdentifier: commandIdentifier, isSuccess: true, result: result, errorMessage: nil)

        case "axfind":
            // Eval ground truth: a plain AX walk of another app, independent of
            // the grounding registry. Read-only (no actions, no focus changes).
            switch AXFindWalker.find(commandObject) {
            case .success(let findResult):
                reply(commandIdentifier: commandIdentifier, isSuccess: true, result: findResult, errorMessage: nil)
            case .failure(let findError):
                reply(commandIdentifier: commandIdentifier, isSuccess: false, result: findError.details, errorMessage: findError.message)
            }

        case "actionsStatus":
            // P7: the current action task (steps, tier decisions, pending confirm), the last one, settings.
            reply(commandIdentifier: commandIdentifier, isSuccess: true, result: companionManager.actionTaskController.statusSnapshot(), errorMessage: nil)

        case "actionsCancel":
            let wasActive = companionManager.actionTaskController.isActive
            companionManager.actionTaskController.cancel(reason: commandObject["reason"] as? String ?? "cancelled by the debug inbox", stopsSpeech: false, speaksLine: false)
            reply(commandIdentifier: commandIdentifier, isSuccess: true, result: ["cancelled": wasActive], errorMessage: nil)

        case "actionsRun":
            // {steps:[…], goal?, done?, transcript?, dryRun=true}: dryRun resolves + classifies only.
            guard let steps = commandObject["steps"] as? [Any] else {
                reply(commandIdentifier: commandIdentifier, isSuccess: false, result: nil, errorMessage: "actionsRun needs \"steps\"")
                return
            }
            var planObject: [String: Any] = ["steps": steps, "done": commandObject["done"] as? Bool ?? true]
            if let goal = commandObject["goal"] as? String { planObject["goal"] = goal }
            let isDryRun = commandObject["dryRun"] as? Bool ?? true
            let ownerTranscript = commandObject["transcript"] as? String ?? "debug actionsRun"
            Task {
                let (isSuccess, result) = await self.companionManager.actionTaskController.debugRun(planObject: planObject, ownerTranscript: ownerTranscript, isDryRun: isDryRun)
                self.reply(commandIdentifier: commandIdentifier, isSuccess: isSuccess, result: result, errorMessage: isSuccess ? nil : result["error"] as? String)
            }

        case "articleRead":
            // P8: read the article in the front browser now (no scrolling unless {scroll: true}).
            guard let articleWindow = ArticleReader.findArticleWindow() else {
                reply(commandIdentifier: commandIdentifier, isSuccess: false, result: nil, errorMessage: "no browser window is on screen")
                return
            }
            let allowsScrolling = commandObject["scroll"] as? Bool ?? false
            Task {
                _ = await self.companionManager.articleController.readArticle(target: articleWindow, scroll: allowsScrolling ? { point, pixels in
                    SyntheticEvents.mouseEvent(.mouseMoved, at: point)?.post(tap: .cghidEventTap)
                    ArticleHighlightController.postScroll(at: point, pixels: pixels)
                } : nil, isCancelled: { false })
                self.reply(commandIdentifier: commandIdentifier, isSuccess: true, result: self.companionManager.articleController.articleReadSnapshot(), errorMessage: nil)
            }

        case "notesStatus":
            reply(commandIdentifier: commandIdentifier, isSuccess: true, result: companionManager.articleController.notesStatusSnapshot(), errorMessage: nil)

        case "notesSave":
            let line = companionManager.articleController.saveNotesAndDescribe()
            let status = companionManager.articleController.notesStatusSnapshot()
            reply(commandIdentifier: commandIdentifier, isSuccess: status["saveError"] is NSNull && companionManager.articleController.hasNotes,
                  result: ["line": line, "savedPaths": status["savedPaths"] ?? []], errorMessage: nil)

        case "axSetPosition":
            // TEST ONLY (P7 harness): move/resize a TextEdit or Notes window. Nothing else, ever.
            switch ActionsDebugAXCommand.parseSetPosition(commandObject, ownBundleIdentifier: Bundle.main.bundleIdentifier) {
            case .failure(let error):
                reply(commandIdentifier: commandIdentifier, isSuccess: false, result: nil, errorMessage: error.message)
            case .success(let request):
                let (isSuccess, result, errorMessage) = DebugAXTestCommands.setPosition(request)
                reply(commandIdentifier: commandIdentifier, isSuccess: isSuccess, result: result, errorMessage: errorMessage)
            }

        case "axPerform":
            // TEST ONLY (P7 harness): AXPress one (role, title) in TextEdit / Notes, or Notes' Edit ▸ Delete. Never types.
            switch ActionsDebugAXCommand.parsePerform(commandObject, ownBundleIdentifier: Bundle.main.bundleIdentifier) {
            case .failure(let error):
                reply(commandIdentifier: commandIdentifier, isSuccess: false, result: nil, errorMessage: error.message)
            case .success(let request):
                let (isSuccess, result, errorMessage) = DebugAXTestCommands.perform(request)
                reply(commandIdentifier: commandIdentifier, isSuccess: isSuccess, result: result, errorMessage: errorMessage)
            }

        default:
            reply(commandIdentifier: commandIdentifier, isSuccess: false, result: nil, errorMessage: "unknown cmd \(commandName)")
        }
    }

    private func startAsk(questionText: String, speaksResponse: Bool, commandIdentifier: String) {
        companionManager.sendTranscriptToClaudeWithScreenshot(
            transcript: questionText,
            turnOptions: CompanionManager.TurnOptions(
                speaksResponse: speaksResponse,
                keyUpDate: Date(),
                onTurnFinished: { [weak self] turnDirectoryURL, turnError in
                    self?.reply(
                        commandIdentifier: commandIdentifier,
                        isSuccess: turnError == nil,
                        result: ["speak": speaksResponse],
                        errorMessage: turnError.map { String(describing: $0) },
                        turnDirectoryURL: turnDirectoryURL
                    )
                }
            )
        )
    }

    private func pingResult() -> [String: Any] {
        [
            "exe": Bundle.main.executablePath ?? "",
            "sha": TurnLogger.buildGitSHA,
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "ax": AXIsProcessTrusted(),
            "screen": CGPreflightScreenCaptureAccess(),
            "voiceEngine": companionManager.speechOutputClient.currentEngineName,
            "handsFree": companionManager.isHandsFreeSessionActive,
            "wake": companionManager.wakeWordController.state.displayText
        ]
    }

    /// Captures the screens, runs `tagText` through the same legacy
    /// parse → map → draw path as a real answer, and logs it as a turn.
    /// Fresh grounded capture (lists, registry), then the tags go through the
    /// v2 parser, resolver and verifier exactly like an answer's.
    private func presentTagsOnFreshCapture(tagText: String, transcript: String) async throws -> (tags: [[String: Any]], turnDirectoryURL: URL?, screenCaptures: [ScreenCapture]) {
        let turnRecord = TurnLogger.beginTurn(transcript: transcript, keyUpDate: Date())
        var groundedTurn = try await companionManager.groundingCoordinator.prepareTurn(keyUpDate: Date())
        let screenCaptures = groundedTurn.screenCaptures
        turnRecord?.markTiming("captureDone")
        turnRecord?.recordScreens(screenCaptures)
        turnRecord?.recordElementLists(groundedTurn.elementListTexts)
        turnRecord?.grounding = TurnRecord.GroundingEntry(
            isWarm: groundedTurn.isWarm, keyUpToReadyMs: groundedTurn.keyUpToReadyMilliseconds, prewarmReadyBeforeKeyUp: nil,
            registryCount: groundedTurn.registry.orderedIDs.count, badgedCount: 0, isBadged: groundedTurn.isBadged,
            droppedAXApplications: groundedTurn.droppedAXApplications, axWalks: companionManager.groundingCoordinator.lastAXWalkStats
        )
        turnRecord?.rawResponse = tagText
        await groundedTurn.ensureOCRLines()
        await companionManager.presentGroundedTags(responseText: tagText, groundedTurn: &groundedTurn, turnRecord: turnRecord)

        let loggedTags: [[String: Any]] = (turnRecord?.tags ?? []).map { tagEntry in
            var tagObject: [String: Any] = ["raw": tagEntry.raw, "screen": tagEntry.screen, "modelPx": tagEntry.modelPx,
                                            "appKitPoint": tagEntry.appKitPoint, "cgPoint": tagEntry.cgPoint]
            tagObject["box"] = tagEntry.box ?? NSNull()
            tagObject["method"] = tagEntry.method ?? NSNull()
            tagObject["confidence"] = tagEntry.confidence ?? NSNull()
            tagObject["elementID"] = tagEntry.elementID ?? NSNull()
            tagObject["verified"] = tagEntry.verified ?? NSNull()
            tagObject["occludedByPID"] = tagEntry.occludedByPID.map { Int($0) } ?? NSNull()
            return tagObject
        }
        if let turnRecord {
            TurnLogger.finishTurn(turnRecord)
        }
        return (loggedTags, turnRecord?.turnDirectoryURL, screenCaptures)
    }

    // MARK: - Self-tests

    private func runSelfTest(named selfTestName: String, mode: String?) async -> (Bool, [String: Any]) {
        switch selfTestName {
        case "legacyCenter":
            return await runLegacyCenterSelfTest()
        case "fixtureAX":
            return runFixtureAccessibilitySelfTest()
        case "fixtureAXWalkDebug":
            // Walks the fixture with the same AXQuerying calls the enumerator uses.
            guard let groundTruth = GroundingSelfTests.readFixtureGroundTruth() else { return (false, ["error": "no fixture"]) }
            let ax = companionManager.groundingCoordinator.ax
            var lines: [String] = []
            func walk(_ node: AXNodeReference, depth: Int) {
                guard depth < 14, lines.count < 200 else { return }
                let nodeAttributes = ax.attributes(of: node)
                let role = nodeAttributes?.role ?? "nil"
                let frame = nodeAttributes?.frameCG
                if let frame, frame.minX > 700, frame.minY > 240, frame.minY < 480 || role == "AXWindow" {
                    lines.append(String(repeating: " ", count: depth) + "\(role) \(nodeAttributes?.title ?? "") \(frame)")
                }
                let children = ax.children(of: node, role: nodeAttributes?.role, limit: 400)
                if role.contains("Web") || role == "AXScrollArea" || (role == "AXGroup" && (frame?.minX ?? 0) > 700) {
                    let axElement = node.underlyingObject as! AXUIElement
                    var rangedValues: CFArray?
                    let rangedError = AXUIElementCopyAttributeValues(axElement, kAXChildrenAttribute as CFString, 0, 400, &rangedValues)
                    var plainValue: CFTypeRef?
                    let plainError = AXUIElementCopyAttributeValue(axElement, kAXChildrenAttribute as CFString, &plainValue)
                    var countValue: CFIndex = -1
                    let countError = AXUIElementGetAttributeValueCount(axElement, kAXChildrenAttribute as CFString, &countValue)
                    lines.append(String(repeating: " ", count: depth) + "  -> \(children.count) children of \(role); ranged \(rangedError.rawValue) \((rangedValues as? [AnyObject])?.count ?? -1), plain \(plainError.rawValue) \((plainValue as? [AnyObject])?.count ?? -1), count \(countError.rawValue) \(countValue)")
                }
                for child in children { walk(child, depth: depth + 1) }
            }
            let applicationNode = ax.applicationNode(processIdentifier: groundTruth.processIdentifier)
            for window in ax.windows(of: applicationNode) { walk(window, depth: 0) }
            return (true, ["lines": lines])
        case "fixtureAXDump":
            // Diagnostics: every AX node of the fixture with role and frame.
            guard let groundTruth = GroundingSelfTests.readFixtureGroundTruth() else { return (false, ["error": "no fixture"]) }
            let snapshots = FixtureAccessibilityWalker.collectElements(processIdentifier: groundTruth.processIdentifier)
            return (true, ["count": snapshots.count, "nodes": snapshots.filter { $0.frameCG.minX > 700 && $0.frameCG.minY < 520 }.prefix(60).map {
                "\($0.role) t=\($0.title) d=\($0.elementDescription) v=\($0.value.prefix(20)) f=\($0.frameCG)"
            }])
        case "fixtureResolve", "verifyHitTest", "groundingLatency":
            return await GroundingSelfTests.run(named: selfTestName, mode: mode, companionManager: companionManager)
        case "calibration", "overlayExclusion", "transportProbe", "tierProbe":
            return await DiagnosticSelfTests.run(named: selfTestName, companionManager: companionManager)
        case "recheckExclusion", "markRoundTrip":
            return await MarkSelfTests.run(named: selfTestName, companionManager: companionManager)
        case "qwenCaptionSync":
            return await SpeechSelfTests.runQwenCaptionSync(companionManager: companionManager)
        default:
            return (false, ["error": "unknown selftest \(selfTestName); known: legacyCenter, fixtureAX, calibration, overlayExclusion, transportProbe, tierProbe, fixtureResolve, verifyHitTest, groundingLatency, recheckExclusion, markRoundTrip, qwenCaptionSync"])
        }
    }

    /// On each screen, a POINT at the centre pixel of the model image must
    /// land within 2 pt of the display's centre (measured in CG).
    private func runLegacyCenterSelfTest() async -> (Bool, [String: Any]) {
        let maximumAllowedErrorInPoints = 2.0
        var perScreenResults: [[String: Any]] = []
        var isPassing = true

        do {
            let screenCaptures = try await ScreenCaptureService.captureAllScreens()
            for screenCapture in screenCaptures {
                let modelSize = screenCapture.frame.modelSize
                let tagText = "[POINT:\(modelSize.width / 2),\(modelSize.height / 2):c:screen\(screenCapture.screenNumber)]"

                let markResult = try await presentTagsOnFreshCapture(tagText: tagText, transcript: "selftest legacyCenter screen \(screenCapture.screenNumber)")
                // A fresh capture can reorder screens if the cursor moved; use
                // the capture the tag was actually mapped with.
                guard let pointTag = markResult.tags.first,
                      let landedCGPoint = pointTag["cgPoint"] as? [Double],
                      let mappedScreenNumber = pointTag["screen"] as? Int,
                      let mappedCapture = markResult.screenCaptures.first(where: { $0.screenNumber == mappedScreenNumber }) else {
                    perScreenResults.append(["screen": screenCapture.screenNumber, "error": "no point landed"])
                    isPassing = false
                    continue
                }
                let displayBoundsCG = mappedCapture.frame.display.boundsCG
                let distanceFromCenter = hypot(landedCGPoint[0] - displayBoundsCG.midX, landedCGPoint[1] - displayBoundsCG.midY)
                if distanceFromCenter > maximumAllowedErrorInPoints { isPassing = false }
                perScreenResults.append([
                    "screen": mappedScreenNumber,
                    "displayID": Int(mappedCapture.displayID),
                    "image": mappedCapture.frame.modelSize.description,
                    "native": mappedCapture.frame.native.description,
                    "errorPt": Double((distanceFromCenter * 100).rounded() / 100)
                ])
            }
        } catch {
            return (false, ["error": String(describing: error)])
        }

        companionManager.clearDetectedElementLocation()
        return (isPassing, ["maxAllowedPt": maximumAllowedErrorInPoints, "screens": perScreenResults])
    }

    /// The fixture's accessibility frames must match its own ground truth
    /// within 1 pt, which proves both sides use the same CG coordinates.
    private func runFixtureAccessibilitySelfTest() -> (Bool, [String: Any]) {
        let groundTruthURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".clicky/fixture/groundtruth.json")
        guard let groundTruthData = try? Data(contentsOf: groundTruthURL),
              let groundTruth = try? JSONSerialization.jsonObject(with: groundTruthData) as? [String: Any],
              groundTruth["ready"] as? Bool == true,
              let fixtureProcessIdentifier = groundTruth["pid"] as? Int,
              let groundTruthItems = groundTruth["items"] as? [[String: Any]] else {
            return (false, ["error": "no ready fixture groundtruth at \(groundTruthURL.path)"])
        }
        guard AXIsProcessTrusted() else {
            return (false, ["error": "Clicky isn't trusted for Accessibility"])
        }

        let accessibilityElements = FixtureAccessibilityWalker.collectElements(processIdentifier: pid_t(fixtureProcessIdentifier))
        var itemResults: [[String: Any]] = []
        var maximumErrorInPoints = 0.0
        var unmatchedKeys: [String] = []

        for groundTruthItem in groundTruthItems {
            guard groundTruthItem["kind"] as? String == "ax",
                  groundTruthItem["visible"] as? Bool ?? true,
                  let itemKey = groundTruthItem["key"] as? String,
                  let frameValues = groundTruthItem["frameCG"] as? [Double], frameValues.count == 4 else { continue }
            let groundTruthFrame = CGRect(x: frameValues[0], y: frameValues[1], width: frameValues[2], height: frameValues[3])

            guard let matchedFrame = FixtureAccessibilityWalker.frame(forFixtureKey: itemKey, in: accessibilityElements) else {
                unmatchedKeys.append(itemKey)
                continue
            }
            let itemError = [
                abs(matchedFrame.minX - groundTruthFrame.minX), abs(matchedFrame.minY - groundTruthFrame.minY),
                abs(matchedFrame.width - groundTruthFrame.width), abs(matchedFrame.height - groundTruthFrame.height)
            ].max() ?? 0
            maximumErrorInPoints = max(maximumErrorInPoints, itemError)
            itemResults.append([
                "key": itemKey,
                "errorPt": Double((itemError * 100).rounded() / 100),
                "axFrame": [matchedFrame.minX, matchedFrame.minY, matchedFrame.width, matchedFrame.height],
                "groundTruthFrame": frameValues
            ])
        }

        let isPassing = !itemResults.isEmpty && unmatchedKeys.isEmpty && maximumErrorInPoints <= 1.0
        return (isPassing, [
            "checked": itemResults.count,
            "accessibilityElementsFound": accessibilityElements.count,
            "maxErrorPt": (maximumErrorInPoints * 100).rounded() / 100,
            "unmatched": unmatchedKeys,
            "worst": itemResults.sorted { ($0["errorPt"] as? Double ?? 0) > ($1["errorPt"] as? Double ?? 0) }.prefix(5).map { $0 },
            "overOnePoint": itemResults.filter { ($0["errorPt"] as? Double ?? 0) > 1.0 },
            "elementSample": itemResults.isEmpty
                ? accessibilityElements.prefix(25).map { "\($0.role) t=\($0.title) d=\($0.elementDescription) v=\($0.value.prefix(30)) f=\($0.frameCG)" }
                : []
        ])
    }
}

/// Reads the grounding fixture's accessibility tree so fixtureAX can compare
/// it with the fixture's own ground truth.
@MainActor
enum FixtureAccessibilityWalker {
    struct ElementSnapshot {
        let role: String
        let title: String
        let elementDescription: String
        let value: String
        let placeholder: String
        let frameCG: CGRect
        let childTexts: [String]
    }

    static func collectElements(processIdentifier: pid_t) -> [ElementSnapshot] {
        var collectedElements: [ElementSnapshot] = []
        walk(AXUIElementCreateApplication(processIdentifier), depth: 0, into: &collectedElements)
        return collectedElements
    }

    private static func walk(_ element: AXUIElement, depth: Int, into collectedElements: inout [ElementSnapshot]) {
        guard depth < 20 else { return }
        let children = arrayAttribute(element, kAXChildrenAttribute)
        if let frameCG = frame(of: element) {
            collectedElements.append(ElementSnapshot(
                role: stringAttribute(element, kAXRoleAttribute),
                title: stringAttribute(element, kAXTitleAttribute),
                elementDescription: stringAttribute(element, kAXDescriptionAttribute),
                value: stringAttribute(element, kAXValueAttribute),
                placeholder: stringAttribute(element, kAXPlaceholderValueAttribute),
                frameCG: frameCG,
                childTexts: descendantTexts(of: element, depth: 0)
            ))
        }
        for child in children {
            walk(child, depth: depth + 1, into: &collectedElements)
        }
    }

    /// Fixture keys → how the element shows up in the accessibility tree.
    static func frame(forFixtureKey fixtureKey: String, in elements: [ElementSnapshot]) -> CGRect? {
        let buttonTitlesByKey = [
            "back": "Back", "share": "Share", "export_pdf": "Export as PDF…", "build_settings": "Build Settings",
            "run": "Run", "archive": "Archive"
        ]
        let iconDescriptionsByKey = [
            "icon_gear": "Gear", "icon_trash": "Trash", "icon_star": "Star",
            "icon_bell": "Bell", "icon_lock": "Lock", "icon_info": "Info"
        ]
        let buttons = elements.filter { $0.role == kAXButtonRole as String }

        if let buttonTitle = buttonTitlesByKey[fixtureKey] {
            return buttons.first { $0.title == buttonTitle }?.frameCG
        }
        if fixtureKey == "cancel_1" || fixtureKey == "cancel_2" {
            let cancelButtons = buttons.filter { $0.title == "Cancel" }.sorted { $0.frameCG.minX < $1.frameCG.minX }
            let cancelIndex = fixtureKey == "cancel_1" ? 0 : 1
            return cancelIndex < cancelButtons.count ? cancelButtons[cancelIndex].frameCG : nil
        }
        if let iconDescription = iconDescriptionsByKey[fixtureKey] {
            return buttons.first { $0.elementDescription == iconDescription || $0.title == iconDescription }?.frameCG
        }
        let textFields = elements.filter { $0.role == kAXTextFieldRole as String }
        if fixtureKey == "field_search" {
            return textFields.first { $0.placeholder == "Search" }?.frameCG
        }
        if fixtureKey == "field_address" {
            return textFields.first { $0.value.contains("github.com/addy/clicky/pull/12") }?.frameCG
        }
        if fixtureKey.hasPrefix("row_"), let rowNumber = Int(fixtureKey.dropFirst("row_".count)) {
            let rowText = "Row \(rowNumber)"
            return elements.first { $0.role == kAXRowRole as String && $0.childTexts.contains(rowText) }?.frameCG
        }
        return nil
    }

    private static func descendantTexts(of element: AXUIElement, depth: Int) -> [String] {
        guard depth < 4 else { return [] }
        var texts: [String] = []
        for child in arrayAttribute(element, kAXChildrenAttribute) {
            let childValue = stringAttribute(child, kAXValueAttribute)
            if !childValue.isEmpty { texts.append(childValue) }
            let childTitle = stringAttribute(child, kAXTitleAttribute)
            if !childTitle.isEmpty { texts.append(childTitle) }
            texts.append(contentsOf: descendantTexts(of: child, depth: depth + 1))
        }
        return texts
    }

    private static func stringAttribute(_ element: AXUIElement, _ attributeName: String) -> String {
        var attributeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attributeName as CFString, &attributeValue) == .success else { return "" }
        return attributeValue as? String ?? ""
    }

    private static func arrayAttribute(_ element: AXUIElement, _ attributeName: String) -> [AXUIElement] {
        var attributeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attributeName as CFString, &attributeValue) == .success else { return [] }
        return attributeValue as? [AXUIElement] ?? []
    }

    /// AX position is already CG global (top-left origin), same as the
    /// fixture's ground truth.
    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var elementPosition = CGPoint.zero
        var elementSize = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &elementPosition)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &elementSize)
        return CGRect(origin: elementPosition, size: elementSize)
    }
}

/// `axfind`: the eval's ground truth for real apps. Walks one app's AX tree
/// (no Clicky registry, no OCR, no actions) and returns the CG frame of the
/// nth element matching a role and a title. Fields of the command:
///
///   bundle    (required) bundle id of a running app
///   role      AX role ("AXButton"); omitted or "*" = any
///   subrole   optional AX subrole
///   title     matched (case-insensitive, trimmed, "..." = "…") against
///             AXTitle, AXDescription, AXValue, AXPlaceholderValue, AXHelp,
///             AXIdentifier and AXLabelValue
///   match     "exact" (default) | "contains" | "prefix"
///   nth       1-based (default 1), counted in `order`
///   order     "tree" (default, depth first) | "x" | "y" (by minX / minY)
///   all       true → every match's frame in `frames` (for "circle all X")
///   ancestor  role: report the nearest ancestor with that role instead
///             (e.g. a sidebar label's AXRow)
///   within    {role, title, match, nth}: search only under that element
///   text      substring: AXBoundsForRange of its nth occurrence inside the
///             matching element's AXValue (Terminal text, text views)
///   window    "main" (default: main/focused window, then the rest) |
///             "only-main" | "menubar" (include the menu bar)
///   electron  true → sets AXManualAccessibility first (Electron apps such
///             as Slack / VS Code expose no tree otherwise; Clicky's own walk
///             does the same)
///
/// Frames are CG global points (top-left origin). Each result carries the
/// window frame and the fraction of the element visible inside its clipping
/// scroll areas and window, so the eval can drop truths that are scrolled away.
nonisolated enum AXFindWalker {
    struct FindError: Error {
        let message: String
        var details: [String: Any] = [:]
    }

    private struct Query {
        var role: String?
        var subrole: String?
        var title: String?
        var matchMode = "exact"

        init(object: [String: Any]) {
            let roleText = (object["role"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            role = roleText.isEmpty || roleText == "*" ? nil : roleText
            subrole = (object["subrole"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            title = (object["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            matchMode = object["match"] as? String ?? "exact"
        }
    }

    private struct Node {
        let element: AXUIElement
        let role: String
        let subrole: String
        let labels: [String]
        let frameCG: CGRect?
        /// Clipping rects of the ancestors (scroll areas, the window).
        let clips: [CGRect]
        let ancestors: [(role: String, frame: CGRect?)]
    }

    private static let maximumDepth = 60
    private static let maximumNodes = 40_000
    private static let timeBudgetSeconds = 4.0
    private static let labelAttributes = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXPlaceholderValueAttribute,
                                          kAXHelpAttribute, kAXIdentifierAttribute, "AXLabelValue"]

    static func find(_ object: [String: Any]) -> Result<[String: Any], FindError> {
        guard let bundleIdentifier = object["bundle"] as? String, !bundleIdentifier.isEmpty else {
            return .failure(FindError(message: "axfind needs \"bundle\""))
        }
        guard AXIsProcessTrusted() else { return .failure(FindError(message: "Clicky isn't trusted for Accessibility")) }
        guard let application = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
            return .failure(FindError(message: "no running app with bundle \(bundleIdentifier)"))
        }
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(applicationElement, 0.5)
        if object["electron"] as? Bool == true {
            AXUIElementSetAttributeValue(applicationElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }

        let windowMode = object["window"] as? String ?? "main"
        let roots = rootElements(of: applicationElement, windowMode: windowMode)
        guard !roots.isEmpty else { return .failure(FindError(message: "\(bundleIdentifier) has no windows")) }

        var budget = WalkBudget()
        var searchRoots = roots.map { (element: $0, clips: [CGRect](), ancestors: [(role: String, frame: CGRect?)]()) }
        if let withinObject = object["within"] as? [String: Any] {
            let withinQuery = Query(object: withinObject)
            var containers: [Node] = []
            for root in searchRoots { walk(root.element, depth: 0, clips: root.clips, ancestors: root.ancestors, query: withinQuery, budget: &budget, into: &containers) }
            let withinIndex = max(1, withinObject["nth"] as? Int ?? 1) - 1
            guard withinIndex < containers.count else {
                return .failure(FindError(message: "no \"within\" container matched", details: ["nodesVisited": budget.visited]))
            }
            let container = containers[withinIndex]
            searchRoots = [(element: container.element, clips: container.clips, ancestors: container.ancestors)]
        }

        let query = Query(object: object)
        var matches: [Node] = []
        for root in searchRoots { walk(root.element, depth: 0, clips: root.clips, ancestors: root.ancestors, query: query, budget: &budget, into: &matches) }
        matches = matches.filter { $0.frameCG.map { $0.width > 0 && $0.height > 0 } ?? false }
        switch object["order"] as? String ?? "tree" {
        case "x": matches.sort { ($0.frameCG!.minX, $0.frameCG!.minY) < ($1.frameCG!.minX, $1.frameCG!.minY) }
        case "y": matches.sort { ($0.frameCG!.minY, $0.frameCG!.minX) < ($1.frameCG!.minY, $1.frameCG!.minX) }
        default: break
        }

        let windowFrame = mainWindowFrame(of: applicationElement)
        var result: [String: Any] = ["pid": Int(application.processIdentifier), "count": matches.count, "nodesVisited": budget.visited,
                                     "truncated": budget.isExhausted, "windowFrameCG": windowFrame.map(rectArray) ?? NSNull()]
        guard !matches.isEmpty else {
            result["sample"] = sampleLabels(roots: roots, role: query.role)
            return .failure(FindError(message: "no match for role \(query.role ?? "*") title \(query.title ?? "-")", details: result))
        }

        let ancestorRole = object["ancestor"] as? String
        func reportedFrame(_ node: Node) -> CGRect? {
            guard let ancestorRole else { return node.frameCG }
            return node.ancestors.last(where: { $0.role == ancestorRole })?.frame ?? nil
        }

        if object["all"] as? Bool == true {
            let frames = matches.compactMap(reportedFrame)
            result["frames"] = frames.map(rectArray)
            result["visibleFractions"] = matches.map { visibleFraction(of: reportedFrame($0), clips: $0.clips) }
            result["frameCG"] = frames.first.map(rectArray) ?? NSNull()
            return .success(result)
        }

        let matchIndex = max(1, object["nth"] as? Int ?? 1) - 1
        guard matchIndex < matches.count else {
            return .failure(FindError(message: "only \(matches.count) match(es), nth \(matchIndex + 1) asked", details: result))
        }
        let node = matches[matchIndex]
        var frame = reportedFrame(node)
        if let searchText = object["text"] as? String, !searchText.isEmpty {
            let occurrence = max(1, object["textNth"] as? Int ?? 1)
            guard let textFrame = boundsOfText(searchText, occurrence: occurrence, in: node.element) else {
                return .failure(FindError(message: "text \"\(searchText)\" not found in the matching element", details: result))
            }
            frame = textFrame
        }
        guard let frame else { return .failure(FindError(message: "matching element has no \(ancestorRole ?? "") frame", details: result)) }
        result["frameCG"] = rectArray(frame)
        result["role"] = node.role
        result["subrole"] = node.subrole
        result["labels"] = node.labels
        result["visibleFraction"] = visibleFraction(of: frame, clips: node.clips)
        return .success(result)
    }

    private struct WalkBudget {
        var visited = 0
        let deadline = Date().addingTimeInterval(AXFindWalker.timeBudgetSeconds)
        var isExhausted: Bool { visited >= AXFindWalker.maximumNodes || Date() > deadline }
    }

    private static func rootElements(of applicationElement: AXUIElement, windowMode: String) -> [AXUIElement] {
        var roots: [AXUIElement] = []
        for attributeName in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
            if let window = elementAttribute(applicationElement, attributeName), !roots.contains(where: { CFEqual($0, window) }) {
                roots.append(window)
                break
            }
        }
        if windowMode != "only-main" {
            for window in arrayAttribute(applicationElement, kAXWindowsAttribute) where !roots.contains(where: { CFEqual($0, window) }) {
                roots.append(window)
            }
        }
        if windowMode == "menubar", let menuBar = elementAttribute(applicationElement, kAXMenuBarAttribute) {
            roots.append(menuBar)
        }
        return roots
    }

    private static func walk(_ element: AXUIElement, depth: Int, clips: [CGRect], ancestors: [(role: String, frame: CGRect?)],
                             query: Query, budget: inout WalkBudget, into matches: inout [Node]) {
        guard depth <= maximumDepth, !budget.isExhausted else { return }
        budget.visited += 1
        let role = stringAttribute(element, kAXRoleAttribute)
        let subrole = stringAttribute(element, kAXSubroleAttribute)
        let frameCG = frame(of: element)
        let labels = labelAttributes.map { stringAttribute(element, $0) }.filter { !$0.isEmpty }
        let node = Node(element: element, role: role, subrole: subrole, labels: labels, frameCG: frameCG, clips: clips, ancestors: ancestors)
        if isMatch(node, query: query) { matches.append(node) }

        var childClips = clips
        if let frameCG, role == kAXScrollAreaRole as String || role == kAXWindowRole as String { childClips.append(frameCG) }
        let childAncestors = ancestors + [(role: role, frame: frameCG)]
        for child in arrayAttribute(element, kAXChildrenAttribute) {
            walk(child, depth: depth + 1, clips: childClips, ancestors: childAncestors, query: query, budget: &budget, into: &matches)
        }
    }

    private static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "...", with: "…").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func isMatch(_ node: Node, query: Query) -> Bool {
        if let role = query.role, node.role != role { return false }
        if let subrole = query.subrole, node.subrole != subrole { return false }
        guard let title = query.title else { return true }
        let wanted = normalized(title)
        return node.labels.map(normalized).contains { label in
            switch query.matchMode {
            case "contains": return label.contains(wanted)
            case "prefix": return label.hasPrefix(wanted)
            default: return label == wanted
            }
        }
    }

    private static func visibleFraction(of frame: CGRect?, clips: [CGRect]) -> Double {
        guard let frame, frame.width > 0, frame.height > 0 else { return 0 }
        var visible = frame
        for clip in clips {
            visible = visible.intersection(clip)
            if visible.isNull { return 0 }
        }
        return (Double(visible.width * visible.height / (frame.width * frame.height)) * 100).rounded() / 100
    }

    private static func boundsOfText(_ searchText: String, occurrence: Int, in element: AXUIElement) -> CGRect? {
        let value = stringAttribute(element, kAXValueAttribute) as NSString
        var searchRange = NSRange(location: 0, length: value.length)
        var foundRange = NSRange(location: NSNotFound, length: 0)
        for _ in 0..<occurrence {
            foundRange = value.range(of: searchText, options: [], range: searchRange)
            guard foundRange.location != NSNotFound else { return nil }
            searchRange = NSRange(location: foundRange.upperBound, length: value.length - foundRange.upperBound)
        }
        var cfRange = CFRange(location: foundRange.location, length: foundRange.length)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &boundsValue) == .success,
              let boundsValue, CFGetTypeID(boundsValue) == AXValueGetTypeID() else { return nil }
        var bounds = CGRect.zero
        AXValueGetValue(boundsValue as! AXValue, .cgRect, &bounds)
        return bounds.width > 0 && bounds.height > 0 ? bounds : nil
    }

    private static func mainWindowFrame(of applicationElement: AXUIElement) -> CGRect? {
        let window = elementAttribute(applicationElement, kAXMainWindowAttribute) ?? elementAttribute(applicationElement, kAXFocusedWindowAttribute)
        return window.flatMap(frame(of:))
    }

    /// Up to 40 "role: label" pairs, to help fix a fixture row that missed.
    private static func sampleLabels(roots: [AXUIElement], role: String?) -> [String] {
        var budget = WalkBudget()
        var nodes: [Node] = []
        var sampleQuery = Query(object: [:])
        sampleQuery.role = role
        for root in roots { walk(root, depth: 0, clips: [], ancestors: [], query: sampleQuery, budget: &budget, into: &nodes) }
        return nodes.filter { !$0.labels.isEmpty }.prefix(40).map { "\($0.role): \($0.labels.joined(separator: " | ").prefix(80))" }
    }

    private static func rectArray(_ rect: CGRect) -> [Double] {
        [rect.minX, rect.minY, rect.width, rect.height].map { (Double($0) * 100).rounded() / 100 }
    }

    private static func stringAttribute(_ element: AXUIElement, _ attributeName: String) -> String {
        var attributeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attributeName as CFString, &attributeValue) == .success else { return "" }
        return attributeValue as? String ?? ""
    }

    private static func elementAttribute(_ element: AXUIElement, _ attributeName: String) -> AXUIElement? {
        var attributeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attributeName as CFString, &attributeValue) == .success,
              let attributeValue, CFGetTypeID(attributeValue) == AXUIElementGetTypeID() else { return nil }
        return (attributeValue as! AXUIElement)
    }

    private static func arrayAttribute(_ element: AXUIElement, _ attributeName: String) -> [AXUIElement] {
        var attributeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attributeName as CFString, &attributeValue) == .success else { return [] }
        return attributeValue as? [AXUIElement] ?? []
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var elementPosition = CGPoint.zero
        var elementSize = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &elementPosition)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &elementSize)
        return CGRect(origin: elementPosition, size: elementSize)
    }
}

// MARK: - TEST-ONLY AX commands (P7 harness)

/// axSetPosition / axPerform. Argument checks and the TextEdit / Notes
/// allowlist are ClickyCore's ActionsDebugAXCommand (unit-tested); this only
/// talks to AX. Apps are never launched or activated here.
@MainActor
enum DebugAXTestCommands {
    static func application(_ bundleIdentifier: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first { !$0.isTerminated }
    }

    static func windowList(_ applicationElement: AXUIElement) -> [(element: AXUIElement, info: [String: Any])] {
        TypeForMeAccessibility.elementArrayAttribute(kAXWindowsAttribute, of: applicationElement).enumerated().map { index, window in
            let frame = TypeForMeAccessibility.frameCG(of: window)
            return (window, ["index": index, "title": TypeForMeAccessibility.stringAttribute(kAXTitleAttribute, of: window) ?? "",
                             "frame": frame.map { [$0.minX, $0.minY, $0.width, $0.height] } ?? NSNull()])
        }
    }

    static func setPosition(_ request: ActionsDebugAXCommand.SetPositionRequest) -> (Bool, [String: Any]?, String?) {
        guard let runningApplication = application(request.bundleIdentifier) else { return (false, nil, "\(request.bundleIdentifier) isn't running") }
        let applicationElement = TypeForMeAccessibility.applicationElement(processIdentifier: runningApplication.processIdentifier)
        let windows = windowList(applicationElement)
        if request.isDryRun { return (true, ["dryRun": true, "windows": windows.map(\.info)], nil) }
        let chosen: AXUIElement?
        switch request.window {
        case .index(let index): chosen = windows.indices.contains(index) ? windows[index].element : nil
        case .title(let title):
            chosen = windows.first { ($0.info["title"] as? String) == title }?.element
                ?? windows.first { ($0.info["title"] as? String)?.localizedCaseInsensitiveContains(title) == true }?.element
        }
        guard let window = chosen else { return (false, ["windows": windows.map(\.info)], "no such window") }
        var position = CGPoint(x: request.x, y: request.y)
        guard let positionValue = AXValueCreate(.cgPoint, &position),
              AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue) == .success else {
            return (false, nil, "AXPosition couldn't be set")
        }
        if let width = request.width, let height = request.height {
            var size = CGSize(width: width, height: height)
            if let sizeValue = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue) }
        }
        let newFrame = TypeForMeAccessibility.frameCG(of: window)
        return (true, ["frame": newFrame.map { [$0.minX, $0.minY, $0.width, $0.height] } ?? NSNull()], nil)
    }

    static func perform(_ request: ActionsDebugAXCommand.PerformRequest) -> (Bool, [String: Any]?, String?) {
        guard let runningApplication = application(request.bundleIdentifier) else { return (false, nil, "\(request.bundleIdentifier) isn't running") }
        let processIdentifier = runningApplication.processIdentifier
        if request.action == "delete" {
            // Notes only (checked in ClickyCore): the menu bar's Edit ▸ Delete, pressed through AX.
            let menu = TypeForMeAccessibility.applicationElement(processIdentifier: processIdentifier)
            var menuBarValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(menu, kAXMenuBarAttribute as CFString, &menuBarValue) == .success, let menuBarValue,
                  CFGetTypeID(menuBarValue) == AXUIElementGetTypeID() else { return (false, nil, "no menu bar") }
            // swiftlint:disable:next force_cast
            let menuBar = menuBarValue as! AXUIElement
            guard let editItem = TypeForMeAccessibility.elementArrayAttribute(kAXChildrenAttribute, of: menuBar)
                    .first(where: { TypeForMeAccessibility.stringAttribute(kAXTitleAttribute, of: $0) == "Edit" }),
                  let editMenu = TypeForMeAccessibility.elementArrayAttribute(kAXChildrenAttribute, of: editItem).first,
                  let deleteItem = TypeForMeAccessibility.elementArrayAttribute(kAXChildrenAttribute, of: editMenu)
                    .first(where: { TypeForMeAccessibility.stringAttribute(kAXTitleAttribute, of: $0) == "Delete" }) else {
                return (false, nil, "no Edit ▸ Delete menu item")
            }
            guard TypeForMeAccessibility.boolAttribute(kAXEnabledAttribute, of: deleteItem) == true else { return (false, nil, "Edit ▸ Delete is disabled (no note selected?)") }
            let didPress = TypeForMeAccessibility.press(deleteItem)
            return (didPress, ["did": didPress ? "pressed Edit ▸ Delete" : "nothing"], didPress ? nil : "AXPress failed")
        }
        guard let role = request.role, let title = request.title, let window = ActionExecutor.focusedWindow(processIdentifier: processIdentifier) else {
            return (false, nil, "no front window")
        }
        var queue: [AXUIElement] = [window]
        var visitedCount = 0
        while !queue.isEmpty && visitedCount < 3_000 {
            let element = queue.removeFirst()
            visitedCount += 1
            let elementTitle = TypeForMeAccessibility.stringAttribute(kAXTitleAttribute, of: element) ?? TypeForMeAccessibility.stringAttribute(kAXDescriptionAttribute, of: element)
            if TypeForMeAccessibility.stringAttribute(kAXRoleAttribute, of: element) == role, elementTitle == title {
                let didPress = TypeForMeAccessibility.press(element)
                return (didPress, ["did": didPress ? "pressed \(role) \"\(title)\"" : "nothing", "visited": visitedCount], didPress ? nil : "AXPress failed")
            }
            queue += TypeForMeAccessibility.elementArrayAttribute(kAXChildrenAttribute, of: element)
        }
        return (false, ["visited": visitedCount], "no \(role) titled \"\(title)\" in the front window")
    }
}

#endif
