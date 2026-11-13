//
//  OwnerNameTests.swift
//  ClickyCoreTests
//
//  The owner's name is a setting: prompts use whatever is saved, say "the owner" until then, and a Mac that finished setup
//  before the setting existed keeps the name its bots already knew.
//

import Foundation
import Testing
@testable import ClickyCore

struct OwnerNameTests {
    @Test func aSavedNameIsTidiedAndNothingSavedMeansTheOwner() {
        #expect(OwnerName.resolved(saved: nil) == "the owner")
        #expect(OwnerName.resolved(saved: "   ") == "the owner")
        #expect(OwnerName.resolved(saved: "  Sam \n") == "Sam")
        #expect(OwnerName.resolved(saved: String(repeating: "x", count: 90)).count == OwnerName.maximumLength)
    }

    @Test func theOwnerStartsASentenceWithACapital() {
        #expect(OwnerName.startingSentence(OwnerName.unset) == "The owner")
        #expect(OwnerName.startingSentence("sam") == "sam")
        #expect(OwnerName.pronounLine("Sam") == "Call the owner Sam, or they, never he or she.")
        #expect(OwnerName.pronounLine(OwnerName.unset) == "Call the owner they, never he or she.")
    }

    @Test func setupSuggestsTheComputersFirstName() {
        #expect(OwnerName.suggestion(fullUserName: "Sam Rivera", accountName: "srivera") == "Sam")
        #expect(OwnerName.suggestion(fullUserName: "", accountName: "priya") == "Priya")
        #expect(OwnerName.suggestion(fullUserName: "  ", accountName: "root") == "")
        #expect(OwnerName.suggestion(fullUserName: "", accountName: "") == "")
    }

    @Test func onlyAMacThatFinishedSetupBeforeTheSettingGetsTheOldName() {
        #expect(OwnerName.migratedName(savedValueExists: false, setupCompleted: true) == OwnerName.nameBeforeItWasASetting)
        // A new install is asked in setup instead.
        #expect(OwnerName.migratedName(savedValueExists: false, setupCompleted: false) == nil)
        // Anything saved, even a name cleared on purpose, stays as it is.
        #expect(OwnerName.migratedName(savedValueExists: true, setupCompleted: true) == nil)
    }

    /// Every prompt text that takes the owner, built for someone else and for nobody yet.
    private func everyOwnerPrompt(owner: String) -> [String] {
        [
            HarnessGuide.markdown(owner: owner),
            BotProtocol.houseStyle(owner: owner),
            BotProtocol.reachHowTo(reachable: [("Coder", "Writes code")], owner: owner),
            BotProtocol.screenHowTo(owner: owner),
            BotProtocol.routineHowTo(owner: owner),
            BotProtocol.mergeNote(owner: owner),
            BotProtocol.planNote(hasOthers: true, owner: owner),
            BotProtocol.headOpensNote(owner: owner),
            BotProtocol.wrapUpNote(owner: owner),
            BotAwareness.whereYouAre(BotPlaceFacts(owner: owner, thisMac: "MacBook Pro", otherMac: "Mac mini")),
            BotAwareness.whoYouAre(BotIdentityFacts(name: "Coder", owner: owner, job: "Writes code.")),
            ClickyTeamPrompts.theoHowTo(team: ["Memory"], owner: owner),
            ClickyTeamPrompts.callHowTo(owner: owner),
            ClickyTeamPrompts.theoFromCallNote(report: "Done.", owner: owner),
            ClickyTeamPrompts.rememberPrompt("milk", owner: owner),
            ClickyTeamPrompts.summarisePrompt(entries: [], owner: owner),
            ClickyDuty.memory.instructions(owner: owner),
            ScreenTaskPolicy.systemPrompt,
            ScreenTaskPolicy.refusal(app: "Terminal") ?? "",
            ScreenTaskPolicy.refusal(pressing: "Send") ?? "",
        ]
    }

    @Test func promptsUseADifferentNameAndNeverTheOldOne() {
        for prompt in everyOwnerPrompt(owner: "Priya") {
            #expect(!prompt.contains(OwnerName.nameBeforeItWasASetting), "Still names the old owner: \(prompt.prefix(120))")
        }
        #expect(ClickyDuty.memory.instructions(owner: "Priya").contains("Call the owner Priya, or they"))
        #expect(HarnessGuide.markdown(owner: "Priya").contains("Theo is Priya's bot harness"))
    }

    @Test func withNoNameSetPromptsSayTheOwnerAndReadAsSentences() {
        for prompt in everyOwnerPrompt(owner: OwnerName.unset) {
            #expect(!prompt.contains(OwnerName.nameBeforeItWasASetting), "Names the old owner with no name set: \(prompt.prefix(120))")
            // "the owner" never starts a sentence in lower case.
            for sentenceStart in [". the owner", "\n\nthe owner", "\"the owner"] {
                #expect(!prompt.contains(sentenceStart), "Starts a sentence with \"the owner\": \(prompt.prefix(120))")
            }
        }
        #expect(HarnessGuide.markdown().contains("Theo is the owner's bot harness"))
        #expect(BotProtocol.screenHowTo(owner: OwnerName.unset).hasPrefix("The owner's Mac Studio"))
    }
}
