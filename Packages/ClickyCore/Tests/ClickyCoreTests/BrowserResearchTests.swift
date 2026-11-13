//
//  BrowserResearchTests.swift
//  ClickyCoreTests
//
//  What may open in the owner's logged-in browser, when a page needs it, human checks, and who gets a tile.
//

import CoreGraphics
import XCTest
@testable import ClickyCore

final class BrowserResearchTests: XCTestCase {
    private func url(_ text: String) -> URL { URL(string: text)! }

    func testOrdinaryPagesMayOpen() {
        for page in ["https://www.macbartender.com/", "https://github.com/jordanbaird/Ice", "https://www.reddit.com/r/macapps/comments/abc/best_menu_bar/", "https://news.ycombinator.com/item?id=4"] {
            XCTAssertTrue(BrowserResearchPolicy.mayOpen(url(page)), page)
        }
    }

    func testPrivatePlacesNeverOpen() {
        for page in ["https://mail.google.com/mail/u/0/", "https://accounts.google.com/", "https://www.icloud.com/mail", "https://drive.google.com/file/d/1", "https://docs.google.com/document/d/1",
                     "https://www.paypal.com/myaccount", "https://netbanking.hdfcbank.com/", "https://www.onlinesbibank.com/", "https://web.whatsapp.com/", "https://kite.zerodha.com/"] {
            XCTAssertFalse(BrowserResearchPolicy.mayOpen(url(page)), page)
        }
    }

    func testAddressesThatDoSomethingNeverOpen() {
        for page in ["https://example.com/logout", "https://example.com/account/settings", "https://example.com/unsubscribe?u=1", "https://shop.example.com/checkout", "https://example.com/oauth/authorize", "https://example.com/users/4/delete"] {
            XCTAssertFalse(BrowserResearchPolicy.mayOpen(url(page)), page)
        }
    }

    func testSecretsInTheAddressNeverOpen() {
        XCTAssertFalse(BrowserResearchPolicy.mayOpen(url("https://example.com/page?token=abc")))
        XCTAssertFalse(BrowserResearchPolicy.mayOpen(url("https://example.com/page?session=abc")))
        XCTAssertFalse(BrowserResearchPolicy.mayOpen(url("https://me:pw@example.com/")))
    }

    func testOnlyTheWebOpens() {
        XCTAssertFalse(BrowserResearchPolicy.mayOpen(url("file:///etc/passwd")))
        XCTAssertFalse(BrowserResearchPolicy.mayOpen(url("chrome://settings")))
        XCTAssertFalse(BrowserResearchPolicy.mayOpen(url("http://192.168.1.1/")))
        XCTAssertFalse(BrowserResearchPolicy.mayOpen(url("http://localhost:3000/")))
        XCTAssertTrue(BrowserResearchPolicy.mayOpen(url("http://127.0.0.1:8123/check.html"), allowsLocalHostForTests: true))
    }

    func testWhenAPageNeedsTheBrowser() {
        XCTAssertTrue(BrowserResearchPolicy.needsBrowser(text: nil))
        XCTAssertTrue(BrowserResearchPolicy.needsBrowser(text: "  "))
        XCTAssertTrue(BrowserResearchPolicy.needsBrowser(text: "Please enable JavaScript"))
        XCTAssertTrue(BrowserResearchPolicy.needsBrowser(text: "Just a moment... Verify you are human"))
        XCTAssertFalse(BrowserResearchPolicy.needsBrowser(text: String(repeating: "A real article with real words. ", count: 20)))
    }

    func testHumanChecks() {
        XCTAssertTrue(BrowserResearchPolicy.isHumanCheck(title: "Just a moment...", text: ""))
        XCTAssertTrue(BrowserResearchPolicy.isHumanCheck(title: "x", text: "Verify you are human by completing the action below."))
        XCTAssertTrue(BrowserResearchPolicy.isHumanCheck(title: nil, text: "Our systems have detected unusual traffic from your computer network."))
        XCTAssertFalse(BrowserResearchPolicy.isHumanCheck(title: "Docs", text: "How to install the app and get going."))
        // An article about captchas isn't one.
        XCTAssertFalse(BrowserResearchPolicy.isHumanCheck(title: "History", text: String(repeating: "How captcha systems changed the web. ", count: 60)))
    }

