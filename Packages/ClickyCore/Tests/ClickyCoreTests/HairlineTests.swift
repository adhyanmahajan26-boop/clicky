//
//  HairlineTests.swift
//  ClickyCoreTests
//
//  Theme tokens, crew figure saving, Studio gating and tile math, and the chat cards' parsing.
//

import CoreGraphics
import XCTest
@testable import ClickyCore

final class HairlineTests: XCTestCase {
    // MARK: Theme

    func testBlackIsTrueBlackAndLightIsTrueWhite() {
        XCTAssertEqual(TheoPalette.black.background, TheoInk(0x000000))
        XCTAssertEqual(TheoPalette.black.sidebar, TheoInk(0x000000))
        XCTAssertEqual(TheoPalette.black.card, TheoInk(0x0A0A0A))
        XCTAssertEqual(TheoPalette.black.card2, TheoInk(0x141414))
        XCTAssertEqual(TheoPalette.black.line, TheoInk(0xFFFFFF, 0.08))
        XCTAssertEqual(TheoPalette.black.line2, TheoInk(0xFFFFFF, 0.15))
        XCTAssertEqual(TheoPalette.black.accent, TheoInk(0xFF7A45))
        XCTAssertEqual(TheoPalette.light.background, TheoInk(0xFFFFFF))
        XCTAssertEqual(TheoPalette.light.sidebar, TheoInk(0xFAFAFA))
        XCTAssertEqual(TheoPalette.light.card2, TheoInk(0xF4F4F4))
        XCTAssertEqual(TheoPalette.light.line2, TheoInk(0x000000, 0.16))
        XCTAssertEqual(TheoPalette.light.text, TheoInk(0x0B0B0C))
        XCTAssertEqual(TheoPalette.light.accent, TheoInk(0xEC622B))
    }

    func testAccentSwatches() {
        XCTAssertEqual(TheoPalette.accent("ember", dark: true), 0xFF7A45)
        XCTAssertEqual(TheoPalette.accent("ember", dark: false), 0xEC622B)
        XCTAssertEqual(TheoPalette.accent("nonsense", dark: true), 0xFF7A45)
    }

    // MARK: Figure looks

    func testLookRoundTripsThroughJSON() throws {
        let look = CrewLook(shell: "mint", glow: "#60a5fa", hat: .tophat, hatColor: "#a78bfa", antenna: .bolt, eyes: .hearts, extra: .scarf)
        let data = try JSONEncoder().encode(look)
        XCTAssertEqual(try JSONDecoder().decode(CrewLook.self, from: data), look)
    }

    func testUnknownPartsFallBackInsteadOfFailing() throws {
        let json = ##"{"shell":"chrome","glow":"#ff0000","hat":"fez","antenna":"ball","eyes":"wink","extra":"cape"}"##
        let look = try JSONDecoder().decode(CrewLook.self, from: Data(json.utf8))
        XCTAssertEqual(look.shell, "white")
        XCTAssertEqual(look.hat, .none)
        XCTAssertEqual(look.antenna, .ball)
        XCTAssertEqual(look.eyes, .pill)
        XCTAssertEqual(look.extra, .none)
        XCTAssertEqual(look.hatColor, "#ff0000")
    }

    func testDefaultsFollowTheSpec() {
        XCTAssertEqual(CrewLook.standard(id: "theo", name: "Theo"), .theo)
        XCTAssertEqual(CrewLook.theo.shell, "black")
        XCTAssertEqual(CrewLook.theo.antenna, .ball)
        XCTAssertEqual(CrewLook.theo.extra, .tie)
        XCTAssertEqual(CrewLook.standard(id: "clicky", name: "Clicky").antenna, .cursor)
        XCTAssertEqual(CrewLook.clicky.eyes, .round)
        XCTAssertEqual(CrewLook.standard(id: "x", name: "Code Reviewer"), .reviewer)
        XCTAssertEqual(CrewLook.standard(id: "x", name: "Builder"), .builder)
    }

    func testAStrangerKeepsTheSameLookAcrossLaunches() {
        XCTAssertEqual(CrewLook.standard(id: "abc123", name: "Gus"), CrewLook.standard(id: "abc123", name: "Gus"))
    }

