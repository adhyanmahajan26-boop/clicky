//
//  PixelTests.swift
//  ClickyCoreTests
//
//  The Pixel faces: which state shows (one test per rule, in priority order), how saved looks carry over, and the shape of
//  every frame.
//

import ClickyCore
import XCTest

final class PixelStatePriorityTests: XCTestCase {
    /// Everything true at once, so each rule has to beat all the ones below it.
    private let everything = PixelStateFacts(isOn: true, isWaitingOnOwner: true, hasUnseenFailure: true, isTyping: true, isListening: true,
                                             isWorking: true, isThinking: true, finishedRecently: true, isAwake: true)

    func testRule1OffBeatsEverything() {
        var facts = everything
        facts.isOn = false
        XCTAssertEqual(PixelStatePriority.state(for: facts), .off)
    }

    func testRule2NeedsYouBeatsFailedAndWork() {
        XCTAssertEqual(PixelStatePriority.state(for: everything), .needs)
    }

    func testRule3FailedBeatsTalkingAndWork() {
        var facts = everything
        facts.isWaitingOnOwner = false
        XCTAssertEqual(PixelStatePriority.state(for: facts), .failed)
    }

    func testRule4TalkingBeatsListening() {
        var facts = everything
        facts.isWaitingOnOwner = false
        facts.hasUnseenFailure = false
        XCTAssertEqual(PixelStatePriority.state(for: facts), .talking)
    }

    func testRule5ListeningBeatsWorking() {
        let facts = PixelStateFacts(isListening: true, isWorking: true, isThinking: true, finishedRecently: true, isAwake: true)
        XCTAssertEqual(PixelStatePriority.state(for: facts), .listening)
    }

    func testRule6WorkingBeatsThinking() {
        let facts = PixelStateFacts(isWorking: true, isThinking: true, finishedRecently: true, isAwake: true)
        XCTAssertEqual(PixelStatePriority.state(for: facts), .working)
    }

    func testRule7ThinkingBeatsDone() {
        let facts = PixelStateFacts(isThinking: true, finishedRecently: true, isAwake: true)
        XCTAssertEqual(PixelStatePriority.state(for: facts), .thinking)
    }

    func testRule8DoneBeatsAwake() {
        let facts = PixelStateFacts(finishedRecently: true, isAwake: true)
        XCTAssertEqual(PixelStatePriority.state(for: facts), .done)
    }

    func testRule9Awake() {
        XCTAssertEqual(PixelStatePriority.state(for: PixelStateFacts(isAwake: true)), .awake)
    }

    func testRule10IdleWhenNothingElse() {
        XCTAssertEqual(PixelStatePriority.state(for: PixelStateFacts()), .idle)
    }

    func testRulesFollowThePublishedPriorityList() {
        XCTAssertEqual(PixelState.priority, [.off, .needs, .failed, .talking, .listening, .working, .thinking, .done, .awake, .idle])
        XCTAssertEqual(PixelStatePriority.mostUrgent([.working, .done, .failed, .needs]), .needs)
        XCTAssertEqual(PixelStatePriority.mostUrgent([.working, .failed]), .failed)
        XCTAssertNil(PixelStatePriority.mostUrgent([]))
    }

    func testNeedsYouIsYellowAndOnlyFailedIsRed() {
        XCTAssertEqual(PixelState.needs.hex, 0xFFD938)
        XCTAssertEqual(PixelState.failed.hex, 0xFF4A5E)
        let red: UInt32 = 0xFF4A5E
        XCTAssertEqual(PixelState.allCases.filter { $0.hex == red }, [.failed])
    }

    func testOldPosesMapAcross() {
        XCTAssertEqual(PixelState(CrewPose.sleep), .idle)
        XCTAssertEqual(PixelState(CrewPose.awake), .awake)
        XCTAssertEqual(PixelState(CrewPose.working), .working)
        XCTAssertEqual(PixelState(CrewPose.needs), .needs)
        XCTAssertEqual(PixelState(CrewPose.done), .done)
        XCTAssertEqual(PixelState(CrewPose.talking), .talking)
    }

    func testLanesSortUrgentFirst() {
        XCTAssertEqual(PixelState.needs.lane, .needsYou)
        XCTAssertEqual(PixelState.failed.lane, .failed)
        XCTAssertEqual(PixelState.thinking.lane, .working)
        XCTAssertEqual(PixelState.done.lane, .done)
        XCTAssertEqual(PixelState.idle.lane, .quiet)
        XCTAssertEqual(PixelState.off.lane, .quiet)
        XCTAssertEqual(PixelState.Lane.allCases.map(\.title), ["Needs you", "Failed", "Working", "Done", "Quiet"])
    }