    func testTextRunsJoinByBlock() {
        XCTAssertEqual(BrowserResearchPolicy.joined(runs: [("Hello", 1), ("world", 1), ("  ", 1), ("Next", 2)]), "Hello world\nNext")
        XCTAssertEqual(BrowserResearchPolicy.joined(runs: []), "")
        let long = BrowserResearchPolicy.joined(runs: Array(repeating: (String(repeating: "x", count: 1000), 1), count: 100))
        XCTAssertEqual(long.count, BrowserResearchPolicy.maximumCharacters)
    }

    func testWaitsForAPauseInTheOwnersInput() {
        XCTAssertFalse(BrowserResearchPolicy.ownerHasPaused(secondsSinceInput: 0.2))
        XCTAssertFalse(BrowserResearchPolicy.ownerHasPaused(secondsSinceInput: 1.4))
        XCTAssertTrue(BrowserResearchPolicy.ownerHasPaused(secondsSinceInput: 1.5))
    }

    // MARK: Tiles

    private let a = StudioTileID(screen: 0, tile: 0), b = StudioTileID(screen: 0, tile: 1), c = StudioTileID(screen: 1, tile: 0)

    func testTilesGoFirstComeUpToTheLimit() {
        var queue = ResearchTileQueue(limit: 2)
        XCTAssertEqual(queue.request("one", free: [a, b, c]), a)
        XCTAssertEqual(queue.request("two", free: [b, c]), b)
        XCTAssertNil(queue.request("three", free: [c]))
        XCTAssertEqual(queue.waiting, ["three"])
        XCTAssertEqual(queue.holding.count, 2)
    }

    func testReleasingLetsTheNextIn() {
        var queue = ResearchTileQueue(limit: 2)
        _ = queue.request("one", free: [a, b])
        _ = queue.request("two", free: [b])
        _ = queue.request("three", free: [])
        _ = queue.request("four", free: [])
        XCTAssertNil(queue.grantNext(free: [c]))
        queue.release("one")
        let next = queue.grantNext(free: [a])
        XCTAssertEqual(next?.id, "three")
        XCTAssertEqual(next?.tile, a)
        XCTAssertEqual(queue.waiting, ["four"])
    }

    func testNoFreeTileMeansWaitingEvenUnderTheLimit() {
        var queue = ResearchTileQueue(limit: 2)
        XCTAssertNil(queue.request("one", free: []))
        XCTAssertEqual(queue.waiting, ["one"])
        XCTAssertEqual(queue.grantNext(free: [a])?.id, "one")
    }

    func testNobodyJumpsTheLine() {
        var queue = ResearchTileQueue(limit: 2)
        XCTAssertNil(queue.request("first", free: []))
        XCTAssertNil(queue.request("second", free: [a]))
        XCTAssertEqual(queue.waiting, ["first", "second"])
    }

    func testGivingUpLeavesTheLine() {
        var queue = ResearchTileQueue(limit: 1)
        _ = queue.request("one", free: [a])
        _ = queue.request("two", free: [])
        queue.leave("two")
        queue.release("one")
        XCTAssertNil(queue.grantNext(free: [a]))
    }

    func testAskingAgainKeepsTheSameTile() {
        var queue = ResearchTileQueue(limit: 1)
        XCTAssertEqual(queue.request("one", free: [a]), a)
        XCTAssertEqual(queue.request("one", free: [b]), a)
    }

    // MARK: Live views

    func testHoveredTileGoesFaster() {
        XCTAssertEqual(StudioPreviewSchedule.framesPerSecond(for: a, focused: nil), 2)
        XCTAssertEqual(StudioPreviewSchedule.framesPerSecond(for: a, focused: a), 6)
        XCTAssertEqual(StudioPreviewSchedule.framesPerSecond(for: b, focused: a), 2)
        XCTAssertEqual(StudioPreviewSchedule.framesPerSecond(for: b, focused: a, base: 5), 5)
    }

    func testTilesAreDrawnOnlyWhenDue() {
        XCTAssertTrue(StudioPreviewSchedule.isDue(a, last: nil, now: 10, focused: nil))
        XCTAssertFalse(StudioPreviewSchedule.isDue(a, last: 10, now: 10.1, focused: nil))
        XCTAssertTrue(StudioPreviewSchedule.isDue(a, last: 10, now: 10.5, focused: nil))
        XCTAssertTrue(StudioPreviewSchedule.isDue(a, last: 10, now: 10.2, focused: a))
        XCTAssertFalse(StudioPreviewSchedule.isDue(b, last: 10, now: 10.2, focused: a))
    }

