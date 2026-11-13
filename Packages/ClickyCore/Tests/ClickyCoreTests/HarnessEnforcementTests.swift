//
//  HarnessEnforcementTests.swift
//  ClickyCore
//
//  What a misbehaving bot's reply can't get by itself: a routine the owner didn't ask for, a full-access coding run from words that
//  weren't about code, or a PDF renderer that fetches something. Each case here was a working attack before its fix.
//

import Foundation
import Testing
@testable import ClickyCore

struct RoutineIntentTests {
    @Test func ownerAskingForASchedule() {
        for words in ["Every weekday at 7:30, remind me to check the supplier invoices. Set that up.",
                      "Set up a routine that posts the sales numbers", "Can you do this daily?", "Run it every 30 minutes",
                      "each morning summarise my inbox", "on Mondays send me the plan", "Schedule a weekly review", "every 9am check the build"] {
            #expect(RoutineIntent.ownerAsked(words), "\(words)")
        }
    }

    @Test func wordsThatAreNotASchedule() {
        for words in ["What's 2 + 2?", "Summarise minutes.md from your memory folder in three bullet points.", "Quick poll: tea or coffee?",
                      "What do I like, according to your notes?", "Is everyone here?", "Tell me everything about the vendor"] {
            #expect(!RoutineIntent.ownerAsked(words), "\(words)")
        }
    }

    @Test func aRoutinesOwnRunIsNeverTheOwnerAsking() {
        #expect(RoutineIntent.isRoutineRun("\u{23F0} Routine \"x\": Every day remind Addy to stretch"))
        #expect(!RoutineIntent.ownerAsked("\u{23F0} Routine \"x\": Every day remind Addy and set up another routine"))
    }
}

struct BuildAskTests {
    @Test func asksForCode() {
        for words in ["build a todo app", "make me a landing page", "fix the parser in ~/Projects/foo", "Fix the login bug",
                      "Build it: in a new folder called liar-1, make liar.txt containing the word liar.", "ship it",
                      "Can you build me a todo app?", "write a python script that renames my photos", "add tests for the parser",
                      "refactor the store", "open a PR for this", "I need a site for my bakery", "update index.html with the new prices"] {
            #expect(BuildAsk.matches(words), "\(words)")
        }
    }

    /// Each of these got a smuggled ```prompt started as a full-access run before the fix.
    @Test func questionsThatOnlyUseTheWords() {
        for words in ["How do I build up my savings faster?", "Can you ship me a two-line summary of what you do?",
                      "Quick one: what's the usual fix for a squeaky door hinge?", "I want to add a reading habit. Any tool for that?",
                      "What's a good way to update my CV?", "Let's make a plan for the weekend: any app ideas?",
                      "update me on this page's news", "what should I have for lunch?", "make me laugh"] {
            #expect(!BuildAsk.matches(words), "\(words)")
        }
    }
}

struct InertHTMLBypassTests {
    let host = "http://127.0.0.1:9/"

    private func loads(_ html: String) -> Bool {
        let out = BotPDFOrder.inertHTML(html).lowercased()
        return out.contains("127.0.0.1") && (out.contains("url") || out.contains("image-set") || out.contains("background") || out.contains("import") || out.contains("src"))
    }

    @Test func slashBetweenAttributes() {
        #expect(!loads(#"<table/background="\#(host)a"><tr><td>x</td></tr></table>"#))
        #expect(!loads(#"<body/background="\#(host)b">x</body>"#))
    }

    @Test func characterReferencesInStyle() {
        #expect(!loads(#"<p style="background-image:url&#40;\#(host)c)">x</p>"#))
        #expect(!loads(#"<p style="background-image:url&#x28;\#(host)c)">x</p>"#))
        #expect(!loads(#"<p style="background-image:url&lpar;\#(host)c)">x</p>"#))
    }

