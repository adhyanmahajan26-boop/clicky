import Testing
@testable import ClickyCore

/// A live run drew a mark on the wrong display: the model put ":screen3" right after the
/// coordinates, the parser didn't read it there, and the mark fell back to SCREEN 1.
struct MarkTagParserScreenFieldTests {
    @Test func screenFieldRightAfterRawCoordinates() throws {
        let tag = try #require(MarkTagParser.parse("[MARK:box:302,507,206,68:screen3:Cherry Lamp|$89]"))
        #expect(tag.screenNumber == 3)
        #expect(tag.name == "Cherry Lamp")
        #expect(tag.note == "$89")
    }

    @Test func trailingScreenFieldStillWorks() throws {
        let tag = try #require(MarkTagParser.parse("[POINT:\"Submit\":Submit:screen3]"))
        #expect(tag.screenNumber == 3)
        #expect(tag.name == "Submit")
    }

    @Test func screenFieldAfterAnElementID() throws {
        let tag = try #require(MarkTagParser.parse("[MARK:box:#42:screen2:Card|note]"))
        #expect(tag.screenNumber == 2)
        #expect(tag.name == "Card")
    }

    @Test func noScreenFieldMeansDefault() throws {
        let tag = try #require(MarkTagParser.parse("[MARK:box:#42:Card|note]"))
        #expect(tag.screenNumber == nil)
        #expect(tag.effectiveScreenNumber == 1)
    }
}
