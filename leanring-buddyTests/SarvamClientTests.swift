//
//  SarvamClientTests.swift
//  leanring-buddyTests
//

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
