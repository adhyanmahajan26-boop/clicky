//
//  QwenP3HostedTests.swift
//  leanring-buddyTests
//
//  P3 hosted tests for the Qwen client, against a URLProtocol stub (no
//  server, no audio): the exact request, WAV pass-through, a refusing
//  server, the watchdog, /v1/models, and that the supervisor does nothing
//  under XCTest. DEFERRED: compiled with build-for-testing in silent mode;
//  `xcodebuild test` starts the app binary, so they run with the live
//  checks (docs/v2/PENDING_LIVE_TESTS.md, P3).
//

import ClickyCore
import Foundation
import Testing
@testable import Clicky

/// Answers every request from `handler`, after `delaySeconds`.
final class QwenStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var delaySeconds: TimeInterval = 0
    nonisolated(unsafe) static var lastRequestBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequestBody = request.httpBody ?? request.httpBodyStream.map(Self.readAll)
        let (statusCode, body) = Self.handler?(request) ?? (404, Data())
        let respond = { [weak self] in
            guard let self, let url = self.request.url else { return }
            let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "audio/wav"])!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: body)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        if Self.delaySeconds > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.delaySeconds, execute: respond)
        } else {
            respond()
        }
    }

    override func stopLoading() {}

    private static func readAll(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let readCount = stream.read(&buffer, maxLength: buffer.count)
            if readCount <= 0 { break }
            data.append(buffer, count: readCount)
        }
        return data
    }
}

/// A 16-bit mono 24 kHz WAV of `sampleCount` silent samples (mlx-serve's format).
private func stubWAV(sampleCount: Int = 2400) -> Data {
    func le32(_ value: UInt32) -> [UInt8] { withUnsafeBytes(of: value.littleEndian) { Array($0) } }
    func le16(_ value: UInt16) -> [UInt8] { withUnsafeBytes(of: value.littleEndian) { Array($0) } }
    let payload = [UInt8](repeating: 0, count: sampleCount * 2)
    var bytes: [UInt8] = Array("RIFF".utf8) + le32(UInt32(36 + payload.count)) + Array("WAVE".utf8)
    bytes += Array("fmt ".utf8) + le32(16) + le16(1) + le16(1) + le32(24_000) + le32(48_000) + le16(2) + le16(16)
    bytes += Array("data".utf8) + le32(UInt32(payload.count)) + payload
    return Data(bytes)
}

@MainActor
private func makeStubbedClient() -> QwenLocalTTSClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [QwenStubURLProtocol.self]
    QwenStubURLProtocol.delaySeconds = 0
    QwenStubURLProtocol.lastRequestBody = nil
    return QwenLocalTTSClient(urlSession: URLSession(configuration: configuration))
}

@MainActor
@Suite("P3 Qwen client (hosted, deferred)", .serialized)
struct QwenP3HostedTests {

    @Test func requestCarriesExactlyTheProbedKeys() throws {
        let client = makeStubbedClient()
        let request = try client.makeSpeechRequest(for: "Open PR #12 in Xcode.")
        #expect(request.url?.path == "/v1/audio/speech")
        #expect(request.httpMethod == "POST")
        let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        #expect(Set(body.keys) == ["model", "input", "speaker", "instruct", "language", "response_format", "max_tokens"])
        #expect(body["input"] as? String == "Open P R number 12 in X code.")
        #expect(body["response_format"] as? String == "wav")
        #expect(body["language"] as? String == "English")
        #expect(body["model"] as? String == client.modelIdentifier)
    }

    @Test func synthesisReturnsTheServersWAV() async throws {
        let client = makeStubbedClient()
        let wav = stubWAV()
        QwenStubURLProtocol.handler = { _ in (200, wav) }
        let audioData = try await client.synthesizeSpeech(for: "Okay, found it.")
        #expect(audioData == wav)
        #expect(PCMAudio(wavData: audioData)?.sampleRate == 24_000)
    }

    @Test func refusingServerIsAHardError() async {
        let client = makeStubbedClient()
        QwenStubURLProtocol.handler = { _ in (500, Data("{}".utf8)) }
        await #expect(throws: QwenLocalTTSError.self) {
            _ = try await client.synthesizeSpeech(for: "Okay, found it.")
        }
    }

    @Test func slowServerTripsTheWatchdog() async {
        let client = makeStubbedClient()
        QwenStubURLProtocol.handler = { _ in (200, stubWAV()) }
        QwenStubURLProtocol.delaySeconds = 0.5
        await #expect(throws: QwenSlowSynthesisError.self) {
            _ = try await client.synthesizeSpeech(for: "Okay, found it.", watchdogSeconds: 0.1)
        }
    }

    @Test func modelsListIsParsed() async throws {
        let client = makeStubbedClient()
        let models = #"{"object":"list","data":[{"id":"mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16","loaded":true}]}"#
        QwenStubURLProtocol.handler = { _ in (200, Data(models.utf8)) }
        let parsed = try #require(await client.fetchModels())
        #expect(QwenSupervisor.ttsModelIdentifier(fromModels: parsed) == "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16")
    }

    @Test func supervisorStaysOffUnderXCTest() {
        let supervisor = QwenServerSupervisor(client: makeStubbedClient())
        #expect(QwenServerSupervisor.isRunningUnderXCTest)
        supervisor.start()
        #expect(supervisor.isUnavailable)
        #expect(!supervisor.isReady)
    }
}
