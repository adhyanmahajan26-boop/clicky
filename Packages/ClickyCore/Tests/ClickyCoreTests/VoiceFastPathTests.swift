import Foundation
import Testing
@testable import ClickyCore

/// P8 local fast path: the parser (phrasings, en-IN ASR quirks, things that
/// must go to Claude), the number words and the tier mapping.
struct VoiceFastPathParserTests {
    func parse(_ text: String) -> VoiceFastPathCommand? { VoiceFastPathParser.parse(text) }

    @Test(arguments: [
        ("volume up", VoiceFastPathCommand.volumeUp), ("turn up the volume", .volumeUp), ("turn the volume up", .volumeUp),
        ("Hey Claudia, could you turn the volume up please", .volumeUp), ("louder", .volumeUp), ("increase the volume", .volumeUp),
        ("raise volume", .volumeUp), ("more volume", .volumeUp), ("sound up", .volumeUp), ("turn it up", .volumeUp),
        ("volume down", .volumeDown), ("turn down the volume", .volumeDown), ("reduce the volume", .volumeDown), ("reduce volume", .volumeDown),
        ("quieter", .volumeDown), ("lower the volume a bit", .volumeDown), ("less volume", .volumeDown), ("turn it down", .volumeDown),
        ("volume 40", .volumeSet(percent: 40)), ("set the volume to 40%", .volumeSet(percent: 40)), ("set volume to forty percent", .volumeSet(percent: 40)),
        ("volume hundred percent", .volumeSet(percent: 100)), ("make volume fifty", .volumeSet(percent: 50)), ("volume at 25 percent", .volumeSet(percent: 25)),
        ("put the volume on 70", .volumeSet(percent: 70)), ("volume full", .volumeSet(percent: 100)), ("volume zero", .volumeSet(percent: 0)),
        ("set volume to fifty five", .volumeSet(percent: 55)), ("volume to half", .volumeSet(percent: 50)), ("change the volume to 30 per cent", .volumeSet(percent: 30)),
        ("mute", .mute), ("mute the sound", .mute), ("mute it", .mute), ("sound off", .mute), ("unmute", .unmute), ("unmute the mac", .unmute),
        ("brightness up", .brightnessUp), ("increase brightness", .brightnessUp), ("brighter", .brightnessUp),
        ("turn down the brightness", .brightnessDown), ("dim the screen", .brightnessDown), ("dimmer", .brightnessDown)
    ])
    func volumeAndBrightness(_ text: String, _ expected: VoiceFastPathCommand) {
        #expect(parse(text) == expected, "\(text)")
    }

    @Test(arguments: [
        ("play", VoiceFastPathCommand.media(.playPause, namesNetflixOrSafari: false)), ("pause", .media(.playPause, namesNetflixOrSafari: false)),
        ("pause the music", .media(.playPause, namesNetflixOrSafari: false)), ("resume", .media(.playPause, namesNetflixOrSafari: false)),
        ("play music", .media(.playPause, namesNetflixOrSafari: false)), ("stop the music", .media(.playPause, namesNetflixOrSafari: false)),
        ("pause netflix", .media(.playPause, namesNetflixOrSafari: true)), ("play Netflix", .media(.playPause, namesNetflixOrSafari: true)),
        ("next song", .media(.next, namesNetflixOrSafari: false)), ("next track", .media(.next, namesNetflixOrSafari: false)),
        ("skip", .media(.next, namesNetflixOrSafari: false)), ("skip this song", .media(.next, namesNetflixOrSafari: false)),
        ("play the next song", .media(.next, namesNetflixOrSafari: false)), ("next one", .media(.next, namesNetflixOrSafari: false)),
        ("previous song", .media(.previous, namesNetflixOrSafari: false)), ("last track", .media(.previous, namesNetflixOrSafari: false)),
        ("go back a song", .media(.previous, namesNetflixOrSafari: false))
    ])
    func media(_ text: String, _ expected: VoiceFastPathCommand) {
        #expect(parse(text) == expected, "\(text)")
    }