    private let hidden = [CGRect(x: 5360, y: 1278, width: 1440, height: 900), CGRect(x: 6800, y: 1278, width: 1440, height: 900)]

    func testOnlyWindowsOnHiddenScreensMayBeCaptured() {
        XCTAssertTrue(StudioPreviewSchedule.mayCapture(window: CGRect(x: 5360, y: 1278, width: 720, height: 900), hiddenScreens: hidden))
        // The owner's monitors, and anything hanging off a hidden screen.
        XCTAssertFalse(StudioPreviewSchedule.mayCapture(window: CGRect(x: 100, y: 100, width: 720, height: 900), hiddenScreens: hidden))
        XCTAssertFalse(StudioPreviewSchedule.mayCapture(window: CGRect(x: 5000, y: 1278, width: 720, height: 900), hiddenScreens: hidden))
        XCTAssertFalse(StudioPreviewSchedule.mayCapture(window: .zero, hiddenScreens: hidden))
        XCTAssertFalse(StudioPreviewSchedule.mayCapture(window: CGRect(x: 5360, y: 1278, width: 720, height: 900), hiddenScreens: []))
    }

    func testAWindowFindsItsTile() {
        func tile(_ x: CGFloat) -> StudioTileID? { StudioPreviewSchedule.tile(of: CGRect(x: x, y: 1278, width: 720, height: 900), hiddenScreens: hidden, tilesPerScreen: 2) }
        XCTAssertEqual(tile(5360), StudioTileID(screen: 0, tile: 0))
        XCTAssertEqual(tile(6080), StudioTileID(screen: 0, tile: 1))
        XCTAssertEqual(tile(6800), StudioTileID(screen: 1, tile: 0))
        XCTAssertEqual(tile(7520), StudioTileID(screen: 1, tile: 1))
        XCTAssertNil(tile(100))
        XCTAssertEqual(StudioPreviewSchedule.tile(of: CGRect(x: 6080, y: 1278, width: 720, height: 900), hiddenScreens: hidden, tilesPerScreen: 1), StudioTileID(screen: 0, tile: 0))
    }

    // MARK: Looks for bots from before the crew

    func testBotsGetAFigureThatFitsTheirJob() {
        XCTAssertEqual(CrewLook.standard(id: "x", name: "Builder"), .builder)
        XCTAssertEqual(CrewLook.standard(id: "x", name: "Github Coder"), .builder)
        XCTAssertEqual(CrewLook.standard(id: "x", name: "Researcher"), .researcher)
        XCTAssertEqual(CrewLook.standard(id: "x", name: "mail manager · invoice scanner for work mail"), .inbox)
        XCTAssertEqual(CrewLook.standard(id: "x", name: "Accountant"), .accountant)
        XCTAssertEqual(CrewLook.standard(id: "x", name: "Catalogue pricing"), .accountant)
        XCTAssertEqual(CrewLook.standard(id: "x", name: "CEO"), .manager)
        XCTAssertEqual(CrewLook.standard(id: "x", name: "project manager"), .manager)
        XCTAssertEqual(CrewLook.standard(id: "x", name: "Planner"), .manager)
        XCTAssertEqual(CrewLook.standard(id: "theo", name: "Theo", isPrimary: true), .theo)
    }

    func testTheRoleIsUsedWhenTheNameSaysNothing() {
        XCTAssertEqual(CrewLook.standard(id: "x", name: "kadi ninda", role: "Designs the screens"), .designer)
        // Nothing to go on: its own figure, the same every time.
        XCTAssertEqual(CrewLook.standard(id: "seven", name: "kadi ninda"), CrewLook.standard(id: "seven", name: "kadi ninda"))
    }

    func testALookSurvivesSaving() throws {
        let data = try JSONEncoder().encode(CrewLook.manager)
        XCTAssertEqual(try JSONDecoder().decode(CrewLook.self, from: data), .manager)
    }

    // MARK: The owner's monitors

    private func monitor(id: UInt32 = 4, x: Int = 0, y: Int = 0, width: Int = 1920, height: Int = 1080, pixelWidth: Int = 3840, pixelHeight: Int = 2160, hz: Double = 120, rotation: Double = 0) -> RealDisplayState {
        RealDisplayState(id: id, x: x, y: y, width: width, height: height, pixelWidth: pixelWidth, pixelHeight: pixelHeight, refreshRate: hz, rotation: rotation)
    }

