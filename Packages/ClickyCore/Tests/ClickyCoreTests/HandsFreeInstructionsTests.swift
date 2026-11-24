import Testing
@testable import ClickyCore

/// Pointer Assistant hands-free (the owner, 2026-11-24): a new instruction replaces the old task, and a yes never
/// needs a click. Live log on the Air that morning: "Displays" and System Settings' close button each waited for a
/// click on the confirm card, the click itself then cancelled the step ("you moved the mouse"), Vello's "Yes, Addy
/// confirmed" became a new order that asked again, and later orders queued behind the old ones.
struct HandsFreeInstructionsTests {
    // MARK: A yes passed on by Vello

    @Test func aRelayedYesCountsByItsOpeningWords() {
        #expect(ActionConfirmReply.parseRelayed("Yes, Addy confirmed. Click #88 to open Displays in System Settings.") == .yes)
        #expect(ActionConfirmReply.parseRelayed("Haan, kar do. Open Displays.") == .yes)
        #expect(ActionConfirmReply.parseRelayed("yes") == .yes)
        #expect(ActionConfirmReply.parseRelayed("no") == .no)
        // A "no" that goes on is a new request, not only a no.
        #expect(ActionConfirmReply.parseRelayed("No, open Safari instead and search for ramen") == .notAReply)
        #expect(ActionConfirmReply.parseRelayed("Open the OpenCode desktop app") == .notAReply)
    }

    // MARK: Newer orders replace older ones

    @Test func anOrderFromNewerWordsReplacesTheOldOnes() {
        #expect(ClickyOrderReplacement.replaces(newOwnerLine: "forget that, open opencode", earlierOwnerLine: "close system settings"))
        // The same words gave both orders ("open Safari", then "search this"): they take turns.
        #expect(!ClickyOrderReplacement.replaces(newOwnerLine: "Open Safari and search ramen.", earlierOwnerLine: "open safari and search ramen"))
        // Orders that didn't come from the owner's words never replace or get replaced.
        #expect(!ClickyOrderReplacement.replaces(newOwnerLine: "", earlierOwnerLine: "close system settings"))
        #expect(!ClickyOrderReplacement.replaces(newOwnerLine: "open opencode", earlierOwnerLine: ""))
    }

    // MARK: Talking over Pointer Assistant

    @Test func aNewInstructionOverPointerAssistantsVoiceIsntEcho() {
        let saying: Set<String> = ["opening", "spotlight", "and", "typing", "opencode", "then", "i'll", "check", "the", "result"]
        #expect(HandsFreeBargeIn.isNewInstruction("no wait open whatsapp instead", recentClickySpokenWords: saying))
        // Its own words coming back through the mic.
        #expect(!HandsFreeBargeIn.isNewInstruction("opening spotlight and typing opencode", recentClickySpokenWords: saying))
        // Too short to tell from a stray word ("stop" and "wait" have their own path).
        #expect(!HandsFreeBargeIn.isNewInstruction("okay", recentClickySpokenWords: saying))
    }

    // MARK: Clicking the confirm card doesn't cancel what it confirmed

    @Test func movingTheMouseRightAfterClickingTheCardDoesntCancel() {
        var logic = ActionCancelLogic()
        logic.arm(excusingMouseMovesUntilUptime: 12.5)
        #expect(logic.handle(PhysicalInputEvent(kind: .mouseMoved(deltaX: 80, deltaY: 40), timestamp: 10.2)) == .ignore)
        #expect(logic.handle(PhysicalInputEvent(kind: .mouseMoved(deltaX: 120, deltaY: 0), timestamp: 12.0)) == .ignore)
        // A real click or key still cancels at once.
        #expect(logic.handle(PhysicalInputEvent(kind: .keyDown(keyCode: 0), timestamp: 12.1)) == .cancel(reason: "you pressed a key"))
        // After the grace, moving cancels again.
        var later = ActionCancelLogic()
        later.arm(excusingMouseMovesUntilUptime: 12.5)
        guard case .cancel = later.handle(PhysicalInputEvent(kind: .mouseMoved(deltaX: 20, deltaY: 0), timestamp: 13)) else {
            Issue.record("expected a cancel after the grace")
            return
        }
    }
}