    func testFailureRecordKeepsTheFirstSentence() {
        XCTAssertEqual(BotFailureRecord(reason: "Your GitHub sign-in has expired. The changes are saved.").firstSentence, "Your GitHub sign-in has expired")
        XCTAssertEqual(BotFailureRecord(reason: "Grok isn't signed in\nRun grok login").firstSentence, "Grok isn't signed in")
        let record = BotFailureRecord(reason: "x", at: Date(timeIntervalSince1970: 1_000), step: "Push", runID: "r1")
        XCTAssertEqual(try JSONDecoder().decode(BotFailureRecord.self, from: JSONEncoder().encode(record)), record)
    }
}

final class PixelLookMappingTests: XCTestCase {
    func testBodiesMapAcrossAndMintBecomesSlate() {
        let expected = ["white": "bone", "graphite": "graphite", "black": "onyx", "cream": "sand", "sky": "sky", "blush": "blush", "mint": "slate",
                        "lilac": "lilac", "slate": "slate", "cocoa": "cocoa"]
        for (shell, finish) in expected {
            XCTAssertEqual(CrewLook(shell: shell).pixel.finish, finish, shell)
        }
    }

    func testOldGlowsBecomeTrimsAndNoneIsAStatusColour() {
        let expected: [String: UInt32] = ["#ff7a45": 0xFF7A45, "#ff6f9f": 0xF06FB0, "#34d3e6": 0x45C8E6, "#60a5fa": 0x5B8DEF, "#a78bfa": 0x9B7BF0,
                                          "#f4f4f5": 0xF4F4F5, "#a3e635": 0x45C8E6, "#f5b03c": 0xFF7A45, "#f87171": 0xF06FB0]
        for (glow, trim) in expected {
            XCTAssertEqual(CrewLook(glow: glow).pixel.trim, trim, glow)
        }
        let statusColours: Set<UInt32> = [0x22D391, 0xFFD938, 0xFF4A5E]
        for glow in ["#a3e635", "#f5b03c", "#f87171"] {
            XCTAssertFalse(statusColours.contains(CrewLook(glow: glow).pixel.trim))
        }
    }

    func testHatColourIsTheTrimUnderAHat() {
        let look = CrewLook(glow: "#60a5fa", hat: .beanie, hatColor: "#f5b03c")
        XCTAssertEqual(look.pixel.top, "beanie")
        XCTAssertEqual(look.pixel.trim, 0xFF7A45)
        XCTAssertTrue(look.pixel.hasHat)
    }

    func testAHatWinsOverAnAntenna() {
        let look = CrewLook(hat: .crown, antenna: .ball)
        XCTAssertEqual(look.pixel.top, "crown")
        XCTAssertEqual(CrewLook(antenna: .dish).pixel.top, "dish")
        XCTAssertEqual(CrewLook(antenna: .handle).pixel.top, "handle")
    }

    func testEyesAndExtrasMapAcross() {
        let eyes: [CrewLook.Eyes: String] = [.pill: "tall", .round: "round", .pixel: "block", .visor: "wide", .hearts: "heart"]
        for (old, new) in eyes { XCTAssertEqual(CrewLook(eyes: old).pixel.eye, new) }
        let extras: [CrewLook.Extra: String] = [.none: "none", .tie: "tie", .bowtie: "bowtie", .scarf: "scarf", .pencil: "pencil", .glasses: "bezel", .badge: "star"]
        for (old, new) in extras { XCTAssertEqual(CrewLook(extra: old).pixel.extra, new) }
    }

    func testEveryMappedPartIsOneTheFacesKnow() {
        for look in [CrewLook.theo, .clicky, .builder, .researcher, .designer, .reviewer, .inbox, .copyEditor, .release, .manager, .accountant] {
            let pixel = look.pixel
            XCTAssertTrue(PixelLook.finishOrder.contains(pixel.finish))
            XCTAssertTrue(PixelFaces.eyeStyles.contains(pixel.eye))
            XCTAssertTrue(PixelLook.antennas.contains(pixel.top) || PixelLook.hats.contains(pixel.top))
            XCTAssertTrue(PixelLook.extras.contains(pixel.extra))
        }
    }

