import Foundation
import Testing
@testable import ClickyCore

/// "update it to the Claude Code project called Mahajan motor work": the
/// named-destination trigger, the yes/no answer and the 60 s offer, the
/// project matcher (words, initials, aliases, close scores, the pick card's
/// spoken answers), ~/.claude/projects name decoding, the forked-session
/// argv, and the screenshot attachment helpers.
struct NamedProjectTests {
    // MARK: - Trigger

    @Test func theOwnersOwnPhraseNamesMahajanMotorWork() throws {
        let transcript = "can you screenshot the changes and update it to the Claud code projects called Mahajan motor work so it can update it"
        let match = try #require(NamedProjectTrigger.match(transcript: transcript))
        #expect(match.projectName == "Mahajan Motor Work")
        #expect(match.taskText == "can you screenshot the changes and update it so it can update it")
        #expect(match.destinationPhrase == "to the Claud code projects called Mahajan motor work")
        // The plain bridge doesn't fire on it.
        #expect(ProjectSendTrigger.match(transcript: transcript) == nil)
    }

    @Test(arguments: [
        ("send this to the scratch helpers project add a multiply function", "Scratch Helpers", "add a multiply function"),
        ("send it to my Mahajan project, fix the header", "Mahajan", "fix the header"),
        ("send to MMI website project: update the banner", "MMI Website", "update the banner"),
        ("tell the billing project to add GST", "Billing", "to add GST"),
        ("ask my partatlas project why the build fails", "Partatlas", "why the build fails"),
        ("in my scratch helpers project, update the readme and send it", "Scratch Helpers", "update the readme and send it"),
        ("send this to the claude code project named Shivaurra, swap the logo", "Shivaurra", "swap the logo"),
        ("update the hero image in the project called MMI Website please", "MMI Website", "update the hero image please"),
        ("send this over to the dunder mifflin project", "Dunder Mifflin", "")
    ])
    func namedDestinations(transcript: String, projectName: String, taskText: String) throws {
        let match = try #require(NamedProjectTrigger.match(transcript: transcript))
        #expect(match.projectName == projectName)
        #expect(match.taskText == taskText)
    }

    @Test(arguments: [
        "send this to my project fix the login page",
        "send it to the project, update the readme",
        "tell my project to bump the version",
        "send this to the clicky project fix the tests",
        "send it to the project called clicky",
        "tell me about the project",
        "what's in the project called Mahajan",
        "don't send this to the Mahajan project",
        "never update it to the project called Mahajan motor work",
        "in my scratch project there's a bug",
        "send this to [the Mahajan project] fix it",
        "the project called Mahajan is big"
    ])
    func notANamedDestination(transcript: String) {
        #expect(NamedProjectTrigger.match(transcript: transcript) == nil)
    }

    @Test func aLongNameIsCutToSixtyCharacters() throws {
        let longName = Array(repeating: "alpha", count: 20).joined(separator: " ")
        let match = try #require(NamedProjectTrigger.match(transcript: "update it to the project called \(longName)"))
        #expect(match.projectName.count <= NamedProjectTrigger.maximumNameLength)
        #expect(match.projectName.hasPrefix("Alpha Alpha"))
    }

    // MARK: - Yes / no and the offer

    @Test(arguments: ["yes", "Yeah.", "do it", "go ahead", "sure", "okay", "OK please", "yes please", "yeah go ahead", "sure, do it clicky"])
    func yes(transcript: String) {
        #expect(SpokenConfirmation.parse(transcript) == .yes)
    }

    @Test(arguments: ["no", "No thanks", "cancel", "nope", "never mind", "don't do it", "no, cancel that"])
    func no(transcript: String) {
        #expect(SpokenConfirmation.parse(transcript) == .no)
    }

    @Test(arguments: ["what's the weather", "yes and also open the website", "", "thank you", "send it to the billing project"])
    func notAYesOrNo(transcript: String) {
        #expect(SpokenConfirmation.parse(transcript) == .other)
    }

