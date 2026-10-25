//
//  MarkController.swift
//  leanring-buddy
//
//  Owns the live marks: lays them out (MarkSceneBuilder) across every
//  display, publishes the drawings for the overlays, keeps at most
//  v2.marks.max (the oldest go first), runs the OCR re-check for marks that
//  came from OCR or raw coordinates, and applies MarkTracker's moves, hides
//  and removals. Records what was drawn in turn.json and tracking events in
//  <turn>/marks.jsonl.
//
//  Each answer hands it the screen's text bounds (AX text / cell / row
//  frames and OCR lines from the grounded turn's registry) so the builder
//  can underline dense rows and keep labels off text. When tracked marks
//  scroll, the bounds inside their window are shifted by the same amount.
//
//  Labels follow v2.marks.labelStyle: `nearCursor` (default) puts numbered
//  chips on the marks and publishes their words as the caption bubble's
//  legend (onLegendChanged); `column` keeps the clear-space label column.
//

import AppKit
import ClickyCore

@MainActor
final class MarkController {
    private(set) var marks: [LiveScreenMark] = []
    private(set) var drawings: [MarkDrawing] = []
    /// Called whenever the drawings change (CompanionManager publishes them).
    var onDrawingsChanged: (([MarkDrawing]) -> Void)?
    /// nearCursor: the bubble's "1  …" lines for the marks on screen.
    private(set) var legend: [MarkLegendEntry] = []
    /// Called when the legend changes (CompanionManager puts it in the bubble).
    var onLegendChanged: (([MarkLegendEntry]) -> Void)?
    /// Marks resolved for this answer so far (fired or not): with two or
    /// more on the way the first one gets its chip right away.
    private var expectedMarkCount = 0
    /// Where the companion is parked while pointing: labels avoid it.
    var companionRect: CGRect? {
        didSet { if companionRect != oldValue { rebuild() } }
    }

    /// This answer's text bounds (CG), as captured; see currentTextObstacles().
    var textObstaclesCG: [CGRect] = [] {
        didSet {
            leafTextObstaclesCG = MarkDensity.leafTextBounds(textObstaclesCG)
            if !marks.isEmpty { rebuild() }
        }
    }
    private var leafTextObstaclesCG: [CGRect] = []

    private let tracker = MarkTracker()
    /// Kept strongly: tracking keeps logging to marks.jsonl after the turn's
    /// own record is finished (the debug `marks` turn ends immediately).
    private var turnRecord: TurnRecord?
    private var screenObserver: NSObjectProtocol?

