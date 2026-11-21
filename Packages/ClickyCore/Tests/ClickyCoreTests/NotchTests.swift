import AppKit
import Foundation
import SwiftUI
import Testing
@testable import ClickyCore

// MARK: - Geometry

struct NotchGeometryTests {
    /// The owner's ultrawide: no camera housing, so a virtual notch 6 % of its width (capped at 170) × 28.
    static let ultrawide = NotchScreenMetrics(screenFrame: CGRect(x: 0, y: 0, width: 3440, height: 1440))

    @Test func ultrawideGetsAVirtualNotchFlushWithTheTopCentre() {
        let layout = NotchGeometry.layout(for: Self.ultrawide)
        #expect(!layout.hasPhysicalNotch)
        #expect(layout.notchRect == CGRect(x: 1635, y: 1412, width: 170, height: 28))
        #expect(layout.notchRect.maxY == 1440)
        #expect(layout.notchRect.midX == 1720)
    }

    @Test func secondaryDisplayAtNegativeOriginStaysOnItsOwnTopEdge() {
        let layout = NotchGeometry.layout(for: NotchScreenMetrics(screenFrame: CGRect(x: -1920, y: 200, width: 1920, height: 1080)))
        #expect(layout.notchRect.midX == -960)
        #expect(layout.notchRect.maxY == 1280)
    }

    @Test func notchedDisplayHugsTheHousingFromTheAuxiliaryAreas() {
        let metrics = NotchScreenMetrics(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), safeAreaTopInset: 32,
                                         auxiliaryTopLeftArea: CGRect(x: 0, y: 950, width: 662, height: 32),
                                         auxiliaryTopRightArea: CGRect(x: 850, y: 950, width: 662, height: 32))
        let layout = NotchGeometry.layout(for: metrics)
        #expect(layout.hasPhysicalNotch)
        #expect(layout.notchRect == CGRect(x: 662, y: 950, width: 188, height: 32))
        // Wings on both sides for the logo and the status.
        let collapsed = NotchGeometry.collapsedSize(layout: layout)
        // Wide enough for a status while busy, and slim while idle.
        #expect(layout.wingWidth == NotchGeometry.physicalNotchWingWidth)
        #expect(NotchGeometry.collapsedSize(layout: layout, isIdle: true).width == 188 + 2 * NotchGeometry.idleWingWidth + 2 * NotchGeometry.topFlareRadius)
        #expect(collapsed.width == 188 + 2 * layout.wingWidth + 2 * NotchGeometry.topFlareRadius)
        #expect(collapsed.height == 32)
        let frame = NotchGeometry.panelFrame(layout: layout, size: collapsed)
        #expect(frame.midX == layout.notchRect.midX)
        #expect(frame.maxY == 982)
    }

    @Test func safeAreaWithoutAuxiliaryAreasFallsBackToVirtual() {
        let layout = NotchGeometry.layout(for: NotchScreenMetrics(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), safeAreaTopInset: 32))
        #expect(!layout.hasPhysicalNotch)
        #expect(layout.notchRect.size == NotchGeometry.virtualNotchSize(screenWidth: 1512, menuBarHeight: 0))
        #expect(layout.notchRect.width == 116)
    }

    @Test func virtualNotchFollowsTheDisplaysProportionsAndMenuBar() {
        let laptop = NotchGeometry.layout(for: NotchScreenMetrics(screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900), menuBarHeight: 24))
        #expect(laptop.notchRect.size == CGSize(width: 116, height: 24))
        let small = NotchGeometry.virtualNotchSize(screenWidth: 1024, menuBarHeight: 50)
        #expect(small == CGSize(width: 116, height: 30))
    }

    @Test func collapsedAndExpandedSizes() {
        let layout = NotchGeometry.layout(for: Self.ultrawide)
        let collapsed = NotchGeometry.collapsedSize(layout: layout)
        #expect(collapsed == CGSize(width: 170 + 2 * NotchGeometry.topFlareRadius, height: 28))

        let empty = NotchGeometry.expandedSize(layout: layout, agentRowCount: 0, hasMoreAgentsLine: false, hasCaption: false)
        #expect(empty.width == NotchGeometry.expandedBodyWidth + 2 * NotchGeometry.topFlareRadius)
        let expectedEmptyHeight = 28 + NotchGeometry.expandedTopPadding + NotchGeometry.noAgentsLineHeight + NotchGeometry.sectionSpacing
            + NotchGeometry.actionsRowHeight + NotchGeometry.expandedBottomPadding
        #expect(empty.height == expectedEmptyHeight)

        let two = NotchGeometry.expandedSize(layout: layout, agentRowCount: 2, hasMoreAgentsLine: false, hasCaption: true)
        let four = NotchGeometry.expandedSize(layout: layout, agentRowCount: 4, hasMoreAgentsLine: true, hasCaption: true)
        let ten = NotchGeometry.expandedSize(layout: layout, agentRowCount: 10, hasMoreAgentsLine: true, hasCaption: true)
        #expect(two.height > empty.height)
        #expect(four.height - two.height == 2 * (NotchGeometry.agentRowHeight + NotchGeometry.agentRowSpacing) + NotchGeometry.moreAgentsLineHeight)
        // Never more than four rows.
        #expect(ten == four)
    }

    @Test func expandedPanelGrowsDownwardFromTheNotchAndStaysCentred() {
        let layout = NotchGeometry.layout(for: Self.ultrawide)
        let collapsedFrame = NotchGeometry.panelFrame(layout: layout, size: NotchGeometry.collapsedSize(layout: layout))
        let expandedFrame = NotchGeometry.panelFrame(layout: layout, size: NotchGeometry.expandedSize(layout: layout, agentRowCount: 3, hasMoreAgentsLine: false, hasCaption: true))
        #expect(collapsedFrame.maxY == 1440 && expandedFrame.maxY == 1440)
        #expect(collapsedFrame.midX == expandedFrame.midX)
        #expect(expandedFrame.minY < collapsedFrame.minY)
        let union = NotchGeometry.unionSize(collapsedFrame.size, expandedFrame.size)
        #expect(union == expandedFrame.size)
    }

    @Test func panelFrameIsClampedToTheScreen() {
        // A notch near the left edge (made-up auxiliary areas) can't push the panel off screen.
        let layout = NotchLayout(notchRect: CGRect(x: 10, y: 950, width: 100, height: 32), hasPhysicalNotch: true, screenFrame: CGRect(x: 0, y: 0, width: 800, height: 982))
        let frame = NotchGeometry.panelFrame(layout: layout, size: CGSize(width: 472, height: 300))
        #expect(frame.minX == 0)
        #expect(frame.maxY == 982)
    }
}

