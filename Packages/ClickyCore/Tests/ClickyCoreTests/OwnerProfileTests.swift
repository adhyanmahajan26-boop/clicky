import XCTest
@testable import ClickyCore

final class OwnerProfileTests: XCTestCase {
    func testTheSectionCarriesTheFileWithoutItsCommentAndNamesTheOwner() {
        let section = OwnerProfile.section(OwnerProfile.newFile + "- Runs a studio in Pune\n", path: "/m/about-you.md", owner: "Addy")
        XCTAssertTrue(section.hasPrefix("About Addy, shared by every bot (/m/about-you.md):"))
        XCTAssertTrue(section.contains("<about-owner>\n- Runs a studio in Pune\n</about-owner>"))
        XCTAssertFalse(section.contains("<!--"))
        XCTAssertTrue(section.contains(OwnerProfile.tagExample))
        let empty = OwnerProfile.section(OwnerProfile.newFile, path: "/m/about-you.md", owner: OwnerName.unset)
        XCTAssertTrue(empty.hasPrefix("About the owner: nothing is saved yet"))
        XCTAssertFalse(empty.contains("Addy"))
    }

    func testAnOversizedFileIsCutAtTheLimit() {
        let section = OwnerProfile.section(String(repeating: "a", count: OwnerProfile.limit + 50), path: "p", owner: "Addy")
        XCTAssertTrue(section.contains("[… cut at \(OwnerProfile.limit) characters …]"))
    }

    func testFactsAreTakenOutOfTheReply() {
        let reply = "Noted, I'll keep it short.\n[ABOUT YOU: Prefers short answers]\n  [about you: Cofounder is Riya ]\n[ABOUT YOU: ]"
        let taken = OwnerProfile.extract(from: reply)
        XCTAssertEqual(taken.text, "Noted, I'll keep it short.")
        XCTAssertEqual(taken.facts, ["Prefers short answers", "Cofounder is Riya"])
        let plain = OwnerProfile.extract(from: "Nothing here [ABOUT YOU: inline isn't a line]")
        XCTAssertEqual(plain.text, "Nothing here [ABOUT YOU: inline isn't a line]")
        XCTAssertTrue(plain.facts.isEmpty)
    }

    func testFactsAreAddedOnceAndNeverPastTheLimit() {
        let start = OwnerProfile.newFile + "- Prefers short answers.\n"
        guard case .added(let text, let facts) = OwnerProfile.adding(["prefers short answers", "Lives in Pune", "Lives in Pune"], to: start) else {
            return XCTFail("expected an addition")
        }
        XCTAssertEqual(facts, ["Lives in Pune"])
        XCTAssertTrue(text.hasSuffix("- Prefers short answers.\n- Lives in Pune\n"))
        XCTAssertTrue(text.hasPrefix("<!--"))
        XCTAssertEqual(OwnerProfile.adding(["Lives in Pune!"], to: text), .alreadyKnown)
        XCTAssertEqual(OwnerProfile.adding(["new fact"], to: String(repeating: "x", count: OwnerProfile.limit)), .full)
    }

    func testTheNoteSaysWhatWasSavedAndWhereToChangeIt() {
        XCTAssertEqual(OwnerProfile.addedNote(facts: ["Lives in Pune"]),
                       "Saved to About you, which every bot reads: \"Lives in Pune\". Change or remove it in Settings › About.")
    }
}
