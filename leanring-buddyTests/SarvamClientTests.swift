//
//  SarvamClientTests.swift
//  leanring-buddyTests
//

import AVFoundation
import Foundation
import Testing
@testable import Clicky

struct SarvamClientTests {
    @Test func ttsRequestShape() throws {
        let request = try SarvamClient.makeTTSRequest(apiKey: "k", text: "Namaste", languageSetting: "hinglish", speaker: "shubh", model: "bulbul:v4-flash", pace: 5)
        #expect(request.url?.absoluteString == "https://api.sarvam.ai/text-to-speech")
        #expect(request.value(forHTTPHeaderField: "api-subscription-key") == "k")
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        #expect(body["language_code"] as? String == "hi-IN")
        #expect(body["speaker"] as? String == "shubh_enhi_companion")
        #expect(body["pace"] as? Double == 2.0)
        #expect(body["model"] as? String == "bulbul:v4-flash")
    }

    @Test func v3KeepsShortSpeaker() {
        #expect(SarvamClient.resolveSpeaker("shubh", model: "bulbul:v3", languageSetting: "hi-IN") == "shubh")
        #expect(SarvamClient.resolveSpeaker("shubh", model: "bulbul:v4-flash", languageSetting: "en-IN") == "shubh_en_narration")
        #expect(SarvamClient.resolveSpeaker("shubh_hi_ads", model: "bulbul:v4-flash", languageSetting: "hi-IN") == "shubh_hi_ads")
    }

    @Test func emptyTextThrows() {
        #expect(throws: SarvamError.self) {
            try SarvamClient.makeTTSRequest(apiKey: "k", text: "  ", languageSetting: "en-IN", speaker: "shubh", model: "bulbul:v3", pace: 1)
        }
    }

    @Test func parsesTTSResponse() throws {
        let json = #"{"request_id":"r1","audios":["UklGRg=="]}"#.data(using: .utf8)!
        let audios = try SarvamClient.parseTTSResponse(json)
        #expect(audios.count == 1)
        #expect(audios[0] == Data([0x52, 0x49, 0x46, 0x46]))
        #expect(throws: SarvamError.self) { try SarvamClient.parseTTSResponse(#"{"audios":[]}"#.data(using: .utf8)!) }
    }

    @Test func parsesSTTTranslateChat() throws {
        let stt = try SarvamClient.parseSTTResponse(#"{"transcript":"hello","language_code":"en-IN"}"#.data(using: .utf8)!)
        #expect(stt.transcript == "hello" && stt.languageCode == "en-IN")
        #expect(try SarvamClient.parseTranslateResponse(#"{"translated_text":"नमस्ते"}"#.data(using: .utf8)!) == "नमस्ते")
        #expect(try SarvamClient.parseChatResponse(#"{"choices":[{"message":{"role":"assistant","content":"hi"}}]}"#.data(using: .utf8)!) == "hi")
    }

    @Test func mapsErrors() {
        let body = #"{"error":{"message":"bad key","code":"invalid_api_key"}}"#.data(using: .utf8)!
        #expect(SarvamClient.error(statusCode: 403, body: body) == .unauthorized("bad key"))
        #expect(SarvamClient.error(statusCode: 429, body: body) == .rateLimited("bad key"))
        #expect(SarvamClient.error(statusCode: 500, body: body) == .server(500, "bad key"))
        #expect(ProviderInfo.testFailure(statusCode: 200, body: Data()) == nil)
    }

    @Test func sttMultipartContainsFields() {
        let request = SarvamClient.makeSTTRequest(apiKey: "k", audio: Data([1, 2, 3]), boundary: "B")
        let text = String(decoding: request.httpBody!, as: UTF8.self)
        #expect(text.contains("name=\"file\"") && text.contains("saaras:v4") && text.hasSuffix("--B--\r\n"))
    }
}