// MARK: - Status and content

struct NotchStatusTests {
    static let start = Date(timeIntervalSince1970: 1_761_400_000)

    static func helper(_ id: String, kind: AgentKind = .worker, status: AgentStatus = .running, repository: String? = nil, title: String = "Battery life") -> AgentRecord {
        var record = AgentRecord(id: id, kind: kind, title: title, model: "haiku", status: status, startedAt: start)
        record.repository = repository
        return record
    }

    @Test func companionPhaseWins() {
        let agents = [Self.helper("a"), Self.helper("b")]
        #expect(NotchStatus.statusText(phase: .listening, activeHelperAgents: agents) == "listening…")
        #expect(NotchStatus.statusText(phase: .thinking, activeHelperAgents: agents) == "thinking…")
        #expect(NotchStatus.statusText(phase: .speaking, activeHelperAgents: []) == "speaking")
    }

    @Test func idleShowsTheAgents() {
        #expect(NotchStatus.statusText(phase: .idle, activeHelperAgents: []) == "")
        #expect(NotchStatus.statusText(phase: .idle, activeHelperAgents: [Self.helper("a")]) == "1 agent")
        #expect(NotchStatus.statusText(phase: .idle, activeHelperAgents: [Self.helper("a"), Self.helper("b")]) == "2 agents")
        let code = Self.helper("c", kind: .codeTask, repository: "adhyan/clicky-scratch", title: "Fix the test")
        #expect(NotchStatus.statusText(phase: .idle, activeHelperAgents: [code]) == "coding: clicky-scratch")
        #expect(NotchStatus.statusText(phase: .idle, activeHelperAgents: [code, Self.helper("a")]) == "2 agents")
        let untitledCode = Self.helper("d", kind: .codeTask, title: "a really long code task title that goes on")
        #expect(NotchStatus.statusText(phase: .idle, activeHelperAgents: [untitledCode]).count <= "coding: ".count + NotchStatus.maximumCodingNameLength)
    }

    @Test func phaseFromVoiceState() {
        #expect(NotchStatus.phase(isListening: true, isProcessing: false, isResponding: false, isCoordinatorThinking: true) == .listening)
        #expect(NotchStatus.phase(isListening: false, isProcessing: true, isResponding: false, isCoordinatorThinking: false) == .thinking)
        #expect(NotchStatus.phase(isListening: false, isProcessing: false, isResponding: true, isCoordinatorThinking: false) == .speaking)
        #expect(NotchStatus.phase(isListening: false, isProcessing: false, isResponding: false, isCoordinatorThinking: true) == .thinking)
        #expect(NotchStatus.phase(isListening: false, isProcessing: false, isResponding: false, isCoordinatorThinking: false) == .idle)
    }

    @Test func captionTextFollowsTheBubble() {
        var caption = CaptionState()
        caption.statusText = "Give me a second…"
        #expect(NotchStatus.captionText(caption) == nil)
        caption.isVisible = true
        #expect(NotchStatus.captionText(caption) == "Give me a second…")
    }

