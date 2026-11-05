//
//  BotProtocolTests.swift
//  ClickyCore
//
//  One way to write to a bot, in every prompt; private threads and their caps; who speaks next in a group chat; the blocks a bot reads
//  about where it is and what it's for.
//

import Foundation
import Testing
@testable import ClickyCore

struct BotProtocolTests {
    // MARK: Threads

    @Test func aThreadIsTheSameWhoeverAsks() {
        #expect(BotDMThread.id("theo", "coder") == BotDMThread.id("coder", "theo"))
        #expect(BotDMThread.id("coder", "theo") == "dm:coder+theo")
        #expect(BotDMThread.isThread("dm:coder+theo"))
        #expect(!BotDMThread.isThread("group-it"))
        #expect(BotDMThread.members(of: "dm:coder+theo")?.first == "coder")
        #expect(BotDMThread.partner(of: "theo", in: "dm:coder+theo") == "coder")
        #expect(BotDMThread.partner(of: "ada", in: "dm:coder+theo") == nil)
        #expect(BotDMThread.members(of: "dm:coder") == nil)
    }

    @Test func aThreadsFileNameRoundTrips() {
        let file = BotDMThread.fileName(forThread: "dm:coder+theo")
        #expect(!file.contains(":"))
        #expect(BotDMThread.thread(fromFileName: file) == "dm:coder+theo")
        #expect(BotDMThread.thread(fromFileName: "theo") == nil)
        #expect(BotDMThread.fileName(forThread: "group-it") == "group-it")
    }

    @Test func aCardNamesItsExchangeAndWhoWasMessaged() {
        let card = BotDMThread.card(exchangeID: "abc-1", targetID: "coder")
        #expect(BotDMThread.parseCard(card)?.exchangeID == "abc-1")
        #expect(BotDMThread.parseCard(card)?.targetID == "coder")
        #expect(BotDMThread.parseCard("delegation:abc") == nil)
        #expect(BotDMThread.parseCard("settings") == nil)
        #expect(BotDMThread.parseCard(nil) == nil)
        #expect(BotDMThread.parseCard("dm:abc") == nil)
    }

    // MARK: Caps

    @Test func anExchangeStopsAtThreeRoundTrips() {
        let budget = BotDMBudget()
        #expect(budget.verdict(roundTripsSoFar: 0) == .send)
        #expect(budget.verdict(roundTripsSoFar: 2) == .send)
        #expect(budget.verdict(roundTripsSoFar: 3) == .roundTripCap)
    }

    @Test func oneOwnerMessageSetsOffTwelveAtMost() {
        var budget = BotDMBudget()
        for _ in 0..<12 {
            #expect(budget.verdict(roundTripsSoFar: 0) == .send)
            budget.noteSent()
        }
        #expect(budget.verdict(roundTripsSoFar: 0) == .totalCap)
        budget.ownerSpoke()
        #expect(budget.verdict(roundTripsSoFar: 0) == .send)
    }

    @Test func aCapIsSaidPlainly() {
        #expect(BotDMBudget.capLine(.send, sender: "Theo", target: "Coder") == nil)
        #expect(BotDMBudget.capLine(.roundTripCap, sender: "Theo", target: "Coder")?.contains("3 times") == true)
        #expect(BotDMBudget.capLine(.totalCap, sender: "Theo", target: "Coder")?.contains("12") == true)
    }

    // MARK: The card

    @Test func aCardReadsLikePartOfTheProduct() {
        #expect(BotDMCardText.headline(sender: "Theo", target: "Coder") == "Theo messaged Coder privately")
        #expect(BotDMCardText.count(1) == "1 message")
        #expect(BotDMCardText.count(2) == "2 messages")
        #expect(BotDMCardText.preview("**Use SQLite.**\nIt's simple") == "Use SQLite.")
        #expect(BotDMCardText.preview(String(repeating: "a", count: 200)).count == 90)
        let now = Date()
        #expect(BotDMCardText.looksLive(lastAuthorIsTarget: false, lastAt: now, now: now))
        #expect(!BotDMCardText.looksLive(lastAuthorIsTarget: true, lastAt: now, now: now))
        #expect(!BotDMCardText.looksLive(lastAuthorIsTarget: false, lastAt: now.addingTimeInterval(-600), now: now))
    }

    // MARK: Mentions

