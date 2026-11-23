import Testing
@testable import ClickyCore

struct ThinkingTextTests {
    /// Feeds `reply` in pieces of `size` characters, as a stream would, and checks the shown text only ever grows.
    private func streamed(_ reply: String, size: Int, holdsUntilSure: Bool = false) -> (pieces: [String], final: String) {
        var shown: [String] = []
        var soFar = ""
        var rest = Substring(reply)
        while !rest.isEmpty {
            soFar += rest.prefix(size)
            rest = rest.dropFirst(size)
            shown.append(ThinkingText.visible(soFar, isComplete: false, holdsUntilSure: holdsUntilSure))
        }
        return (shown, ThinkingText.visible(reply, isComplete: true, holdsUntilSure: holdsUntilSure))
    }

    private func onlyGrows(_ pieces: [String]) -> Bool {
        zip(pieces, pieces.dropFirst()).allSatisfy { $1.hasPrefix($0) }
    }

    @Test func aReplyThatOpensWithThinkingShowsOnlyTheAnswer() {
        let reply = "<think>\nThe owner wants a short answer. Say Paris.\n</think>\n\nIt's Paris."
        #expect(ThinkingText.visible(reply, isComplete: true) == "It's Paris.")
        for size in [1, 3, 7, 50] {
            let run = streamed(reply, size: size)
            #expect(onlyGrows(run.pieces), "size \(size)")
            let leaked = run.pieces.contains { $0.contains("owner wants") || $0.contains("<") }
            #expect(!leaked)
            #expect(run.final == "It's Paris.")
        }
    }

    @Test func aReplyThatStartsMidThinkDropsEverythingBeforeTheClosingTag() {
        let reply = "Okay, they asked about the sky. Rayleigh scattering.\n</think>\n\nBecause blue light scatters more."
        #expect(ThinkingText.visible(reply, isComplete: true) == "Because blue light scatters more.")
        // A model that may start mid-think is held until it's sure, so nothing of the thinking is ever passed on.
        for size in [1, 4, 9, 64] {
            let run = streamed(reply, size: size, holdsUntilSure: true)
            #expect(onlyGrows(run.pieces), "size \(size)")
            let leaked = run.pieces.contains { $0.contains("Rayleigh") }
            #expect(!leaked)
            #expect(run.final == "Because blue light scatters more.")
        }
    }

    @Test func thinkingThatNeverClosesIsNeverShown() {
        let reply = "<think>Let me work this out step by step and then"
        #expect(ThinkingText.visible(reply, isComplete: true) == "")
        let shownWhileStreaming = streamed(reply, size: 5).pieces.filter { !$0.isEmpty }
        #expect(shownWhileStreaming.isEmpty)
        #expect(ThinkingText.visible("Sure. <think>hidden plan", isComplete: true) == "Sure.")
    }

    @Test func aHeldModelWithNoThinkingShowsItsWholeAnswerAtTheEnd() {
        let reply = "Hello there, nice to hear you."
        let run = streamed(reply, size: 6, holdsUntilSure: true)
        let shownEarly = run.pieces.dropLast().filter { !$0.isEmpty }
        #expect(shownEarly.isEmpty)
        #expect(run.final == reply)
    }

    @Test func anEmptyThinkBlockAndLaterBlocksGo() {
        #expect(ThinkingText.visible("<think>\n\n</think>\n\nHi!", isComplete: true) == "Hi!")
        #expect(ThinkingText.visible("One. <think>aside</think>Two.", isComplete: true) == "One. Two.")
        #expect(ThinkingText.visible("<THINK>x</THINK>Caps", isComplete: true) == "Caps")
    }

    @Test func plainTextStreamsAsItComesAndAHalfTagIsHeld() {
        let reply = "Plain answer with no thinking at all."
        let run = streamed(reply, size: 4)
        #expect(onlyGrows(run.pieces))
        #expect(run.pieces.first == "Plai")
        #expect(run.final == reply)
        #expect(ThinkingText.visible("So <thi", isComplete: false) == "So ")
        #expect(ThinkingText.visible("a < b", isComplete: false) == "a < b")
    }

    @Test func whichModelsAreHeldAndWhichLinesCarryReasoning() {
        #expect(ThinkingText.mayThinkWithoutOpeningTag(model: "qwen3.8-27b-uncensored-mlx"))
        #expect(ThinkingText.mayThinkWithoutOpeningTag(model: "deepseek-r1-distill-qwen-14b"))
        #expect(!ThinkingText.mayThinkWithoutOpeningTag(model: "gpt-6-mini"))
        #expect(!ThinkingText.mayThinkWithoutOpeningTag(model: "claude-sonnet-5-5"))
        #expect(ThinkingText.lineCarriesReasoning(#"data: {"choices":[{"delta":{"reasoning_content":"hmm"}}]}"#))
        #expect(ThinkingText.lineCarriesReasoning(#"data: {"choices":[{"delta":{"reasoning":"hmm"}}]}"#))
        #expect(!ThinkingText.lineCarriesReasoning(#"data: {"choices":[{"delta":{"content":"hi"}}]}"#))
        #expect(!ThinkingText.lineCarriesReasoning("data: [DONE]"))
    }
}