    @Test func contentFromTheStore() {
        var store = AgentStore()
        store.upsert(AgentRecord(id: "brain", kind: .brain, title: "compare these laptops", model: "sonnet", status: .running, phase: BrainPhase.speaking.rawValue, startedAt: Self.start))
        store.upsert(Self.helper("w1"))
        store.upsert(Self.helper("w2", status: .queued))
        var code = Self.helper("code", kind: .codeTask, repository: "octo/app", title: "Fix CI")
        code.usage = AgentUsage(model: "claude-sonnet-4-5-20250929", inputTokens: 10, outputTokens: 5, costUSD: 0.031)
        code.currentStep = "running the tests"
        store.upsert(code)
        store.upsert(Self.helper("w3"))
        store.upsert(Self.helper("old", status: .done))

        let content = NotchStatus.content(phase: .speaking, store: store, captionText: "the middle one", isCodeModeOn: true, selectedAgentID: "code",
                                          now: Self.start.addingTimeInterval(42), canCancel: { $0.kind != .worker }, canOpenReview: { $0.kind == .codeTask })
        #expect(content.statusText == "speaking")
        // Brain first, at most four rows, the rest counted.
        #expect(content.agentRows.count == 4)
        #expect(content.agentRows.first?.id == "brain")
        #expect(content.agentRows.first?.statusText == "Speaking")
        #expect(content.hiddenAgentCount == 1)
        // Only running helpers orbit (the queued one and the brain don't).
        #expect(Set(content.orbitingAgentIDs) == ["w1", "code", "w3"])
        #expect(content.cancelTargetID == "code")
        #expect(content.reviewTargetID == "code")
        let codeRow = content.agentRows.first { $0.id == "code" }
        #expect(codeRow?.detailText == "running the tests · sonnet-4-5 · 0:42 · $0.03")
        #expect(content.isLogoAnimating)

        // Selecting a row that can't be cancelled falls back to the first that can.
        let workerSelected = NotchStatus.content(phase: .idle, store: store, captionText: nil, isCodeModeOn: false, selectedAgentID: "w1", now: Self.start,
                                                 canCancel: { $0.kind != .worker }, canOpenReview: { _ in false })
        #expect(workerSelected.cancelTargetID == "brain")
        #expect(workerSelected.reviewTargetID == nil)
    }

    @Test func nothingRunningListsRecentAgents() {
        var store = AgentStore()
        store.upsert(Self.helper("old", status: .done))
        let content = NotchStatus.content(phase: .idle, store: store, captionText: nil, isCodeModeOn: false, selectedAgentID: nil, now: Self.start,
                                          canCancel: { _ in false }, canOpenReview: { _ in false })
        #expect(content.statusText == "")
        #expect(content.agentRowsAreRecent)
        #expect(content.agentRows.map(\.id) == ["old"])
        #expect(content.cancelTargetID == nil)
        #expect(!content.isLogoAnimating)
    }
}

// MARK: - Full screen

struct NotchFullScreenPolicyTests {
    static let display = CGRect(x: 0, y: 0, width: 3440, height: 1440)
    static let secondDisplay = CGRect(x: 3440, y: 0, width: 1920, height: 1080)

    static func window(_ id: CGWindowID, pid: pid_t, layer: Int = 0, bounds: CGRect) -> WindowInfo {
        WindowInfo(windowID: id, processIdentifier: pid, layer: layer, boundsCG: bounds, alpha: 1, ownerName: "App\(pid)", title: nil)
    }

    @Test func fullScreenVideoCoversTheDisplay() {
        let windows = [Self.window(1, pid: 10, bounds: Self.display)]
        #expect(NotchFullScreenPolicy.isFullScreenAppCovering(displayBoundsCG: Self.display, windows: windows, frontmostProcessIdentifier: 10, onlyOwners: nil))
        // Also when the user is working in another app on the other display.
        #expect(NotchFullScreenPolicy.isFullScreenAppCovering(displayBoundsCG: Self.display, windows: windows, frontmostProcessIdentifier: 99, onlyOwners: nil))
    }

    @Test func zoomedWindowBelowTheMenuBarIsNotFullScreen() {
        let zoomed = Self.window(1, pid: 10, bounds: CGRect(x: 0, y: 25, width: 3440, height: 1415))
        #expect(!NotchFullScreenPolicy.isFullScreenAppCovering(displayBoundsCG: Self.display, windows: [zoomed], frontmostProcessIdentifier: 10, onlyOwners: nil))
    }

    @Test func menuBarAndOverlayLayersDontCount() {
        let menuBar = Self.window(1, pid: 5, layer: 24, bounds: CGRect(x: 0, y: 0, width: 3440, height: 25))
        let tint = Self.window(2, pid: 6, layer: 30, bounds: Self.display)
        let normal = Self.window(3, pid: 10, bounds: CGRect(x: 100, y: 100, width: 1200, height: 800))
        #expect(!NotchFullScreenPolicy.isFullScreenAppCovering(displayBoundsCG: Self.display, windows: [menuBar, tint, normal], frontmostProcessIdentifier: 10, onlyOwners: nil))
    }

    @Test func pictureInPictureOverTheFrontmostAppsFullScreenWindow() {
        let pictureInPicture = Self.window(1, pid: 10, bounds: CGRect(x: 3000, y: 1100, width: 400, height: 225))
        let fullScreen = Self.window(2, pid: 10, bounds: Self.display)
        #expect(NotchFullScreenPolicy.isFullScreenAppCovering(displayBoundsCG: Self.display, windows: [pictureInPicture, fullScreen], frontmostProcessIdentifier: 10, onlyOwners: nil))
        // A full-display window of some other app behind a normal window isn't full screen.
        let other = Self.window(3, pid: 11, bounds: Self.display)
        #expect(!NotchFullScreenPolicy.isFullScreenAppCovering(displayBoundsCG: Self.display, windows: [pictureInPicture, other], frontmostProcessIdentifier: 10, onlyOwners: nil))
    }