    @Test(arguments: [
        ("snap left", VoiceFastPathCommand.window(.snapLeftHalf)), ("snap window left", .window(.snapLeftHalf)), ("move it to the left half", .window(.snapLeftHalf)),
        ("move window to the left", .window(.snapLeftHalf)), ("left half", .window(.snapLeftHalf)), ("snap to left side", .window(.snapLeftHalf)),
        ("snap right", .window(.snapRightHalf)), ("put this window on the right half", .window(.snapRightHalf)), ("move window right", .window(.snapRightHalf)),
        ("maximize", .window(.maximize)), ("maximise the window", .window(.maximize)), ("make the window fill the screen", .window(.maximize)),
        ("minimize", .window(.minimize)), ("minimise this window", .window(.minimize)),
        ("move window to monitor 2", .window(.moveToScreenNumber(2))), ("move this to screen two", .window(.moveToScreenNumber(2))),
        ("move it to the second display", .window(.moveToScreenNumber(2))), ("move window to the left screen", .window(.moveToScreenOnLeft)),
        ("move it to the right monitor", .window(.moveToScreenOnRight)), ("move the window to the other screen", .window(.moveToNextScreen))
    ])
    func windows(_ text: String, _ expected: VoiceFastPathCommand) {
        #expect(parse(text) == expected, "\(text)")
    }

    @Test(arguments: [
        ("switch to chrome", VoiceFastPathCommand.switchToApp(name: "chrome")), ("switch over to notes", .switchToApp(name: "notes")),
        ("go back to slack", .switchToApp(name: "slack")), ("switch to the terminal app", .switchToApp(name: "terminal")),
        ("open notes", .openApp(name: "notes")), ("open up chrome", .openApp(name: "chrome")), ("launch spotify", .openApp(name: "spotify")),
        ("open the calculator app", .openApp(name: "calculator")), ("open visual studio code", .openApp(name: "visual studio code")),
        ("open the projects folder", .openItem(name: "projects", kind: .folder)), ("open folder clicky", .openItem(name: "clicky", kind: .folder)),
        ("open my budget file", .openItem(name: "budget", kind: .file)), ("open the file called notes draft", .openItem(name: "notes draft", kind: .file))
    ])
    func apps(_ text: String, _ expected: VoiceFastPathCommand) {
        #expect(parse(text) == expected, "\(text)")
    }

    @Test(arguments: [
        ("new tab", VoiceFastPathCommand.key(.newTab)), ("open a new tab", .key(.newTab)), ("new tap", .key(.newTab)),
        ("close tab", .key(.closeTab)), ("close this tab", .key(.closeTab)), ("close the tap", .key(.closeTab)), ("close the current tab", .key(.closeTab)),
        ("close window", .key(.closeWindow)), ("close this window", .key(.closeWindow)),
        ("go back", .key(.goBack)), ("back", .key(.goBack)), ("previous page", .key(.goBack)), ("go forward", .key(.goForward)),
        ("copy", .key(.copy)), ("copy this", .key(.copy)), ("paste", .key(.paste)), ("paste it here", .key(.paste)),
        ("select all", .key(.selectAll)), ("select everything", .key(.selectAll)),
        ("scroll down", .scroll(.down)), ("scroll down a bit", .scroll(.down)), ("scroll up", .scroll(.up)), ("page down", .scroll(.pageDown)),
        ("page up", .scroll(.pageUp)), ("scroll to the top", .scroll(.top)), ("go to the top", .scroll(.top)), ("go to the bottom of the page", .scroll(.bottom)),
        ("bottom", .scroll(.bottom)),
        ("mission control", .missionControl), ("open mission control", .missionControl), ("show desktop", .showDesktop), ("show me the desktop", .showDesktop),
        ("read this aloud", .readAloud), ("read this", .readAloud), ("read it out loud", .readAloud), ("read the selection", .readAloud),
        ("type what I say", .startDictation), ("take dictation", .startDictation), ("stop typing", .stopDictation), ("stop dictation", .stopDictation),
        ("take a screenshot", .screenshot(.screen)), ("screenshot", .screenshot(.screen)), ("take a screenshot of this window", .screenshot(.window)),
        ("lock the screen", .lockScreen), ("lock screen", .lockScreen), ("lock my mac", .lockScreen)
    ])
    func keysScrollingAndSystem(_ text: String, _ expected: VoiceFastPathCommand) {
        #expect(parse(text) == expected, "\(text)")
    }