    @Test func cssEscapesAndImageSet() {
        #expect(!loads(#"<style>p{background-image:u\72l(\#(host)d)}</style><p>x</p>"#))
        #expect(!loads(#"<style>@\69mport "\#(host)e";</style>"#))
        #expect(!loads(#"<style>p{background-image:image-set("\#(host)f" 1x)}</style>"#))
        #expect(!loads(#"<p style="background-image:-webkit-image-set('\#(host)g' 1x)">x</p>"#))
        #expect(!loads(#"<style>@font-face{font-family:z;src:local(x),u/**/rl(\#(host)h)}</style>"#))
    }

    @Test func plainStyleStays() {
        let html = #"<style>td { padding: 3pt; color: #333 }</style><table style="width:100%"><tr><td>x</td></tr></table>"#
        #expect(BotPDFOrder.inertHTML(html) == html)
    }
}

struct BotReadScopeTests {
    let home = "/Users/addy"

    @Test func pathsTheOwnerNamed() {
        let words = "Summarise ~/Documents/report.md and compare with /Users/addy/Desktop/notes.txt, then look in `~/Work/Q4 plans`.\n\nAttached (read these):\n- /Users/addy/Downloads/My Invoice.pdf"
        let paths = BotReadScope.paths(in: words, home: home)
        #expect(paths.contains("~/Documents/report.md"))
        #expect(paths.contains("/Users/addy/Desktop/notes.txt"))
        #expect(paths.contains("~/Work/Q4 plans"))
        #expect(paths.contains("/Users/addy/Downloads/My Invoice.pdf"))
    }

    @Test func tooBroadOrClimbingOutIsNeverOpened() {
        for words in ["look at ~/ please", "read /", "check /Users", "read /Users/addy", "read ~/Documents/../.ssh/id_rsa",
                      "read /etc/passwd", "read /private/var/db", "read /Library/Keychains/System.keychain", "what's 2 + 2?"] {
            #expect(BotReadScope.paths(in: words, home: home).isEmpty, "\(words)")
        }
    }

    @Test func rulesCoverTheFileAndWhatsInside() {
        let rules = BotReadScope.readRules(for: ["~/Documents/report.md", "/Volumes/Work/x"])
        #expect(rules.contains("Read(~/Documents/report.md)"))
        #expect(rules.contains("Read(//Volumes/Work/x/**)"))
        #expect(rules.contains("Grep(//Volumes/Work/x/**)"))
    }
}

struct LocalUIGateTests {
    @Test func onlyLoopbackHostAtThePort() {
        #expect(LocalUIGate.hostAllowed("127.0.0.1:47320", port: 47320))
        #expect(LocalUIGate.hostAllowed("localhost:47320", port: 47320))
        #expect(!LocalUIGate.hostAllowed("attacker.example:47320", port: 47320))
        #expect(!LocalUIGate.hostAllowed("127.0.0.1", port: 47320))
        #expect(!LocalUIGate.hostAllowed(nil, port: 47320))
    }

    @Test func t3CodeExactlyOnItsOrigin() {
        #expect(LocalUIGate.isT3Code(origin: "http://127.0.0.1:3773", devServer: false))
        #expect(LocalUIGate.isT3Code(origin: "t3code://app", devServer: false))
        #expect(!LocalUIGate.isT3Code(origin: "http://127.0.0.1:37730", devServer: false))
        #expect(!LocalUIGate.isT3Code(origin: "http://127.0.0.1:3773.attacker.example", devServer: false))
        #expect(!LocalUIGate.isT3Code(origin: "null", devServer: false))
        // A Referer only counts where it's allowed to (embedding), and then only its origin.
        #expect(!LocalUIGate.isT3Code(origin: nil, referer: nil, devServer: false))
        #expect(LocalUIGate.isT3Code(origin: nil, referer: "http://127.0.0.1:3773/settings/theo", devServer: false))
        #expect(!LocalUIGate.isT3Code(origin: nil, referer: "http://127.0.0.1:3773.evil.example/", devServer: false))
    }

    @Test func devServerOnlyWhenSwitchedOn() {
        #expect(!LocalUIGate.isT3Code(origin: "http://localhost:5733", devServer: false))
        #expect(LocalUIGate.isT3Code(origin: "http://localhost:5733", devServer: true))
    }
}