    /// Only browsers and video players hide the pill: the owner keeps the Claude app full screen on the
    /// main display and watches Netflix (Safari) full screen on another.
    @Test func onlyMediaAppsInFullScreenHideThePill() {
        let claude = WindowInfo(windowID: 1, processIdentifier: 10, layer: 0, boundsCG: Self.display, alpha: 1, ownerName: "Claude", title: nil)
        #expect(!NotchFullScreenPolicy.isFullScreenAppCovering(displayBoundsCG: Self.display, windows: [claude], frontmostProcessIdentifier: 10))
        let safari = WindowInfo(windowID: 2, processIdentifier: 11, layer: 0, boundsCG: Self.display, alpha: 1, ownerName: "Safari", title: nil)
        #expect(NotchFullScreenPolicy.isFullScreenAppCovering(displayBoundsCG: Self.display, windows: [safari], frontmostProcessIdentifier: 10))
    }

    @Test func fullScreenOnTheOtherDisplayDoesntHideThisOne() {
        let windows = [Self.window(1, pid: 10, bounds: Self.secondDisplay), Self.window(2, pid: 11, bounds: CGRect(x: 10, y: 40, width: 800, height: 600))]
        #expect(!NotchFullScreenPolicy.isFullScreenAppCovering(displayBoundsCG: Self.display, windows: windows, frontmostProcessIdentifier: 10, onlyOwners: nil))
        #expect(NotchFullScreenPolicy.isFullScreenAppCovering(displayBoundsCG: Self.secondDisplay, windows: windows, frontmostProcessIdentifier: 10, onlyOwners: nil))
    }

    @Test func showDecision() {
        #expect(NotchFullScreenPolicy.shouldShowNotch(isEnabled: true, hidesOverFullScreen: true, isFullScreenAppCovering: false))
        #expect(!NotchFullScreenPolicy.shouldShowNotch(isEnabled: true, hidesOverFullScreen: true, isFullScreenAppCovering: true))
        #expect(NotchFullScreenPolicy.shouldShowNotch(isEnabled: true, hidesOverFullScreen: false, isFullScreenAppCovering: true))
        #expect(!NotchFullScreenPolicy.shouldShowNotch(isEnabled: false, hidesOverFullScreen: false, isFullScreenAppCovering: false))
    }
}

// MARK: - Expand / collapse

struct NotchPresentationStateMachineTests {
    /// A clock the test moves by hand.
    final class ManualClock {
        var now: TimeInterval = 1_000
    }

    @Test func hoverExpandsAndLeavingCollapsesAfterTheGrace() {
        let clock = ManualClock()
        var machine = NotchPresentationStateMachine(clock: { clock.now })
        #expect(machine.presentation == .collapsed)
        machine.pointerEntered()
        #expect(machine.isExpanded)
        #expect(machine.collapseDeadline == nil)

        machine.pointerExited()
        #expect(machine.collapseDeadline == 1_000.4)
        clock.now += 0.39
        let didCollapse1 = machine.update()

        #expect(!didCollapse1)
        #expect(machine.isExpanded)
        clock.now += 0.01
        let didCollapse2 = machine.update()

        #expect(didCollapse2)
        #expect(machine.presentation == .collapsed)
        #expect(machine.collapseDeadline == nil)
        let didCollapse3 = machine.update()

        #expect(!didCollapse3)
    }

    @Test func comingBackWithinTheGraceKeepsItOpen() {
        let clock = ManualClock()
        var machine = NotchPresentationStateMachine(clock: { clock.now })
        machine.pointerEntered()
        machine.pointerExited()
        clock.now += 0.3
        machine.pointerEntered()
        clock.now += 1
        let didCollapse4 = machine.update()

        #expect(!didCollapse4)
        #expect(machine.isExpanded)
        // A second exit starts a fresh grace from that moment.
        machine.pointerExited()
        clock.now += 0.2
        machine.pointerExited()
        #expect(machine.collapseDeadline == 1_001.3 + 0.4)
        clock.now += 0.2
        let didCollapse5 = machine.update()

        #expect(didCollapse5)
    }

    @Test func clickExpandsAndStillCollapsesWhenThePointerIsGone() {
        let clock = ManualClock()
        var machine = NotchPresentationStateMachine(clock: { clock.now })
        machine.clicked()
        #expect(machine.isExpanded)
        clock.now += 0.5
        let didCollapse6 = machine.update()

        #expect(didCollapse6)
        #expect(!machine.isExpanded)
    }

    @Test func resetCollapsesAtOnce() {
        let clock = ManualClock()
        var machine = NotchPresentationStateMachine(clock: { clock.now })
        machine.pointerEntered()
        machine.reset()
        #expect(machine.presentation == .collapsed)
        #expect(!machine.isPointerInside)
        #expect(machine.collapseDeadline == nil)
    }
}

// MARK: - Panel