struct SarvamStreamingTests {
    @Test func ttsMessagesMatchTheDocs() throws {
        let config = try #require(JSONSerialization.jsonObject(with: Data(SarvamWire.ttsConfig(speaker: "shubh_enhi_companion", languageCode: "hi-IN", pace: 1.2, codec: "linear16").utf8)) as? [String: Any])
        #expect(config["type"] as? String == "config")
        let data = try #require(config["data"] as? [String: Any])
        #expect(data["speaker"] as? String == "shubh_enhi_companion")
        #expect(data["language_code"] as? String == "hi-IN")
        #expect(data["output_audio_codec"] as? String == "linear16")
        #expect((30...200).contains(data["min_buffer_size"] as? Int ?? 0))
        #expect((50...500).contains(data["max_chunk_length"] as? Int ?? 0))
        let text = try #require(JSONSerialization.jsonObject(with: Data(SarvamWire.ttsText("नमस्ते").utf8)) as? [String: Any])
        #expect((text["data"] as? [String: Any])?["text"] as? String == "नमस्ते")
        #expect(SarvamWire.ttsURL()?.query?.contains("send_completion_event=true") == true)
        #expect(SarvamWire.ttsURL()?.path == "/text-to-speech/ws")
    }

    @Test func parsesTTSEvents() {
        #expect(SarvamWire.parseTTS(#"{"type":"audio","data":{"content_type":"audio/mp3","audio":"UklGRg==","request_id":"r"}}"#) == .audio(Data([0x52, 0x49, 0x46, 0x46]), contentType: "audio/mp3"))
        #expect(SarvamWire.parseTTS(#"{"type":"event","data":{"event_type":"final","message":"x","timestamp":"t"}}"#) == .final)
        #expect(SarvamWire.parseTTS(#"{"type":"error","data":{"message":"nope"}}"#) == .error("nope"))
    }

    @Test func parsesBothListeningSockets() {
        #expect(SarvamWire.parseRealtimeSTT(#"{"event":"session.begin","request_id":"r","config":{}}"#) == .began)
        #expect(SarvamWire.parseRealtimeSTT(#"{"event":"transcript.partial","utterance_idx":0,"text":"hel"}"#) == .partial("hel"))
        #expect(SarvamWire.parseRealtimeSTT(#"{"event":"transcript.final","utterance_idx":0,"text":"hello","language":"en-IN"}"#) == .final("hello", language: "en-IN"))
        #expect(SarvamWire.parseRealtimeSTT(#"{"event":"error","code":"x","is_fatal":false,"message":"m"}"#) == .error("m", fatal: false))
        #expect(SarvamWire.parseStandardSTT(#"{"type":"data","data":{"request_id":"r","transcript":"namaste","language_code":"hi-IN","metrics":{}}}"#) == .final("namaste", language: "hi-IN"))
        #expect(SarvamWire.parseStandardSTT(#"{"type":"events","data":{"event_type":"x","signal_type":"START_SPEECH"}}"#) == .speechStarted)
        #expect(SarvamWire.parseStandardSTT(#"{"type":"error","data":{"error":"bad","code":"c"}}"#) == .error("bad", fatal: true))
    }

    @Test func listeningAddressesAndAudio() throws {
        let realtime = try #require(SarvamWire.realtimeSTTURL()?.absoluteString)
        #expect(realtime.hasPrefix("wss://api.sarvam.ai/speech-to-text-realtime/ws?"))
        #expect(realtime.contains("language_code=auto") && realtime.contains("mode=codemix") && realtime.contains("sample_rate=16000"))
        let standard = try #require(SarvamWire.standardSTTURL()?.absoluteString)
        #expect(standard.hasPrefix("wss://api.sarvam.ai/speech-to-text/ws?"))
        #expect(standard.contains("language-code=unknown"))
        let audio = try #require(JSONSerialization.jsonObject(with: Data(SarvamWire.standardAudio(Data([1, 2])).utf8)) as? [String: Any])
        let body = try #require(audio["audio"] as? [String: Any])
        #expect(body["data"] as? String == "AQI=")
        #expect(body["encoding"] as? String == "audio/wav")
        #expect(body["sample_rate"] as? Int == 16000)
        #expect(SarvamWire.socketRequest(try #require(SarvamWire.ttsURL()), apiKey: "k").value(forHTTPHeaderField: "Api-Subscription-Key") == "k")
    }