    private let team: [(id: String, name: String)] = [("a", "Coder"), ("b", "Coder 2"), ("c", "Catalogue pricing"), ("d", "Head")]

    @Test func mentionsComeInTheOrderTheyreNamed() {
        #expect(BotMentions.ordered(in: "@Catalogue pricing first, then @Coder, then @coder 2", bots: team) == ["c", "a", "b"])
    }

    @Test func aLongerNameIsntTakenForAShorterOne() {
        #expect(BotMentions.ordered(in: "ask @Coder 2 about it", bots: team) == ["b"])
        #expect(BotMentions.ordered(in: "@Coders aren't anyone", bots: team).isEmpty)
    }

    @Test func eachIsNamedOnceAndCodeDoesntCount() {
        #expect(BotMentions.ordered(in: "@Coder and again @Coder", bots: team) == ["a"])
        #expect(BotMentions.ordered(in: "```\n@Coder\n```\nnobody", bots: team).isEmpty)
    }

    // MARK: Turn order

    @Test func theHeadGoesFirstThenMembersInTheOrderNamedThenOneWrapUp() {
        var plan = GroupTurnPlan(headID: "head", first: [])
        #expect(plan.start() == .speak(botID: "head", isWrapUp: false))
        var step = plan.turnEnded(by: "head", mentions: ["b", "a", "c"], canHandOut: true, others: ["a", "b", "c"])
        #expect(step == .speak(botID: "b", isWrapUp: false))
        step = plan.turnEnded(by: "b", mentions: [], canHandOut: true, others: ["a", "b", "c"])
        #expect(step == .speak(botID: "a", isWrapUp: false))
        step = plan.turnEnded(by: "a", mentions: [], canHandOut: true, others: ["a", "b", "c"])
        #expect(step == .speak(botID: "c", isWrapUp: false))
        step = plan.turnEnded(by: "c", mentions: [], canHandOut: true, others: ["a", "b", "c"])
        #expect(step == .speak(botID: "head", isWrapUp: true))
        step = plan.turnEnded(by: "head", mentions: ["a"], canHandOut: false, others: ["a", "b", "c"])
        #expect(step == .finished)
        #expect(plan.isFinished)
    }

    @Test func aHeadWhoAnswersItselfJustStops() {
        var plan = GroupTurnPlan(headID: "head", first: [])
        _ = plan.start()
        #expect(plan.turnEnded(by: "head", mentions: [], canHandOut: true, others: ["a"]) == .finished)
    }

    @Test func taggedMembersAnswerAndTheHeadStillWrapsUp() {
        var plan = GroupTurnPlan(headID: "head", first: ["a", "b"])
        #expect(plan.start() == .speak(botID: "a", isWrapUp: false))
        #expect(plan.turnEnded(by: "a", mentions: [], canHandOut: true, others: ["a", "b"]) == .speak(botID: "b", isWrapUp: false))
        #expect(plan.turnEnded(by: "b", mentions: [], canHandOut: true, others: ["a", "b"]) == .speak(botID: "head", isWrapUp: true))
    }

    @Test func aTaggedHeadReadsItFirstAndDoesntSpeakTwiceInARow() {
        var plan = GroupTurnPlan(headID: "head", first: ["a", "head"])
        #expect(plan.start() == .speak(botID: "head", isWrapUp: false))
        #expect(plan.turnEnded(by: "head", mentions: [], canHandOut: true, others: ["a"]) == .speak(botID: "a", isWrapUp: false))
        #expect(plan.turnEnded(by: "a", mentions: [], canHandOut: true, others: ["a"]) == .speak(botID: "head", isWrapUp: true))
    }

    @Test func aMemberCanHandOnAndThatBotGoesNext() {
        var plan = GroupTurnPlan(headID: "head", first: [])
        _ = plan.start()
        #expect(plan.turnEnded(by: "head", mentions: ["a", "b"], canHandOut: true, others: ["a", "b", "c"]) == .speak(botID: "a", isWrapUp: false))
        #expect(plan.turnEnded(by: "a", mentions: ["c"], canHandOut: true, others: ["a", "b", "c"]) == .speak(botID: "c", isWrapUp: false))
        #expect(plan.turnEnded(by: "c", mentions: [], canHandOut: true, others: ["a", "b", "c"]) == .speak(botID: "b", isWrapUp: false))
    }