    func testPresetsAreThePixelCrew() {
        XCTAssertEqual(CrewLook.theo.pixel, PixelLook(finish: "onyx", trim: 0xFF7A45, eye: "block", top: "ball", extra: "tie"))
        XCTAssertEqual(CrewLook.clicky.pixel, PixelLook(finish: "bone", trim: 0xFF9A5C, eye: "round", top: "cursor", extra: "none"))
        XCTAssertEqual(CrewLook.builder.pixel, PixelLook(finish: "bone", trim: 0x5B8DEF, eye: "wide", top: "handle", extra: "none"))
        XCTAssertEqual(CrewLook.inbox.pixel, PixelLook(finish: "sand", trim: 0x45C8E6, eye: "round", top: "headset", extra: "none"))
        XCTAssertEqual(CrewLook.manager.pixel, PixelLook(finish: "graphite", trim: 0xF4D7C4, eye: "tall", top: "tophat", extra: "bowtie"))
    }

    func testSavedLooksSurviveIncludingNewValues() throws {
        let old = ##"{"shell":"mint","glow":"#a3e635","hat":"none","hatColor":"#a3e635","antenna":"bolt","eyes":"visor","extra":"glasses"}"##
        let decoded = try JSONDecoder().decode(CrewLook.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.pixel, PixelLook(finish: "slate", trim: 0x45C8E6, eye: "wide", top: "bolt", extra: "bezel"))
        let new = CrewLook(shell: "cocoa", glow: "#f4d7c4", hatColor: "#f4d7c4", antenna: .handle)
        XCTAssertEqual(try JSONDecoder().decode(CrewLook.self, from: JSONEncoder().encode(new)), new)
        XCTAssertTrue(CrewLook.shellOrder.contains("lilac") && CrewLook.shellOrder.contains("slate") && CrewLook.shellOrder.contains("cocoa"))
        XCTAssertTrue(CrewLook.glows.contains("#f4d7c4"))
    }

    func testShuffledLooksNeverWearAStatusColour() {
        var generator = SeededGenerator(seed: "shuffle")
        let statusColours: Set<UInt32> = [0x22D391, 0xFFD938, 0xFF4A5E]
        for _ in 0..<200 {
            let look = CrewLook.shuffled(using: &generator)
            XCTAssertFalse(statusColours.contains(look.pixel.trim))
            XCTAssertNotEqual(look.pixel.finish, "mint")
            XCTAssertFalse(look.hat != .none && look.antenna != .none)
        }
    }
}

final class PixelFacesTests: XCTestCase {
    func testEveryFrameIsThirteenByNine() {
        for state in PixelState.allCases {
            for eye in PixelFaces.eyeStyles {
                let frames = PixelFaces.frames(state, eye: eye)
                XCTAssertFalse(frames.isEmpty, "\(state) \(eye)")
                for frame in frames {
                    XCTAssertEqual(frame.rows.count, PixelFaces.rows, "\(state) \(eye)")
                    for row in frame.rows {
                        XCTAssertEqual(row.count, PixelFaces.columns, "\(state) \(eye)")
                        XCTAssertTrue(row.allSatisfy { "#o.".contains($0) }, "\(state) \(eye) \(row)")
                    }
                    XCTAssertGreaterThan(frame.milliseconds, 0)
                }
            }
        }
    }

    func testMicroSignsAreSevenByFive() {
        for state in PixelState.allCases {
            let rows = PixelFaces.micro(state)
            XCTAssertEqual(rows.count, 5)
            XCTAssertTrue(rows.allSatisfy { $0.count == 7 })
        }
    }

    func testTheClockPicksTheRightFrame() {
        let loop = PixelFaces.frames(.needs, eye: "block")
        XCTAssertEqual(loop.map(\.milliseconds), [500, 400, 500, 400, 900])
        XCTAssertEqual(PixelFaces.frame(.needs, eye: "block", elapsed: 0), loop[0])
        XCTAssertEqual(PixelFaces.frame(.needs, eye: "block", elapsed: 0.6), loop[1])
        XCTAssertEqual(PixelFaces.frame(.needs, eye: "block", elapsed: 2.1), loop[4])
        XCTAssertEqual(PixelFaces.frame(.needs, eye: "block", elapsed: 2.7 + 0.1), loop[0])
    }

    func testOwnEyesOnlyWhereTheDesignSaysSo() {
        XCTAssertEqual(PixelState.allCases.filter(\.usesOwnEyes), [.working, .thinking, .awake, .talking, .listening])
        // The shared signs are the same on every bot.
        for state in PixelState.allCases where !state.usesOwnEyes {
            XCTAssertEqual(PixelFaces.frames(state, eye: "block"), PixelFaces.frames(state, eye: "heart"), "\(state)")
        }
    }
}

