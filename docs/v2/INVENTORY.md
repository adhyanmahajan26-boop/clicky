# Clicky v2 inventory

HEAD = `122e07c82c8040365626361297365fcfd69e8eee` (branch `clicky-v2` created from `claude-companion`).

Paths below are relative to `leanring-buddy/` unless absolute.

## A1 Project

- `xcodebuild -list`: targets `leanring-buddy`, `leanring-buddyTests`, `leanring-buddyUITests`; configurations Debug, Release; scheme `leanring-buddy`.
- PRODUCT_NAME = Clicky; PRODUCT_BUNDLE_IDENTIFIER = com.personal.clicky; MACOSX_DEPLOYMENT_TARGET = 14.2; SWIFT_VERSION = 5.0; SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor; ENABLE_USER_SCRIPT_SANDBOXING = YES; SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES.
- INFOPLIST_FILE = `leanring-buddy/Info.plist` with GENERATE_INFOPLIST_FILE = YES.
- Signing: automatic, team 9JAQUUW553 (Apple Development).

## A2 Synchronized root groups

- PBXFileSystemSynchronizedRootGroup paths: `leanring-buddy`, `leanring-buddyTests`, `leanring-buddyUITests`.
- `Packages/`, `Tools/`, `docs/` sit outside them. OK.

## A3 Project format

- objectVersion = 77 (>= 60). OK.

## A4 Machine

- macOS 27.0 (26A428), Apple M3 Ultra, 96 GB RAM, Xcode 27.1 (27A9275).
- Free disk about 97 GiB.
- Displays: main Dell S3425DW 3440x1440 pt @1x; two Dell S2725QC 4K at 1920x1080 pt @2x.

## A5 Claude CLI call

Source: `ClaudeCodeBridge.swift`.

- Binary located by `locateClaudeCodeExecutable()` (line 57), expected at `~/.local/bin/claude`.
- Working directory: `$TMPDIR/clicky-claude-code-workdir` (line 43).
- Argument list (lines 121-130):
  `claude -p --input-format stream-json --output-format stream-json --verbose --include-partial-messages --model <alias> --system-prompt <text> --tools "" --strict-mcp-config --disable-slash-commands --no-session-persistence`
- Images go in as base64 blocks (line 237-239) inside one stream-json user message. History is folded into the text.
- Workers (`CompanionWorkers.swift`): `workerClaudeModel = "haiku"` (line 88), built via `ClaudeCodeBridge(model:)` (line 92). Same bridge.

## A6 Claude CLI state

- claude 2.1.301, logged in, Max subscription.

## A7 Screen capture

Source: `CompanionScreenCaptureUtility.swift`.

- `captureAllScreensAsJPEG()` at line 30.
- `SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)` at line 31.
- Clicky's own windows are excluded: `ownAppWindows` is filtered by bundle id (lines 43-45), then passed to `SCContentFilter(display:excludingWindows:)` (line 81 for all screens; line 154 for the cursor-screen path).
- All displays are captured; cursor screen is first (lines 62-79).
- `displayFrame` = `NSScreen.frame` (AppKit, bottom-left origin) (lines 73-79, assigned at 119).
- Long edge resized to `maxDimension = 1280`, aspect kept (line 84). JPEG compression 0.8 (line 100).
- Label: the capture label plus " (image dimensions: WxH pixels)", appended in CompanionManager.sendTranscriptToClaudeWithScreenshot (grep "image dimensions").
- Today's image sizes: ultrawide 1280x535, 4K 1280x720.
- Proposed high: ultrawide 2576x1078 (0.749 px/pt), 4K 1920x1080.
- Proposed standard: ultrawide 1568x656, 4K 1456x819.

## A8 Pointing and mark tags

Source: `CompanionManager.swift`, `LiveScreenMark.swift`, `LiveScreenMarksOverlayView.swift`.

- Parse order: WORKER tags stripped first (line 953, `CompanionWorkerTagParser.extractWorkerTags`), then MARK (line 969, `LiveScreenMarkTagParser.extractLiveScreenMarkTags`), then POINT (line 972, `parsePointingCoordinates`, defined at line 1295; POINT is anchored at end).
- "Scale from screenshot pixels to display points" at line 1009.
- `globalScreenLocation(...)` defined at line 1257, used at line 1243.
- Legacy MARK grammar: `[MARK:kind:x,y:label:screenN]` (`LiveScreenMark.swift` line 13). kind = `circle` | `arrow` | step number (lines 102-108).
- Cap: `maximumMarksPerResponse = 6` (`LiveScreenMark.swift` line 54).
- Overlay drawing in `LiveScreenMarksOverlayView.swift`:
  - circle ring radius 34 pt (line 57);
  - numbered badge diameter 26 pt, placed up-left of target (line 58);
  - arrow tail offset 90x70 pt from upper-left, flipping near edges (line 61).
- Auto-clear 20 s after speech: `liveScreenMarksSecondsToKeepAfterSpeech` (`CompanionManager.swift` line 53, used at line 271). Hard-coded, no settings key.

## A9 Microphone gating during speech

- Push-to-talk records only while the hotkey is held.
- Hands-free (`HandsFreeListeningSession.swift`): voice-processing echo cancellation via `setVoiceProcessingEnabled(true)` (line 114), disabled at line 165.
- `CompanionManager` drops non-command speech heard while the buddy was speaking: flag `currentUtteranceOverlappedBuddySpeech` (declared line 595; set line 688; read line 710).
- Pause words fire on partial transcripts.