    init() {
        tracker.onUpdate = { [weak self] markID, rectCG, isShown in
            self?.applyTrackedUpdate(markID: markID, rectCG: rectCG, isShown: isShown)
        }
        tracker.onRemove = { [weak self] markID, _ in
            self?.fadeAndRemove(markID)
        }
        tracker.onLog = { [weak self] event in
            self?.turnRecord?.appendMarkEvent(event)
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // AX marks are re-laid out on the new displays; OCR/raw ones are dropped.
                self?.tracker.screenParametersChanged()
                self?.rebuild()
            }
        }
    }

    // MARK: Showing

    /// Replaces the marks with this answer's (keeping the newest
    /// v2.marks.max) and starts tracking them.
    func show(_ newMarks: [LiveScreenMark], turnRecord: TurnRecord?) {
        tracker.stopAll()
        self.turnRecord = turnRecord
        marks = Array(newMarks.suffix(ClickySettings.maximumMarks))
        for markIndex in marks.indices where marks[markIndex].originalRectCG == nil { marks[markIndex].originalRectCG = marks[markIndex].rectCG }
        rebuild()
        tracker.track(marks)
    }

    /// A new answer: marks from now on are recorded in this turn.
    func startAnswer(turnRecord: TurnRecord?) {
        self.turnRecord = turnRecord
        expectedMarkCount = 0
    }

    /// A mark tag of this answer resolved (it fires when its words are spoken).
    func noteMarkPrepared() {
        expectedMarkCount += 1
        if !marks.isEmpty && expectedMarkCount >= 2 { rebuild() }
    }

    /// One mark, drawn as its words are spoken (the oldest goes past the max).
    func add(_ mark: LiveScreenMark) {
        var mark = mark
        if mark.originalRectCG == nil { mark.originalRectCG = mark.rectCG }
        marks.append(mark)
        let maximumMarks = ClickySettings.maximumMarks
        if marks.count > maximumMarks {
            for droppedMark in marks.prefix(marks.count - maximumMarks) { tracker.stop(droppedMark.id) }
            marks.removeFirst(marks.count - maximumMarks)
        }
        rebuild()
        tracker.track([mark])
    }

    func clear() {
        tracker.stopAll()
        marks = []
        expectedMarkCount = 0
        companionRect = nil
        rebuild()
    }

    func rebuild() {
        let displays = ScreenTopology.current().map(MarkSceneDisplay.init)
        let labelStyle = ClickySettings.markLabelStyle
        let inputs = marks.map(\.sceneInput)
        drawings = MarkSceneBuilder.build(inputs: inputs, displays: displays, companionRect: companionRect,
                                          textObstacles: currentTextObstacles(), labelStyle: labelStyle, expectedMarkCount: expectedMarkCount)
        onDrawingsChanged?(drawings)
        let newLegend = MarkChips.legend(for: inputs, labelStyle: labelStyle, expectedMarkCount: expectedMarkCount)
        if newLegend != legend {
            legend = newLegend
            onLegendChanged?(newLegend)
        }
        recordDrawn()
    }

    /// The text bounds where they are now: those inside a tracked mark's
    /// window move by however far that window's first moved mark has moved
    /// (a scroll or window drag carries its text along).
    private func currentTextObstacles() -> [CGRect] {
        var shiftsByWindow: [(frame: CGRect, dx: CGFloat, dy: CGFloat)] = []
        var seenWindowIDs: Set<CGWindowID> = []
        for mark in marks {
            guard let windowID = mark.windowID, let windowFrame = mark.windowFrameCG, let originalRect = mark.originalRectCG,
                  !seenWindowIDs.contains(windowID) else { continue }
            seenWindowIDs.insert(windowID)
            let dx = mark.rectCG.minX - originalRect.minX
            let dy = mark.rectCG.minY - originalRect.minY
            if dx != 0 || dy != 0 { shiftsByWindow.append((windowFrame, dx, dy)) }
        }
        guard !shiftsByWindow.isEmpty else { return leafTextObstaclesCG }
        return leafTextObstaclesCG.map { bound in
            guard let shift = shiftsByWindow.first(where: { $0.frame.contains(bound.center) }) else { return bound }
            return bound.offsetBy(dx: shift.dx, dy: shift.dy)
        }
    }

    private func recordDrawn() {
        guard let turnRecord else { return }
        for drawing in drawings {
            guard let mark = marks.first(where: { $0.id == drawing.id }), let tagIndex = mark.tagIndex else { continue }
            turnRecord.recordDrawn(tagIndex: tagIndex, drawn: Self.drawnEntry(for: drawing))
        }
    }

    static func drawnEntry(for drawing: MarkDrawing) -> TurnRecord.DrawnEntry {
        func rounded(_ value: CGFloat) -> Double { (Double(value) * 100).rounded() / 100 }
        func rectArray(_ rect: CGRect) -> [Double] { [rect.minX, rect.minY, rect.width, rect.height].map(rounded) }
        var kind = drawing.outline?.kind.rawValue ?? drawing.style.name
        var drawnRect = drawing.outline?.rect ?? drawing.targetCG
        var tip: [Double]?
        if let arrow = drawing.arrow {
            kind = "arrow"
            drawnRect = CGRect(origin: arrow.tip, size: .zero).union(CGRect(origin: arrow.tail, size: .zero))
            tip = [arrow.tip.x, arrow.tip.y].map(rounded)
        }
        if let underline = drawing.underline {
            kind = "underline"
            drawnRect = CGRect(x: underline.start.x, y: underline.start.y, width: underline.end.x - underline.start.x, height: 0)
        }
        if drawing.style == .spot { kind = "spot" }
        return TurnRecord.DrawnEntry(kind: kind, rectCG: rectArray(drawnRect), radius: Double(drawing.outline?.cornerRadius ?? 0),
                                     tip: tip, tentative: drawing.isTentative, recheck: nil)
    }

    // MARK: Tracking callbacks

    private func applyTrackedUpdate(markID: UUID, rectCG: CGRect, isShown: Bool) {
        guard let markIndex = marks.firstIndex(where: { $0.id == markID }) else { return }
        marks[markIndex].rectCG = rectCG
        marks[markIndex].isHidden = !isShown
        rebuild()
    }

    /// Fades over 0.3 s, then removes.
    private func fadeAndRemove(_ markID: UUID) {
        guard let markIndex = marks.firstIndex(where: { $0.id == markID }) else { return }
        marks[markIndex].opacity = 0
        rebuild()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self else { return }
            self.marks.removeAll { $0.id == markID }
            self.rebuild()
        }
    }

    // MARK: OCR re-check

    /// Runs the re-check for marks that need one, waiting up to 150 ms;
    /// results that arrive later are applied when they come (the mark is
    /// drawn first and goes tentative if it then fails).
    func recheck(_ pendingMarks: inout [LiveScreenMark], displays: [DisplayInfo], turnRecord: TurnRecord?) async {
        var recheckTasks: [UUID: Task<MarkRecheck.Outcome, Never>] = [:]
        for mark in pendingMarks where mark.source != .accessibility {
            guard let recheckName = mark.recheckName, !recheckName.isEmpty,
                  let display = displays.first(where: { $0.boundsCG.contains(mark.rectCG.center) }) else { continue }
            let targetRect = mark.rectCG
            recheckTasks[mark.id] = Task { await MarkRecheck.run(name: recheckName, target: targetRect, display: display) }
        }
        guard !recheckTasks.isEmpty else { return }

        let deadline = Date().addingTimeInterval(MarkRecheck.budgetSeconds)
        for markIndex in pendingMarks.indices {
            guard let recheckTask = recheckTasks[pendingMarks[markIndex].id] else { continue }
            let remainingNanoseconds = UInt64(max(0, deadline.timeIntervalSinceNow) * 1_000_000_000)
            if let outcome = await awaitValue(of: recheckTask, timeoutNanoseconds: remainingNanoseconds) {
                Self.apply(outcome, to: &pendingMarks[markIndex])
                recordRecheck(outcome, mark: pendingMarks[markIndex], turnRecord: turnRecord)
            } else {
                let markID = pendingMarks[markIndex].id
                Task { @MainActor [weak self] in
                    let outcome = await recheckTask.value
                    self?.applyLateRecheck(outcome, markID: markID, turnRecord: turnRecord)
                }
            }
        }
    }

    static func apply(_ outcome: MarkRecheck.Outcome, to mark: inout LiveScreenMark) {
        guard !outcome.isPassing else { return }
        mark.confidence = max(0, mark.confidence - 0.3)
        mark.isTentative = true
    }

    /// A re-check that finished after its mark was drawn.
    func applyLateRecheck(_ outcome: MarkRecheck.Outcome, markID: UUID, turnRecord: TurnRecord?) {
        guard let markIndex = marks.firstIndex(where: { $0.id == markID }) else { return }
        Self.apply(outcome, to: &marks[markIndex])
        recordRecheck(outcome, mark: marks[markIndex], turnRecord: turnRecord)
        if !outcome.isPassing { rebuild() }
    }

    func recordRecheck(_ outcome: MarkRecheck.Outcome, mark: LiveScreenMark, turnRecord: TurnRecord?) {
        if !outcome.isPassing {
            print("🔎 Mark re-check failed for \"\(mark.recheckName ?? "")\" (\(Int(outcome.milliseconds)) ms) → tentative")
        }
        guard let tagIndex = mark.tagIndex else { return }
        turnRecord?.recordRecheck(tagIndex: tagIndex, isPassing: outcome.isPassing, milliseconds: outcome.milliseconds, isTentative: mark.isTentative)
    }
}

