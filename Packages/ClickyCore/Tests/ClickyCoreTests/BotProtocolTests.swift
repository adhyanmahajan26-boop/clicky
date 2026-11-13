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
        #expect(BotDMCardText.looksLive(lastAuthorIsSender: true, lastAt: now, now: now))
        #expect(!BotDMCardText.looksLive(lastAuthorIsSender: false, lastAt: now, now: now))
        #expect(!BotDMCardText.looksLive(lastAuthorIsSender: true, lastAt: now.addingTimeInterval(-600), now: now))
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

    // A live round on 9 Nov: the head named all three in words but tagged only the first, and the other two never spoke.
    @Test func theHeadsHandOutCountsNamesWithoutTheAtSign() {
        let team = [(id: "backend", name: "Backend"), (id: "frontend", name: "Frontend"), (id: "security", name: "Security"), (id: "pm", name: "project manager")]
        let opening = "Backend goes first, then Frontend, then Security, each with one line on what a login page needs. @Backend, you're up."
        #expect(BotMentions.named(in: opening, bots: team) == ["backend", "frontend", "security"])
        #expect(BotMentions.named(in: "Ask the Project Manager, then @Security.", bots: team) == ["pm", "security"])
        // Part of another word isn't a name, and code doesn't count.
        #expect(BotMentions.named(in: "Backends and frontends differ.\n```\nSecurity\n```", bots: team).isEmpty)
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
        // A can hand on to b, who hadn't answered; b can't hand back to a, who had. One turn each, then the wrap-up.
        #expect(plan.spoke["a"] == 1)
        #expect(plan.spoke["b"] == 1)
    }

    // MARK: Members can't hand out turns that aren't theirs (T03)

    @Test func aMembersMentionCantBringBackBotsThatAlreadyAnswered() {
        // T03's failing round: the head asks all four; the last member @-names everyone, which used to give two of them a second turn.
        var plan = GroupTurnPlan(headID: "atlas", first: [])
        _ = plan.start()
        let members = ["ledger", "scout", "forge", "hijacker"]
        var step = plan.turnEnded(by: "atlas", mentions: members, canHandOut: true, others: members)
        var order: [String] = ["atlas"]
        while case .speak(let bot, let isWrapUp) = step {
            order.append(bot)
            if isWrapUp { step = plan.turnEnded(by: bot, mentions: [], canHandOut: false, others: members); break }
            // Every member tries to grab turns for everyone else, the head included.
            step = plan.turnEnded(by: bot, mentions: ["atlas"] + members, canHandOut: true, others: members)
        }
        #expect(order == ["atlas", "ledger", "scout", "forge", "hijacker", "atlas"])
        #expect(step == .finished)
        #expect(members.allSatisfy { plan.spoke[$0] == 1 })
        #expect(plan.spoke["atlas"] == 2)
    }

    @Test func aMemberCanStillHandOnToABotThatHasntAnswered() {
        var plan = GroupTurnPlan(headID: "head", first: [])
        _ = plan.start()
        #expect(plan.turnEnded(by: "head", mentions: ["a"], canHandOut: true, others: ["a", "b"]) == .speak(botID: "a", isWrapUp: false))
        #expect(plan.turnEnded(by: "a", mentions: ["b"], canHandOut: true, others: ["a", "b"]) == .speak(botID: "b", isWrapUp: false))
        #expect(plan.turnEnded(by: "b", mentions: ["a"], canHandOut: true, others: ["a", "b"]) == .speak(botID: "head", isWrapUp: true))
    }

    @Test func theHeadCanStillBringABotBackOnce() {
        var plan = GroupTurnPlan(headID: "head", first: ["a"])
        #expect(plan.start() == .speak(botID: "a", isWrapUp: false))
        #expect(plan.turnEnded(by: "a", mentions: [], canHandOut: true, others: ["a"]) == .speak(botID: "head", isWrapUp: true))
        var second = GroupTurnPlan(headID: "head", first: ["head", "a"])
        _ = second.start()
        #expect(second.turnEnded(by: "head", mentions: [], canHandOut: true, others: ["a"]) == .speak(botID: "a", isWrapUp: false))
    }

    @Test func membersTheOwnerNamesAnswerEvenIfTheHeadAnswersAlone() {
        // T03's other failing round: the head answered everything itself and named nobody.
        var plan = GroupTurnPlan(headID: "atlas", first: [], asked: ["ledger", "scout", "forge", "hijacker"])
        #expect(plan.start() == .speak(botID: "atlas", isWrapUp: false))
        var step = plan.turnEnded(by: "atlas", mentions: [], canHandOut: true, others: ["ledger", "scout", "forge", "hijacker"])
        var order: [String] = []
        while case .speak(let bot, let isWrapUp) = step, !isWrapUp {
            order.append(bot)
            step = plan.turnEnded(by: bot, mentions: [], canHandOut: true, others: ["ledger", "scout", "forge", "hijacker"])
        }
        #expect(order == ["ledger", "scout", "forge", "hijacker"])
        #expect(step == .speak(botID: "atlas", isWrapUp: true))
    }

    @Test func onlyBotsTheOwnerAddressesAreAsked() {
        let team = [(id: "ledger", name: "Ledger"), (id: "runner", name: "Runner"), (id: "memory", name: "Memory"), (id: "scout", name: "Scout")]
        // T03's message: each member addressed at the start of a sentence, with a colon.
        let t03 = "We launch a paid newsletter next month at $8/month. Ledger: break-even subscribers if costs are $1,200/month. Scout: two risks."
        #expect(BotMentions.addressed(in: t03, bots: team) == ["ledger", "scout"])
        #expect(BotMentions.addressed(in: "Ledger: the break-even", bots: team) == ["ledger"])
        #expect(BotMentions.addressed(in: "Scout, two risks please.\n- Ledger: the numbers", bots: team) == ["scout", "ledger"])
        // Talking about something, not to a bot: nobody is asked.
        #expect(BotMentions.addressed(in: "the ledger looks off", bots: team).isEmpty)
        #expect(BotMentions.addressed(in: "my runner crashed again", bots: team).isEmpty)
        #expect(BotMentions.addressed(in: "memory is full, and the Runner: no idea why", bots: team).isEmpty)
        #expect(BotMentions.addressed(in: "Check the Ledger, it looks off.", bots: team).isEmpty)
        #expect(BotMentions.addressed(in: "```\nLedger: x\n```", bots: team).isEmpty)
    }

    @Test func askedMembersComeAfterTaggedOnesAndNeverTwice() {
        var plan = GroupTurnPlan(headID: "head", first: ["b"], asked: ["a", "b", "head"])
        #expect(plan.queue == ["b", "a"])
        _ = plan.start()
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
            Role(name: "CEO", identity: BotIdentityFacts(name: "Theo", owner: "Sam", job: "Your primary bot", isCEO: true, ceoName: "Theo"), reporting: []),
            Role(name: "manager", identity: BotIdentityFacts(name: "Mira", owner: "Sam", job: "Runs the IT guys", teams: ["IT guys"], managesTeams: ["IT guys"], ceoName: "Theo"),
                 reporting: [.init(name: "IT guys", purpose: "Keep it running", mates: ["Coder", "Ops"], isManager: true)]),
            Role(name: "member", identity: BotIdentityFacts(name: "Coder", owner: "Sam", job: "Writes code", teams: ["IT guys"], managerName: "Mira", ceoName: "Theo", apps: ["Gmail"]),
                 reporting: [.init(name: "IT guys", mates: ["Mira", "Ops"], managerName: "Mira")]),
            Role(name: "no-manager member", identity: BotIdentityFacts(name: "Ops", owner: "Sam", job: "Runs servers", teams: ["Ops"], ceoName: "Theo"),
                 reporting: [.init(name: "Ops")]),
        ]
    }

    private let place = BotPlaceFacts(owner: "Sam", thisMac: "MacBook Air", projects: ["a", "b"], ready: ["Claude Code (signed in)", "T3 Code 0.1.7"], otherMac: "Mac Studio", otherMacConnected: true, otherMacHasScreens: true)
    private let reachable: [(name: String, description: String)] = [("Coder", "Writes code"), ("Ops", "Runs servers")]

    /// Everything a bot can be told, in any kind of chat.
    private func allPrompts(_ role: Role) -> [String] {
        let identity = BotAwareness.whoYouAre(role.identity)
        let whereNow = BotAwareness.whereYouAre(place)
        let reach = BotProtocol.reachHowTo(reachable: reachable, owner: "Sam")
        let reporting = role.reporting.map { BotProtocol.reportingLine($0, ceoName: "Theo") }.joined(separator: "\n")
        let shared = [identity, whereNow, reach, reporting, BotProtocol.houseStyle(owner: "Sam"), BotProtocol.routineHowTo(owner: "Sam"), BotProtocol.codingHowTo(harnessLabel: "Claude Code"), BotProtocol.screenHowTo(owner: "Sam"), BotProtocol.askingStyle].joined(separator: "\n\n")
        let group = BotProtocol.groupTurnPrompt(botName: role.identity.name, groupName: "IT guys", owner: "Sam", others: reachable, firstTimeIntro: [], transcript: [("Sam", "hi"), ("Coder", "hello")],
                                                includesScreenHowTo: true, turnNote: BotProtocol.memberTurnNote(name: role.identity.name, headName: "Mira"))
        let head = BotProtocol.groupTurnPrompt(botName: role.identity.name, groupName: "IT guys", owner: "Sam", others: reachable, firstTimeIntro: [], transcript: [("Sam", "hi")],
                                               includesScreenHowTo: true, turnNote: BotProtocol.headOpensNote(owner: "Sam"))
        let wrap = BotProtocol.groupTurnPrompt(botName: role.identity.name, groupName: "IT guys", owner: "Sam", others: reachable, firstTimeIntro: [], transcript: [("Coder", "done")],
                                               includesScreenHowTo: false, turnNote: BotProtocol.wrapUpNote(owner: "Sam"))
        let privately = [BotProtocol.privateThreadHowTo(partner: "Theo"),
                         BotProtocol.privateMessagePrompt(from: "Theo", senderRole: "the CEO", message: "Which database?", ownerAsked: "ask Coder", earlier: [], owner: "Sam")].joined(separator: "\n\n")
        let carryOn = BotProtocol.repliesPrompt([("Coder", "SQLite")], notes: [], lastRoundWith: [], reader: "Sam")
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
        let prompt = BotProtocol.groupTurnPrompt(botName: "Ops", groupName: "IT guys", owner: "Sam", others: reachable, firstTimeIntro: [],
                                                 transcript: [("Sam", "which database?"), ("Mira", "@Coder @Ops your take?"), ("Coder", "Postgres, because of the joins")],
                                                 includesScreenHowTo: false, turnNote: BotProtocol.memberTurnNote(name: "Ops", headName: "Mira"))
        #expect(prompt.contains("Coder: Postgres, because of the joins"))
        #expect(prompt.contains("Don't repeat a point already made"))
        #expect(prompt.contains("nobody else is writing"))
    }

    @Test func aPrivateMessageHoldsAllOfItWhoSentItAndWhy() {
        let long = String(repeating: "word ", count: 2000)
        let prompt = BotProtocol.privateMessagePrompt(from: "Theo", senderRole: "the CEO", message: long, ownerAsked: "ask Coder which database", earlier: ["Coder: Earlier we said SQLite"], owner: "Sam")
        #expect(prompt.contains(long))
        #expect(prompt.contains("Private message from Theo (the CEO)"))
        #expect(prompt.contains("ask Coder which database"))
        #expect(prompt.contains("Earlier we said SQLite"))
        #expect(prompt.contains("Answer Theo directly"))
    }

    @Test func aRepliesPromptHoldsAllOfTheAnswer() {
        let long = String(repeating: "word ", count: 2000)
        let prompt = BotProtocol.repliesPrompt([("Coder", long)], notes: ["There's nobody called Bob."], lastRoundWith: ["Coder"], reader: "Sam")
        #expect(prompt.contains(long))
        #expect(prompt.contains("There's nobody called Bob."))
        #expect(prompt.contains("last message to Coder"))
    }

    // MARK: Where you are, who you are

    @Test func whereYouAreNamesBothMacsAndWhereCodeGoes() {
        let text = BotAwareness.whereYouAre(place)
        #expect(text.contains("running on Sam's MacBook Air, the Mac Sam is using"))
        #expect(text.contains("Folders and coding runs from this chat are on the MacBook Air"))
        #expect(text.contains("Mac Studio, is connected"))
        #expect(text.contains("hidden screens"))
        #expect(text.contains("Never offer a folder on one Mac and run on the other"))
    }

    /// Day-one finding: a bot whose instructions mention a local folder outside its read scope tried it, was refused, and asked
    /// the owner to "allow Glob", which no setting does. It's now told what it may read, and the way to reach anything else.
    @Test func whereYouAreSaysWhatTheBotMayRead() {
        let text = BotAwareness.whereYouAre(place)
        #expect(text.contains("You can read only your memory folder, ~/Projects and files or folders Sam names in the message"))
        #expect(text.contains("ask Sam to name its path"))
        var noTools = place
        noTools.canReadFiles = false
        #expect(!BotAwareness.whereYouAre(noTools).contains("You can read only"))
    }

    @Test func aTurnFromTheOtherMacSaysSo() {
        var facts = place
        facts.thisMac = "Mac Studio"
        facts.ownerMac = "MacBook Air"
        facts.whyHere = "Grok isn't signed in on this MacBook Air"
        facts.codingMac = "MacBook Air"
        let text = BotAwareness.whereYouAre(facts)
        #expect(text.contains("running on Sam's Mac Studio"))
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
        let text = BotAwareness.whereYouAre(BotPlaceFacts(owner: "Sam", thisMac: "Mac Studio", thisMacHasScreens: true))
        #expect(text.contains("no other Mac linked"))
        #expect(text.contains("hidden screens"))
    }

    @Test func whoYouAreIsBuiltFromTheBot() {
        let text = BotAwareness.whoYouAre(BotIdentityFacts(name: "Coder", owner: "Sam", job: "Writes code.", teams: ["IT guys"], managerName: "Mira", ceoName: "Theo", apps: ["Gmail"]))
        #expect(text.contains("you're Coder, Sam's bot"))
        #expect(text.contains("Your job: Writes code."))
        #expect(text.contains("on the IT guys team; your manager is Mira"))
        #expect(text.contains("use Gmail"))
        #expect(text.contains("say who on the team fits"))
        #expect(text.contains("Work out what Sam actually wants"))
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

    // MARK: The other Mac can be away

    private func turn(_ choice: DeviceChoice, on mac: DeviceKind = .macBookAir, paired: Bool = true, online: Bool, here: Bool, there: Bool = true) -> BotTurnRoute {
        DeviceRouting.botTurn(choice: choice, thisMac: mac, paired: paired, otherMacOnline: online, engineHere: here, engineThere: there)
    }

    @Test func theDefaultNeverDependsOnTheOtherMac() {
        #expect(turn(DeviceFeature.bots.defaultChoice, online: false, here: true) == .runHere)
        #expect(turn(DeviceFeature.bots.defaultChoice, online: true, here: true) == .runHere)
        #expect(turn(DeviceFeature.bots.defaultChoice, paired: false, online: false, here: true) == .runHere)
    }

    @Test func setToTheOtherMacAndItsReachable() {
        #expect(turn(.macStudio, online: true, here: true) == .sendAcross)
        #expect(turn(.macStudio, online: true, here: false) == .sendAcross)
    }

    @Test func setToTheOtherMacAndItsAwayWithTheEngineHere() {
        #expect(turn(.macStudio, online: false, here: true) == .waitForOtherMac(canRunHere: true))
    }

    @Test func setToTheOtherMacAndItsAwayWithNoEngineHere() {
        #expect(turn(.macStudio, online: false, here: false) == .waitForOtherMac(canRunHere: false))
    }

    @Test func noEngineHereGoesAcrossOnlyWhenTheOtherMacCanHelp() {
        #expect(turn(.any, online: true, here: false, there: true) == .engineOnOtherMac)
        #expect(turn(.any, online: true, here: false, there: false) == .tryHere)
        #expect(turn(.any, online: false, here: false, there: true) == .tryHere)
        #expect(turn(.any, paired: false, online: false, here: false) == .tryHere)
    }

    @Test func beingAwayIsSaidPlainly() {
        #expect(DeviceRouting.unreachableLine(otherMac: "Mac Studio", thisMac: "MacBook Air", engineProblem: nil) == "Your Mac Studio isn't reachable right now. This starts when it is.")
        let noEngine = DeviceRouting.unreachableLine(otherMac: "Mac Studio", thisMac: "MacBook Air", engineProblem: "Grok isn't signed in")
        #expect(noEngine.contains("It can't run on this MacBook Air instead: Grok isn't signed in."))
    }

    // MARK: The Macs meet again

    private struct Line: Equatable {
        let id: String
        let at: Date
    }

    private func merged(_ local: [Line], _ remote: [Line]) -> [Line] { LinkMerge.union(local: local, remote: remote, id: \.id, at: \.at) }

    @Test func offlineMessagesOnBothSidesMergeTheSameWayWithNoDuplicates() {
        let base = Date(timeIntervalSince1970: 1000)
        let shared = [Line(id: "s1", at: base), Line(id: "s2", at: base.addingTimeInterval(1))]
        // Apart, with their fractions kept: one question and answer here, another there, in the same second.
        let air = shared + [Line(id: "air-ask", at: base.addingTimeInterval(10.1)), Line(id: "air-answer", at: base.addingTimeInterval(10.3))]
        let studio = shared + [Line(id: "studio-ask", at: base.addingTimeInterval(10.2)), Line(id: "studio-answer", at: base.addingTimeInterval(10.4))]
        let onAir = merged(air, studio)
        let onStudio = merged(studio, air)
        #expect(onAir == onStudio)
        #expect(onAir.map(\.id) == ["s1", "s2", "air-ask", "studio-ask", "air-answer", "studio-answer"])
        // Again, and again: nothing doubles or moves.
        #expect(merged(onAir, onStudio) == onAir)
        #expect(merged(merged(onAir, air), studio) == onAir)
    }

    @Test func anOlderChatWithWholeSecondsKeepsItsOwnOrder() {
        let second = Date(timeIntervalSince1970: 1000)
        let lines = [Line(id: "z-question", at: second), Line(id: "a-answer", at: second), Line(id: "m-next", at: second)]
        #expect(merged(lines, []).map(\.id) == ["z-question", "a-answer", "m-next"])
        #expect(merged([], lines).map(\.id) == ["z-question", "a-answer", "m-next"])
        #expect(merged(lines, lines).map(\.id) == ["z-question", "a-answer", "m-next"])
    }

    @Test func eachMacKeepsWritingOnlyItsOwnRuns() {
        struct Run: Equatable { let id: String; let origin: String; let phase: String; let at: Date }
        let at = Date(timeIntervalSince1970: 1000)
        let mine = Run(id: "mine", origin: "Air", phase: "running", at: at)
        let theirs = Run(id: "theirs", origin: "Studio", phase: "running", at: at.addingTimeInterval(5))
        // Their copy of my run is old, and mine stands. Their own run comes through, and an update to it wins.
        let staleCopyOfMine = Run(id: "mine", origin: "Air", phase: "done", at: at)
        let once = LinkMerge.ownedRuns(local: [mine], remote: [staleCopyOfMine, theirs], isTheirs: { $0.origin != "Air" }, id: \.id, at: \.at)
        #expect(once == [mine, theirs])
        let finished = Run(id: "theirs", origin: "Studio", phase: "done", at: at.addingTimeInterval(5))
        let twice = LinkMerge.ownedRuns(local: once, remote: [finished], isTheirs: { $0.origin != "Air" }, id: \.id, at: \.at)
        #expect(twice == [mine, finished])
    }

    @Test func memoryWrittenApartEndsUpTheSameOnBoth() {
        let air = "likes tea\nadded on the Air\n"
        let studio = "likes tea\nadded on the Studio\n"
        let onAir = BotMemoryMerge.union(air, studio)
        let onStudio = BotMemoryMerge.union(studio, air)
        #expect(BotMemoryMerge.digest(onAir) == BotMemoryMerge.digest(onStudio))
        #expect(BotMemoryMerge.union(onAir, onStudio) == onAir)
        #expect(onAir.components(separatedBy: "\n").filter { $0 == "likes tea" }.count == 1)
    }

    @Test func aSessionHearsWhatItMissedAndNothingElse() {
        let ids = ["a", "b", "c", "d"]
        #expect(BotCatchUp.unheard(messages: ids, id: { $0 }, heard: "b", hasSession: true, isLinked: true) == ["c", "d"])
        #expect(BotCatchUp.unheard(messages: ids, id: { $0 }, heard: "d", hasSession: true, isLinked: true).isEmpty)
        // No record of what it heard: it knows its own chat.
        #expect(BotCatchUp.unheard(messages: ids, id: { $0 }, heard: nil, hasSession: true, isLinked: true).isEmpty)
        // A new session here on a linked Mac gets the chat's latest. On a lone Mac there's nothing it could have missed.
        #expect(BotCatchUp.unheard(messages: ids, id: { $0 }, heard: nil, hasSession: false, isLinked: true) == ids)
        #expect(BotCatchUp.unheard(messages: ids, id: { $0 }, heard: nil, hasSession: false, isLinked: false).isEmpty)
        #expect(BotCatchUp.unheard(messages: ids, id: { $0 }, heard: BotCatchUp.fromTheStart, hasSession: true, isLinked: true) == ids)
    }

    /// Day-one finding: after /new (session dropped, the whole chat marked heard) a bot on a Mac paired with the Air was still
    /// handed its last replies, so mail manager's old "Hostinger needs authorizing" came straight back.
    @Test func aFreshSessionAfterNewStartsCleanEvenWhenLinked() {
        let ids = ["a", "b", "c", "d"]
        #expect(BotCatchUp.unheard(messages: ids, id: { $0 }, heard: "d", hasSession: false, isLinked: true).isEmpty)
        // What came after /new (a message from the other Mac) still arrives.
        #expect(BotCatchUp.unheard(messages: ids, id: { $0 }, heard: "c", hasSession: false, isLinked: true) == ["d"])
    }

    @Test func aLongJobIsCutAtASentenceOrAWord() {
        let mailManager = "Reports to CEO. Owns the Hostinger/work mailbox: inbox checks, unread mail and routing, plus non-invoice digests (credit notes, promotional schemes, claims). Sends invoices on to Accountant."
        let cut = BotAwareness.shortJob(mailManager)
        #expect(cut == "Reports to CEO. Owns the Hostinger/work mailbox: inbox checks, unread mail and routing, plus non-invoice digests (credit notes, promotional schemes, claims).")
        #expect(cut.count <= BotAwareness.maximumJobCharacters)
        let oneLongSentence = String(repeating: "keeps the ledgers tidy and ", count: 10) + "more"
        let words = BotAwareness.shortJob(oneLongSentence)
        #expect(words.hasSuffix("tidy…") || words.hasSuffix("and…") || words.hasSuffix("ledgers…") || words.hasSuffix("the…") || words.hasSuffix("keeps…"))
        #expect(!words.contains("  "))
        #expect(BotAwareness.shortJob("Short job.") == "Short job.")        // Said in the "who you are" block without a full stop after the ellipsis.
        let ceo = "CEO for Adhyan. Manages department heads (COM, COP, CTO, HEAD MANAGMENT, and ops leads) and delivers a morning brief covering stock/invoices, pricing, websites, mail, and overall ops."
        let block = BotAwareness.whoYouAre(BotIdentityFacts(name: "CEO", owner: "Sam", job: BotAwareness.shortJob(ceo)))
        #expect(block.contains("…") && !block.contains("…."))
    }

    @Test func messagesFromTheOtherMacInTheMiddleAreStillHeard() {
        // The Studio's session had heard up to "here-2". What the Air wrote while apart sorts before that.
        let merged = ["here-1", "air-1", "air-2", "here-2"]
        let arrived: Set<String> = ["air-1", "air-2"]
        let heard = BotCatchUp.heardAfterMerge(heard: "here-2", merged: merged, arrived: arrived)
        #expect(heard == "here-1")
        #expect(BotCatchUp.unheard(messages: merged, id: { $0 }, heard: heard, hasSession: true, isLinked: true) == ["air-1", "air-2", "here-2"])
        // Nothing moves when they come after it.
        #expect(BotCatchUp.heardAfterMerge(heard: "here-1", merged: merged, arrived: ["here-2"]) == "here-1")
        // At the very start.
        #expect(BotCatchUp.heardAfterMerge(heard: "here-1", merged: ["air-1", "here-1"], arrived: ["air-1"]) == BotCatchUp.fromTheStart)
        #expect(BotCatchUp.heardAfterMerge(heard: nil, merged: merged, arrived: arrived) == nil)
        #expect(BotCatchUp.seenAfterMerge(seen: 4, merged: merged, arrived: arrived) == 1)
        #expect(BotCatchUp.seenAfterMerge(seen: 1, merged: merged, arrived: ["here-2"]) == 1)
    }

    @Test func aCatchUpStaysASensibleSize() {
        let long = String(repeating: "x", count: 5000)
        let lines = BotCatchUp.lines((0..<50).map { (who: "Bot\($0)", text: long) })
        #expect(lines.count * BotCatchUp.maximumCharactersEach <= BotCatchUp.maximumCharactersTotal + BotCatchUp.maximumCharactersEach)
        #expect(lines.allSatisfy { $0.count <= BotCatchUp.maximumCharactersEach + 8 })
        // The newest are the ones kept.
        #expect(lines.last?.hasPrefix("Bot49:") == true)
        #expect(lines.joined().count <= BotCatchUp.maximumCharactersTotal)
        #expect(BotCatchUp.lines([(who: "A", text: "hi")]) == ["A: hi"])
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

    @Test func aFolderWithMoreToDoIsntOnlyAFolder() {
        #expect(ProjectWords.asksOnlyForFolder("make a new folder called moon-site"))
        #expect(ProjectWords.asksOnlyForFolder("make a folder called theo-test-1 please"))
        #expect(ProjectWords.asksOnlyForFolder("new folder called moon-site on this Mac"))
        #expect(!ProjectWords.asksOnlyForFolder("make a folder called theo-test-1 and put hello.txt in it"))
        #expect(!ProjectWords.asksOnlyForFolder("make a new folder called moon and build a site in it"))
        #expect(ProjectWords.newFolderName(in: "make a folder called theo-test-1 and put hello.txt in it") == "theo-test-1")
    }

    @Test func aTellCanHoldBracketsAndRunOverSeveralLines() {
        let brackets = ClickyOrder.extract(from: "ok [TELL: Coder: is arr[0] safe?] thanks")
        #expect(brackets.text == "ok  thanks")
        #expect(ClickyOrder.tellTarget(in: brackets.orders[0])?.message == "is arr[0] safe?")
        let lines = ClickyOrder.extract(from: "[TELL: Coder: first line\n\nsecond line]")
        #expect(ClickyOrder.tellTarget(in: lines.orders[0])?.message == "first line\n\nsecond line")
        let long = String(repeating: "word ", count: 2000)
        #expect(ClickyOrder.tellTarget(in: ClickyOrder.extract(from: "[TELL: Coder: \(long)]").orders[0])?.message == long.trimmingCharacters(in: .whitespaces))
    }

    @Test func aTellWithNoClosingBracketStillGoes() {
        let open = ClickyOrder.extract(from: "Asking now. [TELL: Coder: which database\n\nAnything else.")
        #expect(ClickyOrder.tellTarget(in: open.orders[0])?.message == "which database")
        #expect(open.text.contains("Anything else."))
    }

    @Test func noTellIsDroppedOverACount() {
        let many = (1...5).map { "[TELL: Bot\($0): hello]" }.joined(separator: "\n")
        #expect(ClickyOrder.extract(from: many).orders.count == 5)
        let clicky = (1...5).map { "[CLICKY: job \($0)]" }.joined(separator: "\n")
        #expect(ClickyOrder.extract(from: clicky).orders.count == ClickyOrder.maximumPerReply)
    }

    @Test func aTagBeingTalkedAboutStaysInTheWords() {
        let said = ClickyOrder.extract(from: "I won't use [TELL: name: what to do] for that.")
        #expect(said.orders.isEmpty)
        #expect(said.text.contains("[TELL: name: what to do]"))
    }

    @Test func aTagBeingWrittenStaysHiddenWhileItStreams() {
        #expect(ClickyOrder.withoutTags(streaming: "Asking now. [TELL: Coder: is arr[0] saf") == "Asking now. ")
        #expect(ClickyOrder.withoutTags(streaming: "Asking now. [TEL") == "Asking now. ")
        #expect(ClickyOrder.withoutTags(streaming: "Done [TELL: Coder: hi] and more") == "Done  and more")
    }

    @Test func onlyCodeTalkCountsAsCarryingOnACodingChat() {
        #expect(CodingIntent.mentionsCodeWork("continue that thread in the moon folder"))
        #expect(CodingIntent.mentionsCodeWork("carry on the Codex chat"))
        #expect(!CodingIntent.mentionsCodeWork("let's continue where we left off"))
    }

    @Test func theProjectsFolderIsSaidTheWayAnAgentsShellReadsIt() {
        let usual = BotAwareness.whereYouAre(BotPlaceFacts(owner: "Sam", thisMac: "Mac Studio", projects: ["moon"]))
        #expect(usual.contains("(~/Projects: moon)"))
        let elsewhere = BotAwareness.whereYouAre(BotPlaceFacts(owner: "Sam", thisMac: "Mac Studio", projects: ["moon"], projectsFolder: "/tmp/test home/Projects"))
        #expect(elsewhere.contains("(/tmp/test home/Projects: moon)"))
        #expect(!elsewhere.contains("~/Projects"))
    }

    @Test func theFinalPromptNeverSendsTheAgentToAFolder() {
        #expect(BotProtocol.mergeNote(owner: "Sam").contains("never tell the agent to create or go to a folder"))
        #expect(BotProtocol.planNote(hasOthers: false, owner: "Sam").contains("never tell the agent to create or go to a folder"))
    }

    @Test func aTagInCodeIsNotAnOrder() {
        let text = "Here's the prompt.\n\n```prompt\nMake Theo read [TELL: Coder: hello there] lines.\n```\n\n[TELL: Coder: a real one]"
        let taken = ClickyOrder.extract(from: text)
        #expect(taken.orders.count == 1)
        #expect(ClickyOrder.tellTarget(in: taken.orders.first ?? "")?.message == "a real one")
        #expect(taken.text.contains("[TELL: Coder: hello there]"))
        // In backticks it's someone showing how the tag is written.
        #expect(ClickyOrder.extract(from: "I write `[TELL: Coder: hello there]` to reach Coder.").orders.isEmpty)
        #expect(ClickyOrder.extract(from: "```\n[CLICKY: point at the Save button]\n```").orders.isEmpty)
        // The other tags the same.
        #expect(BotScreenOrder.extract(from: "```\n[SCREEN: open the notes app]\n```").orders.isEmpty)
        #expect(BotResearchOrder.extract(from: "```\n[RESEARCH: what year is it]\n```").questions.isEmpty)
        #expect(BotScreenGift.extract(from: "```\n[GIVE SCREEN: Coder: own]\n```").gifts.isEmpty)
        // And a fence never closed, still being written.
        #expect(ClickyOrder.withoutTags(streaming: "```prompt\nread [TELL: Coder: hi] lines").contains("[TELL: Coder: hi]"))
    }

    @Test func oneOwnerMessageStartsAChatsLimitsOverOnce() {
        var mark = OwnerMessageMark()
        let asked = [("group", "theo#1"), ("group", "theo#1"), ("group", "theo#1"), ("other", "theo#1"), ("group", "theo#2")].map { mark.isNew(room: $0.0, message: $0.1) }
        #expect(asked == [true, false, false, true, true])
    }

    @Test func catchUpLooksItsPlaceUpAmongEverything() {
        // What it heard last was a card or a note, which aren't words to read.
        let all = ["said here", "CARD", "said on the Air"]
        func unheard(_ heard: String?) -> [String] {
            BotCatchUp.unheard(messages: all, id: { $0 }, heard: heard, hasSession: true, isLinked: true, counts: { $0 != "CARD" })
        }
        #expect(unheard("CARD") == ["said on the Air"])
        #expect(unheard("said here") == ["said on the Air"])
        #expect(unheard(BotCatchUp.fromTheStart) == ["said here", "said on the Air"])
        #expect(unheard("gone") == [])
    }

    @Test func runsThatWaitedLongAskFirstAndRepeatsCollapseWhenTheMacIsBack() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        func item(_ id: String, _ action: String, title: String? = nil, prompt: String? = nil, minutesAgo: Double) -> DeviceRouting.WaitingItem {
            .init(id: id, action: action, title: title, prompt: prompt, at: now.addingTimeInterval(-minutesAgo * 60))
        }
        // 5 Nov: the same run asked for three times on the Air over a morning, plus a message, a fresh run and a two-day-old one.
        let items = [item("r1", "run", title: "Black Hole Explainer", prompt: "p", minutesAgo: 240),
                     item("r2", "run", title: "Black Hole Explainer", prompt: "p", minutesAgo: 120),
                     item("r3", "run", title: "Black Hole Explainer", prompt: "p", minutesAgo: 60),
                     item("m1", "botSay", minutesAgo: 60),
                     item("r4", "run", title: "Moon page", prompt: "q", minutesAgo: 2),
                     item("r5", "run", title: "Old", prompt: "z", minutesAgo: 2 * 24 * 60)]
        let plan = DeviceRouting.planForReconnect(items, now: now)
        #expect(plan.duplicates == ["r1", "r2"])
        #expect(plan.askFirst == ["r3"])
        #expect(plan.send == ["m1", "r4"])
        #expect(plan.stale == ["r5"])
        #expect(DeviceRouting.waitedText(since: now.addingTimeInterval(-3 * 3600 - 50), now: now) == "3 hours")
        #expect(DeviceRouting.waitedText(since: now.addingTimeInterval(-40 * 60), now: now) == "40 minutes")
    }

    @Test func aWaitingItemGoesStaleAfterADay() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        #expect(!DeviceRouting.hasWaitedTooLong(since: start, now: start.addingTimeInterval(DeviceRouting.maximumWaitSeconds)))
        #expect(DeviceRouting.hasWaitedTooLong(since: start, now: start.addingTimeInterval(DeviceRouting.maximumWaitSeconds + 1)))
    }

    @Test func aFileThatHasEverythingStaysAsItIs() {
        // The live file holds all of the backup's lines and more: it's taken as it is, in its own order, headings and all.
        let older = "- likes tea\n"
        let newer = "# Notes\n\n- likes tea\n\n# Work\n\n- uses Hinglish\n"
        #expect(BotMemoryMerge.union(older, newer) == newer)
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
        let merged = BotMemoryMerge.union("likes tea\nuses Hinglish\nnotes\n", "uses Hinglish\n  likes tea  \nprefers Haiku\n")
        #expect(merged == "likes tea\nuses Hinglish\nnotes\nprefers Haiku\n")
        #expect(BotMemoryMerge.union("", "") == "")
        // A file moved or merged keeps its layout: only what's new is added.
        let notes = "# Notes\n\n- likes tea\n\n- uses Hinglish\n"
        #expect(BotMemoryMerge.union("", notes) == notes)
        #expect(BotMemoryMerge.union(notes, notes) == notes)
        #expect(BotMemoryMerge.union(notes, "- prefers Haiku") == notes + "- prefers Haiku\n")
        #expect(BotMemoryMerge.union("no newline", "- new") == "no newline\n- new\n")
        #expect(BotMemoryMerge.digest("a\nb\n") == BotMemoryMerge.digest("b\na"))
        #expect(BotMemoryMerge.digest("a\nb") != BotMemoryMerge.digest("a"))
    }

    @Test func skillsTravelAndDeletionsStick() {
        let t0 = Date(timeIntervalSince1970: 1000), t1 = Date(timeIntervalSince1970: 2000)
        let a = SkillCopy(text: "steps A", modifiedAt: t0), a2 = SkillCopy(text: "steps A, better", modifiedAt: t1), b = SkillCopy(text: "steps B", modifiedAt: t0)
        // First time: whatever's new comes over.
        var r = BotSkillSync.merged(mine: [:], theirs: ["ledger/invoice": a], lastTheirs: nil)
        #expect(r.write == ["ledger/invoice": a] && r.delete.isEmpty)
        // Edited there later: the newer one wins; edited here later: this one stays.
        r = BotSkillSync.merged(mine: ["ledger/invoice": a], theirs: ["ledger/invoice": a2], lastTheirs: ["ledger/invoice"])
        #expect(r.write == ["ledger/invoice": a2])
        r = BotSkillSync.merged(mine: ["ledger/invoice": a2], theirs: ["ledger/invoice": a], lastTheirs: ["ledger/invoice"])
        #expect(r.write.isEmpty)
        // Dropped there: dropped here. Dropped here: not brought back. New here: kept.
        r = BotSkillSync.merged(mine: ["ledger/invoice": a, "shared/b": b], theirs: [:], lastTheirs: ["ledger/invoice"])
        #expect(r.delete == ["ledger/invoice"] && r.write.isEmpty)
        r = BotSkillSync.merged(mine: [:], theirs: ["ledger/invoice": a], lastTheirs: ["ledger/invoice"])
        #expect(r.write.isEmpty && r.delete.isEmpty)
        #expect(BotSkillSync.key(owner: "ledger", folder: "../x") == nil)
        #expect(BotSkillSync.key(owner: "shared", folder: "invoice") == "shared/invoice")
        #expect(BotSkillSync.digest(["x/a": a, "x/b": b]) == BotSkillSync.digest(["x/b": b, "x/a": a]))
    }

    @Test func aTidyUpOnOneMacSticksOnBoth() {
        let old = "# Notes\n- likes tea\n- likes tea a lot\n- uses Hinglish\n- temp: call bank\n"
        let tidy = "# Notes\n- likes tea (a lot)\n- uses Hinglish\n"
        // The Studio tidied; the Air still has the old file, which is what the Studio heard from it last.
        let onStudio = BotMemoryMerge.merged(mine: tidy, theirs: old, lastTheirs: old)
        #expect(onStudio == tidy)
        let onAir = BotMemoryMerge.merged(mine: old, theirs: tidy, lastTheirs: old)
        #expect(onAir == tidy)
        // Meanwhile the Air learned something new: it stays, and the tidy-up still holds.
        let airNew = old + "- prefers Haiku\n"
        let airAfter = BotMemoryMerge.merged(mine: airNew, theirs: tidy, lastTheirs: old)
        #expect(airAfter == "# Notes\n- uses Hinglish\n- prefers Haiku\n- likes tea (a lot)\n")
        let studioAfter = BotMemoryMerge.merged(mine: tidy, theirs: airAfter, lastTheirs: old)
        #expect(BotMemoryMerge.digest(studioAfter) == BotMemoryMerge.digest(airAfter))
        // A line dropped here that the other Mac still has (and had before) stays dropped.
        #expect(BotMemoryMerge.merged(mine: "a\nc\n", theirs: "a\nb\nc\n", lastTheirs: "a\nb\nc\n") == "a\nc\n")
        // Emptied on one Mac: emptied on the other.
        #expect(BotMemoryMerge.merged(mine: "a\nb\n", theirs: "", lastTheirs: "a\nb\n") == "")
        // Never heard from that Mac: the union, as before.
        #expect(BotMemoryMerge.merged(mine: "a\n", theirs: "b\n", lastTheirs: nil) == "a\nb\n")
    }
}
