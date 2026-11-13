import Foundation
import Testing
@testable import ClickyCore

/// Which app a key step goes to (Studio, 2026-11-13: Enter was attributed to a UserNotificationCenter alert).
struct ActionKeyTargetTests {
    let spotifyProcessIdentifier: Int32 = 500
    let theoProcessIdentifier: Int32 = 100

    @Test func anAlertInFrontSendsTheKeyToTheTasksApp() {
        let alert = ActionKeyTarget.Frontmost(processIdentifier: 900, bundleIdentifier: "com.apple.UserNotificationCenter")
        #expect(ActionKeyTarget.processIdentifier(frontmost: alert, previousTargetProcessIdentifier: spotifyProcessIdentifier,
                                                  previousTargetIsRunning: true) == spotifyProcessIdentifier)
        let banner = ActionKeyTarget.Frontmost(processIdentifier: 901, bundleIdentifier: "com.apple.notificationcenterui")
        #expect(ActionKeyTarget.processIdentifier(frontmost: banner, previousTargetProcessIdentifier: spotifyProcessIdentifier,
                                                  previousTargetIsRunning: true) == spotifyProcessIdentifier)
    }

    @Test func anAlertWithNoPreviousTargetStaysTheFrontmost() {
        let alert = ActionKeyTarget.Frontmost(processIdentifier: 900, bundleIdentifier: "com.apple.UserNotificationCenter")
        #expect(ActionKeyTarget.processIdentifier(frontmost: alert, previousTargetProcessIdentifier: nil, previousTargetIsRunning: false) == 900)
        // The task's app has quit since: nothing to go back to.
        #expect(ActionKeyTarget.processIdentifier(frontmost: alert, previousTargetProcessIdentifier: spotifyProcessIdentifier,
                                                  previousTargetIsRunning: false) == 900)
    }

    @Test func aNormalAppInFrontStaysItself() {
        let finder = ActionKeyTarget.Frontmost(processIdentifier: 300, bundleIdentifier: "com.apple.finder")
        #expect(ActionKeyTarget.processIdentifier(frontmost: finder, previousTargetProcessIdentifier: spotifyProcessIdentifier,
                                                  previousTargetIsRunning: true) == 300)
    }

    @Test func theosMainWindowInFrontStaysTheoSoTheConfirmRuleApplies() {
        let theoMainWindow = ActionKeyTarget.Frontmost(processIdentifier: theoProcessIdentifier, bundleIdentifier: "com.personal.clicky",
                                                       isOwnApplication: true, showsOwnMainWindow: true)
        #expect(ActionKeyTarget.processIdentifier(frontmost: theoMainWindow, previousTargetProcessIdentifier: spotifyProcessIdentifier,
                                                  previousTargetIsRunning: true) == theoProcessIdentifier)
        // One of Theo's panels (the notch, a card) in front: the key goes back to the task's app.
        let theoPanel = ActionKeyTarget.Frontmost(processIdentifier: theoProcessIdentifier, bundleIdentifier: "com.personal.clicky",
                                                  isOwnApplication: true, showsOwnMainWindow: false)
        #expect(ActionKeyTarget.processIdentifier(frontmost: theoPanel, previousTargetProcessIdentifier: spotifyProcessIdentifier,
                                                  previousTargetIsRunning: true) == spotifyProcessIdentifier)
    }
}
