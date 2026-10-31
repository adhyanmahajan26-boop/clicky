//
//  WhiteboardExporter.swift
//  ClickyCore
//
//  Offscreen pictures of a board, fully revealed and nothing highlighted:
//   - export: the whole board 1:1 under its title, at 2× (ImageRenderer),
//     for ~/Pictures/Clicky/whiteboard-<timestamp>.png and the pasteboard
//   - export PDF: the same picture as a vector PDF (text stays selectable,
//     fonts embedded, math as vectors with its TeX as invisible text; a board
//     taller than A4 proportions is paged between section rows), for
//     ~/Pictures/Clicky/whiteboard-<timestamp>.pdf
//   - panel renders: the board as the panel shows it at a fixed size
//     (goldens, the debug `boardCtl export` check)
//  Swift Charts can come out blank in ImageRenderer on some systems; when
//  a chart's area is empty the picture is taken again with
//  NSView.cacheDisplay from an offscreen NSHostingView. Nothing is ever put
//  on screen. Main thread only.
//

import AppKit
import PDFKit
import SwiftUI

@MainActor
public enum WhiteboardExporter {
    nonisolated public static let exportScale: CGFloat = 2

    /// The whole board at 1:1 (times `scale`), title on top.
    public static func exportImage(scene: WhiteboardScene, theme: WhiteboardTheme, scale: CGFloat = exportScale) -> CGImage? {
        let boardSize = scene.layout.bounds.size
        let state = WhiteboardRenderState.fullyRevealed(scene, camera: scene.actualSizeTransform)
        let view = WhiteboardView(scene: scene, state: state, theme: theme, isStatic: true, showsHeader: true, showsSubtitle: false,
                                  viewportSize: boardSize)
        let size = CGSize(width: boardSize.width, height: boardSize.height + WhiteboardScene.headerHeight)
        return render(view, size: size, scale: scale, chartRects: chartRects(in: scene, offsetY: WhiteboardScene.headerHeight, cameraScale: 1, translation: .zero))
    }

    /// The board as the panel shows it (fit camera), at `panelSize`.
    public static func panelImage(scene: WhiteboardScene, theme: WhiteboardTheme, panelSize: CGSize, scale: CGFloat = 1, subtitle: String = "") -> CGImage? {
        let state = WhiteboardRenderState.fullyRevealed(scene, subtitle: subtitle)
        let view = WhiteboardView(scene: scene, state: state, theme: theme, isStatic: true)
        let camera = state.camera
        return render(view, size: panelSize, scale: scale,
                      chartRects: chartRects(in: scene, offsetY: WhiteboardScene.headerHeight, cameraScale: camera.scale, translation: camera.translation))
    }

    // MARK: PDF

    /// One PDF page: the board rows it shows (board points, full board width) and the sections on it.
    public struct PDFPage: Equatable, Sendable {
        public let boardRect: CGRect
        public let sectionIdentifiers: [String]
        /// The page's media box (every page of a document has the same size).
        public let pageSize: CGSize
    }

    /// Tallest page, as a share of the board's width: A4 portrait (√2), so a page prints on A4 or Letter without shrinking further.
    nonisolated public static let maximumPageAspectRatio: CGFloat = 2.0.squareRoot()