    @Test func theOfferLastsSixtySeconds() {
        let createdAt = Date(timeIntervalSince1970: 1_000)
        let offer = NamedProjectOffer(projectName: "Mahajan Motor Work", taskText: "update the banner", createdAt: createdAt)
        #expect(NamedProjectOffer.resolve(offer, transcript: "yes", now: createdAt.addingTimeInterval(30)) == .accept(offer))
        #expect(NamedProjectOffer.resolve(offer, transcript: "no", now: createdAt.addingTimeInterval(59)) == .decline)
        #expect(NamedProjectOffer.resolve(offer, transcript: "yes", now: createdAt.addingTimeInterval(61)) == .notAnAnswer)
        #expect(NamedProjectOffer.resolve(offer, transcript: "what time is it", now: createdAt.addingTimeInterval(5)) == .notAnAnswer)
        #expect(NamedProjectOffer.resolve(nil, transcript: "yes", now: createdAt) == .notAnAnswer)
        #expect(offer.isExpired(at: createdAt.addingTimeInterval(-1)))
    }

    @Test func spokenLines() {
        #expect(NamedProjectSpeech.offerLine(projectName: "Mahajan Motor India Works")
            == "I can only send to the Clicky project right now. Want me to open Claude at Mahajan Motor India Works and put your message in the box for you to send?")
        #expect(NamedProjectSpeech.declineLine == "Okay, I won't.")
        #expect(NamedProjectSpeech.pasteFallbackLine(projectName: "Mahajan Motor India Works")
            == "I've copied it and brought Claude up — open Mahajan Motor India Works and paste it.")
        #expect(NamedProjectSpeech.clipboardText(taskText: "fix the banner", screenshotPath: "/tmp/s.png") == "fix the banner\nScreenshot: /tmp/s.png")
        #expect(NamedProjectSpeech.clipboardText(taskText: "fix the banner", screenshotPath: nil) == "fix the banner")
        #expect(NamedProjectSpeech.whichProjectLine(["mmi-website", "mmi-counter-billing"]) == "Which project — mmi-website or mmi-counter-billing?")
    }

    // MARK: - Matching

    static let home = "/Users/owner"
    static let mmiWebsite = ProjectFolderCandidate(path: "\(home)/mmi-website", isGitRepository: true,
                                                  remoteURL: "https://github.com/adhyanmahajan26-boop/mmi-website.git", source: .localRepository)
    static let mmiBilling = ProjectFolderCandidate(path: "\(home)/Projects/mmi-counter-billing", isGitRepository: true, source: .localRepository)
    static let mmiProject = ProjectFolderCandidate(path: "\(home)/Documents/mmi-project", isGitRepository: false, source: .claudeProject)
    static let mmiMail = ProjectFolderCandidate(path: "\(home)/jstest/mmi-mail", isGitRepository: false, source: .claudeProject)
    static let scratch = ProjectFolderCandidate(path: "\(home)/Projects/clicky-scratch", isGitRepository: true, source: .localRepository)
    static let partatlas = ProjectFolderCandidate(path: "\(home)/Projects/partatlas", isGitRepository: true, source: .localRepository)
    static let shivaurra = ProjectFolderCandidate(path: "\(home)/shivaurra", isGitRepository: true, source: .localRepository)
    static let allFolders = [scratch, partatlas, shivaurra, mmiWebsite, mmiBilling, mmiProject, mmiMail]

    @Test func mahajanMotorWorkFindsMMIWebsiteByItsInitials() {
        #expect(ProjectDestinationMatcher.score(spokenName: "Mahajan motor work", candidateName: "mmi-website") >= ProjectDestinationMatcher.confidentScore)
        #expect(ProjectDestinationMatcher.score(spokenName: "Mahajan Motor India Works", candidateName: "mmi-website") >= 0.9)
        #expect(ProjectDestinationMatcher.score(spokenName: "MMI website", candidateName: "mmi-website") == 1)
        #expect(ProjectDestinationMatcher.score(spokenName: "MMI", candidateName: "mahajan-motors-india") >= 0.9)
        #expect(ProjectDestinationMatcher.score(spokenName: "Mahajan motor work", candidateName: "partatlas") < ProjectDestinationMatcher.minimumPickScore)
        #expect(ProjectDestinationMatcher.score(spokenName: "Mahajan motor work", candidateName: "shivaurra") < ProjectDestinationMatcher.minimumPickScore)

        let decision = ProjectDestinationMatcher.decide(spokenName: "Mahajan motor work", requestText: "update the banner",
                                                        candidates: [Self.scratch, Self.partatlas, Self.mmiWebsite], aliases: [:])
        guard case .confident(let top) = decision else { Issue.record("expected a confident match, got \(decision)"); return }
        #expect(top.candidate == Self.mmiWebsite)
    }

    @Test func severalMMIFoldersMakeAPickWithTheWebsitePreselected() {
        let decision = ProjectDestinationMatcher.decide(spokenName: "Mahajan motor work", requestText: "screenshot the changes and update it",
                                                        candidates: Self.allFolders, aliases: [:])
        guard case .pick(let rows, let preselectedIndex) = decision else { Issue.record("expected a pick, got \(decision)"); return }
        #expect(Set(rows.map(\.candidate)) == [Self.mmiWebsite, Self.mmiBilling, Self.mmiProject, Self.mmiMail])
        #expect(rows[preselectedIndex].candidate == Self.mmiWebsite)
        // Without a web hint the repo with a remote still wins the preselection.
        if case .pick(let plainRows, let plainIndex) = ProjectDestinationMatcher.decide(spokenName: "Mahajan motor work", requestText: "add GST",
                                                                                        candidates: Self.allFolders, aliases: [:]) {
            #expect(plainRows[plainIndex].candidate == Self.mmiWebsite)
        } else {
            Issue.record("expected a pick")
        }
    }

    @Test func closeScoreDecision() {
        let first = ProjectFolderCandidate(path: "/r/alpha-tools", isGitRepository: true, source: .localRepository)
        let second = ProjectFolderCandidate(path: "/r/alpha-tool", isGitRepository: true, source: .localRepository)
        let far = ProjectFolderCandidate(path: "/r/zebra", isGitRepository: true, source: .localRepository)
        // Two equally good names → pick.
        if case .pick(let rows, _) = ProjectDestinationMatcher.decide(spokenName: "alpha tools", requestText: "", candidates: [first, second, far], aliases: [:]) {
            #expect(rows.count == 2)
        } else {
            Issue.record("expected a pick")
        }
        // One clear winner → confident.
        if case .confident(let top) = ProjectDestinationMatcher.decide(spokenName: "zebra", requestText: "", candidates: [first, second, far], aliases: [:]) {
            #expect(top.candidate == far)
        } else {
            Issue.record("expected confident")
        }
        // Nothing near → no match (the Claude-app offer).
        #expect(ProjectDestinationMatcher.decide(spokenName: "Mahajan Motor India Works", requestText: "", candidates: [first, far], aliases: [:]) == .noMatch)
        #expect(ProjectDestinationMatcher.decide(spokenName: "anything", requestText: "", candidates: [], aliases: [:]) == .noMatch)
    }

    @Test func scratchHelpersProjectFindsClickyScratch() {
        let decision = ProjectDestinationMatcher.decide(spokenName: "Scratch Helpers", requestText: "add a multiply function",
                                                        candidates: Self.allFolders, aliases: [:])
        guard case .confident(let top) = decision else { Issue.record("expected confident, got \(decision)"); return }
        #expect(top.candidate == Self.scratch)
    }

    @Test func aSavedAliasWinsOutright() {
        var aliases: [String: String] = [:]
        aliases = ProjectAliasBook.adding(spokenName: "The Mahajan Motor Work project", path: Self.mmiWebsite.path, to: aliases)
        #expect(aliases == ["mahajan motor work": Self.mmiWebsite.path])
        #expect(ProjectAliasBook.lookup(spokenName: "mahajan motor work", in: aliases) == Self.mmiWebsite.path)
        #expect(ProjectAliasBook.lookup(spokenName: "Mahajan, Motor Work!", in: aliases) == Self.mmiWebsite.path)
        #expect(ProjectAliasBook.lookup(spokenName: "mahajan", in: aliases) == nil)
        #expect(ProjectDestinationMatcher.decide(spokenName: "Mahajan Motor Work", requestText: "", candidates: Self.allFolders, aliases: aliases)
            == .alias(Self.mmiWebsite))
        // An alias to a folder that is gone is ignored.
        let staleAliases = ProjectAliasBook.adding(spokenName: "mahajan motor work", path: "/gone/mmi-website", to: [:])
        if case .alias = ProjectDestinationMatcher.decide(spokenName: "Mahajan Motor Work", requestText: "", candidates: Self.allFolders, aliases: staleAliases) {
            Issue.record("a stale alias must not win")
        }
        let removed = ProjectAliasBook.removing(key: "mahajan motor work", from: aliases)
        #expect(removed.isEmpty)
        #expect(ProjectAliasBook.rows(["b": "/2", "a": "/1"]).map(\.key) == ["a", "b"])
    }

    @Test func mergedCandidatesKeepTheRepoEntry() {
        let decodedTwin = ProjectFolderCandidate(path: Self.mmiWebsite.path + "/", isGitRepository: false, source: .claudeProject)
        let merged = ProjectFolderCandidate.merged(repositories: [Self.mmiWebsite], claudeProjects: [decodedTwin, Self.mmiMail])
        #expect(merged == [Self.mmiWebsite, Self.mmiMail])
    }

    // MARK: - The spoken answer to the pick card

    @Test func pickReplies() {
        let rows = [Self.mmiWebsite, Self.mmiBilling, Self.mmiProject, Self.mmiMail]
        #expect(ProjectPickReply.parse("the website one", rows: rows, preselectedIndex: 0) == .choose(0))
        #expect(ProjectPickReply.parse("billing", rows: rows, preselectedIndex: 0) == .choose(1))
        #expect(ProjectPickReply.parse("the mail one", rows: rows, preselectedIndex: 0) == .choose(3))
        #expect(ProjectPickReply.parse("the second one", rows: rows, preselectedIndex: 0) == .choose(1))
        #expect(ProjectPickReply.parse("the last one", rows: rows, preselectedIndex: 0) == .choose(3))
        #expect(ProjectPickReply.parse("yes", rows: rows, preselectedIndex: 2) == .choose(2))
        #expect(ProjectPickReply.parse("that one", rows: rows, preselectedIndex: 1) == .choose(1))
        #expect(ProjectPickReply.parse("cancel", rows: rows, preselectedIndex: 0) == .cancel)
        #expect(ProjectPickReply.parse("what's the weather in Delhi", rows: rows, preselectedIndex: 0) == .notAReply)
    }

    // MARK: - ~/.claude/projects names

    @Test func claudeProjectNamesDecodeToExistingFolders() {
        let folders: Set<String> = ["/Users", "/Users/owner", "/Users/owner/mmi-website", "/Users/owner/dunder-mifflin",
                                    "/Users/owner/dunder-mifflin/projects", "/Users/owner/dunder-mifflin/projects/paper-story-v2",
                                    "/Users/owner/Projects", "/Users/owner/Projects/clicky_scratch", "/Users/owner/Documents", "/Users/owner/Documents/my app"]
        let isDirectory: (String) -> Bool = { folders.contains($0) }
        #expect(ClaudeProjectDirectory.encodedName(forPath: "/Users/owner/mmi-website") == "-Users-owner-mmi-website")
        #expect(ClaudeProjectDirectory.encodedName(forPath: "/Users/owner/.clicky/x_y") == "-Users-owner--clicky-x-y")
        #expect(ClaudeProjectDirectory.decodedPath(fromDirectoryName: "-Users-owner-mmi-website", isDirectory: isDirectory) == "/Users/owner/mmi-website")
        #expect(ClaudeProjectDirectory.decodedPath(fromDirectoryName: "-Users-owner-dunder-mifflin-projects-paper-story-v2", isDirectory: isDirectory)
            == "/Users/owner/dunder-mifflin/projects/paper-story-v2")
        #expect(ClaudeProjectDirectory.decodedPath(fromDirectoryName: "-Users-owner-Projects-clicky-scratch", isDirectory: isDirectory) == "/Users/owner/Projects/clicky_scratch")
        #expect(ClaudeProjectDirectory.decodedPath(fromDirectoryName: "-Users-owner-Documents-my-app", isDirectory: isDirectory) == "/Users/owner/Documents/my app")
        #expect(ClaudeProjectDirectory.decodedPath(fromDirectoryName: "-Users-owner-gone-folder", isDirectory: isDirectory) == nil)

        #expect(ClaudeProjectDirectory.isCandidateName("-Users-owner-mmi-website", homeDirectory: "/Users/owner"))
        #expect(!ClaudeProjectDirectory.isCandidateName("-Users-owner--clicky-worktrees-x", homeDirectory: "/Users/owner"))
        #expect(!ClaudeProjectDirectory.isCandidateName("-Users-owner-Library-Application-Support-Claude-x", homeDirectory: "/Users/owner"))
        #expect(!ClaudeProjectDirectory.isCandidateName("-private-tmp", homeDirectory: "/Users/owner"))
        #expect(!ClaudeProjectDirectory.isCandidateName("-Users-owner", homeDirectory: "/Users/owner"))
    }

    @Test func newestSessionByModificationDate() {
        let older = "11111111-2222-3333-4444-555555555555"
        let newer = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        let entries: [(name: String, modificationDate: Date)] = [
            (older + ".jsonl", Date(timeIntervalSince1970: 10)),
            (newer + ".jsonl", Date(timeIntervalSince1970: 20)),
            ("notes.jsonl", Date(timeIntervalSince1970: 99)),
            ("--dangerously-skip-permissions.jsonl", Date(timeIntervalSince1970: 98)),
            ("memory", Date(timeIntervalSince1970: 97))
        ]
        #expect(ClaudeProjectDirectory.newestSessionIdentifier(in: entries) == newer.lowercased())
        #expect(ClaudeProjectDirectory.newestSessionIdentifier(in: []) == nil)
    }

    // MARK: - The forked session in the agent's argv

    static func invocation(session: AgentInvocation.Session) -> AgentInvocation {
        AgentInvocation(prompt: "update the banner", contextDirectoryPath: "/c", outboxDirectoryPath: "/o", emptyGHConfigDirectoryPath: "/g",
                        ownership: .own, isReadOnly: false, bashAllowed: false, session: session)
    }

    @Test func forkingTheOwnersSessionAddsResumeAndForkSession() {
        let sessionID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let invocation = Self.invocation(session: .forkOwnerSession(identifier: sessionID, fallbackNewIdentifier: "ffffffff-0000-1111-2222-333333333333"))
        var supportedFlags = Set(AgentFlagSupport.allAgentFlags)
        supportedFlags.insert("--fork-session")
        let (arguments, droppedFlags) = invocation.arguments(supportedFlags: supportedFlags)
        let resumeIndex = arguments.firstIndex(of: "--resume")
        #expect(resumeIndex.map { arguments[$0 + 1] } == sessionID)
        #expect(arguments.contains("--fork-session"))
        #expect(!arguments.contains("--session-id"))
        #expect(droppedFlags.isEmpty)
        #expect(AgentInvocation.forbiddenTokens(in: arguments).isEmpty)
        // Every isolation flag is still there.
        for flag in ["-p", "--permission-mode", "--strict-mcp-config", "--tools", "--settings", "--setting-sources", "--disable-slash-commands"] {
            #expect(arguments.contains(flag), "missing \(flag)")
        }
        #expect(invocation.missingRequiredFlags(supportedFlags: supportedFlags).isEmpty)
    }

    @Test func withoutForkSessionItStartsFreshAndNeverResumesTheOriginal() {
        let fallbackID = "ffffffff-0000-1111-2222-333333333333"
        let invocation = Self.invocation(session: .forkOwnerSession(identifier: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", fallbackNewIdentifier: fallbackID))
        let supportedFlags = Set(AgentFlagSupport.allAgentFlags).subtracting(["--fork-session"])
        let (arguments, droppedFlags) = invocation.arguments(supportedFlags: supportedFlags)
        #expect(!arguments.contains("--resume"))
        #expect(!arguments.contains("--fork-session"))
        #expect(arguments.firstIndex(of: "--session-id").map { arguments[$0 + 1] } == fallbackID)
        #expect(droppedFlags == ["--fork-session"])
    }

    @Test func aForkThatNeverStartedIsRetriedFresh() {
        func report(_ outcome: AgentRunOutcome, session: String?) -> AgentRunReport {
            AgentRunReport(outcome: outcome, droppedFlags: [], sessionIdentifier: session, processIdentifier: nil, isProcessGroupReaped: true)
        }
        #expect(CodeTaskEngine.shouldRetryFresh(after: report(.reportedError("No conversation found"), session: nil)))
        #expect(CodeTaskEngine.shouldRetryFresh(after: report(.endedWithoutResult, session: nil)))
        #expect(!CodeTaskEngine.shouldRetryFresh(after: report(.endedWithoutResult, session: "s")))
        #expect(!CodeTaskEngine.shouldRetryFresh(after: report(.cancelled, session: nil)))
        #expect(!CodeTaskEngine.shouldRetryFresh(after: report(.initRejected([.notAnInitEvent]), session: nil)))
    }

    // MARK: - Screenshot attachments

    @Test func attachmentHelpers() {
        #expect(CodeTaskAttachments.excludeFileText(adding: "") == "# Clicky: screenshots for the code agent (never committed)\n/.clicky-attachments/\n")
        let once = CodeTaskAttachments.excludeFileText(adding: "*.log")
        #expect(once.hasPrefix("*.log\n"))
        #expect(CodeTaskAttachments.excludeFileText(adding: once) == once)
        #expect(CodeTaskAttachments.attachmentFileName(index: 0) == "screenshot.png")
        #expect(CodeTaskAttachments.attachmentFileName(index: 1) == "screenshot-2.png")
        #expect(CodeTaskAttachments.promptLines(fileNames: []) == "")
        #expect(CodeTaskAttachments.promptLines(fileNames: ["screenshot.png"]).contains(".clicky-attachments/screenshot.png"))
    }

    @Test func repoRootDepths() {
        #expect(LocalRepoIndexer.maximumDepth(forRoot: "/Users/owner", homeDirectory: "/Users/owner") == 1)
        #expect(LocalRepoIndexer.maximumDepth(forRoot: "/Users/owner/Projects", homeDirectory: "/Users/owner") == 3)
        #expect(LocalRepoIndexer.maximumDepth(forRoot: "/Users/owner/Documents", homeDirectory: "/Users/owner") == 2)
        #expect(LocalRepoIndexer.maximumDepth(forRoot: "/Users/owner/jstest/", homeDirectory: "/Users/owner") == 2)
        #expect(LocalRepoIndexer.maximumDepth(forRoot: "/Users/owner/Code", homeDirectory: "/Users/owner") == 3)
    }
}

/// Live: "send this to my project, Mahajan motor Works project that what's the update on…" went to
/// the bridge with "motor Works project that…" left over.
@Test func bridgeLeftoverNamingAnotherProjectIsRerouted() throws {
    let named = try #require(NamedProjectTrigger.leadingProjectName(in: "motor Works project that what's the update on the Mahajan motor website AI visibility"))
    #expect(named.name == "Motor Works")
    #expect(named.rest.hasPrefix("that what's the update"))
    #expect(NamedProjectTrigger.leadingProjectName(in: "add a multiply function to utils") == nil)
    #expect(NamedProjectTrigger.leadingProjectName(in: "my project needs a new readme") == nil)
}

@Test func questionsForAProjectAreQuestions() {
    #expect(NamedProjectTrigger.isQuestion("that what's the update on the Mahajan motor website AI visibility"))
    #expect(NamedProjectTrigger.isQuestion("is the deploy done?"))
    #expect(!NamedProjectTrigger.isQuestion("make 3G9024 use the photo of 4G9089"))
    #expect(!NamedProjectTrigger.isQuestion("add a subtract function with a test"))
}
