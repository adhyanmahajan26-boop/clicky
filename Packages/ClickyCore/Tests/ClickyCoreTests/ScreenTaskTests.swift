//
//  ScreenTaskTests.swift
//  ClickyCoreTests
//
//  The helper's steps for a hidden-screen job, and what it may never do there.
//

import XCTest
@testable import ClickyCore

final class ScreenTaskTests: XCTestCase {
    func testStepsParse() {
        XCTAssertEqual(ScreenTaskStep.parse(#"{"do":"open","app":"Stickies"}"#), .open(app: "Stickies"))
        XCTAssertEqual(ScreenTaskStep.parse(#"```json\#n{"do":"press","id":4}\#n```"#), .press(id: 4))
        XCTAssertEqual(ScreenTaskStep.parse(#"{"do":"menu","path":["File","New Note"]}"#), .menu(path: ["File", "New Note"]))
        XCTAssertEqual(ScreenTaskStep.parse(#"{"do":"type","id":7,"text":"Hello Addy"}"#), .type(id: 7, text: "Hello Addy"))
        XCTAssertEqual(ScreenTaskStep.parse(#"{"do":"done","say":" A note is up. "}"#), .done(say: "A note is up."))
        XCTAssertEqual(ScreenTaskStep.parse(#"{"do":"cant","say":"No field."}"#), .cant(say: "No field."))
    }

    func testBadStepsAreNotSteps() {
        for reply in ["sure, done!", #"{"do":"click","id":1}"#, #"{"do":"press"}"#, #"{"do":"menu","path":[]}"#, "{broken}"] {
            XCTAssertNil(ScreenTaskStep.parse(reply), reply)
        }
    }

    func testOrdinaryAppsAreAllowed() {
        for app in ["Stickies", "Calculator", "Clock", "Notes", "TextEdit", "Calendar", "Reminders"] {
            XCTAssertNil(ScreenTaskPolicy.refusal(app: app), app)
        }
    }

    func testAppsThatAreNeverDrivenThere() {
        for app in ["Terminal", "iTerm", "Xcode", "Google Chrome", "Safari", "Mail", "Messages", "Slack", "System Settings", "Finder", "Music", "Theo"] {
            XCTAssertNotNil(ScreenTaskPolicy.refusal(app: app), app)
        }
    }

    func testPressesThatCantBeTakenBackAreRefused() {
        for title in ["Send", "Pay now", "Delete Note", "Quit Stickies", "Empty Trash", "Sign In"] {
            XCTAssertNotNil(ScreenTaskPolicy.refusal(pressing: title), title)
        }
        for title in ["New Note", "7", "Add", "Start", "Close", "Sender info", "Reposition"] {
            XCTAssertNil(ScreenTaskPolicy.refusal(pressing: title), title)
        }
    }
}

final class StudioScreensConfigTests: XCTestCase {
    private func tile(_ screen: Int, _ index: Int) -> StudioTileID { StudioTileID(screen: screen, tile: index) }
    private var current: StudioScreensConfig { .migrated(screenCount: 2, tilesPerScreen: 2, previewFPS: 4) { _ in nil } }

    func testTodaysScreensMigrateUnchanged() {
        XCTAssertEqual(current.screens.map(\.name), ["Screen 1", "Screen 2"])
        for spec in current.screens {
            XCTAssertEqual(spec.sizeLabel, "1440×900")
            XCTAssertEqual(spec.refresh, 60)
            XCTAssertEqual(spec.tiles, 2)
            XCTAssertFalse(spec.hiDPI)
            XCTAssertTrue(spec.owners.isEmpty)
        }
    }

    func testAnOwnerPickedByHandIsKept() {
        let config = StudioScreensConfig.migrated(screenCount: 2, tilesPerScreen: 2, previewFPS: 4) { $0 == 1 ? "kadi" : "" }
        XCTAssertEqual(config.screens.map(\.owners), [[], ["kadi"]])
    }

    func testItSurvivesEncoding() throws {
        var config = current
        config.addScreen()
        config.screens[2].hiDPI = true
        config.set(.none, for: "quiet")
        XCTAssertEqual(StudioScreensConfig.decoded(try XCTUnwrap(config.encoded())), config)
    }

    func testBadValuesAreBroughtIn() throws {
        var config = current
        config.screens[0].width = 99999
        config.screens[0].refresh = 77
        config.screens[0].tiles = 3
        config.screens[0].previewFPS = 500
        let spec = try XCTUnwrap(StudioScreensConfig.decoded(try XCTUnwrap(config.encoded()))).screens[0]
        XCTAssertEqual([spec.width, spec.refresh, spec.tiles, spec.previewFPS], [3840, 60, 2, 15])
        XCTAssertNil(StudioScreensConfig.decoded(Data("nope".utf8)))
    }

    func testOnlyDisplayChangesNeedARebuild() {
        var changed = current
        changed.screens[0].name = "Mine"
        changed.screens[0].tiles = 4
        changed.screens[0].previewFPS = 10
        changed.set(.screen("screen-1"), for: "bot")
        XCTAssertFalse(changed.needsRebuild(from: current))
        changed.screens[0].refresh = 120
        XCTAssertTrue(changed.needsRebuild(from: current))
        var more = current
        more.addScreen()
        XCTAssertTrue(more.needsRebuild(from: current))
    }

    func testTheLastScreenCantBeRemoved() {
        var config = current
        config.removeScreen("screen-1")
        config.removeScreen("screen-2")
        XCTAssertEqual(config.screens.count, 1)
    }

    func testABotsOwnScreenComesFirstThenThePool() {
        var config = current
        config.set(.screen("screen-2"), for: "researcher")
        XCTAssertEqual(config.freeTiles(for: "researcher", roster: StudioRoster()), [tile(1, 0), tile(1, 1), tile(0, 0), tile(0, 1)])
        XCTAssertEqual(config.freeTiles(for: "other", roster: StudioRoster()), [tile(0, 0), tile(0, 1)])
    }

    func testABotWithNoScreenWaitsAndChoicesReplaceEachOther() {
        var config = current
        config.set(.none, for: "bot")
        XCTAssertEqual(config.choice(for: "bot"), StudioScreenChoice.none)
        XCTAssertTrue(config.freeTiles(for: "bot", roster: StudioRoster()).isEmpty)
        config.set(.screen("screen-1"), for: "bot")
        XCTAssertEqual(config.choice(for: "bot"), .screen("screen-1"))
        config.set(.sharedPool, for: "bot")
        XCTAssertEqual(config.choice(for: "bot"), .sharedPool)
        XCTAssertEqual(config.screens[0].owners, [])
    }

    func testScreensCanShareAnOwnerAndOneCanHaveSeveral() {
        var config = current
        config.screens[0].owners = ["a", "b"]
        XCTAssertEqual(config.freeTiles(for: "b", roster: StudioRoster()).first, tile(0, 0))
        XCTAssertEqual(config.freeTiles(for: "c", roster: StudioRoster()), [tile(1, 0), tile(1, 1)])
    }

    func testFourTilesMakeASquare() {
        let size = CGSize(width: 1440, height: 900)
        XCTAssertEqual(StudioLayout.tileFrame(index: 0, tilesPerScreen: 4, in: size), CGRect(x: 0, y: 450, width: 720, height: 450))
        XCTAssertEqual(StudioLayout.tileFrame(index: 3, tilesPerScreen: 4, in: size), CGRect(x: 720, y: 0, width: 720, height: 450))
    }

    func testScreensOfDifferentSizesDontOverlap() {
        let origins = StudioLayout.origins(forSizes: [CGSize(width: 1280, height: 800), CGSize(width: 1920, height: 1080)], besides: [CGRect(x: 0, y: 0, width: 100, height: 100)])
        XCTAssertEqual(origins, [CGPoint(x: 100, y: 100), CGPoint(x: 1380, y: 100)])
    }

    func testCostRisesWithWhatsAskedFor() {
        let plain = StudioScreenCost.estimate(StudioScreenSpec(id: "a", name: "a"))
        XCTAssertEqual(plain.graphicsMB, 14)
        var big = StudioScreenSpec(id: "b", name: "b", width: 2560, height: 1440)
        XCTAssertGreaterThan(StudioScreenCost.estimate(big).graphicsMB, plain.graphicsMB)
        big.hiDPI = true
        XCTAssertGreaterThan(StudioScreenCost.estimate(big).graphicsMB, 150)
        XCTAssertGreaterThan(StudioScreenCost.estimate(StudioScreenSpec(id: "c", name: "c", previewFPS: 15)).cpuPercent, plain.cpuPercent)
        XCTAssertEqual(StudioScreenCost.total([StudioScreenSpec(id: "a", name: "a"), StudioScreenSpec(id: "b", name: "b")]).graphicsMB, 28)
    }

    func testResearchAndGiftTagsComeOutOfTheText() {
        let research = BotResearchOrder.extract(from: "Sure.\n[RESEARCH: what Stickies can do]")
        XCTAssertEqual(research.text, "Sure.")
        XCTAssertEqual(research.questions, ["what Stickies can do"])
        let gift = BotScreenGift.extract(from: "Done [GIVE SCREEN: Researcher: own]")
        XCTAssertEqual(gift.text, "Done")
        XCTAssertEqual(gift.gifts.first?.bot, "Researcher")
        XCTAssertEqual(gift.gifts.first?.screen, "own")
        XCTAssertEqual(BotTagWords.withoutTags(streaming: "Sure [RESEARCH: wha"), "Sure ")
    }

    func testGiftWordsResolve() {
        var config = current
        XCTAssertEqual(BotScreenGift.choice(for: "own", in: config), .screen("screen-2"))
        XCTAssertEqual(BotScreenGift.choice(for: "screen 1", in: config), .screen("screen-1"))
        XCTAssertEqual(BotScreenGift.choice(for: "None", in: config), StudioScreenChoice.none)
        XCTAssertEqual(BotScreenGift.choice(for: "shared", in: config), .sharedPool)
        XCTAssertNil(BotScreenGift.choice(for: "Screen 9", in: config))
        config.screens[0].owners = ["a"]
        config.screens[1].owners = ["b"]
        XCTAssertNil(BotScreenGift.choice(for: "own", in: config))
    }
}