    /// How the board is cut into pages. A board that fits one page of A4
    /// proportions (height ≤ √2 × width, header included) is one page the
    /// board's own size. A taller board is cut between section rows (never
    /// through a section) and the rows are packed greedily into pages; every
    /// page then has the same size (board width × √2 × board width, or the
    /// tallest row when a single row is taller than that), content at the
    /// top, the board's title in each page's header with "page n of m".
    public static func pdfPages(for scene: WhiteboardScene) -> [PDFPage] {
        let bounds = scene.layout.bounds
        let header = WhiteboardScene.headerHeight
        let maximumContentHeight = max(200, bounds.width * maximumPageAspectRatio - header)
        let allSectionIdentifiers = scene.layout.sections.map(\.id)
        if bounds.height <= maximumContentHeight || scene.layout.sections.count < 2 {
            return [PDFPage(boardRect: bounds, sectionIdentifiers: allSectionIdentifiers, pageSize: CGSize(width: bounds.width, height: bounds.height + header))]
        }

        // Rows of sections (sections that overlap vertically share a row).
        var rows: [(minY: CGFloat, maxY: CGFloat, sections: [String])] = []
        for section in scene.layout.sections.sorted(by: { $0.rect.minY < $1.rect.minY }) {
            if let last = rows.last, section.rect.minY < last.maxY {
                rows[rows.count - 1] = (last.minY, max(last.maxY, section.rect.maxY), last.sections + [section.id])
            } else {
                rows.append((section.rect.minY, section.rect.maxY, [section.id]))
            }
        }
        // Cut lines halfway between rows; the first band starts at 0, the last ends at the board's bottom.
        var bands: [(rect: CGRect, sections: [String])] = []
        for (rowIndex, row) in rows.enumerated() {
            let top = rowIndex == 0 ? 0 : (rows[rowIndex - 1].maxY + row.minY) / 2
            let bottom = rowIndex == rows.count - 1 ? bounds.height : (row.maxY + rows[rowIndex + 1].minY) / 2
            bands.append((CGRect(x: 0, y: top, width: bounds.width, height: bottom - top), row.sections))
        }
        var packed: [(rect: CGRect, sections: [String])] = []
        for band in bands {
            if let last = packed.last, band.rect.maxY - last.rect.minY <= maximumContentHeight {
                packed[packed.count - 1] = (last.rect.union(band.rect), last.sections + band.sections)
            } else {
                packed.append(band)
            }
        }
        let contentHeight = max(maximumContentHeight, packed.map(\.rect.height).max() ?? 0)
        let pageSize = CGSize(width: bounds.width, height: ceil(contentHeight) + header)
        return packed.map { PDFPage(boardRect: $0.rect, sectionIdentifiers: $0.sections, pageSize: pageSize) }
    }