    @Test func dictationRequestCarriesModeAndWords() throws {
        let request = SarvamClient.makeSTTRequest(apiKey: "k", audio: Data([0]), mode: .codemix, languageCode: "hi-IN", keyterms: ["Sarvam"], boundary: "B")
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(body.contains("name=\"mode\"\r\n\r\ncodemix"))
        #expect(body.contains("name=\"keyterms\"\r\n\r\n[\"Sarvam\"]"))
        let plain = String(decoding: try #require(SarvamClient.makeSTTRequest(apiKey: "k", audio: Data([0]), mode: nil, boundary: "B").httpBody), as: UTF8.self)
        #expect(!plain.contains("name=\"mode\""))
    }

    @Test func voiceCatalogIsWellFormed() {
        #expect(SarvamClient.v4VoiceGroups.flatMap(\.speakers).count >= 180)
        for group in SarvamClient.v4VoiceGroups {
            #expect(!group.speakers.isEmpty)
            for speaker in group.speakers { #expect(speaker.split(separator: "_").count == 3 && speaker.contains("_\(group.tag)_")) }
        }
        #expect(SarvamClient.knownV4Speakers.contains("shubh_enhi_companion"))
        #expect(SarvamClient.speaker("shubh_enhi_companion", in: "hi-IN").contains("shubh_hi_"))
        #expect(SarvamClient.speaker("shubh_enhi_companion", in: "ta-IN").contains("_ta_"))
        #expect(SarvamClient.voiceTitle("shubh_enhi_companion").name == "Shubh")
    }
}

struct CallAudioTests {
    @Test func decodesWavThenRawChunks() throws {
        let decoder = CallAudioDecoder(sampleRate: 24000)
        let samples = Data(repeating: 0, count: 200)
        let wav = CloudListening.wavFile(pcm16: samples, sampleRate: 16000)
        let first = decoder.decode(wav, contentType: "audio/wav")
        #expect(first.first?.format.sampleRate == 16000)
        #expect(first.first?.frameLength == 100)
        // A chunk split inside a sample keeps the odd byte for the next one.
        let next = decoder.decode(Data(repeating: 0, count: 101), contentType: "audio/wav")
        #expect(next.first?.frameLength == 50)
        #expect(decoder.decode(Data([0]), contentType: "audio/wav").first?.frameLength == 1)
    }

    @Test func rawSamplesUseTheRateInTheType() {
        let decoder = CallAudioDecoder(sampleRate: 24000)
        #expect(decoder.decode(Data(repeating: 0, count: 8), contentType: "audio/l16;rate=8000").first?.format.sampleRate == 8000)
        let other = CallAudioDecoder(sampleRate: 24000)
        #expect(other.decode(Data(repeating: 0, count: 8), contentType: "audio/pcm").first?.format.sampleRate == 24000)
    }

    @Test func levelOfSilence() {
        #expect(CallMicConverter.decibels(of: Data(repeating: 0, count: 100)) <= -99)
        #expect(CallMicConverter.decibels(of: Data()) == -100)
    }

    @Test func speakableDropsMarkdown() {
        #expect(CallPrompt.speakable("**Hello** `world` [link](http://x)") == "Hello world link")
    }
}

struct BotCharacterTests {
    @Test func atLeastTwelveDistinctLooks() {
        #expect(BotCharacter.allCases.count >= 12)
        #expect(Set(BotCharacter.allCases.map(\.colors.0)).count == BotCharacter.allCases.count)
        #expect(Set(BotCharacter.allCases.map(\.title)).count == BotCharacter.allCases.count)
    }

    @Test func aBotKeepsItsLookAndNoTwinsWhenThereIsRoom() {
        #expect(BotCharacter.fromSeed("ada") == BotCharacter.fromSeed("ada"))
        var taken: [NativeBot] = []
        for index in 0..<BotCharacter.allCases.count {
            var bot = NativeBot(id: "b\(index)", name: "B", description: "", instructions: "", hue: 0, accentHue: 0, primary: false, provider: "claude", model: "m", effort: nil, apps: [], category: nil)
            bot.avatar = BotCharacter.firstFree(preferring: .pebble, among: taken).rawValue
            taken.append(bot)
        }
        #expect(Set(taken.compactMap(\.avatar)).count == BotCharacter.allCases.count)
        #expect(BotCharacter.firstFree(preferring: .gem, among: taken) == .gem)
    }
}
