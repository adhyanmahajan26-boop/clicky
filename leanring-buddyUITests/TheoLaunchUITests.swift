//
//  TheoLaunchUITests.swift
//  leanring-buddyUITests
//

import XCTest

/// Theo starts without crashing.
final class TheoLaunchUITests: XCTestCase {
    func testTheoLaunches() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertNotEqual(app.state, .notRunning)
    }
}
