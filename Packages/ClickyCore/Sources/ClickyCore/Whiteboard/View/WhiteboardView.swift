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
        HStack(spacing: 10) {
            Image(systemName: "sparkle")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(WBAccent.gradient)
            Text(AttributedString(scene.board.title.isEmpty ? "Whiteboard" : scene.board.title))
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(palette.ink)
                .lineLimit(1)
            Spacer(minLength: 8)
            if state.isPaused {
                HStack(spacing: 4) {
                    Image(systemName: "pause.fill").font(.system(size: 8, weight: .bold))
                    Text(AttributedString("Paused")).font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(palette.mutedInk)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(palette.ink.opacity(0.08)))
            }
            WBStepProgress(label: state.stepLabel, palette: palette)
        }
        .padding(.horizontal, 18)
        .frame(height: WhiteboardScene.headerHeight)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.ink.opacity(0.07)).frame(height: 1) }
    }

    private var subtitleBar: some View {
        ZStack {
            Rectangle().fill(palette.barBackground)
            Text(AttributedString(state.subtitle))
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(palette.barText)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 28)
        }
        .frame(height: WhiteboardScene.subtitleBarHeight)
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
    }

    /// A faint dot grid behind the board (fixed to the viewport, the camera moves over it).
    private var dotGrid: some View {
        Canvas { context, size in
            let spacing: CGFloat = 26
            let dotColor = palette.ink.opacity(palette.isDark ? 0.075 : 0.085)
            var y: CGFloat = spacing / 2
            while y < size.height {
                var x: CGFloat = spacing / 2
                while x < size.width {
                    context.fill(Path(ellipseIn: CGRect(x: x - 0.9, y: y - 0.9, width: 1.8, height: 1.8)), with: .color(dotColor))
                    x += spacing
                }
                y += spacing
            }
        }
        .frame(width: viewportSize.width, height: viewportSize.height)
    }

    private var viewport: some View {
        ZStack(alignment: .topLeading) {
            dotGrid
            Group {
                if isStatic || reducesMotion {
                    boardContent(now: .infinity)
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !isAnimating(at: Date().timeIntervalSinceReferenceDate))) { context in
                        boardContent(now: context.date.timeIntervalSinceReferenceDate)
                    }
                }
            }
        }
        .frame(width: viewportSize.width, height: viewportSize.height, alignment: .topLeading)
        .clipped()
        .overlay {
            if let statusText = state.statusText {
                Text(AttributedString(statusText))
                    .font(.system(size: 17, weight: .medium))
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

// MARK: - Accent and step progress

/// Theo's orange -> pink -> purple accent.
enum WBAccent {
    static let orange = Color(.sRGB, red: 1.0, green: 0.55, blue: 0.30, opacity: 1)
    static let pink = Color(.sRGB, red: 0.96, green: 0.36, blue: 0.62, opacity: 1)
    static let purple = Color(.sRGB, red: 0.62, green: 0.40, blue: 0.96, opacity: 1)
    static let gradient = LinearGradient(colors: [orange, pink, purple], startPoint: .leading, endPoint: .trailing)
}

/// "3 / 8" as dots (up to 10 steps) or a thin bar, with the numeric label.
struct WBStepProgress: View {
    let label: String
    let palette: WhiteboardPalette

    private var parsed: (current: Int, total: Int)? {
        let parts = label.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let current = Int(parts[0]), let total = Int(parts[1]), total > 0 else { return nil }
        return (min(current, total), total)
    }

    var body: some View {
        if let parsed {
            HStack(spacing: 10) {
                if parsed.total <= 10 {
                    HStack(spacing: 4) {
                        ForEach(0..<parsed.total, id: \.self) { index in
                            Capsule()
                                .fill(index < parsed.current ? AnyShapeStyle(WBAccent.gradient) : AnyShapeStyle(palette.ink.opacity(0.14)))
                                .frame(width: index == parsed.current - 1 ? 16 : 6, height: 6)
                        }
                    }
                    .animation(.spring(duration: 0.35), value: parsed.current)
                } else {
                    Capsule().fill(palette.ink.opacity(0.14)).frame(width: 90, height: 5)
                        .overlay(alignment: .leading) {
                            GeometryReader { proxy in
                                Capsule().fill(WBAccent.gradient).frame(width: proxy.size.width * CGFloat(parsed.current) / CGFloat(parsed.total))
                            }
                        }
                }
                Text(AttributedString("\(parsed.current) / \(parsed.total)"))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(palette.mutedInk)
                    .monospacedDigit()
            }
        } else if !label.isEmpty {
            Text(AttributedString(label)).font(.system(size: 11.5, weight: .semibold)).foregroundColor(palette.mutedInk)
        }
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
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(palette.background.opacity(0.94)))
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
            let haloRect = placedElement.rect.insetBy(dx: -5, dy: -5)
            var isRound = placedElement.shape == .ellipse
            if case .box(let box)? = scene.adapted.nodeElements[placedElement.id]?.payload { isRound = box.shape == .circle }
            let haloPath = isRound ? Path(ellipseIn: haloRect) : Path(roundedRect: haloRect, cornerRadius: 16, style: .continuous)
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: 5))
                layer.stroke(haloPath, with: .color(palette.halo), style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
            }
        }
        for placedEdge in scene.layout.edges {
            guard let owner = scene.adapted.owner(ofEdge: placedEdge.edgeIndex), highlightSet.contains(owner),
                  clock.elapsed(owner: owner) != nil, scene.board.element(withIdentifier: owner)?.kind == .arrow else { continue }
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: 4))
                layer.stroke(Path(placedEdge.path), with: .color(palette.halo), style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
            }
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
                let framePath = Path(roundedRect: frameRect, cornerRadius: 18, style: .continuous)
                sectionContext.fill(framePath, with: .color(palette.sectionFill))
                sectionContext.stroke(framePath, with: .color(palette.sectionStroke), style: StrokeStyle(lineWidth: 1))
            }
            if let title = placedSection.title, let titleRect = placedSection.titleRect {
                sectionContext.draw(Text(AttributedString(title)).font(.system(size: WBSectionLayout.titleFontSize, weight: .semibold)).foregroundColor(palette.ink),
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
        let strokeStyle = StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
        let shadowColor = Color.black.opacity(palette.isDark ? 0.35 : 0.10)
        switch element.payload {
        case .box(let box):
            let progress = WBRevealClock.fraction(elapsed, over: WhiteboardAnimation.boxOutline)
            let shapes = WBShapePaths.box(shape: box.shape, rect: placed.rect, seedIdentifier: placed.id)
            let accent = palette.stroke(for: box.color)
            context.drawLayer { layer in
                layer.addFilter(.shadow(color: shadowColor.opacity(progress), radius: 9, x: 0, y: 4))
                layer.fill(shapes.fill, with: .color(palette.defaultBoxFill.opacity(progress)))
            }
            context.fill(shapes.fill, with: .color(palette.fill(for: box.color).opacity(progress)))
            context.stroke(shapes.outline.trimmedPath(from: 0, to: progress), with: .color(accent.opacity(0.9)), style: strokeStyle)
            if let detail = shapes.detail, progress >= 1 {
                context.stroke(detail, with: .color(accent.opacity(0.9)), style: strokeStyle)
            }
        case .callout(let callout):
            let progress = WBRevealClock.fraction(elapsed, over: WhiteboardAnimation.boxOutline)
            let calloutColor = palette.calloutColor(callout.style)
            let shapes = WBShapePaths.box(shape: .round, rect: placed.rect, seedIdentifier: placed.id)
            context.fill(shapes.fill, with: .color(calloutColor.opacity(palette.fillOpacity * progress)))
            context.stroke(shapes.outline.trimmedPath(from: 0, to: progress), with: .color(calloutColor.opacity(0.85)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            // A colour bar on the leading edge.
            let barRect = CGRect(x: placed.rect.minX + 1, y: placed.rect.minY + 10, width: 3, height: max(0, placed.rect.height - 20))
            context.fill(Path(roundedRect: barRect, cornerRadius: 1.5), with: .color(calloutColor.opacity(progress)))
        case .code:
            let progress = WBRevealClock.fraction(elapsed, over: 0.2)
            let codePath = Path(roundedRect: placed.rect, cornerRadius: 12, style: .continuous)
            context.fill(codePath, with: .color(palette.codeBackground.opacity(progress)))
            context.stroke(codePath, with: .color(palette.ink.opacity(0.08 * progress)), style: StrokeStyle(lineWidth: 1))
        case .chart:
            let progress = WBRevealClock.fraction(elapsed, over: 0.2)
            let chartPath = Path(roundedRect: placed.rect, cornerRadius: 12, style: .continuous)
            context.drawLayer { layer in
                layer.addFilter(.shadow(color: shadowColor.opacity(progress), radius: 8, x: 0, y: 3))
                layer.fill(chartPath, with: .color(palette.defaultBoxFill.opacity(progress)))
            }
            context.stroke(chartPath, with: .color(palette.ink.opacity(0.08 * progress)), style: StrokeStyle(lineWidth: 1))
        case .table:
            let progress = WBRevealClock.fraction(elapsed, over: WhiteboardAnimation.tableFade)
            let tablePath = Path(roundedRect: placed.rect, cornerRadius: 10, style: .continuous)
            context.fill(tablePath, with: .color(palette.defaultBoxFill.opacity(progress)))
            context.stroke(tablePath, with: .color(palette.ink.opacity(0.16 * progress)), style: StrokeStyle(lineWidth: 1))
        case .divider:
            let progress = WBRevealClock.fraction(elapsed, over: WhiteboardAnimation.arrow)
            var linePath = Path()
            linePath.move(to: CGPoint(x: placed.rect.minX, y: placed.rect.midY))
            linePath.addLine(to: CGPoint(x: placed.rect.maxX, y: placed.rect.midY))
            context.stroke(linePath.trimmedPath(from: 0, to: progress), with: .color(palette.ink.opacity(0.18)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        default:
            break
        }
    }

    private func drawEdge(_ placedEdge: WBPlacedEdge, arrow: WBArrow?, elapsed: TimeInterval, in context: inout GraphicsContext) {
        let progress = WBRevealClock.fraction(elapsed, over: WhiteboardAnimation.arrow)
        let paths = WBShapePaths.edge(placedEdge, head: arrow?.head ?? .end)
        let lineWidth: CGFloat = arrow?.style == .thick ? 3 : 1.8
        let dash: [CGFloat] = arrow?.style == .dashed ? [7, 6] : []
        let color = palette.ink.opacity(0.62)
        context.stroke(paths.body.trimmedPath(from: 0, to: progress), with: .color(color),
                       style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round, dash: dash))
        if progress >= 1 {
            context.fill(paths.heads, with: .color(color))
            context.stroke(paths.heads, with: .color(color), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
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
        switch shape {
        case .rect:
            let path = Path(roundedRect: rect, cornerRadius: min(12, rect.height / 3), style: .continuous)
            return BoxShapes(outline: path, fill: path, detail: nil)
        case .round:
            let path = Path(roundedRect: rect, cornerRadius: min(16, rect.height / 2.5), style: .continuous)
            return BoxShapes(outline: path, fill: path, detail: nil)
        case .pill:
            let path = Path(roundedRect: rect, cornerRadius: rect.height / 2, style: .continuous)
            return BoxShapes(outline: path, fill: path, detail: nil)
        case .diamond:
            var path = Path()
            path.addLines([CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.midY),
                           CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.midY)])
            path.closeSubpath()
            return BoxShapes(outline: path, fill: path, detail: nil)
        case .circle:
            let path = Path(ellipseIn: rect)
            return BoxShapes(outline: path, fill: path, detail: nil)
        case .cyl:
            let capHeight = min(18, rect.height / 3)
            let topCap = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: capHeight)
            var outline = Path(ellipseIn: topCap)
            outline.move(to: CGPoint(x: rect.minX, y: topCap.midY))
            outline.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - capHeight / 2))
            let bottomArc = (0...24).map { index -> CGPoint in
                let angle = Double.pi * Double(index) / 24
                return CGPoint(x: rect.minX + rect.width / 2 - cos(angle) * rect.width / 2, y: rect.maxY - capHeight / 2 + sin(angle) * capHeight / 2)
            }
            outline.addLines(bottomArc)
            outline.addLine(to: CGPoint(x: rect.maxX, y: topCap.midY))
            var fillPath = Path(CGRect(x: rect.minX, y: topCap.midY, width: rect.width, height: rect.height - capHeight))
            fillPath.addEllipse(in: topCap)
            fillPath.addEllipse(in: CGRect(x: rect.minX, y: rect.maxY - capHeight, width: rect.width, height: capHeight))
            return BoxShapes(outline: outline, fill: fillPath, detail: nil)
        case .note:
            let fold = min(16, rect.height / 3)
            let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX - fold, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY + fold),
                           CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
            var outline = Path()
            outline.addLines(corners)
            outline.closeSubpath()
            var foldPath = Path()
            foldPath.addLines([CGPoint(x: rect.maxX - fold, y: rect.minY), CGPoint(x: rect.maxX - fold, y: rect.minY + fold), CGPoint(x: rect.maxX, y: rect.minY + fold)])
            return BoxShapes(outline: outline, fill: outline, detail: foldPath)
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
        let body = Path(placedEdge.path)
        var heads = Path()
        func addHead(tip: CGPoint, from source: CGPoint) {
            let dx = tip.x - source.x, dy = tip.y - source.y
            let length = hypot(dx, dy)
            guard length > 0.001 else { return }
            let direction = CGPoint(x: dx / length, y: dy / length)
            let normal = CGPoint(x: -direction.y, y: direction.x)
            let headLength: CGFloat = 11, halfWidth: CGFloat = 4.8
            let back = CGPoint(x: tip.x - direction.x * headLength, y: tip.y - direction.y * headLength)
            heads.addLines([tip, CGPoint(x: back.x + normal.x * halfWidth, y: back.y + normal.y * halfWidth),
                            CGPoint(x: back.x - normal.x * halfWidth, y: back.y - normal.y * halfWidth)])
            heads.closeSubpath()
        }
        if head != .none, let lastSegment = placedEdge.segments.last {
            let tangentSource = lastSegment.control2 == lastSegment.end ? lastSegment.start : lastSegment.control2
            addHead(tip: lastSegment.end, from: tangentSource)
        }
        if head == .both, let firstSegment = placedEdge.segments.first {
            let tangentSource = firstSegment.control1 == firstSegment.start ? firstSegment.end : firstSegment.control1
            addHead(tip: firstSegment.start, from: tangentSource)
        }
        return (body, heads)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
