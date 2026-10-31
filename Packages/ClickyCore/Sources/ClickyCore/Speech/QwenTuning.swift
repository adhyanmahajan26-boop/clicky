//
//  QwenTuning.swift
//  ClickyCore
//
//  Every Qwen-voice tunable in one place, plus the pure maths the engine
//  uses (watchdog, overrun estimate, request body, speed steps), so the
//  numbers measured in docs/v2/EVAL.md "P3 probe" live next to the code
//  that depends on them and can be unit-tested.
//
//  Probe facts (mlx-serve, Qwen3-TTS 1.7B Base bf16, warm):
//   - no real streaming: "stream": true sends progress events and then
//     the whole WAV, so the first segment is cut early instead;
//   - a cancelled request keeps the server busy until it finishes, so
//     only one segment is synthesized ahead (lookahead 1);
//   - unknown JSON keys are accepted (and ignored by the Base model).
//

import Foundation

public enum QwenTuning {
    public static let serverHost = "127.0.0.1"
    public static let serverPort = 11234
    /// The model Clicky asks for when the server has no TTS model loaded yet.
    public static let defaultModelIdentifier = "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16"
    /// Listed by mlx-serve but NOT used: its Qwen3-TTS backend has no named
    /// speakers (the `speaker`/`voice` fields are ignored, live 25 Oct), and
    /// CustomVoice has no speaker encoder to clone with.
    public static let customVoiceModelIdentifier = "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-bf16"
    /// One fixed voice = the Base model cloning one reference clip
    /// (`ref_audio`, base64 WAV, no `ref_text`). Without it Qwen improvises
    /// a different voice for every text. Live: ~1.7–2.1 s per sentence vs 0.7–0.9 s.
    public static let referenceClipDefaultPath = "~/.clicky/voice/clicky-voice.wav"
    public static let mlxServeExecutablePath = "/Applications/MLX Core.app/Contents/MacOS/mlx-serve"

    /// Segments synthesized ahead of the one playing (probe: L = 1).
    /// Two segments are synthesized ahead, so the next clip is ready when a short one ends (with one, a
    /// 2-word opener was followed by seconds of silence while the next sentence was made).
    public static let lookahead = 2
    /// Speaking speed used for every time estimate.
    public static let charactersPerSecond: Double = 15
    /// Audio longer than this many times the estimate is cut at its last pause.
    public static let overrunFactor: Double = 3
    public static let warmUpText = "Hi."
    public static let language = "English"
    /// A dead server is respawned at most once per this many seconds.
    public static let respawnMinimumIntervalSeconds: TimeInterval = 60
    public static let serverStartupTimeoutSeconds: TimeInterval = 40

    /// Echo tail: the mic's words count as Clicky's own until this long
    /// after the last audio (output latency + 0.25 s).
    public static let audioOutputLatencySeconds: TimeInterval = 0.10
    public static let echoResumePaddingSeconds: TimeInterval = 0.25
    public static var echoTailSeconds: TimeInterval { audioOutputLatencySeconds + echoResumePaddingSeconds }

    // MARK: Voice

    /// Qwen3-TTS CustomVoice speakers (honoured only by a CustomVoice model).
    public static let speakers = ["Vivian", "Serena", "Uncle_Fu", "Dylan", "Eric", "Ryan", "Aiden", "Ono_Anna", "Sohee"]
    public static let englishNativeSpeakers: Set<String> = ["Ryan", "Aiden"]
    public static let defaultSpeaker = "Ryan"
    public static let instructPresets: [(name: String, instruct: String)] = [
        ("Warm conversational", "Speak in a warm, friendly, natural conversational tone."),
        ("Calm teacher", "Speak like a calm, patient teacher: clear, unhurried and encouraging.")
    ]

    // MARK: Timing

    public static func estimatedAudioSeconds(characters: Int) -> TimeInterval {
        Double(max(0, characters)) / charactersPerSecond
    }

    /// How long one synthesis may take before Qwen counts as down (then the
    /// Mac voice speaks the REST of the answer). Generous on purpose: a slow
    /// segment is waited for, never swapped to another voice mid-answer.
    public static func watchdogSeconds(characters: Int) -> TimeInterval {
        max(20, 10 + 3 * estimatedAudioSeconds(characters: characters))
    }

    /// Generation cap sent with every request (ignored by servers that don't know it).
    public static func maxTokens(characters: Int) -> Int {
        50 + 2 * max(0, characters)
    }

    // MARK: Request

    /// The JSON body for one segment: the TTS text gets the lexicon, the
    /// caption keeps the original words.
    /// The JSON body for one segment. With a reference clip (base64 WAV) the
    /// Base model clones that one voice for every segment; the `speaker` and
    /// `instruct` fields are never sent (mlx-serve ignores them).
    public static func requestBody(model: String, speech: String, referenceClipBase64: String?) -> [String: Any] {
        let ttsText = Lexicon.apply(speech)
        var body: [String: Any] = [
            "model": model,
            "input": ttsText,
            "language": language,
            "response_format": "wav",
            "max_tokens": maxTokens(characters: ttsText.count)
        ]
        if let referenceClipBase64 { body["ref_audio"] = referenceClipBase64 }
        return body
    }

    /// The model to request: Base whenever a reference clip exists (only it can
    /// clone), else whatever TTS model the server has loaded.
    public static func modelIdentifier(hasReferenceClip: Bool, loadedModelIdentifier: String) -> String {
        hasReferenceClip ? defaultModelIdentifier : loadedModelIdentifier
    }

    // MARK: Speed

    public static let rateSteps: [Double] = [0.85, 1.0, 1.15, 1.3]

    public static func nearestRate(to rate: Double) -> Double {
        rateSteps.min(by: { abs($0 - rate) < abs($1 - rate) }) ?? 1.0
    }

    /// One step slower or faster, stopping at the ends.
    public static func steppedRate(from rate: Double, faster: Bool) -> Double {
        let currentIndex = rateSteps.firstIndex(of: nearestRate(to: rate)) ?? 1
        let nextIndex = min(rateSteps.count - 1, max(0, currentIndex + (faster ? 1 : -1)))
        return rateSteps[nextIndex]
    }
}