    func testNothingChangedMeansNoDifferences() {
        XCTAssertEqual(StudioDisplayGuard.differences(baseline: [monitor(), monitor(id: 2, x: 1920)], now: [monitor(id: 2, x: 1920), monitor()]), [])
    }

    func testAMovedMonitorIsCaught() {
        XCTAssertEqual(StudioDisplayGuard.differences(baseline: [monitor(x: -1920)], now: [monitor(x: -3360)]), [.moved(4)])
    }

    func testEveryPartOfTheModeIsWatched() {
        XCTAssertEqual(StudioDisplayGuard.differences(baseline: [monitor()], now: [monitor(width: 2560, height: 1440)]), [.modeChanged(4)])
        // The same look at a different sharpness is still a change.
        XCTAssertEqual(StudioDisplayGuard.differences(baseline: [monitor()], now: [monitor(pixelWidth: 1920, pixelHeight: 1080)]), [.modeChanged(4)])
        XCTAssertEqual(StudioDisplayGuard.differences(baseline: [monitor()], now: [monitor(hz: 60)]), [.modeChanged(4)])
        XCTAssertEqual(StudioDisplayGuard.differences(baseline: [monitor()], now: [monitor(hz: 119.88)]), [])
        XCTAssertEqual(StudioDisplayGuard.differences(baseline: [monitor()], now: [monitor(rotation: 90)]), [.rotated(4)])
    }

    func testAMonitorUnpluggedIsLeftAlone() {
        XCTAssertEqual(StudioDisplayGuard.differences(baseline: [monitor(), monitor(id: 2)], now: [monitor()]), [])
    }

    func testResearchCanHoldSeveralTilesWhileAssigningMoves() {
        var roster = StudioRoster()
        roster.hold("researcher", tile: a)
        roster.hold("researcher", tile: b)
        XCTAssertEqual(roster.bots.count, 2)
        roster.clear(a)
        XCTAssertEqual(roster.bots[b], "researcher")
        roster.assign("researcher", to: c)
        XCTAssertEqual(roster.bots.count, 1)
    }
}

final class StudioOwnershipTests: XCTestCase {
    private let owners = [0: "researcher"]
    private func config(_ owners: [Int: String]) -> StudioScreensConfig {
        StudioScreensConfig(screens: (0..<2).map { StudioScreenSpec(id: "screen-\($0 + 1)", name: "Screen \($0 + 1)", owners: owners[$0].map { [$0] } ?? []) })
    }
    private func tile(_ screen: Int, _ index: Int) -> StudioTileID { StudioTileID(screen: screen, tile: index) }
    private func free(_ bot: String, _ roster: StudioRoster = StudioRoster(), owners: [Int: String]? = nil) -> [StudioTileID] {
        config(owners ?? self.owners).freeTiles(for: bot, roster: roster)
    }

    func testTheOwnerFillsItsOwnScreenThenTheSharedOne() {
        XCTAssertEqual(free("researcher"), [tile(0, 0), tile(0, 1), tile(1, 0), tile(1, 1)])
        var roster = StudioRoster()
        roster.hold("researcher", tile: tile(0, 0))
        roster.hold("researcher", tile: tile(0, 1))
        XCTAssertEqual(free("researcher", roster), [tile(1, 0), tile(1, 1)])
    }

    func testAnotherBotOnlyGetsTheSharedScreen() {
        XCTAssertEqual(free("someone"), [tile(1, 0), tile(1, 1)])
    }

    func testAScreenWithAnotherOwnerIsNeverUsed() {
        XCTAssertEqual(free("someone", owners: [0: "researcher", 1: "other"]), [])
    }

    func testResearchCanUseEveryTile() {
        XCTAssertEqual(BrowserResearchPolicy.maximumBrowsersAtOnce, 4)
    }
}

final class StudioCaptureGuardTests: XCTestCase {
    func testPlayingVideoStopsCapture() {
        XCTAssertTrue(StudioCaptureGuard.videoIsPlaying(assertionNames: ["com.apple.WebCore: HTMLMediaElement playback"]))
        XCTAssertTrue(StudioCaptureGuard.videoIsPlaying(assertionNames: ["Electron", "Video Wake Lock"]))
        XCTAssertTrue(StudioCaptureGuard.videoIsPlaying(assertionNames: ["Playing video"]))
    }