@MainActor
struct NotchPanelTests {
    /// The panel is configured but never ordered on screen.
    @Test func panelNeverBecomesKeyOrMain() {
        let panel = NotchPanel.make(contentRect: CGRect(x: 0, y: 0, width: 212, height: 32), showsOverFullScreenApps: false)
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.styleMask.contains(.borderless))
        #expect(!panel.isVisible)
        #expect(panel.level.rawValue > NSWindow.Level.mainMenu.rawValue)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.stationary))
        #expect(panel.collectionBehavior.contains(.ignoresCycle))
        #expect(!panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(!panel.hidesOnDeactivate)
        #expect(NotchPanel.collectionBehavior(showsOverFullScreenApps: true).contains(.fullScreenAuxiliary))
    }
}

// MARK: - Bot board

struct NotchBotBoardTests {
    static func line(_ botID: String, _ lane: NotchBotLane, button: String? = nil) -> NotchBotLine {
        NotchBotLine(botID: botID, name: botID.capitalized, state: "x", lane: lane, line: "line", button: button)
    }

    @Test func pixelStatesMapToLanes() {
        #expect(NotchBotLane.lane(forPixelState: "needs") == .needsYou)
        #expect(NotchBotLane.lane(forPixelState: "failed") == .failed)
        #expect(NotchBotLane.lane(forPixelState: "working") == .working)
        #expect(NotchBotLane.lane(forPixelState: "thinking") == .working)
        #expect(NotchBotLane.lane(forPixelState: "talking") == .working)
        #expect(NotchBotLane.lane(forPixelState: "done") == .done)
        for quiet in ["awake", "idle", "listening"] {
            #expect(NotchBotLane.lane(forPixelState: quiet) == .ready)
        }
        // Only a bot that's off stays off the notch.
        #expect(NotchBotLane.lane(forPixelState: "off") == nil)
        // Green working, yellow needs you, red failed: the faces' own colours.
        #expect(NotchBotLane.working.hex == PixelState.working.hex)
        #expect(NotchBotLane.needsYou.hex == PixelState.needs.hex)
        #expect(NotchBotLane.failed.hex == PixelState.failed.hex)
    }

    @Test func mostUrgentFirstAndOrderKeptInsideALane() {
        let board = NotchBots.board(from: [Self.line("a", .working), Self.line("b", .done), Self.line("c", .failed),
                                           Self.line("d", .needsYou), Self.line("e", .working), Self.line("f", .needsYou)])
        #expect(board.lines.map(\.botID) == ["d", "f", "c", "a"])
        #expect(board.tally == NotchBotTally(needsYou: 2, failed: 1, working: 2))
        // "e" is still working but didn't fit; the done bot isn't counted.
        #expect(board.hiddenCount == 1)
    }

    @Test func tallyChipsOnlyForLanesWithBots() {
        #expect(NotchBotTally().chips.isEmpty)
        #expect(NotchBotTally().isEmpty)
        let tally = NotchBotTally(needsYou: 0, failed: 2, working: 12)
        #expect(tally.chips.map(\.lane) == [.failed, .working])
        #expect(NotchBotTally.countText(12) == "9+")
        #expect(NotchBotTally.countText(3) == "3")
        #expect(NotchBotTally(needsYou: 1, failed: 0, working: 3).spokenText == "1 needs you, 3 working")
    }

    @Test func doneBotsAloneMakeNoChips() {
        let board = NotchBots.board(from: [Self.line("a", .done)])
        #expect(board.lines.count == 1)
        #expect(board.tally.isEmpty)
        #expect(NotchBots.collapsedStatus(board: board) == "")
    }

    @Test func readyBotsAreOnTheNotchWhenAllAreQuiet() {
        let board = NotchBots.board(from: [Self.line("builder", .ready), Self.line("planner", .ready), Self.line("researcher", .ready)])
        #expect(board.lines.map(\.botID) == ["builder", "planner", "researcher"])
        #expect(board.tally == NotchBotTally(ready: 3))
        #expect(!board.tally.isEmpty)
        #expect(board.tally.isQuiet)
        #expect(board.tally.chips.map(\.lane) == [.ready])
        #expect(board.tally.spokenText == "3 ready")
        #expect(NotchBots.collapsedStatus(board: board) == "3 bots ready")
        #expect(NotchBots.collapsedStatus(board: NotchBots.board(from: [Self.line("builder", .ready)])) == "Builder is ready")
    }

    @Test func readyBotsComeLastAndAreNotCountedAsMore() {
        let board = NotchBots.board(from: [Self.line("a", .ready), Self.line("b", .ready), Self.line("c", .working), Self.line("d", .done),
                                           Self.line("e", .ready), Self.line("f", .needsYou)])
        #expect(board.lines.map(\.botID) == ["f", "c", "d", "a"])
        #expect(board.hiddenCount == 0)
        #expect(board.tally.chips.map(\.lane) == [.needsYou, .working, .ready])
        #expect(board.tally.ready == 3)
        // Something going on wins over the ready count.
        #expect(NotchBots.collapsedStatus(board: board) == "F needs you")
        #expect(NotchBots.collapsedStatus(board: NotchBots.board(from: [Self.line("a", .ready), Self.line("c", .working)])) == "C is working")
    }