    /// Questions and real requests go to Claude.
    @Test(arguments: [
        "what's the volume of a sphere", "what is the volume", "how do I mute a zoom call", "is the volume too loud", "why is my screen so dim",
        "open the second link", "open chrome and google this", "open this", "open the article and summarize it", "open the first result",
        "switch to the second tab", "close the tab after you read it", "can you explain what this code does", "summarize this page",
        "play the guitar for me in the video and tell me the chords", "what does select all do", "highlight the important facts",
        "read this article and tell me what it says", "turn the volume up and then open spotify", "stop it", "stop",
        "tell me about the window functions in sql", "copy the second paragraph into notes", "the next song on the album is great",
        "lock the door", "move the meeting to monday", "hey claudia", ""
    ])
    func notCommands(_ text: String) {
        #expect(parse(text) == nil, "\(text)")
    }

    @Test func numberWords() {
        #expect(VoiceNumberWords.percent(from: "forty") == 40)
        #expect(VoiceNumberWords.percent(from: "fifty five") == 55)
        #expect(VoiceNumberWords.percent(from: "hundred") == 100)
        #expect(VoiceNumberWords.percent(from: "one hundred") == 100)
        #expect(VoiceNumberWords.percent(from: "twenty") == 20)
        #expect(VoiceNumberWords.percent(from: "max") == 100)
        #expect(VoiceNumberWords.percent(from: "150") == nil)
        #expect(VoiceNumberWords.percent(from: "up") == nil)
        #expect(VoiceNumberWords.percent(from: "to") == nil)
        #expect(VoiceNumberWords.ordinalOrCardinal("second") == 2)
    }

    @Test func acknowledgementsAreShort() {
        #expect(VoiceFastPathCommand.volumeSet(percent: 40).acknowledgement(volumePercentAfter: 40) == "Volume 40.")
        #expect(VoiceFastPathCommand.mute.acknowledgement() == "Muted.")
        for command in [VoiceFastPathCommand.volumeUp, .key(.newTab), .window(.maximize), .media(.next, namesNetflixOrSafari: false), .lockScreen] {
            #expect(command.acknowledgement(volumePercentAfter: 50).split(separator: " ").count <= 3)
        }
    }
}

struct VoiceFastPathPolicyTests {
    let textEdit = ActionTargetFacts(bundleIdentifier: "com.apple.TextEdit", applicationName: "TextEdit", windowTitle: "Untitled")
    let safari = ActionTargetFacts(bundleIdentifier: "com.apple.Safari", applicationName: "Safari", windowTitle: "Netflix")
    let terminal = ActionTargetFacts(bundleIdentifier: "com.apple.Terminal", applicationName: "Terminal", windowTitle: "zsh")

    func decide(_ command: VoiceFastPathCommand, _ facts: VoiceFastPathFacts, _ transcript: String = "do it") -> VoiceFastPathDecision {
        VoiceFastPathPolicy.decide(command, facts: facts, transcript: transcript)
    }

    @Test func systemControlsRunFree() {
        for command in [VoiceFastPathCommand.volumeUp, .volumeSet(percent: 30), .mute, .missionControl, .showDesktop, .screenshot(.screen)] {
            #expect(decide(command, VoiceFastPathFacts(frontmost: textEdit)).tierName == "execute", "\(command)")
        }
    }