    func testOtherAssertionsDontCount() {
        XCTAssertFalse(StudioCaptureGuard.videoIsPlaying(assertionNames: []))
        XCTAssertFalse(StudioCaptureGuard.videoIsPlaying(assertionNames: ["com.apple.universalcontrol.preventDisplaySleep", "Electron", "Powerd - Prevent sleep while display is on", "com.apple.audio.BuiltInSpeakerDevice.context.preventuseridlesleep"]))
    }

    func testAPageIsCutToSize() {
        XCTAssertEqual(StudioTilePage(host: "a.com", title: nil, text: String(repeating: "x", count: 900)).excerpt.count, 420)
    }

    func testTileHeadings() {
        XCTAssertEqual(StudioRemoteView.headline(note: "Ideas · Reading a.com", fallback: "Researcher").title, "Ideas")
        XCTAssertEqual(StudioRemoteView.headline(note: "Ideas · Reading a.com", fallback: "Researcher").detail, "Reading a.com")
        XCTAssertEqual(StudioRemoteView.headline(note: "Opening a.com", fallback: "Researcher").title, "Researcher")
        XCTAssertEqual(StudioRemoteView.headline(note: nil, fallback: "Researcher").title, "Researcher")
    }

    func testTheViewSurvivesTheLink() throws {
        let view = StudioRemoteView(isOn: true, screens: 2, tilesPerScreen: 2, paused: false, tiles: [.init(screen: 0, tile: 1, bot: "b", note: "n", page: StudioTilePage(host: "a", title: "t", text: "x"), jpeg: Data([1, 2]))])
        XCTAssertEqual(try JSONDecoder().decode(StudioRemoteView.self, from: JSONEncoder().encode(view)), view)
    }
}

final class ResearchAgentTests: XCTestCase {
    private func url(_ text: String) -> URL { URL(string: "https://\(text)")! }
    private let all = Set(ResearchRole.allCases)

    func testTwoAgentsByDefaultAndUpToFour() {
        XCTAssertEqual(ResearchAgentPlan.roles(enabled: all, count: 2), [.ideas, .info])
        XCTAssertEqual(ResearchAgentPlan.roles(enabled: all, count: 3), [.ideas, .info, .examples])
        XCTAssertEqual(ResearchAgentPlan.roles(enabled: all, count: 4), [.ideas, .info, .examples, .check])
        XCTAssertEqual(ResearchAgentPlan.roles(enabled: all, count: 9).count, 4)
        XCTAssertEqual(ResearchAgentPlan.roles(enabled: all, count: 1).count, 2)
    }

    func testRolesSwitchedOffAreLeftOut() {
        XCTAssertEqual(ResearchAgentPlan.roles(enabled: [.info, .check], count: 2), [.info, .check])
        XCTAssertEqual(ResearchAgentPlan.roles(enabled: [.check], count: 4), [.check])
    }

    func testAQuestionIsStillAnsweredWithEveryRoleOff() {
        XCTAssertEqual(ResearchAgentPlan.roles(enabled: [], count: 3), [.ideas, .info])
    }

    func testAgentsDontReadTheSamePage() {
        let shared = url("a.com/1")
        let plan = ResearchAgentPlan.pages(from: [(.ideas, [shared, url("b.com/1")]), (.info, [shared, url("c.com/1")])])
        XCTAssertEqual(plan[0].urls, [shared, url("b.com/1")])
        XCTAssertEqual(plan[1].urls, [url("c.com/1")])
    }

    func testDifferentSitesComeFirstButASiteCanRepeatIfThatsAllThereIs() {
        let plan = ResearchAgentPlan.pages(from: [(.ideas, [url("a.com/1"), url("a.com/2"), url("b.com/1")])])
        XCTAssertEqual(plan[0].urls, [url("a.com/1"), url("b.com/1")])
        let only = ResearchAgentPlan.pages(from: [(.ideas, [url("a.com/1"), url("a.com/2")])])
        XCTAssertEqual(only[0].urls, [url("a.com/1"), url("a.com/2")])
    }

    func testAnAgentWithNoResultsGetsNothing() {
        let plan = ResearchAgentPlan.pages(from: [(.ideas, []), (.info, [url("a.com/1")])])
        XCTAssertEqual(plan[0].urls, [])
        XCTAssertEqual(plan[1].urls, [url("a.com/1")])
    }