struct CallAnyBotTests {
    private func streamed(_ reply: String, size: Int) -> String {
        var stream = CallBracketLineStream()
        var speech = ""
        var rest = Substring(reply)
        while !rest.isEmpty {
            speech += stream.feed(String(rest.prefix(size)))
            rest = rest.dropFirst(size)
        }
        return speech + stream.finish()
    }

    @Test func anotherBotsPromptHasItsOwnNameMemoryAndChatAndNoneOfVellosControls() {
        let prompt = CallPromptText.otherBot(
            name: "Ledger", instructions: "You keep the books.\n\nYour nature:\nDry and exact.", owner: "Sam",
            languageRule: "Answer in English.", reportingLines: ["You report to Vello."],
            memorySection: "Your memory: the rent is due on the 5th.",
            recentChat: [.init(isFromOwner: true, text: "What's left this month?"), .init(isFromOwner: false, text: "About 400.\nMostly food.")])
        #expect(prompt.hasPrefix("You are Ledger.\n\nYou keep the books."))
        #expect(prompt.contains("Your nature:\nDry and exact."))
        #expect(prompt.contains("live voice call with Sam"))
        #expect(prompt.contains("On this call you only talk."))
        #expect(prompt.contains("Answer in English."))
        #expect(prompt.contains("You report to Vello."))
        #expect(prompt.contains("the rent is due on the 5th"))
        #expect(prompt.contains("Sam: What's left this month?"))
        #expect(prompt.contains("Ledger: About 400. Mostly food."))
        for control in ["[CLICKY", "[POINTER", "[ROUTINE", "[TELL", "Pointer Assistant"] {
            #expect(!prompt.contains(control), "\(control) is Vello's alone")
        }
        // Nothing of the owner's name when it isn't set.
        let named = CallPromptText.otherBot(name: "Ledger", instructions: "You are Ledger, the bookkeeper.", owner: "Sam", languageRule: "")
        #expect(named.hasPrefix("You are Ledger, the bookkeeper.\n\n"))
        let unnamed = CallPromptText.otherBot(name: "Ledger", instructions: "", owner: "the owner", languageRule: "")
        #expect(unnamed.contains("live voice call with the owner"))
        #expect(CallPromptText.hello(owner: "the owner") == "(The call just connected. Say hello in a few words and stop there.)")
    }

    @Test func recentChatKeepsTheLastSixLines() {
        let lines = (1...9).map { CallPromptText.ChatLine(isFromOwner: $0 % 2 == 1, text: "line \($0)") }
        let section = CallPromptText.recentChat(botName: "Ledger", owner: "Sam", lines: lines) ?? ""
        #expect(!section.contains("line 3"))
        #expect(section.contains("Ledger: line 4"))
        #expect(section.hasSuffix("Sam: line 9"))
        #expect(CallPromptText.recentChat(botName: "Ledger", owner: "Sam", lines: []) == nil)
    }

    @Test func everyBracketLineOfAnotherBotIsTakenOutWhereverItSplits() {
        let reply = "Sure, I'll sort that.[TELL: Vello: book it] And done. [CLICKY: open mail][POINTER: on][FILE: notes.md] [SILENT]Bye."
        for size in [1, 2, 5, 11, 200] {
            let speech = streamed(reply, size: size)
            #expect(speech == "Sure, I'll sort that. And done.  Bye.", "size \(size)")
        }
        #expect(CallBracketLineStream.strip("See [the docs](https://example.com) for more.") == "See [the docs](https://example.com) for more.")
        #expect(CallBracketLineStream.strip("Pick [a] or [b].") == "Pick [a] or [b].")
        #expect(CallBracketLineStream.strip("Wait [POINT:120,40:the button:screen1]here") == "Wait here")
        // A tag that never closes is dropped rather than read out.
        #expect(CallBracketLineStream.strip("Okay. [TELL: Vello: and then it stopped") == "Okay. ")
        #expect(CallBracketLineStream.strip("Prices [in dollars") == "Prices [in dollars")
    }

