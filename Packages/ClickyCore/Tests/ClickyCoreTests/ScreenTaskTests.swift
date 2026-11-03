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