    @Test func mediaKeysNeverReachNetflixUnlessNamed() {
        let netflixFacts = VoiceFastPathFacts(frontmost: textEdit, isNetflixOrSafariLikelyPlaying: true)
        #expect(decide(.media(.playPause, namesNetflixOrSafari: false), netflixFacts, "pause").tierName == "refuse")
        #expect(decide(.media(.playPause, namesNetflixOrSafari: true), netflixFacts, "pause netflix").tierName == "execute")
        #expect(decide(.media(.next, namesNetflixOrSafari: false), VoiceFastPathFacts(frontmost: textEdit), "next song").tierName == "execute")
    }

    @Test func windowsInSafariNeedItNamed() {
        #expect(decide(.window(.maximize), VoiceFastPathFacts(frontmost: safari), "maximize").tierName == "refuse")
        #expect(decide(.window(.maximize), VoiceFastPathFacts(frontmost: safari), "maximize safari").tierName == "execute")
        #expect(decide(.window(.snapLeftHalf), VoiceFastPathFacts(frontmost: textEdit), "snap left").tierName == "execute")
        #expect(decide(.window(.snapLeftHalf), VoiceFastPathFacts(frontmost: nil), "snap left").tierName == "refuse")
    }

    @Test func closeIsExplicitConfirmUnlessUnsaved() {
        // cmd+w is a confirm-tier key; saying "close tab" is the confirm.
        #expect(VoiceFastPathPolicy.tier(for: .key(.closeTab), facts: VoiceFastPathFacts(frontmost: textEdit), context: ActionTurnContext(ownerTranscript: "close tab")).tier == .confirm)
        #expect(decide(.key(.closeTab), VoiceFastPathFacts(frontmost: textEdit), "close tab").tierName == "execute")
        let unsaved = VoiceFastPathFacts(frontmost: textEdit, frontWindowHasUnsavedChanges: true)
        #expect(decide(.key(.closeWindow), unsaved, "close window").tierName == "confirm")
    }

    @Test func lockAlwaysWaitsForYes() {
        guard case .confirm(let prompt, _) = decide(.lockScreen, VoiceFastPathFacts(frontmost: textEdit), "lock the screen") else {
            Issue.record("lock should confirm")
            return
        }
        #expect(prompt.contains("Lock"))
    }

    @Test func secureFieldsAndTerminalsAreRefused() {
        var passwordField = textEdit
        passwordField.subrole = "AXSecureTextField"
        #expect(decide(.key(.paste), VoiceFastPathFacts(frontmost: passwordField), "paste").tierName == "refuse")
        #expect(decide(.key(.copy), VoiceFastPathFacts(frontmost: terminal), "copy").tierName == "refuse")
        #expect(VoiceFastPathPolicy.dictationRefusal(focused: passwordField) != nil)
        #expect(VoiceFastPathPolicy.dictationRefusal(focused: terminal) != nil)
        #expect(VoiceFastPathPolicy.dictationRefusal(focused: textEdit) == nil)
        #expect(VoiceFastPathPolicy.dictationRefusal(focused: nil) != nil)
        var ownWindow = textEdit
        ownWindow.isOwnApplication = true
        #expect(decide(.key(.newTab), VoiceFastPathFacts(frontmost: ownWindow), "new tab").tierName == "refuse")
    }

    @Test func scrollKeysInATerminalStillScroll() {
        #expect(decide(.scroll(.pageDown), VoiceFastPathFacts(frontmost: terminal), "page down").tierName == "execute")
    }

    @Test func unsavedTitleDetection() {
        #expect(VoiceFastPathFacts.titleShowsUnsavedChanges("Untitled — Edited"))
        #expect(VoiceFastPathFacts.titleShowsUnsavedChanges("notes.txt - Edited"))
        #expect(!VoiceFastPathFacts.titleShowsUnsavedChanges("How I Edited My Video"))
        #expect(!VoiceFastPathFacts.titleShowsUnsavedChanges(nil))
    }
}

/// en-IN heard "new tab" as "New time" in a live follow-up feed.
@Test func newTimeIsNewTab() {
    #expect(VoiceFastPath.parse("New time") == .key(.newTab))
    #expect(VoiceFastPath.parse("what time is it") == nil)
}