    func testEachRoleSearchesItsOwnWay() {
        let queries = Set(ResearchRole.allCases.map { $0.searchQuery(for: "menu bar apps") })
        XCTAssertEqual(queries.count, 4)
        XCTAssertTrue(queries.allSatisfy { $0.hasPrefix("menu bar apps") })
    }

    func testTheMergeKeepsAgentsApart() {
        let prompt = ResearchAgentPlan.mergePrompt(question: "q", reports: [(.info, 2, url("b.com"), nil, "two"), (.ideas, 1, url("a.com"), "A", "one")])
        XCTAssertLessThan(prompt.range(of: "agent: Ideas")!.lowerBound, prompt.range(of: "agent: Info")!.lowerBound)
        XCTAssertTrue(prompt.contains("[1] A"))
    }

    func testTheFallbackBriefHasASectionPerAgent() {
        let brief = ResearchAgentPlan.plainBrief(topic: "T", reports: [(.ideas, 1, nil, "first line\nmore"), (.info, 2, nil, "facts")])
        XCTAssertEqual(brief, "# T\n\n## Ideas\n- first line [1]\n\n## Info\n- facts [2]")
    }
}

final class DeviceRoutingTests: XCTestCase {
    // Addy's two Macs: a desktop and a laptop.
    private let studio = LinkedMac(id: "B-STUDIO", name: "Adhyan’s Mac Studio", isDesktop: true)
    private let air = LinkedMac(id: "A-AIR", name: "Adhyan’s MacBook Air", isDesktop: false)

    /// The pair as `thisMac` sees it, with the other Mac's own Routines choice.
    private func pair(_ thisMac: LinkedMac, _ otherMac: LinkedMac?, otherRoutines: DeviceChoice? = nil, paired: Bool = true, online: Bool = true) -> MacPair {
        var other = otherMac
        if let otherRoutines { other?.routinesChoice = otherRoutines }
        return MacPair(thisMac: thisMac, otherMac: other, paired: paired, otherMacOnline: online)
    }

    private func route(_ feature: DeviceFeature, _ choice: DeviceChoice? = nil, on thisMac: LinkedMac, with otherMac: LinkedMac?, otherRoutines: DeviceChoice? = nil,
                       paired: Bool = true, online: Bool = true) -> DeviceRoute {
        DeviceRouting.route(feature, choice: choice ?? feature.defaultChoice, pair: pair(thisMac, otherMac, otherRoutines: otherRoutines, paired: paired, online: online))
    }

    func testBotsAndCodingRunOnTheMacYoureUsing() {
        XCTAssertEqual(route(.bots, on: studio, with: air), .runHere)
        XCTAssertEqual(route(.bots, on: air, with: studio), .runHere)
    }

    func testRoutinesFireOnTheStudioAndTheAirSendsThem() {
        XCTAssertEqual(route(.routines, on: studio, with: air), .runHere)
        XCTAssertEqual(route(.routines, on: air, with: studio), .sendAcross)
    }

    func testTheAirKeepsWorkingWhileTheStudioIsAway() {
        XCTAssertEqual(route(.bots, on: air, with: studio, online: false), .runHere)
        // Routines still wait for the Mac that fires them.
        XCTAssertEqual(route(.routines, on: air, with: studio, online: false), .waitForOtherMac)
    }

    func testBotsSetToTheOtherMacByHandStillGoThere() {
        XCTAssertEqual(route(.bots, .otherMac, on: air, with: studio), .sendAcross)
        XCTAssertEqual(route(.bots, .otherMac, on: air, with: studio, online: false), .waitForOtherMac)
    }

    func testAMacOnItsOwnRunsEverything() {
        for feature in DeviceFeature.allCases {
            for choice in DeviceChoice.allCases {
                XCTAssertEqual(route(feature, choice, on: air, with: nil, paired: false, online: false), .runHere, "\(feature) \(choice)")
            }
        }
    }

    func testClickyDictationAndVoiceRunOnBoth() {
        for feature in [DeviceFeature.clicky, .dictation, .voice] {
            XCTAssertEqual(route(feature, on: studio, with: air), .runHere, feature.title)
            XCTAssertEqual(route(feature, on: air, with: studio), .runHere, feature.title)
        }
    }