    func testShuffleNeverGivesTheCursorAway() {
        var generator = SeededGenerator(seed: "shuffle")
        for _ in 0..<300 {
            let look = CrewLook.shuffled(using: &generator)
            XCTAssertNotEqual(look.antenna, .cursor)
            XCTAssertNotNil(CrewLook.shells[look.shell])
        }
    }

    func testAntennaClearsHats() {
        XCTAssertEqual(CrewLook(hat: .tophat).antennaLift, -8.5)
        XCTAssertEqual(CrewLook(hat: .hardhat).antennaLift, -3.5)
        XCTAssertEqual(CrewLook(hat: .headset).antennaLift, 0)
    }

    // MARK: SVG

    func testPathWithCompactNumbersAndArc() {
        let box = SVGPath.cgPath("M7.5 15.5a16.5 12 0 0 1 33 0z").boundingBoxOfPath
        XCTAssertEqual(box.minX, 7.5, accuracy: 0.01)
        XCTAssertEqual(box.maxX, 40.5, accuracy: 0.01)
        XCTAssertEqual(box.maxY, 15.5, accuracy: 0.01)
        XCTAssertLessThan(box.minY, 4)
    }

    func testPathKeepsImplicitRepeats() {
        let box = SVGPath.cgPath("m9 12 2.2 2.2 4-4.2").boundingBoxOfPath
        XCTAssertEqual(box.minX, 9, accuracy: 0.01)
        XCTAssertEqual(box.maxX, 15.2, accuracy: 0.01)
        XCTAssertEqual(box.minY, 10, accuracy: 0.01)
    }

    func testHeartParses() {
        let box = SVGPath.cgPath("M0 2.3C-2.7.5-3.5-.8-3.5-2a1.75 1.75 0 0 1 3.5-.6A1.75 1.75 0 0 1 3.5-2c0 1.2-.8 2.5-3.5 4.3z").boundingBoxOfPath
        XCTAssertEqual(box.minX, -3.5, accuracy: 0.05)
        XCTAssertEqual(box.maxX, 3.5, accuracy: 0.05)
    }

    // MARK: Studio

    func testOnlyMacStudiosGetStudio() {
        XCTAssertTrue(StudioGate.isMacStudio(model: "Mac15,14"))
        XCTAssertTrue(StudioGate.isMacStudio(model: "Mac13,1"))
        XCTAssertTrue(StudioGate.isMacStudio(model: "Mac99,1", productName: "Mac Studio"))
        XCTAssertFalse(StudioGate.isMacStudio(model: "Mac15,12"), "MacBook Air")
        XCTAssertFalse(StudioGate.isMacStudio(model: "Mac99,1", productName: "MacBook Pro"))
        XCTAssertFalse(StudioGate.isMacStudio(model: ""))
    }

    func testTwoTilesAreHalves() {
        XCTAssertEqual(StudioLayout.tileFrame(index: 0, tilesPerScreen: 2), CGRect(x: 0, y: 0, width: 720, height: 900))
        XCTAssertEqual(StudioLayout.tileFrame(index: 1, tilesPerScreen: 2), CGRect(x: 720, y: 0, width: 720, height: 900))
        XCTAssertEqual(StudioLayout.tileFrame(index: 0, tilesPerScreen: 1), CGRect(x: 0, y: 0, width: 1440, height: 900))
    }

    func testOddWidthLeavesNoGap() {
        let size = CGSize(width: 1441, height: 900)
        let left = StudioLayout.tileFrame(index: 0, tilesPerScreen: 2, in: size)
        let right = StudioLayout.tileFrame(index: 1, tilesPerScreen: 2, in: size)
        XCTAssertEqual(left.maxX, right.minX)
        XCTAssertEqual(right.maxX, 1441)
    }