    @Test func twoMembersCantKeepHandingToEachOther() {
        var plan = GroupTurnPlan(headID: "head", first: [])
        _ = plan.start()
        var step = plan.turnEnded(by: "head", mentions: ["a"], canHandOut: true, others: ["a", "b"])
        var turns = 1
        while case .speak(let bot, let isWrapUp) = step, !isWrapUp {
            let other = bot == "a" ? "b" : "a"
            step = plan.turnEnded(by: bot, mentions: [other], canHandOut: true, others: ["a", "b"])
            turns += 1
            #expect(turns < 10)
        }
        #expect(step == .speak(botID: "head", isWrapUp: true))
        // Two turns each at most, then the wrap-up.
        #expect(plan.spoke["a"] == 2)
        #expect(plan.spoke["b"] == 2)
    }

    @Test func theCapStillEndsWithOneWrapUp() {
        let many = (1...12).map { "m\($0)" }
        var plan = GroupTurnPlan(headID: "head", first: [])
        _ = plan.start()
        var step = plan.turnEnded(by: "head", mentions: many, canHandOut: true, others: many)
        var turns = 1
        while case .speak(let bot, let isWrapUp) = step, !isWrapUp {
            step = plan.turnEnded(by: bot, mentions: [], canHandOut: true, others: many)
            turns += 1
        }
        #expect(step == .speak(botID: "head", isWrapUp: true))
        #expect(turns + 1 == GroupTurnPlan.maximumTurns)
    }

    @Test func nobodySpeaksAfterTheOwnerStopsIt() {
        var plan = GroupTurnPlan(headID: "head", first: [])
        _ = plan.start()
        _ = plan.turnEnded(by: "head", mentions: ["a", "b"], canHandOut: true, others: ["a", "b"])
        plan.finish()
        #expect(plan.turnEnded(by: "a", mentions: ["b"], canHandOut: true, others: ["a", "b"]) == .finished)
    }

    @Test func aMemberThatFailedDoesntStallTheRound() {
        var plan = GroupTurnPlan(headID: "head", first: [])
        _ = plan.start()
        _ = plan.turnEnded(by: "head", mentions: ["a", "b"], canHandOut: true, others: ["a", "b"])
        #expect(plan.turnEnded(by: "a", mentions: [], canHandOut: false, others: ["a", "b"]) == .speak(botID: "b", isWrapUp: false))
    }

    @Test func aDiscussionGoesPlanCritiqueMerge() {
        var plan = GroupTurnPlan(headID: "head", first: ["head"])
        #expect(plan.start() == .speak(botID: "head", isWrapUp: false))
        #expect(plan.turnEnded(by: "head", mentions: ["a", "b"], canHandOut: true, others: ["a", "b"]) == .speak(botID: "a", isWrapUp: false))
        #expect(plan.turnEnded(by: "a", mentions: [], canHandOut: false, others: ["a", "b"]) == .speak(botID: "b", isWrapUp: false))
        #expect(plan.turnEnded(by: "b", mentions: [], canHandOut: false, others: ["a", "b"]) == .speak(botID: "head", isWrapUp: true))
        #expect(plan.isWrappingUp)
    }

    // MARK: The assembled prompts: one way to write, in all of them

    private struct Role {
        let name: String
        let identity: BotIdentityFacts
        let reporting: [BotProtocol.TeamFacts]
    }

    private var roles: [Role] {
        [
            Role(name: "CEO", identity: BotIdentityFacts(name: "Theo", owner: "Addy", job: "Your primary bot", isCEO: true, ceoName: "Theo"), reporting: []),
            Role(name: "manager", identity: BotIdentityFacts(name: "Mira", owner: "Addy", job: "Runs the IT guys", teams: ["IT guys"], managesTeams: ["IT guys"], ceoName: "Theo"),
                 reporting: [.init(name: "IT guys", purpose: "Keep it running", mates: ["Coder", "Ops"], isManager: true)]),
            Role(name: "member", identity: BotIdentityFacts(name: "Coder", owner: "Addy", job: "Writes code", teams: ["IT guys"], managerName: "Mira", ceoName: "Theo", apps: ["Gmail"]),
                 reporting: [.init(name: "IT guys", mates: ["Mira", "Ops"], managerName: "Mira")]),
            Role(name: "no-manager member", identity: BotIdentityFacts(name: "Ops", owner: "Addy", job: "Runs servers", teams: ["Ops"], ceoName: "Theo"),
                 reporting: [.init(name: "Ops")]),
        ]
    }

