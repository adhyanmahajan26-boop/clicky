//
//  PrismEval.swift
//  leanring-buddy
//
//  Test profile only: runs a file of labelled cases through the same questions the app asks Prism, one after another,
//  and writes each answer and its time to a file. `uiPrismEval {cases, out}`. Also records what today's rules decide,
//  for the decisions that have rules.
//

import AVFoundation
import ClickyCore
import Foundation

enum PrismEval {
    static func run(casesPath: String, outPath: String) async -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: casesPath),
              let file = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cases = file["cases"] as? [[String: Any]] else { return ["error": "Can't read the cases"] }
        var rows: [[String: Any]] = []
        for item in cases {
            let kind = item["kind"] as? String ?? ""
            guard let question = question(for: item, kind: kind) else { continue }
            var row = item
            do {
                let outcome = try await PrismClient.ask(question, timeout: 30)
                row["answer"] = outcome.answer.choice
                row["p"] = outcome.answer.probability
                row["probabilities"] = outcome.answer.probabilities
                row["ms"] = outcome.milliseconds
                if let one = outcome.all[FastDecisions.namesOneID]?.probabilities["true"] { row["namesOne"] = one }
                row["options"] = nil
            } catch {
                row["error"] = error.localizedDescription
            }
            rows.append(row)
        }
        let output = ["rows": rows]
        if let json = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted]) {
            FileManager.default.createFile(atPath: outPath, contents: json)
        }
        let failed = rows.filter { $0["error"] != nil }
        return ["rows": rows.count, "errors": failed.count, "firstError": failed.first?["error"] ?? ""]
    }

    /// One real pass over Sarvam's voice models. Bulbul's audio goes back through Saaras, and each socket's address is opened and pinged.
    static func liveCheck() async -> [String: Any] {
        var report: [String: Any] = [:]
        guard let client = SarvamClient.fromKeychain() else { return ["error": "No Sarvam key"] }
        let line = "The invoice for Bosch was paid on Monday."
        do {
            let started = Date()
            let audio = try await client.synthesize(text: line, languageSetting: "en-IN", speaker: "shubh_en_narration", model: SarvamVoiceConfig.model, pace: 1)
            report["tts"] = ["model": SarvamVoiceConfig.model, "bytes": audio.count, "ms": Int(Date().timeIntervalSince(started) * 1000)]
            let heardAt = Date()
            let heard = try await client.transcribe(audio: audio)
            report["stt"] = ["model": "saaras:v4", "said": line, "heard": heard.transcript, "ms": Int(Date().timeIntervalSince(heardAt) * 1000)]
        } catch {
            report["restError"] = error.localizedDescription
        }
        for (name, url) in [("ttsSocket", SarvamWire.ttsURL()), ("realtimeSocket", SarvamWire.realtimeSTTURL()), ("standardSocket", SarvamWire.standardSTTURL())] {
            guard let url else { continue }
            report[name] = await socketAnswers(url, key: client.apiKey)
        }
        if let dictation = CompanionManager.current?.dictationController {
            var clean: [[String: Any]] = []
            for text in ["Please send the invoice to Rahul by Friday and copy the accounts team.",
                         "So you know the thing is that like the invoice was you know sent twice, no wait, sent three times."] {
                let readsClean = await dictation.readsCleanAlready(text)
                clean.append(["text": String(text.prefix(30)), "skipsHaiku": readsClean])
            }
            report["dictationGate"] = clean
        }
        return report
    }

    /// Whether the server keeps a socket open at this address, or what it says when it won't.
    private static func socketAnswers(_ url: URL, key: String) async -> String {
        let task = URLSession.shared.webSocketTask(with: SarvamWire.socketRequest(url, apiKey: key))
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }
        // A ping can go unanswered for good, so a timer settles it too.
        let once = NSLock()
        var settled = false
        let pinged: String = await withCheckedContinuation { continuation in
            func settle(_ value: String) {
                once.lock(); defer { once.unlock() }
                guard !settled else { return }
                settled = true
                continuation.resume(returning: value)
            }
            task.sendPing { error in settle(error.map { $0.localizedDescription } ?? "open") }
            DispatchQueue.global().asyncAfter(deadline: .now() + 6) { settle("no answer in 6 s, state \(task.state.rawValue), close \(task.closeCode.rawValue)") }
        }
        guard pinged == "open" else { return pinged + (task.closeReason.map { " " + String(decoding: $0, as: UTF8.self).prefix(160) } ?? "") }
        // A bad model is refused just after the handshake, so give it a moment to say so.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        return task.closeCode == .invalid ? "open" : "closed \(task.closeCode.rawValue) " + (task.closeReason.map { String(decoding: $0, as: UTF8.self).prefix(160) } ?? "")
    }

    /// Real audio through each of Sarvam's sockets, with real timings. The audio is Bulbul saying a line, so nothing comes from the mic or goes to the speakers.
    static func socketCheck() async -> [String: Any] {
        guard let client = SarvamClient.fromKeychain() else { return ["error": "No Sarvam key"] }
        var report: [String: Any] = [:]
        let line = "The invoice for Bosch was paid on Monday, and the credit note comes next week."
        var restTimes: [Int] = []
        var audio = Data()
        for _ in 0..<3 {
            let started = Date()
            do { audio = try await client.synthesize(text: line, languageSetting: "en-IN", speaker: "shubh_en_narration", model: SarvamVoiceConfig.model, pace: 1) }
            catch { report["ttsRestError"] = error.localizedDescription }
            restTimes.append(Int(Date().timeIntervalSince(started) * 1000))
        }
        report["ttsRestMs"] = restTimes
        var socketTimes: [Int] = []
        for _ in 0..<3 {
            let started = Date()
            do { _ = try await client.synthesizeOverSocket(text: line, languageSetting: "en-IN", speaker: "shubh_en_narration", model: SarvamVoiceConfig.model, pace: 1) }
            catch { report["ttsSocketWholeError"] = error.localizedDescription }
            socketTimes.append(Int(Date().timeIntervalSince(started) * 1000))
        }
        report["ttsSocketWholeMs"] = socketTimes
        guard let pcm = pcm16k(fromWAV: audio) else { report["error"] = "Couldn't read Bulbul's audio"; return report }
        report["audioSeconds"] = Double(pcm.count) / 32000
        if let url = SarvamWire.realtimeSTTURL(model: "saaras:v3-realtime") { report["realtime v3"] = await listen(url, key: client.apiKey, pcm: pcm, realtime: true) }
        if let url = SarvamWire.realtimeSTTURL(model: "saaras:v4") { report["realtime v4"] = await listen(url, key: client.apiKey, pcm: pcm, realtime: true) }
        if let url = SarvamWire.standardSTTURL() { report["standard v4"] = await listen(url, key: client.apiKey, pcm: pcm, realtime: false) }
        if let url = SarvamWire.ttsURL() { report["ttsSocket"] = await speak(url, key: client.apiKey, text: line) }
        return report
    }

    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var texts: [String] = []
        private var times: [Date] = []
        func add(_ text: String) { lock.lock(); texts.append(text); times.append(Date()); lock.unlock() }
        var all: [(String, Date)] { lock.lock(); defer { lock.unlock() }; return Array(zip(texts, times)) }
    }

    private static func reading(_ task: URLSessionWebSocketTask, into events: Events) -> Task<Void, Never> {
        Task.detached {
            while !Task.isCancelled {
                guard let message = try? await task.receive() else { return }
                if case .string(let text) = message { events.add(text) }
            }
        }
    }

    private static func listen(_ url: URL, key: String, pcm: Data, realtime: Bool) async -> [String: Any] {
        let task = URLSession.shared.webSocketTask(with: SarvamWire.socketRequest(url, apiKey: key))
        let events = Events()
        task.resume()
        let reader = reading(task, into: events)
        defer { reader.cancel(); task.cancel(with: .normalClosure, reason: nil) }
        let silence = Data(count: 32000 * 2)
        var offset = 0
        let all = pcm + silence
        let started = Date()
        var speechEnded: Date?
        while offset < all.count {
            let chunk = all.subdata(in: offset..<min(offset + 3200, all.count))
            try? await task.send(.string(realtime ? SarvamWire.realtimeAudio(chunk) : SarvamWire.standardAudio(chunk)))
            offset += 3200
            if speechEnded == nil, offset >= pcm.count { speechEnded = Date() }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if !realtime { try? await task.send(.string(SarvamWire.standardFlush)) }
        for _ in 0..<60 {
            if events.all.contains(where: { if case .final = (realtime ? SarvamWire.parseRealtimeSTT($0.0) : SarvamWire.parseStandardSTT($0.0)) { return true } else { return false } }) { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        var firstPartial: Int?
        var final: String?
        var finalAfterSpeech: Int?
        var errors: [String] = []
        for (text, at) in events.all {
            switch realtime ? SarvamWire.parseRealtimeSTT(text) : SarvamWire.parseStandardSTT(text) {
            case .partial(let words): if firstPartial == nil, !words.isEmpty { firstPartial = Int(at.timeIntervalSince(started) * 1000) }
            case .final(let words, _): if final == nil { final = words; finalAfterSpeech = speechEnded.map { Int(at.timeIntervalSince($0) * 1000) } }
            case .error(let message, _): errors.append(String(message.prefix(160)))
            default: break
            }
        }
        return ["final": final ?? NSNull(), "finalMsAfterSpeech": finalAfterSpeech ?? NSNull(), "firstPartialMs": firstPartial ?? NSNull(), "errors": errors,
                "closeCode": task.closeCode.rawValue, "messages": events.all.count]
    }

    private static func speak(_ url: URL, key: String, text: String) async -> [String: Any] {
        let task = URLSession.shared.webSocketTask(with: SarvamWire.socketRequest(url, apiKey: key))
        let events = Events()
        task.resume()
        let reader = reading(task, into: events)
        defer { reader.cancel(); task.cancel(with: .normalClosure, reason: nil) }
        let started = Date()
        try? await task.send(.string(SarvamWire.ttsConfig(speaker: "shubh_en_narration", languageCode: "en-IN", pace: 1, codec: "linear16")))
        try? await task.send(.string(SarvamWire.ttsText(text)))
        try? await task.send(.string(SarvamWire.ttsFlush))
        var firstAudio: Int?
        var bytes = 0
        var errors: [String] = []
        var ended = false
        for _ in 0..<150 where !ended {
            try? await Task.sleep(nanoseconds: 100_000_000)
            firstAudio = nil; bytes = 0; errors = []
            for (message, at) in events.all {
                switch SarvamWire.parseTTS(message) {
                case .audio(let audio, _): if firstAudio == nil { firstAudio = Int(at.timeIntervalSince(started) * 1000) }; bytes += audio.count
                case .final: ended = true
                case .error(let problem): errors.append(String(problem.prefix(160))); ended = true
                case .other: break
                }
            }
        }
        return ["firstAudioMs": firstAudio ?? NSNull(), "bytes": bytes, "errors": errors, "ended": ended, "closeCode": task.closeCode.rawValue]
    }

    private static func pcm16k(fromWAV wav: Data) -> Data? {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("prism-voice-check-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: file) }
        guard (try? wav.write(to: file)) != nil, let input = try? AVAudioFile(forReading: file),
              let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(input.length)), (try? input.read(into: buffer)) != nil,
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: input.processingFormat, to: target) else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16000 / input.processingFormat.sampleRate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var given = false
        var problem: NSError?
        converter.convert(to: output, error: &problem) { _, status in
            if given { status.pointee = .endOfStream; return nil }
            given = true
            status.pointee = .haveData
            return buffer
        }
        guard problem == nil, let samples = output.int16ChannelData else { return nil }
        return Data(bytes: samples[0], count: Int(output.frameLength) * 2)
    }

    private static func question(for item: [String: Any], kind: String) -> FastDecisionQuestion? {
        let text = item["text"] as? String ?? ""
        switch kind {
        case "dictation": return FastDecisions.dictationNeedsCleanup(text: text)
        case "press":
            let options = (item["options"] as? [[String: String]] ?? []).map { FastPressOption(id: $0["id"] ?? "", role: $0["role"] ?? "", label: $0["label"] ?? "", app: $0["app"] ?? "") }
            return FastDecisions.whichToPress(words: text, options: options, pointerOn: item["pointer"] as? String)
        default: return nil
        }
    }
}