    /// The board as a vector PDF: see `pdfPages(for:)` for how it's paged.
    /// Each page is the same WhiteboardView the PNG export draws (ImageRenderer
    /// into the PDF context: shapes as paths, text as embedded-font text),
    /// showing only that page's sections. Math is drawn after it straight into
    /// the context (SwiftMath's glyphs and rules stay vectors, where a SwiftUI
    /// Image would be a bitmap), with its TeX source as invisible text so
    /// formulas are searchable. When a chart comes out blank in ImageRenderer
    /// the page is drawn from an offscreen NSHostingView instead (the PNG's
    /// fallback). The document's Title is the board's title. No window is used.
    public static func exportPDFData(scene: WhiteboardScene, theme: WhiteboardTheme) -> Data? {
        let pages = pdfPages(for: scene)
        guard let firstPage = pages.first else { return nil }
        let pdfData = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: firstPage.pageSize)
        let documentInfo: [CFString: Any] = [kCGPDFContextTitle: scene.board.title.isEmpty ? "Whiteboard" : scene.board.title,
                                             kCGPDFContextCreator: "Clicky"]
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let pdfContext = CGContext(consumer: consumer, mediaBox: &mediaBox, documentInfo as CFDictionary) else { return nil }
        for (pageIndex, page) in pages.enumerated() {
            let pageLabel = pages.count > 1 ? "page \(pageIndex + 1) of \(pages.count)" : ""
            let view = pageView(scene: scene, theme: theme, page: page, pageLabel: pageLabel)
            var pageBox = CGRect(origin: .zero, size: page.pageSize)
            let pageInfo: [CFString: Any] = [kCGPDFContextMediaBox: Data(bytes: &pageBox, count: MemoryLayout<CGRect>.size)]
            pdfContext.beginPDFPage(pageInfo as CFDictionary)
            drawPageContent(view, size: page.pageSize, chartRects: chartRects(in: scene, page: page), into: pdfContext)
            drawMath(scene: scene, theme: theme, page: page, into: pdfContext)
            pdfContext.endPDFPage()
        }
        pdfContext.closePDF()
        return pdfData as Data
    }

    /// Writes the board's PDF to `url` (atomically).
    public static func exportPDF(scene: WhiteboardScene, theme: WhiteboardTheme, to url: URL) throws {
        guard let pdfData = exportPDFData(scene: scene, theme: theme) else { throw CocoaError(.fileWriteUnknown) }
        try pdfData.write(to: url, options: .atomic)
    }

    /// The page's part of the board under the title: only its sections revealed, the camera on its rows.
    static func pageView(scene: WhiteboardScene, theme: WhiteboardTheme, page: PDFPage, pageLabel: String) -> some View {
        let contentSize = CGSize(width: page.pageSize.width, height: page.pageSize.height - WhiteboardScene.headerHeight)
        let pageSections = Set(page.sectionIdentifiers)
        var state = WhiteboardRenderState.fullyRevealed(scene, camera: WBCameraTransform(framedRect: page.boardRect, scale: 1,
                                                                                         translation: CGVector(dx: 0, dy: -page.boardRect.minY)))
        state.revealTimes = state.revealTimes.filter { identifier, _ in
            scene.board.element(withIdentifier: identifier).map { pageSections.contains($0.sectionIdentifier) } ?? false
        }
        state.stepLabel = pageLabel
        return WhiteboardView(scene: scene, state: state, theme: theme, isStatic: true, showsHeader: true, showsSubtitle: false,
                              viewportSize: contentSize)
            .environment(\.wbDrawsMathExternally, true)
            .frame(width: page.pageSize.width, height: page.pageSize.height)
    }

    /// Chart rects of the page's sections, in page points (top-left origin).
    static func chartRects(in scene: WhiteboardScene, page: PDFPage) -> [CGRect] {
        let pageSections = Set(page.sectionIdentifiers)
        return scene.layout.elements.filter { $0.kind == .chart && pageSections.contains($0.sectionID) }.map { placed in
            placed.rect.offsetBy(dx: 0, dy: WhiteboardScene.headerHeight - page.boardRect.minY).insetBy(dx: 14, dy: 30)
        }
    }

    /// The view drawn as vectors into the current PDF page (ImageRenderer), or from an
    /// offscreen hosting view's PDF when a chart came out blank.
    static func drawPageContent<Content: View>(_ view: Content, size: CGSize, chartRects: [CGRect], into pdfContext: CGContext) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = exportScale
        renderer.proposedSize = ProposedViewSize(size)
        if !chartRects.isEmpty {
            let previewImage = renderer.cgImage
            if previewImage == nil || chartRects.contains(where: { isBlank(previewImage!, rect: $0, scale: exportScale) }),
               let fallbackData = cacheDisplayPDF(view, size: size),
               let provider = CGDataProvider(data: fallbackData as CFData), let fallbackPage = CGPDFDocument(provider)?.page(at: 1) {
                pdfContext.saveGState()
                pdfContext.drawPDFPage(fallbackPage)
                pdfContext.restoreGState()
                return
            }
        }
        renderer.render { _, drawContent in
            pdfContext.saveGState()
            drawContent(pdfContext)
            pdfContext.restoreGState()
        }
    }

    /// The page's formulas straight into the PDF context (y up), where the view left their place empty.
    static func drawMath(scene: WhiteboardScene, theme: WhiteboardTheme, page: PDFPage, into pdfContext: CGContext) {
        let pageSections = Set(page.sectionIdentifiers)
        for placed in scene.layout.elements where pageSections.contains(placed.sectionID) {
            guard let element = scene.adapted.nodeElements[placed.id], case .math(let math) = element.payload,
                  let image = WBMathRenderer.image(tex: math.tex, fontSize: WBMeasure.mathFontSize, color: theme.palette.mathInk) else { continue }
            let rect = mathRect(imageSize: image.size, placed: placed)
            let topInPage = rect.minY + WhiteboardScene.headerHeight - page.boardRect.minY
            let pdfRect = CGRect(x: rect.minX, y: page.pageSize.height - topInPage - rect.height, width: rect.width, height: rect.height)
            pdfContext.saveGState()
            pdfContext.clip(to: CGRect(x: 0, y: 0, width: page.pageSize.width, height: page.pageSize.height - WhiteboardScene.headerHeight))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: pdfContext, flipped: false)
            image.draw(in: pdfRect, from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            WBInvisibleText.draw(math.tex, fittingYUp: pdfRect, in: pdfContext)
            pdfContext.restoreGState()
        }
    }

    /// Where WBElementContentView puts a formula: centred in the element, at its content scale (board points).
    static func mathRect(imageSize: CGSize, placed: WBPlacedElement) -> CGRect {
        let size = CGSize(width: imageSize.width * placed.contentScale, height: imageSize.height * placed.contentScale)
        return CGRect(x: placed.rect.midX - size.width / 2, y: placed.rect.midY - size.height / 2, width: size.width, height: size.height)
    }

    public static func pngData(_ image: CGImage) -> Data? {
        let bitmap = NSBitmapImageRep(cgImage: image)
        return bitmap.representation(using: .png, properties: [:])
    }

    // MARK: Rendering

    static func render<Content: View>(_ view: Content, size: CGSize, scale: CGFloat, chartRects: [CGRect]) -> CGImage? {
        let framedView = view.frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: framedView)
        renderer.scale = scale
        renderer.proposedSize = ProposedViewSize(size)
        guard let image = renderer.cgImage else { return cacheDisplayImage(framedView, size: size, scale: scale) }
        if !chartRects.isEmpty, chartRects.contains(where: { isBlank(image, rect: $0, scale: scale) }) {
            return cacheDisplayImage(framedView, size: size, scale: scale) ?? image
        }
        return image
    }

    /// The chart fallback for PDF: the offscreen hosting view written out with NSView.dataWithPDF (no window).
    static func cacheDisplayPDF<Content: View>(_ view: Content, size: CGSize) -> Data? {
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = CGRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()
        return hostingView.dataWithPDF(inside: hostingView.bounds)
    }

    /// The fallback: an offscreen hosting view drawn into a bitmap (no window).
    static func cacheDisplayImage<Content: View>(_ view: Content, size: CGSize, scale: CGFloat) -> CGImage? {
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = CGRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        bitmap.size = size
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        return bitmap.cgImage
    }

    /// Chart rects in the picture's points.
    static func chartRects(in scene: WhiteboardScene, offsetY: CGFloat, cameraScale: CGFloat, translation: CGVector) -> [CGRect] {
        scene.layout.elements.filter { $0.kind == .chart }.map { placed in
            CGRect(x: placed.rect.minX * cameraScale + translation.dx, y: placed.rect.minY * cameraScale + translation.dy + offsetY,
                   width: placed.rect.width * cameraScale, height: placed.rect.height * cameraScale).insetBy(dx: 14 * cameraScale, dy: 30 * cameraScale)
        }
    }

    /// True when every pixel in `rect` (points) has the same colour.
    static func isBlank(_ image: CGImage, rect: CGRect, scale: CGFloat) -> Bool {
        let pixelRect = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale).integral
        guard pixelRect.width > 4, pixelRect.height > 4, let cropped = image.cropping(to: pixelRect) else { return false }
        let width = cropped.width, height = cropped.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        let first = Array(pixels[0..<4])
        for pixelIndex in stride(from: 0, to: pixels.count, by: 4) {
            for channel in 0..<4 where abs(Int(pixels[pixelIndex + channel]) - Int(first[channel])) > 12 { return false }
        }
        return true
    }
}
