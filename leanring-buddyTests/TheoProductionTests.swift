//
//  TheoProductionTests.swift
//  leanring-buddyTests
//
//  The parts that broke silently before: logos and symbols that render blank, provider requests, the streaming
//  parsers, and the facts a coding run reports.
//

import AppKit
import ClickyCore
import Foundation
import Testing
@testable import Clicky

@MainActor
struct TheoProductionTests {
    // MARK: Icons

    /// A symbol name macOS doesn't know draws nothing at all, so every one in the source is checked.
    @Test func everySymbolNameExists() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("leanring-buddy")
        let regex = try NSRegularExpression(pattern: #"(?:systemName|systemImage|symbol|glyph): "([a-z0-9.]+)""#)
        var missing: Set<String> = []
        var seen = 0
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            guard file.pathExtension == "swift", let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                let name = String(text[range])
                seen += 1
                if NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil { missing.insert(name) }
            }
        }
        #expect(seen > 100)
        #expect(missing.isEmpty, "Symbols that draw nothing: \(missing.sorted())")
    }

    @Test func everyHarnessHasItsLogoAndSetup() {
        for info in HarnessCatalog.all {
            #expect(BrandLogo.hasLogo(info.id), "No logo for \(info.id)")
            let setup = HarnessCatalog.setups[info.id]
            #expect(setup != nil, "No install or sign-in for \(info.id)")
            #expect(setup?.install.isEmpty == false)
        }
    }

    @Test func everyProviderHasItsLogo() {
        for provider in ProviderInfo.builtIn { #expect(BrandLogo.hasLogo(provider.id), "No logo for \(provider.id)") }
    }

    @Test func everyConnectorShowsSomething() {
        for connector in BotConnectors.known where connector.id != "theo" && connector.id != "studio" && connector.id != "hyperframes" {
            #expect(BrandLogo.hasLogo(connector.id), "No logo for \(connector.id)")
        }
    }

    // MARK: Providers

    @Test func everyProviderCanBeTestedAndCarriesItsKey() {
        for provider in ProviderInfo.builtIn where !provider.keyless {
            let request = ProviderInfo.testRequest(for: provider, key: "SECRETKEY")
            #expect(request != nil, "\(provider.id) can't be tested")
            let headers = request?.allHTTPHeaderFields?.values.joined() ?? ""
            if provider.id == "cursor" {
                #expect(headers.contains("Basic "))
            } else {
                #expect(headers.contains("SECRETKEY"), "\(provider.id) doesn't send the key")
            }
            // Never in the address, where it could end up in a log.
            #expect(request?.url?.absoluteString.contains("SECRETKEY") == false)
        }
    }

    @Test func providerErrorsAreReadable() {
        let body = Data(#"{"error":{"message":"Incorrect API key"}}"#.utf8)
        #expect(ProviderInfo.testFailure(statusCode: 200, body: Data()) == nil)
        #expect(ProviderInfo.testFailure(statusCode: 401, body: body)?.contains("Incorrect API key") == true)
        #expect(ProviderInfo.testFailure(statusCode: 429, body: Data())?.contains("rate limited") == true)
        #expect(ProviderInfo.testFailure(statusCode: 500, body: Data(#"<html>"#.utf8)) == "HTTP 500")
    }

    @Test func modelListsFromEveryShape() {
        #expect(ProviderInfo.modelIDs(from: Data(#"{"data":[{"id":"a"},{"id":"b"}]}"#.utf8)) == ["a", "b"])
        #expect(ProviderInfo.modelIDs(from: Data(#"{"models":[{"name":"models/gemini-3"}]}"#.utf8)) == ["gemini-3"])
        #expect(ProviderInfo.modelIDs(from: Data(#"[{"id":"x"}]"#.utf8)) == ["x"])
        #expect(ProviderInfo.modelIDs(from: Data("nope".utf8)).isEmpty)
    }

    @Test func customProviderNeedsAWebAddress() {
        #expect(CustomProviders.make(name: "Mine", baseURL: "not a url") == nil)
        #expect(CustomProviders.make(name: "", baseURL: "https://example.com/v1") == nil)
        let provider = CustomProviders.make(name: "Mine", baseURL: "https://example.com/v1/")
        #expect(provider?.baseURL == "https://example.com/v1")
        #expect(provider?.kind == .openAICompatible)
    }

    @Test func maskNeverShowsTheWholeKey() {
        let key = "sk-abcdefghijklmnop"
        let mask = ProviderKeys.mask(key)
        #expect(!mask.contains(key))
        #expect(!mask.contains("abcdefghijkl"))
        #expect(ProviderKeys.mask("short") == "••••")
    }

    // MARK: Streaming

    @Test func anthropicStream() {
        let delta = #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}"#
        #expect(APIChat.parse(line: delta, kind: .anthropic).text == "Hi")
        #expect(APIChat.parse(line: #"data: {"type":"message_stop"}"#, kind: .anthropic).done)
        #expect(APIChat.parse(line: "event: ping", kind: .anthropic).text == nil)
        #expect(APIChat.parse(line: #"data: {"error":{"message":"overloaded"}}"#, kind: .anthropic).error == "overloaded")
    }

    @Test func openAIStream() {
        #expect(APIChat.parse(line: #"data: {"choices":[{"delta":{"content":"Yo"}}]}"#, kind: .openAICompatible).text == "Yo")
        #expect(APIChat.parse(line: "data: [DONE]", kind: .openAICompatible).done)
        #expect(APIChat.parse(line: #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#, kind: .openAICompatible).text == nil)
    }

    @Test func chatRequestsPutTheSystemPromptWhereEachAPIWantsIt() throws {
        let messages = [APIChatMessage(role: "user", text: "hello")]
        let anthropic = try #require(ProviderInfo.builtIn.first { $0.id == "anthropic" })
        let request = try #require(APIChat.request(provider: anthropic, key: "K", model: "m", system: "S", messages: messages))
        let body = try #require(try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: Any])
        #expect(body["system"] as? String == "S")
        #expect(request.url?.absoluteString.hasSuffix("/messages") == true)

        let groq = try #require(ProviderInfo.builtIn.first { $0.id == "groq" })
        let openAI = try #require(APIChat.request(provider: groq, key: "K", model: "m", system: "S", messages: messages))
        let openAIBody = try #require(try JSONSerialization.jsonObject(with: try #require(openAI.httpBody)) as? [String: Any])
        #expect((openAIBody["messages"] as? [[String: Any]])?.first?["role"] as? String == "system")
        #expect(openAI.url?.absoluteString == "https://api.groq.com/openai/v1/chat/completions")
    }

    @Test func screenshotsTravelWithTheirMessage() throws {
        let image = APIChatMessage(role: "user", text: "what's this", imagesJPEGBase64: ["AAAA"])
        let provider = try #require(ProviderInfo.builtIn.first { $0.id == "openai" })
        let request = try #require(APIChat.request(provider: provider, key: "K", model: "m", system: "", messages: [image]))
        let text = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(text.contains("image_url"))
        #expect(text.contains("base64,AAAA"))
    }

    @Test func historyDropsScreenshots() {
        let session = "test-\(UUID().uuidString)"
        APIChat.History.save([APIChatMessage(role: "user", text: "hi", imagesJPEGBase64: ["AAAA"])], session: session)
        let loaded = APIChat.History.load(session)
        #expect(loaded.first?.text == "hi")
        #expect(loaded.first?.imagesJPEGBase64.isEmpty == true)
    }

    @Test func brainModelsCanRunOnAnAPIKey() {
        let model = BrainModel(setting: "api:groq/llama-4")
        #expect(model.provider == .api)
        #expect(model.modelIdentifier == "groq/llama-4")
        #expect(model.setting == "api:groq/llama-4")
        #expect(!BrainProvider.allCases.contains(.api))
        #expect(BrainModel(setting: "claude-sonnet-5-5").isClaude)
        #expect(BrainModel(setting: "api:lmstudio/qwen").sendsScreenshotsToThirdParty == false)
    }

    // MARK: Voice

    @Test func wavHeaderIsValid() {
        let wav = CloudListening.wavFile(pcm16: Data(repeating: 0, count: 320), sampleRate: 16000)
        #expect(wav.count == 364)
        #expect(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: wav[8..<12], as: UTF8.self) == "WAVE")
    }

    @Test func deepgramReply() {
        let reply = Data(#"{"results":{"channels":[{"alternatives":[{"transcript":"hello theo"}]}]}}"#.utf8)
        #expect(CloudListening.deepgramTranscript(reply) == "hello theo")
        #expect(CloudListening.deepgramTranscript(Data("{}".utf8)) == nil)
    }

    @Test func elevenLabsRequest() throws {
        let request = try #require(ElevenLabsClient.speechRequest(key: "K", voice: "v1", model: "m", text: "hi"))
        #expect(request.value(forHTTPHeaderField: "xi-api-key") == "K")
        #expect(request.url?.absoluteString.contains("/v1/text-to-speech/v1") == true)
    }

    // MARK: Sign-in

    @Test func signInLinkAndCodeFromTheScreen() {
        let screen = "Open this link to sign in:\nhttps://claude.ai/oauth/authorize?code=true&x=1\nand enter ABCD-1234 when asked"
        #expect(HarnessTerminalModel.link(in: screen)?.absoluteString == "https://claude.ai/oauth/authorize?code=true&x=1")
        #expect(HarnessTerminalModel.code(in: screen) == "ABCD-1234")
        #expect(HarnessTerminalModel.link(in: "nothing here") == nil)
        #expect(HarnessTerminalModel.code(in: "no code") == nil)
    }

    @Test func signInCommandsAreTheOnesTheCLIsDocument() {
        #expect(HarnessCatalog.setups["claude"]?.signIn == ["auth", "login"])
        #expect(HarnessCatalog.setups["codex"]?.signIn == ["login"])
        #expect(HarnessCatalog.setups["cursor"]?.signIn == ["login"])
        #expect(HarnessCatalog.setups["opencode"]?.signIn == ["auth", "login"])
        #expect(HarnessCatalog.setups["grok"]?.signIn == ["login"])
        #expect(HarnessCatalog.setups["gemini"]?.signIn.isEmpty == true)
    }

    // MARK: Coding runs

    @Test func runTitlesReadWell() {
        #expect(BotsT3.shortTitle(from: "fix the bug in add.js so the test passes, in ~/foo") == "Fix the bug in add.js")
        #expect(BotsT3.shortTitle(from: "build a todo app") == "Build a todo app")
    }

    @Test func findsTheFolderInAMessage() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("theo test \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(BotsT3.targetRepo(answer: "", pitch: "fix it in `\(folder.path)`")?.standardizedFileURL == folder.standardizedFileURL)
        #expect(BotsT3.targetRepo(answer: "", pitch: "fix it in /definitely/not/here") == nil)
        #expect(BotsT3.targetRepo(answer: "Repo: \(folder.path)", pitch: "")?.standardizedFileURL == folder.standardizedFileURL)
    }

    @Test func codingCommands() {
        #expect(BotsStore.isCodingCommand("@code fix it"))
        #expect(BotsStore.isCodingCommand("/run fix it"))
        #expect(BotsStore.isCodingCommand("hey @T3 do this"))
        #expect(!BotsStore.isCodingCommand("what's the weather"))
        #expect(BotsStore.isAboutExistingCode("fix the login bug"))
        #expect(!BotsStore.isAboutExistingCode("build a todo app"))
    }

    @Test func changedFilesFromGit() {
        let files = BotsT3.parseNumstat("12\t3\tsrc/a.swift\n-\t-\tlogo.png\n")
        #expect(files == [RunFileChange(path: "src/a.swift", added: 12, removed: 3), RunFileChange(path: "logo.png", added: 0, removed: 0)])
    }

    @Test func aFinishedTurnIsNoticedQuickly() {
        #expect(HarnessCoding.looksBusy("✻ Baking… (esc to interrupt)"))
        #expect(!HarnessCoding.looksBusy("✻ Baked for 19s · done 11:21 PM\n❯"))
    }

    @Test func aModelStaysWithItsHarness() {
        let before = HarnessPrefs.codingTarget
        defer { HarnessPrefs.codingTarget = before }
        HarnessPrefs.codingTarget = "claude"
        HarnessPrefs.codingModel = "claude-haiku-5-5"
        HarnessPrefs.codingTarget = "codex"
        #expect(HarnessPrefs.codingModel == nil)
    }

    // MARK: Cursor cloud agents

    @Test func cursorCloudRequests() {
        #expect(CursorCloud.webURL(fromRemote: "git@github.com:me/repo.git\n") == "https://github.com/me/repo")
        #expect(CursorCloud.webURL(fromRemote: "https://github.com/me/repo.git") == "https://github.com/me/repo")
        #expect(CursorCloud.webURL(fromRemote: "/tmp/local.git") == nil)
        let body = CursorCloud.startBody(prompt: "fix", repoURL: "https://github.com/me/repo", startingRef: "main")
        #expect(body["autoCreatePR"] as? Bool == true)
    }

    // MARK: Clicks

    @Test func firstClickPatchCoversSwiftUIContainers() {
        TheoFirstClick.install()
        #expect(NSView().acceptsFirstMouse(for: nil))
        #expect(NSScrollView().acceptsFirstMouse(for: nil))
        #expect(NSSwitch().acceptsFirstMouse(for: nil))
    }
}
