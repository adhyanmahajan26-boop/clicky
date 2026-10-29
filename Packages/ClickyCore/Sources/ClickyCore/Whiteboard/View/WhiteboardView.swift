//
//  WhiteboardView.swift
//  ClickyCore
//
//  Draws a board hand-drawn: a header (title, step), the board viewport
//  (camera = scaleEffect + offset, springing 0.6 s between steps) and a
//  subtitle bar with the words being spoken. Strokes (section frames,
//  rough outlines, arrows, halos) go in one Canvas; content (labels, text,
//  lists, code, math, charts, tables, callouts) are SwiftUI views placed on
//  the layout's rects. Each element animates from its reveal time:
//  box outline 0.45 s then label 0.3 s, arrow 0.35 s, text typed at
//  40 ch/s, code 30 ms a line, math fades 0.25 s, chart 0.5 s. A step's
//  highlights get a halo and everything else dims to 55 %. Static mode
//  (exports, goldens) and Reduce Motion draw everything finished.
//  Text is Text(AttributedString) built from plain strings: no markdown,
//  no links. Font: ChalkboardSE-Regular, else the rounded system font.
//

import AppKit
import Charts
import SwiftUI

public enum WhiteboardAnimation {
    public static let boxOutline: TimeInterval = 0.45
    public static let boxLabel: TimeInterval = 0.3
    public static let arrow: TimeInterval = 0.35
    public static let textCharactersPerSecond = 40.0
    /// Lists type at the text rate but never take longer than this.
    public static let listMaximum: TimeInterval = 2
    public static let codeSecondsPerLine: TimeInterval = 0.03
    public static let mathFade: TimeInterval = 0.25
    public static let chart: TimeInterval = 0.5
    public static let tableFade: TimeInterval = 0.35
    public static let sectionFade: TimeInterval = 0.3
    /// Inner boxes and arrows of a flow follow each other this far apart.
    public static let flowStagger: TimeInterval = 0.12
    public static let dimmedOpacity = 0.55
    /// Longest any element animates (the timeline stops after it).
    public static let longest: TimeInterval = 3
}

public struct WhiteboardView: View {
    let scene: WhiteboardScene
    let state: WhiteboardRenderState
    let theme: WhiteboardTheme
    /// Everything finished, no timeline (exports, goldens).
    let isStatic: Bool
    let reducesMotion: Bool
    let showsHeader: Bool
    let showsSubtitle: Bool
    /// The board area's size (default: what the scene was laid out for).
    let viewportSize: CGSize

    public init(scene: WhiteboardScene, state: WhiteboardRenderState, theme: WhiteboardTheme, isStatic: Bool = false,
                reducesMotion: Bool = false, showsHeader: Bool = true, showsSubtitle: Bool = true, viewportSize: CGSize? = nil) {
        self.scene = scene
        self.state = state
        self.theme = theme
        self.isStatic = isStatic
        self.reducesMotion = reducesMotion
        self.showsHeader = showsHeader
        self.showsSubtitle = showsSubtitle
        self.viewportSize = viewportSize ?? scene.viewportSize
    }

    private var palette: WhiteboardPalette { theme.palette }