    @Test func collapsedWordsNameTheMostUrgentBot() {
        #expect(NotchBots.collapsedStatus(board: NotchBots.board(from: [Self.line("builder", .working), Self.line("researcher", .needsYou)])) == "Researcher needs you")
        #expect(NotchBots.collapsedStatus(board: NotchBots.board(from: [Self.line("builder", .failed)])) == "Builder failed")
        #expect(NotchBots.collapsedStatus(board: NotchBots.board(from: [Self.line("builder", .working)])) == "Builder is working")
        #expect(NotchBots.collapsedStatus(board: NotchBots.board(from: [Self.line("a", .working), Self.line("b", .working)])) == "2 bots working")
    }

    @Test func companionWordsWinOverTheBots() {
        var listening = NotchContent(phase: .listening, statusText: "listening…")
        listening.apply(botBoard: NotchBots.board(from: [Self.line("researcher", .needsYou)]))
        #expect(listening.statusText == "listening…")
        // The chips stay: the bots are always on the pill.
        #expect(listening.botTally.needsYou == 1)

        var idle = NotchContent()
        idle.apply(botBoard: NotchBots.board(from: [Self.line("researcher", .needsYou)]))
        #expect(idle.statusText == "Researcher needs you")
    }

    @Test func chipsWidenTheVirtualNotchOnTheRight() {
        let layout = NotchGeometry.layout(for: NotchGeometryTests.ultrawide)
        let plain = NotchGeometry.collapsedBodySize(layout: layout)
        let three = NotchGeometry.collapsedBodySize(layout: layout, botChipCount: 3)
        #expect(three.width - plain.width == NotchGeometry.botChipsWidth(chipCount: 3) + NotchGeometry.botChipsLeadingGap)
        #expect(NotchGeometry.botChipsWidth(chipCount: 0) == 0)
        #expect(NotchGeometry.botChipsWidth(chipCount: 9) == NotchGeometry.botChipsWidth(chipCount: 4))
    }

    @Test func chipsWidenBothWingsOfARealNotchSoItStaysCentred() {
        let layout = NotchLayout.sample(hasPhysicalNotch: true)
        let wing = NotchGeometry.collapsedWingWidth(layout: layout, isIdle: false, botChipCount: 3)
        #expect(wing == NotchGeometry.logoFrameWidth + NotchGeometry.botChipsLeadingGap + NotchGeometry.botChipsWidth(chipCount: 3) + NotchGeometry.botChipsTrailingPadding)
        #expect(wing > layout.wingWidth)
        #expect(wing <= layout.maximumWingWidth)
        let size = NotchGeometry.collapsedSize(layout: layout, isIdle: false, botChipCount: 3)
        #expect(size.width == layout.notchRect.width + 2 * wing + 2 * NotchGeometry.topFlareRadius)
        let frame = NotchGeometry.panelFrame(layout: layout, size: size)
        #expect(frame.midX == layout.notchRect.midX)
        // Idle with nothing going on stays slim.
        #expect(NotchGeometry.collapsedWingWidth(layout: layout, isIdle: true, botChipCount: 0) == NotchGeometry.idleWingWidth)
    }

    @Test func aNarrowMenuBarCapsTheWings() {
        let metrics = NotchScreenMetrics(screenFrame: CGRect(x: 0, y: 0, width: 600, height: 400), safeAreaTopInset: 32,
                                         auxiliaryTopLeftArea: CGRect(x: 0, y: 368, width: 200, height: 32),
                                         auxiliaryTopRightArea: CGRect(x: 400, y: 368, width: 200, height: 32))
        let layout = NotchGeometry.layout(for: metrics)
        #expect(layout.maximumWingWidth == 100)
        #expect(NotchGeometry.collapsedWingWidth(layout: layout, isIdle: false, botChipCount: 3) == 100)
    }

    @Test func expandedPanelMakesRoomForTheBots() {
        let layout = NotchGeometry.layout(for: NotchGeometryTests.ultrawide)
        let empty = NotchGeometry.expandedSize(layout: layout, agentRowCount: 0, hasMoreAgentsLine: false, hasCaption: false)
        let twoBots = NotchGeometry.expandedSize(layout: layout, agentRowCount: 0, hasMoreAgentsLine: false, hasCaption: false, botRowCount: 2)
        // Two bot rows replace the "No agents running" line.
        #expect(twoBots.height - empty.height == 2 * NotchGeometry.botRowHeight + NotchGeometry.botRowSpacing - NotchGeometry.noAgentsLineHeight)
        let withAgents = NotchGeometry.expandedSize(layout: layout, agentRowCount: 1, hasMoreAgentsLine: false, hasCaption: false, botRowCount: 2)
        #expect(withAgents.height - twoBots.height == NotchGeometry.agentRowHeight + NotchGeometry.sectionSpacing)
        let many = NotchGeometry.expandedSize(layout: layout, agentRowCount: 0, hasMoreAgentsLine: false, hasCaption: false, botRowCount: 9, hasMoreBotsLine: true)
        let four = NotchGeometry.expandedSize(layout: layout, agentRowCount: 0, hasMoreAgentsLine: false, hasCaption: false, botRowCount: 4, hasMoreBotsLine: true)
        #expect(many == four)
    }

