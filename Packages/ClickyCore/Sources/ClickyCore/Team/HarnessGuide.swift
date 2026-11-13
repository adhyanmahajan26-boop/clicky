import Foundation

/// The guide to Theo's bot harness: everything a bot (or a model helping build one) needs to know to work inside Theo.
/// It's put together from the same `BotProtocol` texts the bots are given on every turn, so it can't drift from what they're told.
/// Theo writes it into the Bots folder at launch (`HARNESS-GUIDE.md`, readable by every bot), and `docs/BOT-HARNESS-GUIDE.md`
/// in the repo is checked against it by a unit test.
public enum HarnessGuide {
    public static let fileName = "HARNESS-GUIDE.md"

    public static func markdown(owner: String = OwnerName.unset, codingHarness: String = "the coding harness Theo picks") -> String {
        let sections: [(String, String)] = [
            ("What Theo is",
             "Theo is \(owner)'s bot harness on their Macs. Each bot is a persona with an engine (Claude Code, OpenCode or an API key), " +
             "its own chat with \(owner), a memory file, the apps (connectors) \(owner) gave it, and a place on a team. Bots message each other " +
             "privately, talk in group chats, run routines on a schedule, and hand coding to a harness that commits, pushes and opens a draft PR. " +
             "Theo is the CEO bot; Clicky is the voice and screen companion, with Memory, Researcher and Runner under it."),
            ("Every turn starts with two notes",
             "\"Where you are\" says which Mac you're running on, which Mac \(owner) is typing on, and what's reachable. \"Who you are\" says your role and who you report to. " +
             "They're refreshed every turn because an engine session keeps old context: trust them over anything you remember."),
            ("How to write", BotProtocol.houseStyle(owner: owner)),
            ("Messaging another bot", BotProtocol.reachHowTo(reachable: [], owner: owner)
                .replacingOccurrences(of: " No other bots are on right now.", with: "")),
            ("Private threads", BotProtocol.privateThreadHowTo(partner: "the other bot")),
            ("Group chats",
             BotProtocol.groupChatHowTo(others: []).replacingOccurrences(of: " The others here: .", with: "") + "\n\n" +
             "**If you're the head:** " + BotProtocol.headOpensNote(owner: owner) + "\n\n" +
             "**If you're a member:** " + BotProtocol.memberTurnNote(name: "you", headName: "the head").replacingOccurrences(of: "It's your turn, you, and", with: "When it's your turn,") + "\n\n" +
             "**The wrap-up:** " + BotProtocol.wrapUpNote(owner: owner)),
            ("Reporting",
             "Your \"who you are\" note names your team and who you report to. With a manager, send your reports and messages to the manager with a [TELL:] line, " +
             "not to Theo; the manager rolls its team's reports up to Theo, who reads them at the start of its next turn. With no manager, report straight to Theo " +
             "with a [TELL:] line when something is worth knowing."),
            ("Coding", BotProtocol.codingHowTo(harnessLabel: codingHarness)),
            ("Routines", BotProtocol.routineHowTo(owner: owner) + " " +
             "Each run lands in your own chat and session, so you keep the context. A run that only checks on something can stay quiet: " +
             RoutineQuiet.howTo(owner: owner) + " A slot missed while Theo was closed runs late only within half the routine's period (2 minutes to 2 hours); " +
             "older ones are recorded as missed."),
            ("Memory, recall and skills",
             "Your memory file's contents are in your prompt on every turn, up to \(BotMemoryPrompt.limit) characters; past that you're shown the start and the newest " +
             "lines and asked to tidy it. Your whole chat with \(owner) is saved as a file your prompt names: Grep it to recall something from before your session. " +
             "Skills are step-by-step procedures in skills/<name>/SKILL.md folders, yours and other bots', all listed in your prompt. " +
             BotSkillsPrompt.writeHowTo(ownFolder: "your memory folder's skills", owner: owner)),
            ("Asking \(owner) to choose", BotProtocol.askingStyle),
            ("Screens and research", BotProtocol.screenHowTo(owner: owner)),
            ("Apps (connectors)",
             "Use only the apps \(owner) gave you. If one looks unavailable at the start of a turn, it may still be loading: load its tools with ToolSearch and try once " +
             "before saying it needs connecting, and quote the real error if it fails. Never send, reply, forward, delete or share without \(owner)'s go-ahead: drafts are fine."),
            ("What you can't do",
             "You can't run shell commands or edit files outside your memory folder (your skills live inside it). Anything that needs a command (a script, a build) goes to a coding run with a ```prompt block. " +
             "You can read only your memory folder, ~/Projects and files or folders \(owner) names in the message: anything else is refused, and no setting opens it, " +
             "so use your app's connector or ask \(owner) to name its path. " +
             BotProtocol.pdfHowTo + " " +
             "Never say something happened until Theo's own line in the chat, a run card or a reply shows it."),
            ("Two Macs",
             "Theo runs on the Mac Studio and the MacBook Air and keeps them in step. A message is answered on the Mac \(owner) typed it on, with that Mac's folders and coding runs, " +
             "unless \(owner) set it to the other Mac. When the other Mac is away, say so plainly; a run that waited long for it asks \(owner) before it starts.")
        ]
        var text = "# Theo's bot harness: the guide\n\n" +
            "Generated from the rules bots are given on every turn (`ClickyCore/Team/BotProtocol.swift`). Don't edit this file by hand: change the code, " +
            "then regenerate it with `UPDATE_HARNESS_GUIDE=1 swift test --filter HarnessGuide` in Packages/ClickyCore.\n"
        for (heading, body) in sections { text += "\n## \(heading)\n\n\(body)\n" }
        return text
    }

    /// One line for a bot's persona: where the full guide is.
    public static func pointer(path: String) -> String {
        "The full guide to how Theo works for bots is at \(path). Read it once before your first answer, and again whenever you're unsure how to message, hand over, schedule or start code."
    }
}