    private let place = BotPlaceFacts(owner: "Addy", thisMac: "MacBook Air", projects: ["a", "b"], ready: ["Claude Code (signed in)", "T3 Code 0.1.7"], otherMac: "Mac Studio", otherMacConnected: true, otherMacHasScreens: true)
    private let reachable: [(name: String, description: String)] = [("Coder", "Writes code"), ("Ops", "Runs servers")]

    /// Everything a bot can be told, in any kind of chat.
    private func allPrompts(_ role: Role) -> [String] {
        let identity = BotAwareness.whoYouAre(role.identity)
        let whereNow = BotAwareness.whereYouAre(place)
        let reach = BotProtocol.reachHowTo(reachable: reachable, owner: "Addy")
        let reporting = role.reporting.map { BotProtocol.reportingLine($0, ceoName: "Theo") }.joined(separator: "\n")
        let shared = [identity, whereNow, reach, reporting, BotProtocol.houseStyle(owner: "Addy"), BotProtocol.routineHowTo, BotProtocol.codingHowTo(harnessLabel: "Claude Code"), BotProtocol.screenHowTo, BotProtocol.askingStyle].joined(separator: "\n\n")
        let group = BotProtocol.groupTurnPrompt(botName: role.identity.name, groupName: "IT guys", owner: "Addy", others: reachable, firstTimeIntro: [], transcript: [("Addy", "hi"), ("Coder", "hello")],
                                                includesScreenHowTo: true, turnNote: BotProtocol.memberTurnNote(name: role.identity.name, headName: "Mira"))
        let head = BotProtocol.groupTurnPrompt(botName: role.identity.name, groupName: "IT guys", owner: "Addy", others: reachable, firstTimeIntro: [], transcript: [("Addy", "hi")],
                                               includesScreenHowTo: true, turnNote: BotProtocol.headOpensNote(owner: "Addy"))
        let wrap = BotProtocol.groupTurnPrompt(botName: role.identity.name, groupName: "IT guys", owner: "Addy", others: reachable, firstTimeIntro: [], transcript: [("Coder", "done")],
                                               includesScreenHowTo: false, turnNote: BotProtocol.wrapUpNote(owner: "Addy"))
        let privately = [BotProtocol.privateThreadHowTo(partner: "Theo"),
                         BotProtocol.privateMessagePrompt(from: "Theo", senderRole: "the CEO", message: "Which database?", ownerAsked: "ask Coder", earlier: [], owner: "Addy")].joined(separator: "\n\n")
        let carryOn = BotProtocol.repliesPrompt([("Coder", "SQLite")], notes: [], lastRoundWith: [], owner: "Addy")
        return [shared, shared + "\n\n" + group, shared + "\n\n" + head, shared + "\n\n" + wrap, shared + "\n\n" + privately, shared + "\n\n" + carryOn]
    }

