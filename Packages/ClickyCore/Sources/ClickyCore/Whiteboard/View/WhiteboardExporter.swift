//
//  WhiteboardExporter.swift
//  ClickyCore
//
//  Offscreen pictures of a board, fully revealed and nothing highlighted:
//   - export: the whole board 1:1 under its title, at 2× (ImageRenderer),
//     for ~/Pictures/Clicky/whiteboard-<timestamp>.png and the pasteboard
//   - export PDF: the same picture as a vector PDF (title stays selectable
//     text), for ~/Pictures/Clicky/whiteboard-<timestamp>.pdf
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

    /// The whole board as a PDF page the board's size (title on top), drawn as vectors.
    /// When a chart comes out blank in ImageRenderer the same fallback as the PNG applies:
    /// the offscreen hosting view is drawn to PDF instead (NSView.dataWithPDF).
    public static func exportPDFData(scene: WhiteboardScene, theme: WhiteboardTheme) -> Data? {
        let boardSize = scene.layout.bounds.size
        let state = WhiteboardRenderState.fullyRevealed(scene, camera: scene.actualSizeTransform)
        let view = WhiteboardView(scene: scene, state: state, theme: theme, isStatic: true, showsHeader: true, showsSubtitle: false,
                                  viewportSize: boardSize)
        let size = CGSize(width: boardSize.width, height: boardSize.height + WhiteboardScene.headerHeight)
        let framedView = view.frame(width: size.width, height: size.height)
        let chartRects = chartRects(in: scene, offsetY: WhiteboardScene.headerHeight, cameraScale: 1, translation: .zero)

        let renderer = ImageRenderer(content: framedView)
        renderer.scale = exportScale
        renderer.proposedSize = ProposedViewSize(size)
        // The same check the PNG makes: if a chart's area is empty, use the hosting-view fallback.
        if let previewImage = renderer.cgImage, !chartRects.contains(where: { isBlank(previewImage, rect: $0, scale: exportScale) }) {
            return renderVectorPDF(renderer: renderer, size: size)
        }
        return cacheDisplayPDF(framedView, size: size)
    }

    /// Writes the board's PDF to `url` (atomically).
    public static func exportPDF(scene: WhiteboardScene, theme: WhiteboardTheme, to url: URL) throws {
        guard let pdfData = exportPDFData(scene: scene, theme: theme) else { throw CocoaError(.fileWriteUnknown) }
        try pdfData.write(to: url, options: .atomic)
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

    /// ImageRenderer drawn into a PDF context page by page (one page, the board's size).
    static func renderVectorPDF<Content: View>(renderer: ImageRenderer<Content>, size: CGSize) -> Data? {
        let pdfData = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let pdfContext = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }
        renderer.render { _, drawContent in
            pdfContext.beginPDFPage(nil)
            drawContent(pdfContext)
            pdfContext.endPDFPage()
        }
        pdfContext.closePDF()
        return pdfData as Data
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
