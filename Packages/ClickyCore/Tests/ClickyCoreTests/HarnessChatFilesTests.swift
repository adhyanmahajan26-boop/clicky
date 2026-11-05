//
//  HarnessChatFilesTests.swift
//  ClickyCore
//
//  Reading the chats each harness already has in a folder, from text shaped like what's on the owner's Macs.
//

import Foundation
import Testing
@testable import ClickyCore

struct HarnessChatFilesTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func t3ThreadsComeNewestFirstFromItsJSON() {
        let json = """
        [{"threadId":"mcp:a05e","projectId":"p","title":"Farewell Function","status":"completed","updatedAt":"2026-11-02T16:15:37.392Z","createdAt":"2026-11-02T16:00:00.000Z"},
         {"threadId":"thread-2","title":"Newer one","updatedAt":"2026-11-03T10:00:00Z"},
         {"title":"no id"}]
        """
        let chats = HarnessChatFiles.t3Threads(json: json)
        #expect(chats.map(\.id) == ["thread-2", "mcp:a05e"])
        #expect(chats.last?.title == "Farewell Function")
    }

    @Test func t3WithNoServerOrNoProjectIsNoChats() {
        #expect(HarnessChatFiles.t3Threads(json: "No T3 Code project matches '.'. Pass a project id or a path inside a project.").isEmpty)
        #expect(HarnessChatFiles.t3Threads(json: "").isEmpty)
    }

    @Test func claudesFolderNameHasOnlyLettersDigitsAndDashes() {
        #expect(HarnessChatFiles.claudeFolderName(for: "/Users/ad/.t3/bots") == "-Users-ad--t3-bots")
        #expect(HarnessChatFiles.claudeFolderName(for: "/Users/ad/Library/Application Support/Theo/Bots/memory") == "-Users-ad-Library-Application-Support-Theo-Bots-memory")
    }

    @Test func aClaudeSessionIsNamedByItsTitleElseItsFirstMessage() {
        let lines = [
            #"{"type":"queue-operation","sessionId":"s1"}"#,
            #"{"type":"user","isMeta":true,"message":{"role":"user","content":"<command-name>/clear</command-name>"}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Fix the login bug in app.js\nmore detail"}]},"cwd":"/x"}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}}"#,
        ]
        #expect(HarnessChatFiles.claudeSession(id: "s1", lines: lines, modifiedAt: now)?.title == "Fix the login bug in app.js")
        let named = lines + [#"{"type":"ai-title","aiTitle":"Login fix"}"#]
        #expect(HarnessChatFiles.claudeSession(id: "s1", lines: named, modifiedAt: now)?.title == "Login fix")
        let custom = named + [#"{"type":"custom-title","customTitle":"My title"}"#]
        #expect(HarnessChatFiles.claudeSession(id: "s1", lines: custom, modifiedAt: now)?.title == "My title")
        #expect(HarnessChatFiles.claudeSession(id: "s1", lines: [#"{"type":"queue-operation"}"#], modifiedAt: now) == nil)
    }

    @Test func theosOwnOpeningIsntAChatsTitle() {
        #expect(HarnessChatText.title(from: "You are already in a git worktree of /x, at /y, on branch z.\n\nBuild a notes app") == "Build a notes app")
        #expect(HarnessChatText.title(from: "<system-reminder>\nReal words") == "Real words")
        #expect(HarnessChatText.title(from: "**Bold** words") == "Bold words")
        #expect(HarnessChatText.title(from: String(repeating: "a", count: 100))?.count == 60)
        #expect(HarnessChatText.title(from: "") == nil)
    }

    @Test func aCodexRolloutSaysWhereItIs() {
        let line = #"{"timestamp":"2026-11-02T12:09:46.083Z","type":"session_meta","payload":{"session_id":"01a1","id":"01a1","timestamp":"2026-11-02T12:09:42.491Z","cwd":"/Users/ad/Projects/bye-sh"}}"#
        let meta = HarnessChatFiles.codexMeta(firstLine: line)
        #expect(meta?.id == "01a1")
        #expect(meta?.cwd == "/Users/ad/Projects/bye-sh")
        #expect(HarnessChatFiles.codexMeta(firstLine: "{}") == nil)
        let titles = HarnessChatFiles.codexTitles(indexLines: [#"{"id":"01a1","thread_name":"Old","updated_at":"x"}"#, #"{"id":"01a1","thread_name":"Bye script","updated_at":"y"}"#, "junk"])
        #expect(titles["01a1"] == "Bye script")
        let lines = [line, #"{"type":"event_msg","payload":{"type":"user_message","message":"Write bye.sh"}}"#]
        #expect(HarnessChatFiles.codexFirstAsk(lines: lines) == "Write bye.sh")
    }

    @Test func cursorsFolderIsTheMD5OfThePath() {
        #expect(HarnessChatFiles.cursorFolderName(for: "/Users/adhyanmahajan/.t3/bots") == "bcde1370889db8ab544157d0a4207e86")
    }

    @Test func aCursorChatComesFromItsMetaFile() {
        let meta = #"{"schemaVersion":1,"createdAtMs":1793548450409,"hasConversation":true,"title":"Fix tests","updatedAtMs":1793548515529,"cwd":"/x"}"#
        let chat = HarnessChatFiles.cursorChat(id: "c1", metaJSON: meta, modifiedAt: now)
        #expect(chat?.title == "Fix tests")
        #expect(chat?.updatedAt == Date(timeIntervalSince1970: 1793548515.529))
        #expect(HarnessChatFiles.cursorChat(id: "c1", metaJSON: #"{"hasConversation":false,"title":"x"}"#, modifiedAt: now) == nil)
    }

    @Test func anOlderCursorChatComesFromItsStore() {
        let hex = Data(#"{"agentId":"a","name":"Old chat","mode":"default"}"#.utf8).map { String(format: "%02x", $0) }.joined()
        #expect(HarnessChatFiles.cursorChat(id: "c2", storeMetaHex: hex + "\n", modifiedAt: now)?.title == "Old chat")
        #expect(HarnessChatFiles.cursorChat(id: "c2", storeMetaHex: "zz", modifiedAt: now) == nil)
    }

    @Test func openCodeListsEveryFolderSoOnlyThisOnesComeBack() {
        let json = #"[{"id":"ses_a","title":"Bedtime story","updated":1793578560507,"created":1793443608362,"projectId":"global","directory":"/p/story"},{"id":"ses_b","title":"Other","updated":1793578560999,"directory":"/p/other"}]"#
        let chats = HarnessChatFiles.openCodeSessions(json: json, folder: "/p/story")
        #expect(chats.map(\.id) == ["ses_a"])
        #expect(chats.first?.title == "Bedtime story")
    }

    @Test func geminiChatsAreReadFromTheirFiles() {
        #expect(HarnessChatFiles.geminiSlug(projectsJSON: #"{"projects":{"/p/moon":"moon"}}"#, folder: "/p/moon") == "moon")
        #expect(HarnessChatFiles.geminiSlug(projectsJSON: #"{"projects":{}}"#, folder: "/p/moon") == nil)
        #expect(HarnessChatFiles.geminiSlug(projectsJSON: nil, folder: "/p/moon") == nil)
        let lines = """
        {"sessionId":"g-1","projectHash":"h","startTime":"2026-11-01T10:00:00.000Z","lastUpdated":"2026-11-02T10:00:00.000Z","kind":"main"}
        {"id":"m1","timestamp":"2026-11-01T10:00:01.000Z","type":"user","content":[{"text":"Fix the login bug"}]}
        {"id":"m2","timestamp":"2026-11-01T10:00:05.000Z","type":"gemini","content":"Done"}
        """
        let chat = HarnessChatFiles.geminiChat(fileText: lines, modifiedAt: now)
        #expect(chat?.id == "g-1")
        #expect(chat?.title == "Fix the login bug")
        #expect(chat?.updatedAt == HarnessChatFiles.date("2026-11-02T10:00:00.000Z"))
        let older = #"{"sessionId":"g-2","lastUpdated":"2026-11-02T10:00:00.000Z","summary":"Poem work","messages":[{"type":"user","content":"write a poem"}]}"#
        #expect(HarnessChatFiles.geminiChat(fileText: older, modifiedAt: now)?.title == "Poem work")
        #expect(HarnessChatFiles.geminiChat(fileText: #"{"sessionId":"g-3","kind":"subagent","messages":[{"type":"user","content":"x"}]}"#, modifiedAt: now) == nil)
        #expect(HarnessChatFiles.geminiChat(fileText: #"{"sessionId":"g-4"}"#, modifiedAt: now) == nil)
    }

    @Test func t3IsOnlyAskedWhenItsServerIsUp() {
        #expect(HarnessChatFiles.t3ServerPID(runtimeJSON: #"{"host":"127.0.0.1","pid":4242,"port":3783}"#) == 4242)
        #expect(HarnessChatFiles.t3ServerPID(runtimeJSON: nil) == nil)
        #expect(HarnessChatFiles.t3ServerPID(runtimeJSON: "not json") == nil)
    }

    @Test func codexsOwnListIsRead() {
        let json = #"[{"id":"t1","title":"Bye script","first_user_message":"make bye.sh","updated_at_ms":1793578560507},{"id":"t2","title":"","first_user_message":"second thing","updated_at_ms":1793578569999}]"#
        let chats = HarnessChatFiles.codexThreads(sqliteJSON: json)
        #expect(chats.map(\.id) == ["t2", "t1"])
        #expect(chats.first?.title == "second thing")
        #expect(HarnessChatFiles.codexThreads(sqliteJSON: "").isEmpty)
        #expect(HarnessChatFiles.sqliteQuoted("it's") == "'it''s'")
    }

    @Test func openCodesOwnListIsRead() {
        let chats = HarnessChatFiles.openCodeRows(sqliteJSON: #"[{"id":"ses_a","title":"Moon page","time_updated":1793578560507}]"#)
        #expect(chats.first?.title == "Moon page")
        #expect(chats.first?.updatedAt == Date(timeIntervalSince1970: 1793578560.507))
    }

    @Test func aCursorChatsFirstPromptNamesAnUntitledOne() {
        let meta = #"{"updatedAtMs":1793548515529,"hasConversation":true,"cwd":"/x"}"#
        #expect(HarnessChatFiles.cursorChat(id: "c", metaJSON: meta, firstPrompt: "fix tests", modifiedAt: now)?.title == "fix tests")
        #expect(HarnessChatFiles.cursorChat(id: "c", metaJSON: #"{"isSubagent":true,"hasConversation":true}"#, modifiedAt: now) == nil)
    }

    @Test func aClaudeSessionFromAnotherFolderWithTheSameNameIsLeftOut() {
        let lines = [#"{"type":"user","cwd":"/a/b.c","message":{"content":"hi"}}"#]
        #expect(HarnessChatFiles.claudeSession(id: "s", lines: lines, folders: ["/a/b.c"], modifiedAt: now) != nil)
        #expect(HarnessChatFiles.claudeSession(id: "s", lines: lines, folders: ["/a/b_c"], modifiedAt: now) == nil)
    }

    @Test func grokHidesItsSubagents() {
        #expect(HarnessChatFiles.grokChat(id: "g", summaryJSON: #"{"session_kind":"subagent","generated_title":"x"}"#, firstPrompt: nil, modifiedAt: now) == nil)
    }

    @Test func grokKeepsChatsByPercentEncodedFolder() {
        #expect(HarnessChatFiles.grokFolderName(for: "/Users/ad/.t3/Application Support/x") == "%2FUsers%2Fad%2F.t3%2FApplication%20Support%2Fx")
        let summary = #"{"generated_title":"Say hi","last_active_at":"2026-10-31T13:04:37.221071Z","updated_at":"2026-10-31T13:04:37.260418Z"}"#
        #expect(HarnessChatFiles.grokChat(id: "g1", summaryJSON: summary, firstPrompt: "hello", modifiedAt: now)?.title == "Say hi")
        #expect(HarnessChatFiles.grokChat(id: "g1", summaryJSON: nil, firstPrompt: "hello there", modifiedAt: now)?.title == "hello there")
        #expect(HarnessChatFiles.grokChat(id: "g1", summaryJSON: nil, firstPrompt: nil, modifiedAt: now) == nil)
        let prompts = HarnessChatFiles.grokFirstPrompts(historyLines: [#"{"session_id":"g1","prompt":"first"}"#, #"{"session_id":"g1","prompt":"second"}"#])
        #expect(prompts["g1"] == "first")
    }

    @Test func aChatIsFoundByIdThenByTitle() {
        let chats = [HarnessChat(id: "mcp:abc", title: "Farewell Function", updatedAt: now), HarnessChat(id: "x2", title: "Login page work", updatedAt: now)]
        #expect(HarnessChatChoice(idOrTitle: "mcp:abc").match(in: chats)?.id == "mcp:abc")
        #expect(HarnessChatChoice(idOrTitle: "farewell function").match(in: chats)?.id == "mcp:abc")
        #expect(HarnessChatChoice(idOrTitle: "login").match(in: chats)?.id == "x2")
        #expect(HarnessChatChoice(idOrTitle: "nothing like it").match(in: chats) == nil)
    }

    @Test func aBotsContinueLineCanHoldAnyId() {
        #expect(ProjectWords.chatToContinue(in: "Project: x\nContinue: mcp:a05e-12\n```prompt\ndo it\n```") == "mcp:a05e-12")
        #expect(ProjectWords.chatToContinue(in: "**Continue:** `Login page work`") == "Login page work")
        #expect(ProjectWords.chatToContinue(in: "Continue with the plan") == nil)
    }

    @Test func agesAreShort() {
        #expect(HarnessChatText.age(of: now.addingTimeInterval(-30), now: now) == "just now")
        #expect(HarnessChatText.age(of: now.addingTimeInterval(-300), now: now) == "5m")
        #expect(HarnessChatText.age(of: now.addingTimeInterval(-7200), now: now) == "2h")
        #expect(HarnessChatText.age(of: now.addingTimeInterval(-172800), now: now) == "2d")
    }
}

struct BotChatMergeTests {
    private struct Line { let id: String; let at: Date }

    @Test func sameSecondMessagesKeepTheOrderTheyWereWritten() {
        let second = Date(timeIntervalSince1970: 1000)
        let question = Line(id: "z-question", at: second)
        let answer = Line(id: "a-answer", at: second.addingTimeInterval(0.4))
        let merged = LinkMerge.union(local: [question, answer], remote: [], id: \.id, at: \.at)
        #expect(merged.map(\.id) == ["z-question", "a-answer"])
        // From the other Mac, whose copy lost its fractions on the wire: still question first.
        let received = LinkMerge.union(local: [], remote: [Line(id: "z-question", at: second), Line(id: "a-answer", at: second)], id: \.id, at: \.at)
        #expect(received.map(\.id) == ["z-question", "a-answer"])
    }

    @Test func aPrivateThreadMergesLikeAnyChat() {
        let at = Date(timeIntervalSince1970: 2000)
        let merged = LinkMerge.union(local: [Line(id: "1", at: at)], remote: [Line(id: "1", at: at), Line(id: "2", at: at.addingTimeInterval(5))], id: \.id, at: \.at)
        #expect(merged.map(\.id) == ["1", "2"])
    }

    @Test func aTagMentionedInASentenceIsntAnOrder() {
        #expect(ClickyOrder.extract(from: "Use a line like [TELL: their exact name: what you need] to do it.").orders.isEmpty)
        #expect(ClickyOrder.extract(from: "[TELL: name: message]").orders.isEmpty)
        #expect(ClickyOrder.extract(from: "ok [TELL: Coder: which database?]").orders.count == 1)
    }

    @Test func aMemberAlwaysReadsEverythingSinceTheOwnerSpoke() {
        struct Said { let owner: Bool; let text: String }
        let long = String(repeating: "x", count: 30_000)
        let messages = [Said(owner: false, text: long), Said(owner: true, text: "question"), Said(owner: false, text: long), Said(owner: false, text: "short")]
        let kept = BotProtocol.trimmedTranscript(messages, isOwner: { $0.owner }, length: { $0.text.count })
        // The huge older message goes; everything since the owner spoke stays, however long.
        #expect(kept.count == 3)
        #expect(kept.first?.text == "question")
        let small = [Said(owner: false, text: "old"), Said(owner: true, text: "q"), Said(owner: false, text: "a")]
        #expect(BotProtocol.trimmedTranscript(small, isOwner: { $0.owner }, length: { $0.text.count }).count == 3)
    }
}