    func testHiddenScreensAreOnOneMacAndNeverSentAcross() {
        XCTAssertEqual(route(.studioScreens, on: studio, with: air), .runHere)
        XCTAssertEqual(route(.studioScreens, on: air, with: studio), .notHere)
        XCTAssertEqual(route(.studioScreens, .otherMac, on: studio, with: air), .notHere)
        // Any Mac can have them now: a laptop on its own, or one set to have them.
        XCTAssertEqual(route(.studioScreens, on: air, with: nil, paired: false), .runHere)
        XCTAssertEqual(route(.studioScreens, .thisMac, on: air, with: studio), .runHere)
    }

    func testResearchFromTheAirGoesToTheStudio() {
        XCTAssertEqual(route(.researchBrowser, on: studio, with: air), .runHere)
        XCTAssertEqual(route(.researchBrowser, on: air, with: studio), .sendAcross)
        XCTAssertEqual(route(.researchBrowser, on: air, with: studio, online: false), .waitForOtherMac)
    }

    func testThePickerIsObeyed() {
        XCTAssertEqual(route(.clicky, .otherMac, on: studio, with: air), .notHere)
        XCTAssertEqual(route(.clicky, .thisMac, on: air, with: studio), .runHere)
        XCTAssertEqual(route(.bots, .thisMac, on: air, with: studio), .runHere)
        XCTAssertEqual(route(.bots, .any, on: air, with: studio), .runHere)
        XCTAssertEqual(route(.bots, .otherMac, on: studio, with: air), .sendAcross)
    }

    // MARK: Routines fire on exactly one Mac, whatever the pair

    /// Both sides of every pair of Routines choices: exactly one Mac fires. `firstMac` holds `firstChoice`, `secondMac` `secondChoice`.
    private func firingMacs(_ firstMac: LinkedMac, _ firstChoice: DeviceChoice, _ secondMac: LinkedMac, _ secondChoice: DeviceChoice) -> [String] {
        var firing: [String] = []
        if route(.routines, firstChoice, on: firstMac, with: secondMac, otherRoutines: secondChoice) == .runHere { firing.append(firstMac.name) }
        if route(.routines, secondChoice, on: secondMac, with: firstMac, otherRoutines: firstChoice) == .runHere { firing.append(secondMac.name) }
        return firing
    }

    private func assertExactlyOneFires(_ firstMac: LinkedMac, _ secondMac: LinkedMac, file: StaticString = #filePath, line: UInt = #line) {
        for firstChoice in DeviceChoice.allCases {
            for secondChoice in DeviceChoice.allCases {
                XCTAssertEqual(firingMacs(firstMac, firstChoice, secondMac, secondChoice).count, 1, "\(firstMac.name): \(firstChoice), \(secondMac.name): \(secondChoice)", file: file, line: line)
            }
        }
    }

    func testTwoLaptopsFireRoutinesOnExactlyOne() {
        // Until now both laptops counted as "MacBook Air", each waited for a "Mac Studio", and routines never fired.
        let pro = LinkedMac(id: "1111", name: "Sam’s MacBook Pro", isDesktop: false)
        let otherAir = LinkedMac(id: "2222", name: "Sam’s MacBook Air", isDesktop: false)
        assertExactlyOneFires(pro, otherAir)
        // Nobody picked: the smaller id, the same answer on both.
        XCTAssertEqual(firingMacs(pro, .any, otherAir, .any), ["Sam’s MacBook Pro"])
    }

    func testTwoDesktopsFireRoutinesOnExactlyOne() {
        let mini = LinkedMac(id: "9999", name: "Office Mac mini", isDesktop: true)
        let iMac = LinkedMac(id: "3333", name: "Kitchen iMac", isDesktop: true)
        assertExactlyOneFires(mini, iMac)
        XCTAssertEqual(firingMacs(mini, .any, iMac, .any), ["Kitchen iMac"])
    }

    func testADesktopAndALaptopFireRoutinesOnExactlyOne() {
        assertExactlyOneFires(studio, air)
        // Nobody picked: the desktop, even though the laptop's id is smaller.
        XCTAssertEqual(firingMacs(studio, .any, air, .any), ["Adhyan’s Mac Studio"])
    }