/// Real `claude mcp list` and `opencode mcp list` output captured on 13 Nov 2026 (the failing servers come from a throwaway
/// config), so the parsers are checked against the exact wording.
final class ConnectorListingTests: XCTestCase {
    private func fixture(_ name: String) throws -> String {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/mcp")
        return try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
    }

    func testClaudeConnectedAndNeedsSignIn() throws {
        let statuses = ConnectorListing.parseClaude(try fixture("claude-mcp-list-real.txt"))
        XCTAssertEqual(statuses["claude.ai Gmail"], .connected)
        XCTAssertEqual(statuses["plugin:theo:theo"], .connected)
        XCTAssertEqual(statuses["claude.ai Runway (runway.team)"], .needsSignIn)
        XCTAssertNil(statuses["Checking MCP server health…"])
    }

    func testClaudeFailedServersKeepTheirReason() throws {
        let statuses = ConnectorListing.parseClaude(try fixture("claude-mcp-list-failing.txt"))
        XCTAssertEqual(statuses["broken-http"], .failed("ECONNREFUSED: Unable to connect. Is the computer able to access the url?"))
        XCTAssertEqual(statuses["broken-stdio"], .failed("CONNECTION_CLOSED: Connection closed"))
        XCTAssertTrue(statuses["missing-binary"]?.isFailed ?? false)
        XCTAssertEqual(statuses["needs-auth-http"], .needsSignIn)
        // A reason with " - " of its own still parses: the status is anchored on its mark.
        XCTAssertEqual(statuses["flaky-http"], .failed("Upstream error - server - closed the stream"))
        XCTAssertEqual(ConnectorListing.parseClaude("x: y - ⏸ Pending approval (run `claude` to approve)")["x"], .missing)
    }

    func testOpenCodeEveryState() throws {
        let statuses = ConnectorListing.parseOpenCode(try fixture("opencode-mcp-list-failing.txt"))
        XCTAssertEqual(statuses["theo"], .connected)
        XCTAssertEqual(statuses["content-studio"], .connected)
        XCTAssertEqual(statuses["broken-stdio"], .failed("MCP error -32000: Connection closed"))
        XCTAssertEqual(statuses["broken-http"], .failed("SSE error: ECONNREFUSED: Unable to connect. Is the computer able to access the url?"))
        XCTAssertTrue(statuses["missing-binary"]?.isFailed ?? false)
        XCTAssertEqual(statuses["needs-auth-http"], .needsSignIn)
        XCTAssertEqual(statuses["off-server"], .missing)
    }

    func testPlainReasons() {
        XCTAssertEqual(ConnectorListing.plainReason("ECONNREFUSED: Unable to connect.", app: "Gmail"), "Gmail didn't answer.")
        XCTAssertEqual(ConnectorListing.plainReason("ENOENT: no such file", app: "Studio"), "Studio's program isn't on this Mac any more.")
        XCTAssertEqual(ConnectorState.failed("x").label, "Can't connect")
        XCTAssertEqual(ConnectorListing.workedAgo(Date(timeIntervalSinceNow: -7200)), "worked 2 h ago")
    }
}

final class FailureTriageTests: XCTestCase {
    private let harnesses: [(id: String, label: String)] = [("claude", "Claude Code"), ("grok", "Grok"), ("codex", "Codex (ChatGPT)")]

    func testASignedOutAgentIsASignInNotAFailure() {
        XCTAssertEqual(FailureTriage.signInHarness(in: "Grok isn't signed in. Run grok login, then try again.", harnesses: harnesses), "grok")
        XCTAssertEqual(FailureTriage.signInHarness(in: "Claude Code is signed out", harnesses: harnesses), "claude")
        XCTAssertNil(FailureTriage.signInHarness(in: "Your GitHub sign-in has expired.", harnesses: harnesses))
        XCTAssertNil(FailureTriage.signInHarness(in: "Grok hit its usage limit.", harnesses: harnesses))
        XCTAssertFalse(FailureTriage.marksUnseen(botID: "b", viewing: nil, isWatching: false, isSignIn: true))
    }

    func testAFailureInTheChatBeingWatchedIsSeen() {
        XCTAssertFalse(FailureTriage.marksUnseen(botID: "b", viewing: "b", isWatching: true, isSignIn: false))
        XCTAssertTrue(FailureTriage.marksUnseen(botID: "b", viewing: "b", isWatching: false, isSignIn: false))
        XCTAssertTrue(FailureTriage.marksUnseen(botID: "b", viewing: "other", isWatching: true, isSignIn: false))
        XCTAssertTrue(FailureTriage.marksUnseen(botID: "b", viewing: nil, isWatching: true, isSignIn: false))
    }
}