    func testHiddenScreensTouchOnlyAtACorner() {
        // Addy's three monitors.
        let displays = [CGRect(x: 0, y: 0, width: 3440, height: 1440), CGRect(x: 3440, y: 198, width: 1920, height: 1080),
                        CGRect(x: -1920, y: 155, width: 1920, height: 1080)]
        let origins = StudioLayout.origins(forScreens: 2, besides: displays)
        XCTAssertEqual(origins, [CGPoint(x: 5360, y: 1278), CGPoint(x: 6800, y: 1278)])
        for origin in origins {
            let frame = CGRect(origin: origin, size: StudioLayout.screenSize)
            XCTAssertFalse(displays.contains { $0.intersects(frame) })
            XCTAssertFalse(displays.contains { StudioLayout.shareAnEdge($0, frame) })
        }
    }

    func testEdgesAndCorners() {
        let main = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertTrue(StudioLayout.shareAnEdge(main, CGRect(x: 100, y: 50, width: 10, height: 10)))
        XCTAssertTrue(StudioLayout.shareAnEdge(main, CGRect(x: 50, y: 100, width: 10, height: 10)))
        XCTAssertFalse(StudioLayout.shareAnEdge(main, CGRect(x: 100, y: 100, width: 10, height: 10)), "only a corner")
        XCTAssertFalse(StudioLayout.shareAnEdge(main, CGRect(x: 200, y: 0, width: 10, height: 10)))
    }

    func testBotHoldsOneTile() {
        var roster = StudioRoster()
        let first = StudioTileID(screen: 0, tile: 0), second = StudioTileID(screen: 1, tile: 1)
        roster.assign("builder", to: first)
        roster.assign("builder", to: second)
        XCTAssertNil(roster.bots[first])
        XCTAssertEqual(roster.tile(of: "builder"), second)
        XCTAssertEqual(roster.firstFree(screens: 2, tilesPerScreen: 2), first)
    }

    func testFewerTilesDropsWhatNoLongerFits() {
        var roster = StudioRoster()
        roster.assign("a", to: StudioTileID(screen: 0, tile: 0))
        roster.assign("b", to: StudioTileID(screen: 0, tile: 1))
        roster.trim(screens: 2, tilesPerScreen: 1)
        XCTAssertEqual(roster.bots.count, 1)
        XCTAssertEqual(roster.tile(of: "a"), StudioTileID(screen: 0, tile: 0))
    }

    // MARK: Cards

    func testLongAnswerWithHeadingsBecomesABrief() throws {
        let body = String(repeating: "Two hidden screens split into tiles keep the work out of sight. ", count: 20)
        let card = try XCTUnwrap(BriefCard.parse("# Studio Screens: **four** bots\n\n\(body)\n\n## Why\n\nBecause.\n\n## How it works\n\nLike this."))
        XCTAssertEqual(card.title, "Studio Screens: four bots")
        XCTAssertEqual(card.sections, ["Why", "How it works"])
        XCTAssertEqual(card.kind, "Brief")
        XCTAssertGreaterThanOrEqual(card.minutes, 1)
        XCTAssertTrue(card.excerpt.hasPrefix("Two hidden screens"))
    }

    func testShortAnswerStaysChat() {
        XCTAssertNil(BriefCard.parse("Sure, done. # not a heading"))
        XCTAssertNil(BriefCard.parse(String(repeating: "one long paragraph with nothing else ", count: 60)))
    }

    func testPromptTagParses() throws {
        let call = try XCTUnwrap(BotCallPrompt.parse("Before I go on.\n[CHOOSE: How should it split? | Side by side: Best for code | Stacked: Better for timelines]"))
        XCTAssertEqual(call.question, "How should it split?")
        XCTAssertEqual(call.options, [.init(title: "Side by side", detail: "Best for code"), .init(title: "Stacked", detail: "Better for timelines")])
        XCTAssertEqual(call.remainingText, "Before I go on.")
    }

    func testPromptNeedsTwoOptions() {
        XCTAssertNil(BotCallPrompt.parse("[CHOOSE: Really? | Yes]"))
        XCTAssertNil(BotCallPrompt.parse("No tag here"))
    }

    func testRunStepFills() {
        XCTAssertEqual(RunSteps.fills(phase: "running", stage: nil), [.done, .active, .todo, .todo, .todo])
        XCTAssertEqual(RunSteps.fills(phase: "reporting", stage: "push"), [.done, .done, .done, .active, .todo])
        XCTAssertEqual(RunSteps.fills(phase: "done", stage: nil), [.done, .done, .done, .done, .done])
    }
}