    @MainActor @Test func pillSizeFollowsTheBoard() {
        let layout = NotchLayout.sample(hasPhysicalNotch: false)
        var content = NotchContent()
        let quiet = NotchView.pillSize(content: content, layout: layout, isExpanded: false)
        content.apply(botBoard: NotchBots.board(from: [Self.line("a", .working), Self.line("b", .failed)]))
        let busy = NotchView.pillSize(content: content, layout: layout, isExpanded: false)
        #expect(busy.width == quiet.width + NotchGeometry.botChipsWidth(chipCount: 2) + NotchGeometry.botChipsLeadingGap)
        let expanded = NotchView.pillSize(content: content, layout: layout, isExpanded: true)
        #expect(expanded == NotchGeometry.expandedSize(layout: layout, agentRowCount: 0, hasMoreAgentsLine: false, hasCaption: false, botRowCount: 2))
    }
}

// MARK: - Renders

/// Offscreen renders of the notch pill (ImageRenderer: no window, nothing on
/// screen) with sample data, collapsed and expanded, light and dark, into
/// ~/Library/Logs/Clicky/renders/notch/. Each sits on a strip the colour of
/// the menu bar in that appearance; the pill itself is black in both.
@MainActor
struct NotchRenderTests {
    static let outputDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Clicky/renders/notch", isDirectory: true)
    static let now = Date(timeIntervalSince1970: 1_761_400_300)

    static func sampleStore() -> AgentStore {
        let start = Date(timeIntervalSince1970: 1_761_400_000)
        var store = AgentStore()
        var brain = AgentRecord(id: "brain", kind: .brain, title: "compare these three laptops for me", model: "sonnet", status: .running,
                                phase: BrainPhase.thinking.rawValue, startedAt: start.addingTimeInterval(282))
        brain.usage = AgentUsage(model: "claude-sonnet-4-5", inputTokens: 3_210, outputTokens: 412, costUSD: 0.0312)
        store.upsert(brain)
        store.upsert(AgentRecord(id: "w1", kind: .worker, title: "Battery life", model: "haiku", status: .running, startedAt: start.addingTimeInterval(285), parentID: "brain"))
        var code = AgentRecord(id: "code", kind: .codeTask, title: "Fix the failing test in clicky-scratch", model: "sonnet", status: .running, startedAt: start.addingTimeInterval(40))
        code.repository = "adhyan/clicky-scratch"
        code.currentStep = "running the tests"
        code.usage = AgentUsage(model: "claude-sonnet-4-5", inputTokens: 18_000, outputTokens: 2_100, costUSD: 0.21)
        store.upsert(code)
        return store
    }

    static func sampleContent(phase: NotchCompanionPhase, captionText: String?) -> NotchContent {
        NotchStatus.content(phase: phase, store: sampleStore(), captionText: captionText, isCodeModeOn: true, selectedAgentID: "code", now: now,
                            canCancel: { $0.status.isActive }, canOpenReview: { $0.kind == .codeTask })
    }