    public var body: some View {
        VStack(spacing: 0) {
            if showsHeader { header }
            viewport
            if showsSubtitle { subtitleBar }
        }
        .background(palette.background)
        .environment(\.colorScheme, palette.isDark ? .dark : .light)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(AttributedString(scene.board.title.isEmpty ? "Whiteboard" : scene.board.title))
                .font(WBViewFonts.hand(20))
                .foregroundColor(palette.ink)
                .lineLimit(1)
            Spacer(minLength: 8)
            if state.isPaused {
                Text(AttributedString("paused"))
                    .font(WBViewFonts.hand(15))
                    .foregroundColor(palette.mutedInk)
            }
            Text(AttributedString(state.stepLabel))
                .font(WBViewFonts.hand(15))
                .foregroundColor(palette.mutedInk)
                .monospacedDigit()
        }
        .padding(.horizontal, 18)
        .frame(height: WhiteboardScene.headerHeight)
    }

    private var subtitleBar: some View {
        ZStack {
            Rectangle().fill(palette.barBackground)
            Text(AttributedString(state.subtitle))
                .font(WBViewFonts.hand(17))
                .foregroundColor(palette.barText)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 24)
        }
        .frame(height: WhiteboardScene.subtitleBarHeight)
    }

    private var viewport: some View {
        Group {
            if isStatic || reducesMotion {
                boardContent(now: .infinity)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !isAnimating(at: Date().timeIntervalSinceReferenceDate))) { context in
                    boardContent(now: context.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .frame(width: viewportSize.width, height: viewportSize.height, alignment: .topLeading)
        .clipped()
        .overlay {
            if let statusText = state.statusText {
                Text(AttributedString(statusText))
                    .font(WBViewFonts.hand(22))
                    .foregroundColor(palette.mutedInk)
            }
        }
    }

    private func isAnimating(at now: TimeInterval) -> Bool {
        state.revealTimes.values.contains { now - $0 < WhiteboardAnimation.longest }
    }

    @ViewBuilder
    private func boardContent(now: TimeInterval) -> some View {
        let camera = state.camera
        WBBoardCanvasView(scene: scene, state: state, palette: palette, now: now)
            .frame(width: scene.layout.bounds.width, height: scene.layout.bounds.height, alignment: .topLeading)
            .scaleEffect(camera.scale, anchor: .topLeading)
            .offset(x: camera.translation.dx, y: camera.translation.dy)
            .frame(width: viewportSize.width, height: viewportSize.height, alignment: .topLeading)
            .animation(isStatic || reducesMotion ? nil : .spring(duration: scene.cameraPlan.springDuration), value: camera)
    }
}

// MARK: - Fonts

enum WBViewFonts {
    static func hand(_ size: CGFloat) -> Font { Font(WBMeasure.handFont(size: size) as CTFont) }
    static func mono(_ size: CGFloat) -> Font { Font(WBMeasure.monospacedFont(size: size) as CTFont) }
}

// MARK: - Reveal progress

struct WBRevealClock {
    let now: TimeInterval
    let revealTimes: [String: TimeInterval]

    /// Seconds since `owner` started appearing (+ `delay`), nil = not yet.
    func elapsed(owner: String?, delay: TimeInterval = 0) -> TimeInterval? {
        guard let owner, let revealTime = revealTimes[owner] else { return nil }
        if now == .infinity { return .infinity }
        let elapsed = now - revealTime - delay
        return elapsed >= 0 ? elapsed : nil
    }

    static func fraction(_ elapsed: TimeInterval, over duration: TimeInterval) -> Double {
        guard duration > 0 else { return 1 }
        return min(1, max(0, elapsed / duration))
    }
}

// MARK: - Board

struct WBBoardCanvasView: View {
    let scene: WhiteboardScene
    let state: WhiteboardRenderState
    let palette: WhiteboardPalette
    let now: TimeInterval

    private var clock: WBRevealClock { WBRevealClock(now: now, revealTimes: state.revealTimes) }
    private var highlightSet: Set<String> { Set(state.highlightedIdentifiers) }

    var body: some View {
        let clock = clock
        let highlightSet = highlightSet
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                drawStrokes(in: &context, clock: clock, highlightSet: highlightSet)
            }
            .frame(width: scene.layout.bounds.width, height: scene.layout.bounds.height)
            ForEach(Array(scene.layout.elements.enumerated()), id: \.element.id) { _, placedElement in
                if let element = scene.adapted.nodeElements[placedElement.id],
                   let elapsed = clock.elapsed(owner: scene.adapted.ownerIdentifiers[placedElement.id], delay: flowDelay(of: placedElement.id)) {
                    WBElementContentView(element: element, placed: placedElement, elapsed: elapsed, palette: palette)
                        .frame(width: placedElement.rect.width, height: placedElement.rect.height)
                        .opacity(opacity(forOwner: scene.adapted.ownerIdentifiers[placedElement.id], highlightSet: highlightSet))
                        .offset(x: placedElement.rect.minX, y: placedElement.rect.minY)
                }
            }
            ForEach(scene.layout.edges, id: \.edgeIndex) { placedEdge in
                if let labelRect = placedEdge.labelRect, let label = placedEdge.label,
                   let elapsed = clock.elapsed(owner: scene.adapted.owner(ofEdge: placedEdge.edgeIndex), delay: edgeDelay(placedEdge.edgeIndex)) {
                    Text(AttributedString(label))
                        .font(WBViewFonts.hand(WBMeasure.edgeLabelFontSize * (scene.layout.element(id: placedEdge.from)?.contentScale ?? 1)))
                        .foregroundColor(palette.mutedInk)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.7)
                        .frame(width: labelRect.width, height: labelRect.height)
                        .background(RoundedRectangle(cornerRadius: 6).fill(palette.background.opacity(0.92)))
                        .opacity(WBRevealClock.fraction(elapsed - WhiteboardAnimation.arrow * 0.6, over: 0.25)
                                 * opacity(forOwner: scene.adapted.owner(ofEdge: placedEdge.edgeIndex), highlightSet: highlightSet))
                        .offset(x: labelRect.minX, y: labelRect.minY)
                }
            }
        }
    }

    // MARK: Delays and dimming

    /// A flow's inner nodes follow each other.
    private func flowDelay(of layoutIdentifier: String) -> TimeInterval {
        guard let owner = scene.adapted.ownerIdentifiers[layoutIdentifier], owner != layoutIdentifier,
              let index = scene.adapted.layoutIdentifiersByElement[owner]?.firstIndex(of: layoutIdentifier) else { return 0 }
        return Double(index) * WhiteboardAnimation.flowStagger
    }

    private func edgeDelay(_ edgeIndex: Int) -> TimeInterval {
        guard let owner = scene.adapted.owner(ofEdge: edgeIndex), case .flow = scene.board.element(withIdentifier: owner)?.payload,
              let edgeElement = scene.adapted.edgeElements[safe: edgeIndex], case .arrow(let arrow) = edgeElement.payload else { return 0 }
        // After both ends of the flow arrow are in.
        return max(flowDelay(of: arrow.fromIdentifier), flowDelay(of: arrow.toIdentifier)) + WhiteboardAnimation.flowStagger
    }

    private func opacity(forOwner owner: String?, highlightSet: Set<String>) -> Double {
        guard !highlightSet.isEmpty, let owner else { return 1 }
        return highlightSet.contains(owner) ? 1 : WhiteboardAnimation.dimmedOpacity
    }

    // MARK: Strokes

    private func drawStrokes(in context: inout GraphicsContext, clock: WBRevealClock, highlightSet: Set<String>) {
        drawSections(in: &context, clock: clock)

        // Halos under everything highlighted.
        for placedElement in scene.layout.elements {
            guard let owner = scene.adapted.ownerIdentifiers[placedElement.id], highlightSet.contains(owner),
                  clock.elapsed(owner: owner) != nil else { continue }
            let haloRect = placedElement.rect.insetBy(dx: -7, dy: -7)
            var isRound = placedElement.shape == .ellipse
            if case .box(let box)? = scene.adapted.nodeElements[placedElement.id]?.payload { isRound = box.shape == .circle }
            let haloPath = isRound ? Path(ellipseIn: haloRect) : Path(roundedRect: haloRect, cornerRadius: 12)
            context.stroke(haloPath, with: .color(palette.halo), style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
        }
        for placedEdge in scene.layout.edges {
            guard let owner = scene.adapted.owner(ofEdge: placedEdge.edgeIndex), highlightSet.contains(owner),
                  clock.elapsed(owner: owner) != nil, scene.board.element(withIdentifier: owner)?.kind == .arrow else { continue }
            context.stroke(Path(placedEdge.path), with: .color(palette.halo), style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))
        }

        // Outlines and fills.
        for placedElement in scene.layout.elements {
            guard let element = scene.adapted.nodeElements[placedElement.id],
                  let elapsed = clock.elapsed(owner: scene.adapted.ownerIdentifiers[placedElement.id], delay: flowDelay(of: placedElement.id)) else { continue }
            var elementContext = context
            elementContext.opacity = opacity(forOwner: scene.adapted.ownerIdentifiers[placedElement.id], highlightSet: highlightSet)
            drawOutline(of: element, placed: placedElement, elapsed: elapsed, in: &elementContext)
        }

        // Arrows.
        for placedEdge in scene.layout.edges {
            let owner = scene.adapted.owner(ofEdge: placedEdge.edgeIndex)
            guard let elapsed = clock.elapsed(owner: owner, delay: edgeDelay(placedEdge.edgeIndex)) else { continue }
            var edgeContext = context
            edgeContext.opacity = opacity(forOwner: owner, highlightSet: highlightSet)
            var arrow: WBArrow?
            if let edgeElement = scene.adapted.edgeElements[safe: placedEdge.edgeIndex], case .arrow(let edgeArrow) = edgeElement.payload { arrow = edgeArrow }
            drawEdge(placedEdge, arrow: arrow, elapsed: elapsed, in: &edgeContext)
        }
    }

    private func drawSections(in context: inout GraphicsContext, clock: WBRevealClock) {
        let showsFrames = scene.layout.sections.count > 1
        for placedSection in scene.layout.sections {
            let sectionOwners = scene.board.elements(inSection: placedSection.id).map(\.id)
            let firstElapsed = sectionOwners.compactMap { clock.elapsed(owner: $0) }.max()
            guard let firstElapsed else { continue }
            var sectionContext = context
            sectionContext.opacity = WBRevealClock.fraction(firstElapsed, over: WhiteboardAnimation.sectionFade)
            if showsFrames {
                let frameRect = placedSection.rect.insetBy(dx: 4, dy: 4)
                sectionContext.fill(Path(roundedRect: frameRect, cornerRadius: 14), with: .color(palette.sectionFill))
                var generator = RoughGenerator(elementID: "section." + placedSection.id, options: Self.sectionRoughOptions)
                sectionContext.stroke(Path(RoughPath.cgPath(generator.rectangle(frameRect))), with: .color(palette.sectionStroke),
                                      style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            }
            if let title = placedSection.title, let titleRect = placedSection.titleRect {
                sectionContext.draw(Text(AttributedString(title)).font(WBViewFonts.hand(WBSectionLayout.titleFontSize)).foregroundColor(palette.ink),
                                    in: titleRect.insetBy(dx: -2, dy: -2))
            }
        }
    }

    static let sectionRoughOptions: RoughOptions = {
        var options = RoughOptions()
        options.roughness = 0.6
        return options
    }()

    private func drawOutline(of element: WBElement, placed: WBPlacedElement, elapsed: TimeInterval, in context: inout GraphicsContext) {
        let strokeStyle = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
        switch element.payload {
        case .box(let box):
            let progress = WBRevealClock.fraction(elapsed, over: WhiteboardAnimation.boxOutline)
            let shapes = WBShapePaths.box(shape: box.shape, rect: placed.rect, seedIdentifier: placed.id)
            context.fill(shapes.fill, with: .color(palette.fill(for: box.color).opacity(progress)))
            context.stroke(shapes.outline.trimmedPath(from: 0, to: progress), with: .color(palette.stroke(for: box.color)), style: strokeStyle)
            if let detail = shapes.detail, progress >= 1 {
                context.stroke(detail, with: .color(palette.stroke(for: box.color)), style: strokeStyle)
            }
        case .callout(let callout):
            let progress = WBRevealClock.fraction(elapsed, over: WhiteboardAnimation.boxOutline)
            let calloutColor = palette.calloutColor(callout.style)
            let shapes = WBShapePaths.box(shape: .round, rect: placed.rect, seedIdentifier: placed.id)
            context.fill(shapes.fill, with: .color(calloutColor.opacity(palette.fillOpacity * progress)))
            context.stroke(shapes.outline.trimmedPath(from: 0, to: progress), with: .color(calloutColor), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        case .code:
            let progress = WBRevealClock.fraction(elapsed, over: 0.2)
            context.fill(Path(roundedRect: placed.rect, cornerRadius: 8), with: .color(palette.codeBackground.opacity(progress)))
        case .chart:
            let progress = WBRevealClock.fraction(elapsed, over: 0.2)
            context.fill(Path(roundedRect: placed.rect, cornerRadius: 10), with: .color(palette.defaultBoxFill.opacity(progress)))
        case .table:
            let progress = WBRevealClock.fraction(elapsed, over: WhiteboardAnimation.tableFade)
            var generator = RoughGenerator(elementID: placed.id, options: Self.sectionRoughOptions)
            context.stroke(Path(RoughPath.cgPath(generator.rectangle(placed.rect))).trimmedPath(from: 0, to: progress),
                           with: .color(palette.ink.opacity(0.7)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        case .divider:
            let progress = WBRevealClock.fraction(elapsed, over: WhiteboardAnimation.arrow)
            var generator = RoughGenerator(elementID: placed.id)
            let midY = placed.rect.midY
            let linePath = Path(RoughPath.cgPath(generator.line(from: CGPoint(x: placed.rect.minX, y: midY), to: CGPoint(x: placed.rect.maxX, y: midY))))
            context.stroke(linePath.trimmedPath(from: 0, to: progress), with: .color(palette.mutedInk), style: strokeStyle)
        default:
            break
        }
    }

    private func drawEdge(_ placedEdge: WBPlacedEdge, arrow: WBArrow?, elapsed: TimeInterval, in context: inout GraphicsContext) {
        let progress = WBRevealClock.fraction(elapsed, over: WhiteboardAnimation.arrow)
        let paths = WBShapePaths.edge(placedEdge, head: arrow?.head ?? .end)
        let lineWidth: CGFloat = arrow?.style == .thick ? 3.6 : 2
        let dash: [CGFloat] = arrow?.style == .dashed ? [9, 7] : []
        let color = palette.ink.opacity(0.85)
        context.stroke(paths.body.trimmedPath(from: 0, to: progress), with: .color(color),
                       style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round, dash: dash))
        if progress >= 1 {
            context.stroke(paths.heads, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
    }
}

// MARK: - Shapes

enum WBShapePaths {
    struct BoxShapes {
        let outline: Path
        let fill: Path
        /// Drawn once the outline is complete (a cylinder's rim, a note's fold).
        let detail: Path?
    }

    static func box(shape: WBBoxShape, rect: CGRect, seedIdentifier: String) -> BoxShapes {
        var generator = RoughGenerator(elementID: seedIdentifier)
        switch shape {
        case .rect:
            return BoxShapes(outline: Path(RoughPath.cgPath(generator.rectangle(rect))), fill: Path(rect), detail: nil)
        case .round, .pill:
            let radius = shape == .pill ? rect.height / 2 : min(14, rect.height / 3)
            let points = roundedRectPoints(rect, radius: radius)
            return BoxShapes(outline: Path(RoughPath.cgPath(generator.curve(through: points + [points[0]]))),
                             fill: Path(roundedRect: rect, cornerRadius: radius), detail: nil)
        case .diamond:
            let corners = [CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.midY),
                           CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.midY)]
            var fillPath = Path()
            fillPath.addLines(corners)
            fillPath.closeSubpath()
            return BoxShapes(outline: Path(RoughPath.cgPath(generator.linearPath(corners, closed: true))), fill: fillPath, detail: nil)
        case .circle:
            return BoxShapes(outline: Path(RoughPath.cgPath(generator.ellipse(in: rect))), fill: Path(ellipseIn: rect), detail: nil)
        case .cyl:
            let capHeight = min(18, rect.height / 3)
            let topCap = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: capHeight)
            var outline = Path(RoughPath.cgPath(generator.ellipse(in: topCap)))
            outline.addPath(Path(RoughPath.cgPath(generator.line(from: CGPoint(x: rect.minX, y: topCap.midY), to: CGPoint(x: rect.minX, y: rect.maxY - capHeight / 2)))))
            let bottomArc = (0...8).map { index -> CGPoint in
                let angle = Double.pi * Double(index) / 8
                return CGPoint(x: rect.midX - cos(angle) * rect.width / 2, y: rect.maxY - capHeight / 2 + sin(angle) * capHeight / 2)
            }
            outline.addPath(Path(RoughPath.cgPath(generator.curve(through: bottomArc))))
            outline.addPath(Path(RoughPath.cgPath(generator.line(from: CGPoint(x: rect.maxX, y: rect.maxY - capHeight / 2), to: CGPoint(x: rect.maxX, y: topCap.midY)))))
            var fillPath = Path(roundedRect: CGRect(x: rect.minX, y: topCap.midY, width: rect.width, height: rect.height - capHeight), cornerRadius: 0)
            fillPath.addEllipse(in: topCap)
            fillPath.addEllipse(in: CGRect(x: rect.minX, y: rect.maxY - capHeight, width: rect.width, height: capHeight))
            return BoxShapes(outline: outline, fill: fillPath, detail: nil)
        case .note:
            let fold = min(16, rect.height / 3)
            let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX - fold, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY + fold),
                           CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
            var fillPath = Path()
            fillPath.addLines(corners)
            fillPath.closeSubpath()
            var foldGenerator = RoughGenerator(elementID: seedIdentifier + ".fold")
            let foldPath = Path(RoughPath.cgPath(foldGenerator.linearPath([CGPoint(x: rect.maxX - fold, y: rect.minY), CGPoint(x: rect.maxX - fold, y: rect.minY + fold),
                                                                           CGPoint(x: rect.maxX, y: rect.minY + fold)], closed: false)))
            return BoxShapes(outline: Path(RoughPath.cgPath(generator.linearPath(corners, closed: true))), fill: fillPath, detail: foldPath)
        }
    }

    /// Points around a rounded rect (clockwise from the top-left corner's end), edges sampled every ~70 pt.
    static func roundedRectPoints(_ rect: CGRect, radius: CGFloat) -> [CGPoint] {
        let radius = max(0, min(radius, min(rect.width, rect.height) / 2))
        var points: [CGPoint] = []
        func edge(from start: CGPoint, to end: CGPoint) {
            let length = hypot(end.x - start.x, end.y - start.y)
            let pieceCount = max(1, Int(length / 70))
            for pieceIndex in 0..<pieceCount {
                let fraction = CGFloat(pieceIndex) / CGFloat(pieceCount)
                points.append(CGPoint(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction))
            }
        }
        func corner(center: CGPoint, startAngle: Double) {
            for stepIndex in 0...4 {
                let angle = startAngle + Double(stepIndex) * (Double.pi / 2) / 4
                points.append(CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius))
            }
        }
        edge(from: CGPoint(x: rect.minX + radius, y: rect.minY), to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        corner(center: CGPoint(x: rect.maxX - radius, y: rect.minY + radius), startAngle: -Double.pi / 2)
        edge(from: CGPoint(x: rect.maxX, y: rect.minY + radius), to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        corner(center: CGPoint(x: rect.maxX - radius, y: rect.maxY - radius), startAngle: 0)
        edge(from: CGPoint(x: rect.maxX - radius, y: rect.maxY), to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        corner(center: CGPoint(x: rect.minX + radius, y: rect.maxY - radius), startAngle: Double.pi / 2)
        edge(from: CGPoint(x: rect.minX, y: rect.maxY - radius), to: CGPoint(x: rect.minX, y: rect.minY + radius))
        corner(center: CGPoint(x: rect.minX + radius, y: rect.minY + radius), startAngle: Double.pi)
        return points
    }

    static func edge(_ placedEdge: WBPlacedEdge, head: WBArrowHead) -> (body: Path, heads: Path) {
        var generator = RoughGenerator(elementID: RoughPath.edgeID(of: placedEdge))
        let body = Path(RoughPath.cgPath(generator.curve(through: placedEdge.points)))
        var heads = Path()
        if head != .none, let lastSegment = placedEdge.segments.last {
            let tangentSource = lastSegment.control2 == lastSegment.end ? lastSegment.start : lastSegment.control2
            heads.addPath(Path(RoughPath.cgPath(generator.arrowhead(tip: lastSegment.end, comingFrom: tangentSource))))
        }
        if head == .both, let firstSegment = placedEdge.segments.first {
            let tangentSource = firstSegment.control1 == firstSegment.start ? firstSegment.end : firstSegment.control1
            heads.addPath(Path(RoughPath.cgPath(generator.arrowhead(tip: firstSegment.start, comingFrom: tangentSource))))
        }
        return (body, heads)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