    @Test func noPromptToldToAtSomeoneOutsideAGroupChat() {
        let banned = ["writing @Name", "by writing @", "@Name in your reply", "they answer you in the chat", "Mention one with @Name", "reports and messages to @", "report to @", "straight to @", "Hand work to them with @"]
        for role in roles {
            for prompt in allPrompts(role) {
                for phrase in banned { #expect(!prompt.contains(phrase), "\(role.name): \(phrase)") }
            }
        }
    }

    @Test func everyPromptGivesTheSameOneWayToMessageABot() {
        for role in roles {
            for prompt in allPrompts(role) {
                #expect(prompt.contains("[TELL: their exact name: what you need]"), "\(role.name)")
                #expect(prompt.contains("Only that line reaches them"), "\(role.name)")
                // @Name is only ever about a group chat.
                #expect(prompt.contains("@Name means something only inside a group chat"), "\(role.name)")
                #expect(!prompt.contains("@Name reaches"), "\(role.name)")
            }
        }
    }

    @Test func aGroupsPromptSaysHowToHandOverAndWhoElseIsThere() {
        let prompt = BotProtocol.groupChatHowTo(others: reachable)
        #expect(prompt.contains("@Name hands that bot the next turn"))
        #expect(prompt.contains("[TELL: their exact name: what you need]"))
        #expect(prompt.contains("Coder (Writes code)"))
    }

    @Test func aMembersPromptHoldsWhatTheMemberBeforeItSaid() {
        let prompt = BotProtocol.groupTurnPrompt(botName: "Ops", groupName: "IT guys", owner: "Addy", others: reachable, firstTimeIntro: [],
                                                 transcript: [("Addy", "which database?"), ("Mira", "@Coder @Ops your take?"), ("Coder", "Postgres, because of the joins")],
                                                 includesScreenHowTo: false, turnNote: BotProtocol.memberTurnNote(name: "Ops", headName: "Mira"))
        #expect(prompt.contains("Coder: Postgres, because of the joins"))
        #expect(prompt.contains("Don't repeat a point already made"))
        #expect(prompt.contains("nobody else is writing"))
    }

    @Test func aPrivateMessageHoldsAllOfItWhoSentItAndWhy() {
        let long = String(repeating: "word ", count: 2000)
        let prompt = BotProtocol.privateMessagePrompt(from: "Theo", senderRole: "the CEO", message: long, ownerAsked: "ask Coder which database", earlier: ["Coder: Earlier we said SQLite"], owner: "Addy")
        #expect(prompt.contains(long))
        #expect(prompt.contains("Private message from Theo (the CEO)"))
        #expect(prompt.contains("ask Coder which database"))
        #expect(prompt.contains("Earlier we said SQLite"))
        #expect(prompt.contains("Answer Theo directly"))
    }

    @Test func aRepliesPromptHoldsAllOfTheAnswer() {
        let long = String(repeating: "word ", count: 2000)
        let prompt = BotProtocol.repliesPrompt([("Coder", long)], notes: ["There's nobody called Bob."], lastRoundWith: ["Coder"], owner: "Addy")
        #expect(prompt.contains(long))
        #expect(prompt.contains("There's nobody called Bob."))
        #expect(prompt.contains("last message to Coder"))
    }

    // MARK: Where you are, who you are

    @Test func whereYouAreNamesBothMacsAndWhereCodeGoes() {
        let text = BotAwareness.whereYouAre(place)
        #expect(text.contains("running on Addy's MacBook Air, the Mac Addy is using"))
        #expect(text.contains("Folders and coding runs from this chat are on the MacBook Air"))
        #expect(text.contains("Mac Studio, is connected"))
        #expect(text.contains("hidden screens"))
        #expect(text.contains("Never offer a folder on one Mac and run on the other"))
    }

    @Test func aTurnFromTheOtherMacSaysSo() {
        var facts = place
        facts.thisMac = "Mac Studio"
        facts.ownerMac = "MacBook Air"
        facts.whyHere = "Grok isn't signed in on this MacBook Air"
        facts.codingMac = "MacBook Air"
        let text = BotAwareness.whereYouAre(facts)
        #expect(text.contains("running on Addy's Mac Studio"))
        #expect(text.contains("typing on their MacBook Air"))
        #expect(text.contains("Grok isn't signed in"))
        #expect(text.contains("coding runs from this chat are on the MacBook Air"))
    }

    @Test func aLongProjectListIsCut() {
        var facts = place
        facts.projects = (1...30).map { "p\($0)" }
        let text = BotAwareness.whereYouAre(facts)
        #expect(text.contains("p12"))
        #expect(!text.contains("p13,"))
        #expect(text.contains("and 18 more"))
    }

    @Test func noOtherMacIsSaidPlainly() {
        let text = BotAwareness.whereYouAre(BotPlaceFacts(owner: "Addy", thisMac: "Mac Studio", thisMacHasScreens: true))
        #expect(text.contains("no other Mac linked"))
        #expect(text.contains("hidden screens"))
    }

    @Test func whoYouAreIsBuiltFromTheBot() {
        let text = BotAwareness.whoYouAre(BotIdentityFacts(name: "Coder", owner: "Addy", job: "Writes code.", teams: ["IT guys"], managerName: "Mira", ceoName: "Theo", apps: ["Gmail"]))
        #expect(text.contains("you're Coder, Addy's bot"))
        #expect(text.contains("Your job: Writes code."))
        #expect(text.contains("on the IT guys team; your manager is Mira"))
        #expect(text.contains("use Gmail"))
        #expect(text.contains("say who on the team fits"))
        #expect(text.contains("Work out what Addy actually wants"))
    }

    @Test func theTwoBlocksStayShort() {
        var facts = place
        facts.projects = (1...30).map { "project-\($0)" }
        for role in roles {
            let words = BotProtocol.wordCount(BotAwareness.whereYouAre(facts)) + BotProtocol.wordCount(BotAwareness.whoYouAre(role.identity))
            #expect(words < 250, "\(role.name): \(words) words")
        }
    }

    // MARK: Devices

    @Test func botsAndCodingFollowTheMacYoureOnAndRoutinesStayOnTheStudio() {
        #expect(DeviceFeature.bots.defaultChoice == .any)
        #expect(DeviceFeature.routines.defaultChoice == .macStudio)
        for mac in [DeviceKind.macStudio, .macBookAir] {
            #expect(DeviceRouting.route(.bots, choice: DeviceFeature.bots.defaultChoice, thisMac: mac, paired: true, otherMacOnline: true) == .runHere)
        }
        #expect(DeviceRouting.route(.routines, choice: DeviceFeature.routines.defaultChoice, thisMac: .macStudio, paired: true, otherMacOnline: true) == .runHere)
        #expect(DeviceRouting.route(.routines, choice: DeviceFeature.routines.defaultChoice, thisMac: .macBookAir, paired: true, otherMacOnline: true) == .sendAcross)
        #expect(DeviceRouting.route(.routines, choice: DeviceFeature.routines.defaultChoice, thisMac: .macBookAir, paired: true, otherMacOnline: false) == .waitForOtherMac)
        // With only one Mac there's nowhere else for them to go.
        #expect(DeviceRouting.route(.routines, choice: DeviceFeature.routines.defaultChoice, thisMac: .macBookAir, paired: false, otherMacOnline: false) == .runHere)
    }

    @Test func botsCanStillBePutOnOneMacByHand() {
        #expect(DeviceRouting.route(.bots, choice: .macStudio, thisMac: .macBookAir, paired: true, otherMacOnline: true) == .sendAcross)
        #expect(DeviceRouting.route(.bots, choice: .macStudio, thisMac: .macStudio, paired: true, otherMacOnline: true) == .runHere)
        #expect(DeviceFeature.bots.anyChoiceTitle == "The Mac you're using")
        #expect(DeviceFeature.routines.anyChoiceTitle == "Any")
    }

    @Test func theMacTheOwnerNamedForARun() {
        #expect(CodingDeviceWords.named(in: "run it on the Studio") == "studio")
        #expect(CodingDeviceWords.named(in: "build this on my MacBook Air") == "air")
        #expect(CodingDeviceWords.named(in: "send it to mac studio please") == "studio")
        #expect(CodingDeviceWords.named(in: "open it in visual studio") == nil)
        #expect(CodingDeviceWords.named(in: "put the page on the web") == nil)
    }

    @Test func aRequestToCarryOnIsRecognised() {
        #expect(CodingIntent.asksToContinueChat("continue that chat in the moon folder"))
        #expect(CodingIntent.asksToContinueChat("carry on the earlier thread"))
        #expect(CodingIntent.asksToContinueChat("pick up where the agent left off"))
        #expect(!CodingIntent.asksToContinueChat("build a todo app"))
        #expect(!CodingIntent.asksToContinueChat("continue"))
    }

    // MARK: Folders and memory

    @Test func theFolderMenuPutsRecentOnesFirst() {
        let now = Date()
        let projects = (1...8).map { DeviceProject(name: "p\($0)", path: "/p\($0)", modifiedAt: now.addingTimeInterval(Double(-$0) * 60)) }
        let menu = ProjectFolderMenu.sections(projects: projects, used: ["/p7", "/gone"])
        #expect(menu.recent.map(\.name) == ["p7", "p1", "p2", "p3", "p4"])
        #expect(menu.others.map(\.name) == ["p5", "p6", "p8"])
    }

    @Test func memoryJoinsWithNoDuplicates() {
        let merged = BotMemoryMerge.union("likes tea\nuses Hinglish\n", "uses Hinglish\n  likes tea  \nprefers Haiku\n")
        #expect(merged == "likes tea\nuses Hinglish\nprefers Haiku\n")
        #expect(BotMemoryMerge.union("", "") == "")
        #expect(BotMemoryMerge.digest("a\nb\n") == BotMemoryMerge.digest("b\na"))
        #expect(BotMemoryMerge.digest("a\nb") != BotMemoryMerge.digest("a"))
    }
}