    @Test func aBotOnABrainThatWorksGetsItAndOneThatDoesntGetsItsFix() {
        let inventory = BrainInventory(readyTools: [.codex], apiBrains: [.init(providerID: "lmstudio", models: ["qwen3.8-27b-uncensored-mlx"])])
        #expect(CallBrainChoice.forBot(named: "Ledger", engine: .init(provider: "api:lmstudio", model: "qwen3.8-27b-uncensored-mlx"),
                                       engineName: "LM Studio", inventory: inventory) == .use(brainSetting: "api:lmstudio/qwen3.8-27b-uncensored-mlx"))
        #expect(CallBrainChoice.forBot(named: "Ledger", engine: .init(provider: "codex", model: "gpt-6"), engineName: "Codex", inventory: inventory)
                == .use(brainSetting: "codex:gpt-6"))
        guard case .cannotCall(let offline) = CallBrainChoice.forBot(named: "Ledger", engine: .init(provider: "api:ollama", model: "llama"),
                                                                       engineName: "Ollama", inventory: inventory) else {
            Issue.record("an API brain that isn't answering can't take the call")
            return
        }
        #expect(offline.contains("Ledger thinks with Ollama, which isn't answering here."))
        #expect(offline.contains("Settings \u{203A} Models & API keys"))
        guard case .cannotCall(let signedOut) = CallBrainChoice.forBot(named: "Ledger", engine: .init(provider: "cursor", model: ""),
                                                                         engineName: "Cursor", inventory: inventory) else {
            Issue.record("Cursor isn't ready here")
            return
        }
        #expect(signedOut.contains("run cursor-agent login"))
        #expect(!signedOut.contains("claude auth login"))
        guard case .cannotCall(let grok) = CallBrainChoice.forBot(named: "Ledger", engine: .init(provider: "grok", model: "grok-5"),
                                                                    engineName: "Grok", inventory: inventory) else {
            Issue.record("Grok isn't a brain a call can use")
            return
        }
        #expect(grok.contains("can't take a voice call yet"))
    }
}

struct BotOwnFilesTests {
    @Test func theInstructionsFileWinsOverTheFieldAndTheNatureComesRightAfter() {
        #expect(BotOwnFiles.personaHead(field: "From settings.", instructionsFile: nil, natureFile: nil) == "From settings.")
        #expect(BotOwnFiles.personaHead(field: "From settings.", instructionsFile: "From the file.\n", natureFile: nil) == "From the file.")
        #expect(BotOwnFiles.personaHead(field: "From settings.", instructionsFile: nil, natureFile: "<!-- a note -->\nCheerful, a bit nerdy.\n")
                == "From settings.\n\nYour nature:\nCheerful, a bit nerdy.")
        // An empty nature file, or one with only its comment, adds nothing.
        #expect(BotOwnFiles.personaHead(field: "X", instructionsFile: nil, natureFile: BotOwnFiles.newNatureFile(botName: "Ledger")) == "X")
        // A new instructions file starts as the field.
        #expect(BotOwnFiles.instructions(field: "Y", instructionsFile: BotOwnFiles.newInstructionsFile(field: "Y")) == "Y")
    }

    @Test func aLongFileIsCappedAndGetsItsCutNoticeOnce() {
        let long = (1...800).map { "Line \($0) of the instructions." }.joined(separator: "\n")
        let shown = BotOwnFiles.instructions(field: "", instructionsFile: long)
        #expect(shown.count <= BotOwnFiles.limit)
        #expect(shown.hasPrefix("Line 1 of the instructions."))
        #expect(shown.hasSuffix("of the instructions."))
        let noticed = BotOwnFiles.addingCutNoticeIfNeeded(long) ?? ""
        #expect(noticed.hasPrefix(BotOwnFiles.cutNotice()))
        #expect(BotOwnFiles.addingCutNoticeIfNeeded(noticed) == nil)
        #expect(BotOwnFiles.addingCutNoticeIfNeeded("short") == nil)
        // The notice itself never reaches the bot.
        #expect(BotOwnFiles.instructions(field: "", instructionsFile: noticed) == shown)
    }

    @Test func aBotsCallVoiceIsUsedOnlyWithItsOwnEngine() {
        let saved = CallVoiceChoice.saved(engine: .sarvam, voiceID: "ritu_en_latenight")
        #expect(saved == "sarvam:ritu_en_latenight")
        #expect(CallVoiceChoice.voiceID(saved: saved, engine: .sarvam) == "ritu_en_latenight")
        #expect(CallVoiceChoice.voiceID(saved: saved, engine: .apple) == nil)
        #expect(CallVoiceChoice.voiceID(saved: "apple:com.apple.voice.premium.en-IN.Isha", engine: .apple) == "com.apple.voice.premium.en-IN.Isha")
        #expect(CallVoiceChoice.voiceID(saved: nil, engine: .apple) == nil)
        #expect(CallVoiceChoice.voiceID(saved: "apple:", engine: .apple) == nil)
    }
}