/// A fresh look at the pixels under a mark: capture target + 24 pt with
/// Clicky's windows excluded (the production filter), OCR it like P1b does,
/// and check the name is still there within 6 pt of the target's centre.
enum MarkRecheck {
    static let budgetSeconds: TimeInterval = 0.15

    struct Outcome: Sendable {
        let isPassing: Bool
        let milliseconds: Double
        let foundFrameCG: CGRect?
    }

    static func run(name: String, target: CGRect, display: DisplayInfo) async -> Outcome {
        let start = Date()
        let cropRect = RecheckMath.cropRect(target: target, displayBounds: display.boundsCG)
        guard cropRect.width >= 1, cropRect.height >= 1,
              let (cropImage, regionCG) = try? await ScreenCaptureService.captureNativeImage(of: display, regionCG: cropRect, includesOwnWindows: false) else {
            return Outcome(isPassing: false, milliseconds: Date().timeIntervalSince(start) * 1000, foundFrameCG: nil)
        }
        let lines = await recognizeLines(in: cropImage, regionCG: regionCG, display: display)
        let foundFrame = RecheckMath.matchingFrame(name: name, lines: lines, target: target)
        return Outcome(isPassing: foundFrame != nil, milliseconds: Date().timeIntervalSince(start) * 1000, foundFrameCG: foundFrame)
    }

    /// OCR of a crop: a CaptureFrame over the crop in its pre-upscale pixel
    /// grid; OCREngine upscales 2x below 1.5 px/pt and maps back through it.
    static func recognizeLines(in cropImage: CGImage, regionCG: CGRect, display: DisplayInfo) async -> [OCRLine] {
        let cropFrame = CaptureFrame(display: display, screenNumber: 0, regionCG: regionCG,
                                     native: PixelSize(width: cropImage.width, height: cropImage.height), model: nil)
        return await OCREngine.recognizeLines(in: cropImage, frame: cropFrame, level: .accurate)
    }
}