    static func render(content: NotchContent, layout: NotchLayout, isExpanded: Bool, canvasWidth: CGFloat,
                       appearanceName: NSAppearance.Name, colorScheme: ColorScheme) throws -> NSImage {
        let pillSize = NotchView.pillSize(content: content, layout: layout, isExpanded: isExpanded)
        let menuBarColor = colorScheme == .dark ? Color(white: 0.16) : Color(white: 0.93)
        let desktopColor = colorScheme == .dark ? Color(red: 0.12, green: 0.13, blue: 0.17) : Color(red: 0.78, green: 0.84, blue: 0.93)
        let canvasHeight = pillSize.height + 24
        let view = ZStack(alignment: .top) {
            desktopColor
            menuBarColor.frame(height: 24)
            NotchView(content: content, layout: layout, isExpanded: isExpanded, actions: .inert, fixedAnimationDate: now)
                .frame(width: pillSize.width, height: pillSize.height)
        }
        .frame(width: canvasWidth, height: canvasHeight)
        .environment(\.colorScheme, colorScheme)
        let appearance = try #require(NSAppearance(named: appearanceName))
        var image: NSImage?
        appearance.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            image = renderer.nsImage
        }
        return try #require(image)
    }

    static func color(in image: NSImage, atPoint point: CGPoint) -> NSColor? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        let scale = CGFloat(bitmap.pixelsWide) / image.size.width
        return bitmap.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.usingColorSpace(.sRGB)
    }

    static func luminance(_ color: NSColor?) -> Double {
        guard let color else { return -1 }
        return 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
    }

    static func writePNG(_ image: NSImage, named fileName: String) throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: outputDirectory.appendingPathComponent(fileName))
    }

    /// A board as the promo shows it: one bot needs you, one failed, two working.
    static func sampleBotBoard() -> NotchBots.Board {
        NotchBots.board(from: [
            NotchBotLine(botID: "ledger", name: "Ledger", state: "working", lane: .working, line: "Reading 6 sources for the weekly summary", sinceText: "4:12"),
            NotchBotLine(botID: "builder", name: "Builder", state: "failed", lane: .failed, line: "GitHub sign-in expired", button: "Fix"),
            NotchBotLine(botID: "researcher", name: "Researcher", state: "needs", lane: .needsYou, line: "Sign in to Notion", button: "Sign in"),
            NotchBotLine(botID: "scout", name: "Scout", state: "working", lane: .working, line: "Drafting replies to 3 emails", sinceText: "1:05")
        ])
    }

    /// The bot board on the pill: collapsed (chips beside the logo, the most urgent bot named), expanded, and with
    /// the companion listening. Written as notch-bots-*.png for the promo and the PR.
    @Test func rendersTheBotBoard() throws {
        let virtualLayout = NotchLayout.sample(hasPhysicalNotch: false)
        let physicalLayout = NotchLayout.sample(hasPhysicalNotch: true)
        var board = NotchContent()
        board.apply(botBoard: Self.sampleBotBoard())
        #expect(board.statusText == "Researcher needs you")
        var working = NotchContent()
        working.apply(botBoard: NotchBots.board(from: Self.sampleBotBoard().lines.filter { $0.lane == .working }))
        var listening = NotchContent(phase: .listening, statusText: "listening…", captionText: "\u{201C}Hey Vello, what's Builder stuck on?\u{201D}")
        listening.apply(botBoard: Self.sampleBotBoard())

        let renders: [(name: String, content: NotchContent, layout: NotchLayout, isExpanded: Bool, canvasWidth: CGFloat)] = [
            ("bots-collapsed", board, virtualLayout, false, 360),
            ("bots-collapsed-working", working, virtualLayout, false, 360),
            ("bots-collapsed-physical", board, physicalLayout, false, 520),
            ("bots-expanded", board, virtualLayout, true, 560),
            ("bots-expanded-physical", board, physicalLayout, true, 560),
            ("bots-expanded-listening", listening, virtualLayout, true, 560)
        ]
        for render in renders {
            for (schemeName, appearanceName, colorScheme) in [("light", NSAppearance.Name.aqua, ColorScheme.light), ("dark", .darkAqua, .dark)] {
                let image = try Self.render(content: render.content, layout: render.layout, isExpanded: render.isExpanded, canvasWidth: render.canvasWidth,
                                            appearanceName: appearanceName, colorScheme: colorScheme)
                try Self.writePNG(image, named: "notch-\(render.name)-\(schemeName).png")
                let pillSize = NotchView.pillSize(content: render.content, layout: render.layout, isExpanded: render.isExpanded)
                #expect(abs(image.size.height - (pillSize.height + 24)) < 1, "\(render.name) height")
            }
        }
    }

    @Test func rendersCollapsedAndExpandedInLightAndDark() throws {
        let virtualLayout = NotchLayout.sample(hasPhysicalNotch: false)
        let physicalLayout = NotchLayout.sample(hasPhysicalNotch: true)
        let thinking = Self.sampleContent(phase: .thinking, captionText: nil)
        let speaking = Self.sampleContent(phase: .speaking, captionText: "The middle one wins on battery by about two hours, and it's the lightest of the three.")
        var idleCoding = NotchStatus.content(phase: .idle, store: { var store = Self.sampleStore(); store.remove("brain"); store.remove("w1"); return store }(),
                                             captionText: nil, isCodeModeOn: true, selectedAgentID: nil, now: Self.now,
                                             canCancel: { $0.status.isActive }, canOpenReview: { _ in false })
        idleCoding.selectedAgentID = nil
        #expect(idleCoding.statusText == "coding: clicky-scratch")

        let renders: [(name: String, content: NotchContent, layout: NotchLayout, isExpanded: Bool, canvasWidth: CGFloat)] = [
            ("collapsed", thinking, virtualLayout, false, 320),
            ("collapsed-coding", idleCoding, virtualLayout, false, 320),
            ("collapsed-physical", thinking, physicalLayout, false, 460),
            ("expanded", speaking, virtualLayout, true, 560),
            ("expanded-physical", thinking, physicalLayout, true, 560)
        ]
        for render in renders {
            var pillLuminanceByScheme: [String: Double] = [:]
            var stripLuminanceByScheme: [String: Double] = [:]
            for (schemeName, appearanceName, colorScheme) in [("light", NSAppearance.Name.aqua, ColorScheme.light), ("dark", .darkAqua, .dark)] {
                let image = try Self.render(content: render.content, layout: render.layout, isExpanded: render.isExpanded, canvasWidth: render.canvasWidth,
                                            appearanceName: appearanceName, colorScheme: colorScheme)
                try Self.writePNG(image, named: "notch-\(render.name)-\(schemeName).png")
                // Inside the pill, below the header and clear of the content: black.
                let pillSize = NotchView.pillSize(content: render.content, layout: render.layout, isExpanded: render.isExpanded)
                let pillProbe = CGPoint(x: render.canvasWidth / 2 + pillSize.width / 2 - 30, y: pillSize.height - 6)
                pillLuminanceByScheme[schemeName] = Self.luminance(Self.color(in: image, atPoint: pillProbe))
                stripLuminanceByScheme[schemeName] = Self.luminance(Self.color(in: image, atPoint: CGPoint(x: 4, y: 4)))
            }
            for schemeName in ["light", "dark"] {
                let pillLuminance = pillLuminanceByScheme[schemeName] ?? -1
                #expect(pillLuminance >= 0 && pillLuminance < 0.08, "\(render.name)-\(schemeName) pill luminance \(pillLuminance)")
            }
            #expect((stripLuminanceByScheme["light"] ?? 0) > 0.8)
            #expect((stripLuminanceByScheme["dark"] ?? 1) < 0.25)
        }
    }
}
