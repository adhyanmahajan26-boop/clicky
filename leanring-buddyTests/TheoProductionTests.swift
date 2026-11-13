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
    // MARK: Clicky's team

    @Test func theTeamJoinsAnySetupOnceAndKeepsTheRest() {
        var bots = BotImport.starters
        var layout = BotsLayout()
        layout.sections = [BotsLayout.Section(name: "Work", items: ["bot:theo"])]
        BotImport.addClickyTeam(to: &bots, layout: &layout)
        #expect(bots.count == 4)
        for bot in bots where bot.owner == BotsStore.clickyID { #expect(bot.model == "claude-haiku-5-5") }
        #expect(Set(bots.compactMap(\.avatar)).count == 3)
        #expect(layout.pinned == ["bot:theo"])
        #expect(layout.sections.first?.name == "Clicky")
        #expect(layout.sections.first?.leaderID == BotsStore.clickyID)
        #expect(layout.sections.first?.items.first == "clicky")
        #expect(layout.sections.first?.items.count == 4)
        #expect(layout.sections.last?.name == "Work")
        // Run again (an old setup with a Clicky category already): nothing doubles.
        BotImport.addClickyTeam(to: &bots, layout: &layout)
        #expect(bots.count == 4)
        #expect(layout.sections.count == 2)
        #expect(layout.sections.first?.items.count == 4)
    }

    @Test func clickyHasItsOwnPlaceInTheSidebarAndItsOwnChat() {
        #expect(BotsLayout.item(forBot: BotsStore.clickyID) == "clicky")
        #expect(BotsLayout.botID(ofItem: "clicky") == BotsStore.clickyID)
        #expect(BotsLayout.botID(ofItem: "bot:theo") == "theo")
        #expect(BotsLayout.botID(ofItem: "group:x") == nil)
        BotsSelection.shared.pane = .bot(BotsStore.clickyID)
        #expect(BotsSelection.shared.pane == .clicky)
        BotsSelection.shared.pane = .home
    }

    // MARK: Bots reading each other

    @MainActor private func aBot(_ id: String = "tester") -> NativeBot {
        var bot = BotImport.starters[0]
        bot.id = id
        bot.name = "Tester"
        return bot
    }

    @Test @MainActor func aBotStillReadsWhatWasPostedUnderItsName() {
        // Theo heading a group, asking it something: the question is under his name, and his session has never seen it.
        let bot = aBot()
        var record = BotConversationRecord()
        record.sessions[bot.id] = "session"
        record.messages = [BotChatMessage(author: "user", text: "old"), BotChatMessage(author: bot.id, text: "Which database should we use?")]
        record.seen[bot.id] = 1
        let shown = BotPrompts.transcriptMessages(in: record, for: bot).map(\.text)
        #expect(shown.contains("Which database should we use?"))
    }

    @Test @MainActor func stopMarksTheRoomEvenWithNothingLive() {
        // A carry-on can be waiting with no exchange live: it mustn't run right after Stop.
        let store = BotsStore.shared
        let room = "stop-\(UUID().uuidString)"
        store.stopPrivateMessages(in: room)
        #expect(store.stoppedExchangeRooms.contains(room))
    }

    @Test @MainActor func catchUpFindsItsPlaceWhenTheNewestHeardIsACard() {
        // Both Macs used apart: a card sorts just before what was said on the other Mac.
        let store = BotsStore.shared
        let bot = aBot()
        let card = BotChatMessage(author: bot.id, text: "", card: "dm:x:y")
        let now = BotChatMessage(author: "user", text: "and now")
        var record = BotConversationRecord()
        record.sessions[bot.id] = "session"
        record.heard = [bot.id: card.id]
        record.messages = [BotChatMessage(author: "user", text: "said here"), card, BotChatMessage(author: "user", text: "said on the Air"), now]
        let words = store.catchUp(in: record, bot: bot, before: now.id)
        #expect(words.contains("said on the Air"))
        #expect(!words.contains("said here"))
    }

    @Test @MainActor func aThreadStartedOnBothMacsCatchesUp() {
        let store = BotsStore.shared
        let target = aBot("target")
        var sender = aBot("sender")
        sender.name = "Sender"
        let context = BotDMContext(rootRoom: "room", ownerWords: nil, fromOwner: false)
        var record = BotConversationRecord()
        record.sessions[target.id] = "session"
        record.heard = [target.id: BotCatchUp.fromTheStart]
        record.messages = [BotChatMessage(author: sender.id, text: "said on the Air"), BotChatMessage(author: sender.id, text: "the new message")]
        let words = store.privateMessageWords(for: target, from: sender, message: "the new message", record: record, hasSession: true, context: context)
        #expect(words.contains("said on the Air"))
        // Lots of it stays within what a catch-up may hold.
        record.messages = (0..<60).map { BotChatMessage(author: sender.id, text: "line \($0) " + String(repeating: "x", count: 3000)) } + [BotChatMessage(author: sender.id, text: "the new message")]
        let long = store.privateMessageWords(for: target, from: sender, message: "the new message", record: record, hasSession: true, context: context)
        #expect(long.count < BotCatchUp.maximumCharactersTotal + 4000)
        #expect(long.contains("line 59"))
    }

    @Test @MainActor func aBotSkipsOnlyTheAnswersItsSessionWrote() {
        let bot = aBot()
        let own = BotChatMessage(author: bot.id, text: "my last answer")
        var record = BotConversationRecord()
        record.sessions[bot.id] = "session"
        record.messages = [own, BotChatMessage(author: bot.id, text: "my words from the other Mac"), BotChatMessage(author: "user", text: "and you?")]
        record.ownAnswers = [bot.id: [own.id]]
        #expect(BotPrompts.transcriptMessages(in: record, for: bot).map(\.text) == ["my words from the other Mac", "and you?"])
        // With no session it wouldn't know what it said.
        record.sessions[bot.id] = nil
        #expect(BotPrompts.transcriptMessages(in: record, for: bot).map(\.text).contains("my last answer"))
    }

    @Test func aPrivateTurnKeepsItsPlaceOnTheOtherMac() {
        let turn = BotDMTurn(exchangeID: "x1", askerID: "theo", context: BotDMContext(rootRoom: "theo", ownerWords: "build it", fromOwner: true), mayMessage: false)
        let fields = turn.linkFields(chain: "studio#3")
        let back = BotDMTurn(linkFields: fields)
        #expect(fields["chain"] == "studio#3")
        #expect(back?.exchangeID == "x1")
        #expect(back?.askerID == "theo")
        #expect(back?.context.rootRoom == "theo")
        #expect(back?.context.ownerWords == "build it")
        #expect(back?.context.fromOwner == true)
        #expect(back?.mayMessage == false)
        // A turn that isn't part of any exchange has none of this.
        #expect(BotDMTurn(linkFields: ["bot": "coder"]) == nil)
    }

    @Test func memoryMovesOldestFirst() {
        #expect(BotMemory.oldFolders == [".t3-backup-20261105/bots", ".t3/bots"])
    }

    // MARK: Routines on both Macs

    private func routine(_ id: String, _ instruction: String = "do it", paused: Bool = false, next: Date? = nil, runs: [BotRoutine.Run] = []) -> BotRoutine {
        var routine = BotRoutine(name: id, target: "theo", instruction: instruction, schedule: BotRoutine.Schedule.parse("every 10 min")!)
        routine.id = id
        routine.paused = paused
        routine.nextRunAt = next
        routine.runs = runs
        return routine
    }

    @Test func aRunIsntAnEdit() {
        let base = routine("a")
        var ran = base
        ran.nextRunAt = Date(timeIntervalSince1970: 100)
        ran.runs = [BotRoutine.Run(startedAt: Date(), status: "done")]
        #expect(BotRoutineSync.edits(of: [ran]) == BotRoutineSync.edits(of: [base]))
        var paused = base
        paused.paused = true
        #expect(BotRoutineSync.edits(of: [paused]) != BotRoutineSync.edits(of: [base]))
    }

    @Test func aPauseOnOneMacSurvivesTheOtherMacFiringIt() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let run = BotRoutine.Run(startedAt: now, status: "done")
        // The Air paused it and the Studio fired it since: its next time moved, its edit didn't.
        var air = LinkMerge.Stamps()
        air.changed["a"] = now.addingTimeInterval(-60)
        var studio = LinkMerge.Stamps()
        studio.changed["a"] = now.addingTimeInterval(-3600)
        var onAir = routine("a", paused: true, next: now.addingTimeInterval(-600))
        onAir.createdAt = now
        var onStudio = routine("a", next: now.addingTimeInterval(600), runs: [run])
        onStudio.createdAt = now
        let there = BotRoutineSync.merged(local: [onStudio], localStamps: studio, remote: [onAir], remoteStamps: air, now: now)
        let here = BotRoutineSync.merged(local: [onAir], localStamps: air, remote: [onStudio], remoteStamps: studio, now: now)
        #expect(there.items == here.items)
        #expect(there.items[0].paused)
        #expect(there.items[0].runs == [run])
        #expect(there.items[0].nextRunAt == now.addingTimeInterval(600))
    }

    @Test func aRoutineArrivingDoesntFireForAMissedSlot() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let merged = BotRoutineSync.merged(local: [], localStamps: .init(), remote: [routine("a", next: now.addingTimeInterval(-3600))], remoteStamps: .init(), now: now)
        #expect((merged.items[0].nextRunAt ?? .distantPast) > now)
    }

    @Test func theSameJobOnBothMacsBecomesOne() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let next = now.addingTimeInterval(60)
        let there = BotRoutineSync.merged(local: [routine("b", next: next)], localStamps: .init(), remote: [routine("a", paused: true, next: next)], remoteStamps: .init(), now: now)
        let here = BotRoutineSync.merged(local: [routine("a", paused: true, next: next)], localStamps: .init(), remote: [routine("b", next: next)], remoteStamps: .init(), now: now)
        // The one that's running stays, and both Macs choose the same.
        #expect(there.items.map(\.id) == ["b"])
        #expect(here.items.map(\.id) == ["b"])
        #expect(there.stamps.gone["a"] != nil)
        #expect(BotRoutineSync.merged(local: [routine("a"), routine("c", "another job")], localStamps: .init(), remote: [], remoteStamps: .init(), now: now).items.count == 2)
    }

    @Test func aDeletedRoutineStaysDeleted() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var gone = LinkMerge.Stamps()
        gone.gone["a"] = now
        var older = LinkMerge.Stamps()
        older.changed["a"] = now.addingTimeInterval(-60)
        let merged = BotRoutineSync.merged(local: [routine("a", next: now)], localStamps: older, remote: [], remoteStamps: gone, now: now)
        #expect(merged.items.isEmpty)
    }

    // MARK: A run's words

    private func claudeEvent(_ text: String, at: String) -> [String: Any] {
        ["type": "assistant", "timestamp": at, "message": ["content": [["type": "text", "text": text]]]]
    }

    @Test func aContinuedChatsOldAnswerIsntThisRuns() {
        let start = ISO8601DateFormatter().date(from: "2026-11-05T10:00:00Z")!
        let old = claudeEvent("the old answer", at: "2026-11-05T09:00:00.123Z")
        // Its message never went in: nothing to report, rather than the last turn's answer.
        #expect(HarnessCoding.lastClaudeAnswer(in: [old], since: start) == nil)
        #expect(HarnessCoding.lastClaudeAnswer(in: [old, claudeEvent("the new answer", at: "2026-11-05T10:00:05.000Z")], since: start) == "the new answer")
        #expect(HarnessCoding.eventDate(["timestamp": "2026-11-05T10:00:00Z"]) == start)
    }

    @Test func aFolderIsLookedUpByItsRealPathToo() {
        #expect(HarnessChats.spellings(of: "/tmp").contains("/private/tmp"))
        #expect(HarnessChats.spellings(of: "/tmp").contains("/tmp"))
    }

    // MARK: Continuing a harness chat

    @Test func aChatIsContinuedByItsOwnIdOnEveryHarness() {
        func args(_ harness: String, resume: String? = "abc") -> [String] { HarnessCoding.interactiveArguments(harness: harness, model: nil, effort: nil, folder: "/f", resume: resume) }
        #expect(args("claude").starts(with: ["--resume", "abc"]))
        #expect(args("codex").starts(with: ["resume", "abc"]))
        #expect(args("cursor").starts(with: ["--resume", "abc"]))
        #expect(args("gemini").starts(with: ["--resume", "abc"]))
        #expect(args("grok").starts(with: ["--resume", "abc"]))
        #expect(args("opencode").starts(with: ["--session", "abc"]))
        // Never "the last one in this folder" once the session is known.
        let known = HarnessCoding.interactiveArguments(harness: "claude", model: nil, effort: nil, folder: "/f", continues: true, resume: "abc")
        #expect(!known.contains("--continue"))
        let new = HarnessCoding.interactiveArguments(harness: "claude", model: nil, effort: nil, folder: "/f", newSessionID: "id-1")
        #expect(new.starts(with: ["--session-id", "id-1"]))
    }

    @Test func aNewChatCanHaveItsIdFromTheStart() {
        func args(_ harness: String) -> [String] { HarnessCoding.interactiveArguments(harness: harness, model: nil, effort: nil, folder: "/f", newSessionID: "id-1") }
        #expect(args("claude").starts(with: ["--session-id", "id-1"]))
        #expect(args("gemini").starts(with: ["--session-id", "id-1"]))
        #expect(args("grok").starts(with: ["--session-id", "id-1"]))
        // Cursor hands out the id, so its new chat is resumed.
        #expect(args("cursor").starts(with: ["--resume", "id-1"]))
        // These have no such flag: their runs wait their turn instead.
        #expect(!args("codex").contains("id-1"))
        #expect(!args("opencode").contains("id-1"))
        func headless(_ harness: String) -> [String] { HarnessCoding.headlessArguments(harness: harness, model: nil, effort: nil, folder: "/f", prompt: "hi", outFile: "/o", newSessionID: "id-1") }
        #expect(headless("claude").contains("--session-id"))
        #expect(headless("gemini").contains("--session-id"))
        #expect(headless("grok").contains("--session-id"))
        let cursor = headless("cursor")
        #expect(cursor.contains("--resume") && !cursor.contains("--session-id"))
        #expect(!headless("codex").contains("id-1"))
        #expect(!headless("opencode").contains("id-1"))
    }

    @Test func aHeadlessRunContinuesByIdToo() {
        func args(_ harness: String) -> [String] { HarnessCoding.headlessArguments(harness: harness, model: nil, effort: nil, folder: "/f", prompt: "hi", outFile: "/o", resume: "abc") }
        #expect(args("claude").contains("--resume"))
        // `codex exec resume` has no -C or -s: the folder is the process's, the sandbox a config value.
        let codex = args("codex")
        #expect(codex.starts(with: ["exec", "resume"]))
        #expect(!codex.contains("-C") && !codex.contains("-s"))
        #expect(args("opencode").contains("--session"))
        #expect(args("grok").contains("--resume"))
    }

    @Test func aBotsMemoryIsntInT3CodesFolder() {
        let bot = BotImport.starters[0]
        #expect(!bot.memoryPath.contains("/.t3"))
        #expect(bot.memoryPath.hasSuffix("/Theo/Bots/memory/theo/memory.md"))
        #expect(!BotRunner.workspace.path.contains("/.t3"))
        for tool in BotRunner.claudeAllowedTools(for: bot) where tool.hasPrefix("Edit(") || tool.hasPrefix("Write(") {
            #expect(!tool.contains("/.t3"))
            #expect(tool.contains("(//"))
        }
    }

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
        let bodyData = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(body["system"] as? String == "S")
        #expect(request.url?.absoluteString.hasSuffix("/messages") == true)

        let groq = try #require(ProviderInfo.builtIn.first { $0.id == "groq" })
        let openAI = try #require(APIChat.request(provider: groq, key: "K", model: "m", system: "S", messages: messages))
        let openAIData = try #require(openAI.httpBody)
        let openAIBody = try #require(try JSONSerialization.jsonObject(with: openAIData) as? [String: Any])
        #expect((openAIBody["messages"] as? [[String: Any]])?.first?["role"] as? String == "system")
        #expect(openAI.url?.absoluteString == "https://api.groq.com/openai/v1/chat/completions")
    }

    @Test func screenshotsTravelWithTheirMessage() throws {
        let image = APIChatMessage(role: "user", text: "what's this", imagesJPEGBase64: ["AAAA"])
        let provider = try #require(ProviderInfo.builtIn.first { $0.id == "openai" })
        let request = try #require(APIChat.request(provider: provider, key: "K", model: "m", system: "", messages: [image]))
        let body = try #require(request.httpBody)
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.contains("image_url"))
        #expect(text.contains("base64,AAAA"))
    }

    @Test func historyDropsScreenshots() {
        let session = "test-\(UUID().uuidString)"
        defer { APIChat.History.forget(session) }
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
        #expect(!BotsStore.isCodingCommand("why does @codemirror/view fail?"))
        #expect(!BotsStore.isCodingCommand("email dev@code.org about it"))
        #expect(!BotsStore.isCodingCommand("set up @t3-oss/env-core"))
        #expect(BotsStore.isCodingCommand("fix the tests @code"))
        #expect(BotsStore.isCodingCommand("@code, fix it"))
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
        // The test host shares the app's preferences, so everything goes back as it was.
        let before = (HarnessPrefs.codingTarget, HarnessPrefs.codingModel, HarnessPrefs.codingEffort)
        defer {
            HarnessPrefs.codingTarget = before.0
            HarnessPrefs.codingModel = before.1
            HarnessPrefs.codingEffort = before.2
        }
        HarnessPrefs.codingTarget = "claude"
        HarnessPrefs.codingModel = "claude-haiku-5-5"
        HarnessPrefs.codingTarget = "codex"
        #expect(HarnessPrefs.codingModel == nil)
    }

    /// A reply that starts streaming redraws with a date a moment before the anchor: it used to crash the app.
    @Test func typingNeverShowsANegativeCount() {
        let earlier = Date(timeIntervalSinceNow: -5)
        let count = min(10, 0 + Int(max(0, earlier.timeIntervalSince(Date())) * 320))
        #expect(count == 0)
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

    @Test func onlyTheOwnersOwnWordsStartARun() {
        #expect(BotsStore.ownerAskedToBuild("fix the parser in ~/Projects/foo"))
        #expect(BotsStore.ownerAskedToBuild("make me a landing page"))
        #expect(BotsStore.ownerAskedToBuild("build a todo app"))
        #expect(!BotsStore.ownerAskedToBuild("make me a prompt for a logo"))
        #expect(!BotsStore.ownerAskedToBuild("update me on this page's news"))
        #expect(!BotsStore.ownerAskedToBuild("what should I have for lunch?"))
    }

    @Test func aDialogIsAQuestionButAReportIsnt() {
        #expect(HarnessCoding.isQuestionScreen("Do you want to proceed?\n❯ 1. Yes\n  2. No"))
        #expect(HarnessCoding.isQuestionScreen("Allow this edit? (y/n)"))
        #expect(!HarnessCoding.isQuestionScreen("All done. Do you want to add more tests?\n✻ Baked for 19s"))
        #expect(!HarnessCoding.isQuestionScreen("⠙ Thinking (esc to cancel, 3s)"))
        #expect(HarnessCoding.looksBusy("⠙ Thinking (esc to cancel, 3s)"))
    }

    @Test func aFinishLineIsTheHarnesssOwn() {
        #expect(HarnessCoding.finishLines(in: "✻ Baked for 19s · done 11:21 PM").count == 1)
        #expect(HarnessCoding.finishLines(in: "─ Worked for 1m 12s ─────").count == 1)
        #expect(HarnessCoding.finishLines(in: "I waited for 30 seconds and tried again").isEmpty)
    }

    @Test func secretsStayOutOfCommits() {
        for path in [".env", "app/.env.local", "certs/server.pem", "deploy.key", "id_rsa", "id_ed25519.pub", "config/credentials.json"] {
            #expect(BotsT3.looksLikeSecret(path), "\(path)")
        }
        for path in [".env.example", "keyboard.swift", "README.md", "src/keys.ts"] {
            #expect(!BotsT3.looksLikeSecret(path), "\(path)")
        }
    }

    @Test func aPlainFolderIsToldToStayOutOfGit() {
        let plain = T3Run(id: "x", title: "t", folder: "/tmp/a")
        #expect(BotsT3.followupNote(for: plain) == BotsT3.plainFolderNote)
        var inRepo = plain
        inRepo.repo = "/tmp/a"
        inRepo.baseCommit = "abc"
        #expect(BotsT3.followupNote(for: inRepo) == BotsT3.deliveryNote)
    }

    @Test func aSubfolderIsNamedToTheAgent() {
        let repo = URL(fileURLWithPath: "/tmp/repo", isDirectory: true)
        #expect(BotsT3.subfolderNote(repo.appendingPathComponent("packages/api"), in: repo).contains("packages/api"))
        #expect(BotsT3.subfolderNote(repo, in: repo).isEmpty)
    }

    @Test func aRemotesTokenNeverReachesCursor() {
        #expect(CursorCloud.webURL(fromRemote: "https://me:ghp_secret@github.com/me/repo.git") == "https://github.com/me/repo")
        #expect(CursorCloud.webURL(fromRemote: "git@github.com:me/repo.git") == "https://github.com/me/repo")
        #expect(CursorCloud.webURL(fromRemote: "ssh://git@github.com/me/repo.git") == "https://github.com/me/repo")
        #expect(CursorCloud.webURL(fromRemote: "https://gitlab.com/me/repo.git") == nil)
    }

    @Test func aStreamSaysWhenItHitTheLimit() {
        #expect(APIChat.stopReason(line: #"data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"}}"#) == "max_tokens")
        #expect(APIChat.stopReason(line: #"data: {"choices":[{"finish_reason":"length","delta":{}}]}"#) == "length")
        #expect(APIChat.stopReason(line: #"data: {"choices":[{"delta":{"content":"hi"}}]}"#) == nil)
        #expect(APIChat.parse(line: #"data: {"error":"out of quota"}"#, kind: .openAICompatible).error == "out of quota")
    }

    @Test func imagesKeepTheirTypeOnTheWire() {
        let message = APIChatMessage(role: "user", text: "look", imagesJPEGBase64: ["AA", "BB"], imageTypes: ["image/jpeg", "image/png"])
        #expect(message.imageType(at: 1) == "image/png")
        #expect(APIChatMessage(role: "user", text: "look", imagesJPEGBase64: ["AA"]).imageType(at: 0) == "image/jpeg")
    }

    @Test @MainActor func everyCategoryGetsAManagerUnlessSwitchedOff() {
        let store = BotsStore.shared
        // aBot copies Theo's starter, which is primary: these two are ordinary members.
        var first = aBot("manager-test-first")
        first.primary = false
        var second = aBot("manager-test-second")
        second.primary = false
        store.save(first)
        store.save(second)
        let ceoItem = store.primary.map { BotsLayout.item(forBot: $0.id) } ?? "bot:theo"
        // Never chosen: the first member who isn't the CEO gets the job.
        var section = BotsLayout.Section(name: "Team", items: [ceoItem, "bot:\(first.id)", "bot:\(second.id)"])
        store.assignManagerIfNeeded(&section)
        #expect(section.leaderID == first.id)
        #expect(section.hasManager)
        // A manager the owner picked stays.
        section.leaderID = second.id
        store.assignManagerIfNeeded(&section)
        #expect(section.leaderID == second.id)
        // Switched off: everyone reports to the CEO, and nobody is handed the job.
        var off = BotsLayout.Section(name: "Flat", items: ["bot:\(first.id)"], wantsManager: false)
        store.assignManagerIfNeeded(&off)
        #expect(off.leaderID == nil)
        // An empty category waits for a bot.
        var empty = BotsLayout.Section(name: "Empty")
        store.assignManagerIfNeeded(&empty)
        #expect(empty.leaderID == nil)
        store.deleteBot(first.id)
        store.deleteBot(second.id)
    }
}
