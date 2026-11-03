//
//  BrowserResearchTests.swift
//  ClickyCoreTests
//
//  What may open in the owner's logged-in browser, when a page needs it, human checks, and who gets a tile.
//

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