## A10 Hotkey

Source: `GlobalPushToTalkShortcutMonitor.swift`.

- Listen-only CGEvent tap (`CGEvent.tapCreate`, line 61; `.listenOnly`, line 64).
- ctrl+option hold = push-to-talk (header comment, line 7).
- Quick double-tap = hands-free toggle.
- Escape = stop: keyCode 53 (line 20), publishes `escapeKeyPressedPublisher` (lines 117-118).

## A11 Permission ping

- Not run in this inventory. To be filled by the debug inbox ping.
- App log currently reports: accessibility true, screen true, mic true, speech authorized.

## A12 content-studio TTS (read-only reference)

Source: `~/ai/content-studio/server.py`.

- `TTS_MODEL = "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16"` (line 62).
- Voice "mine": clones from `VOICE_REF` = `local-avatar/inputs/my_voice_ref.wav` and `VOICE_REF_TEXT` = `my_voice_ref.txt` (lines 46-47), sent as `ref_audio` (base64) / `ref_text`.
- Voice "default": engine stock voice; no speaker or instruct parameter used.
- HF cache also holds Qwen3-TTS-12Hz-1.7B-CustomVoice-bf16 and fish-audio-s2-pro-bf16. mlx-serve's model list only exposes the Base model.

## A13 GitHub CLI

- gh 2.96.0, logged in as adhyanmahajan26-boop (keyring), scopes: gist, read:org, repo.

## A14 Toolchain

- No Homebrew.
- uv 0.11.17; python3 3.9.6; pip 26.0.1; ffmpeg 7.1.

## A17 Qwen voice (current code at 122e07c)

Files:
- `QwenLocalTTSClient.swift`: server adopt/launch, synthesis, sentence chunking, AVAudioPlayer playback.
- `CompanionSpeechOutput.swift`: router and fallback (`speakText`, lines 42-54).
- `SystemVoiceTTSClient.swift`: Mac voice and picker logic (`selectableEnglishVoices` line 28, `automaticallyChosenVoice` line 61, `selectVoice` line 82).
- `CompanionPanelView.swift`: `CompanionVoicePickerRow` (struct at line 928; used at line 38).

Server lifecycle:
- Base URL `http://127.0.0.1:11234` (line 28). Executable `/Applications/MLX Core.app/Contents/MacOS/mlx-serve` (line 30).
- `ensureServerIsRunning()` (line 169): adopts if `http://127.0.0.1:11234/v1/models` answers, else launches `serve --host 127.0.0.1 --port 11234` (line 179).
- Warm-up synthesizes "Ready." (`warmUp()` line 198, call at line 201).
- `stopServerIfStartedByClicky()` (line 208). Called from `CompanionManager.stop()` (line 277), which runs from `applicationWillTerminate`. Clicky kills the server only if it started it.
- Live check: `lsof -nP -iTCP:11234 -sTCP:LISTEN` shows 127.0.0.1:11234 (mlx-serve pid 44155, child of Clicky).

Request and audio:
- `POST /v1/audio/speech` with `{"model": "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16", "input": <chunk>}`, returns `audio/wav`, 24 kHz mono 16-bit.
- Deterministic: same text gives identical bytes (stock voice).
- Player: `AVAudioPlayer`, one per chunk (line 130), not AVAudioPlayerNode.
- Measured: `stream:false` ttfb 1.35 s, total 1.36 s for an 84-char sentence (about 5 s of audio).
- `stream:true` returns text/event-stream with only `progress` events and one `complete` event carrying the whole base64 WAV at about 1.29 s. No real audio streaming; first audio is about equal to total.
- CORS: OPTIONS returns 204 with `Access-Control-Allow-Origin: *`, Allow-Methods POST, GET, OPTIONS, Allow-Headers Content-Type, Authorization.

Pipeline:
- Synthesis starts only after the CLI `result` event (full answer), not from streaming deltas.
- `splitIntoSpokenChunks` (line 218): NSString `.bySentences`, merges fragments under 25 chars, max 220 chars (`maximumCharactersPerSpokenChunk`, line 34), long sentences split at commas or spaces (`breakUpLongSentence`, line 250).
- First chunk synthesized then played; next chunk prefetched while the current one plays (`playRemainingChunks`, line 89).
- Fallback: any error from `ensureServerIsRunning` or synthesis of the FIRST chunk sends that answer to the Mac voice (`CompanionSpeechOutput.speakText`, catch at line 48-50). A mid-answer chunk failure just stops playback.

Settings (UserDefaults, domain com.personal.clicky):
- `usesQwenLocalVoice` (Bool; default true when MLX Core is installed; key at `CompanionSpeechOutput.swift` line 19).
- `selectedSpeechVoiceIdentifier` (Mac voice id; nil = automatic).
- `selectedClaudeCodeModelAlias` (main model: sonnet | opus).
- `isClickyCursorEnabled`, `handsFreeEchoCancellationDisabled`, `hasCompletedOnboarding`, `hasScreenContentPermission`, `com.learningbuddy.hasPreviouslyConfirmedScreenRecordingPermission`.
- Current `defaults read`: only hasCompletedOnboarding=1, hasScreenContentPermission=1, and the screen-recording flag=1. Others are unset (defaults apply).
- Rule: new v2 keys must use the `v2.<dotted>` prefix, read through `ClickySettings`.

## Tests

- `leanring-buddyTests`: Swift Testing, 18+ `@Test`, hosted in the app via TEST_HOST.
- `leanring-buddyUITests`: template only.