    func testTheOwnersPickWins() {
        XCTAssertEqual(firingMacs(studio, .any, air, .thisMac), ["Adhyan’s MacBook Air"])
        XCTAssertEqual(firingMacs(studio, .otherMac, air, .any), ["Adhyan’s MacBook Air"])
        XCTAssertEqual(firingMacs(studio, .otherMac, air, .thisMac), ["Adhyan’s MacBook Air"])
        XCTAssertEqual(firingMacs(studio, .thisMac, air, .otherMac), ["Adhyan’s Mac Studio"])
        // Both want them, or both want the other to have them: the always-on Mac.
        XCTAssertEqual(firingMacs(studio, .thisMac, air, .thisMac), ["Adhyan’s Mac Studio"])
        XCTAssertEqual(firingMacs(studio, .otherMac, air, .otherMac), ["Adhyan’s Mac Studio"])
    }

    func testBeforeTheOtherMacHasBeenHeardFromOnlyADesktopFires() {
        XCTAssertEqual(route(.routines, on: studio, with: nil), .runHere)
        XCTAssertEqual(route(.routines, on: air, with: nil), .sendAcross)
        XCTAssertEqual(route(.routines, on: air, with: nil, online: false), .waitForOtherMac)
    }

    func testAnOlderBuildOnTheOtherMacIsKnownByItsNameAndScreens() {
        // A build from before ids were shared says only its name and whether it has screens (then: whether it's a Mac Studio).
        let oldStudio = DeviceSnapshot(name: "Adhyan’s Mac Studio", projectsFolder: "~/Projects", projects: [], harnesses: [:], hasScreens: true, firesRoutines: true)
        XCTAssertEqual(oldStudio.linkedMac, LinkedMac(id: "name:Adhyan’s Mac Studio", name: "Adhyan’s Mac Studio", isDesktop: true, routinesChoice: nil))
        XCTAssertEqual(route(.routines, on: air, with: oldStudio.linkedMac), .sendAcross)
        let newAir = DeviceSnapshot(name: "Adhyan’s MacBook Air", projectsFolder: "~/Projects", projects: [], harnesses: [:], hasScreens: false,
                                    deviceID: "A-AIR", isDesktop: false, routinesChoice: "thisMac")
        XCTAssertEqual(newAir.linkedMac.routinesChoice, .thisMac)
        XCTAssertEqual(route(.routines, on: studio, with: newAir.linkedMac), .sendAcross)
    }

    // MARK: Settings saved by builds that knew only a Mac Studio and a MacBook Air

    func testOldSavedChoicesBecomeThisMacOrTheOtherMac() {
        XCTAssertEqual(DeviceChoice.fromSaved("macStudio", thisMacWasMacStudio: true), .thisMac)
        XCTAssertEqual(DeviceChoice.fromSaved("macStudio", thisMacWasMacStudio: false), .otherMac)
        XCTAssertEqual(DeviceChoice.fromSaved("macBookAir", thisMacWasMacStudio: true), .otherMac)
        // Every Mac that wasn't a Mac Studio counted as the MacBook Air.
        XCTAssertEqual(DeviceChoice.fromSaved("macBookAir", thisMacWasMacStudio: false), .thisMac)
        XCTAssertEqual(DeviceChoice.fromSaved("any", thisMacWasMacStudio: false), .any)
        XCTAssertEqual(DeviceChoice.fromSaved("thisMac", thisMacWasMacStudio: true), .thisMac)
        XCTAssertNil(DeviceChoice.fromSaved("somethingElse", thisMacWasMacStudio: true))
    }

    func testAddysSavedSettingsBehaveAsBefore() {
        // Before, routines, research and screens defaulted to "Mac Studio" (nothing saved). Now they default to Any, which for
        // these means the always-on Mac: the Studio.
        for feature in [DeviceFeature.routines, .researchBrowser, .studioScreens] {
            XCTAssertEqual(route(feature, on: studio, with: air), .runHere, feature.title)
            XCTAssertNotEqual(route(feature, on: air, with: studio), .runHere, feature.title)
        }
        // Routines set by hand to the Studio on the Air: kept, and still the Studio.
        let airsRoutines = DeviceChoice.fromSaved("macStudio", thisMacWasMacStudio: false)!
        XCTAssertEqual(firingMacs(air, airsRoutines, studio, .any), ["Adhyan’s Mac Studio"])
        // Bots set by hand to the Studio on the Air still go there.
        XCTAssertEqual(route(.bots, DeviceChoice.fromSaved("macStudio", thisMacWasMacStudio: false)!, on: air, with: studio), .sendAcross)
    }
}
