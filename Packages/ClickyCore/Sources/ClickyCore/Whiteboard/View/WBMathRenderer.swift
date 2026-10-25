//
//  WBMathRenderer.swift
//  ClickyCore
//
//  Board math as images: SwiftMath (pinned 1.7.3) typesets the TeX with
//  MTMathImage, in the theme's ink, at the board's math size. TeX SwiftMath
//  can't read falls back to the source drawn monospaced (what WBMeasure
//  measures by default). `install()` points WBMeasure.mathSizeProvider at
//  the same renderer, so the layout leaves exactly the rendered size.
//  Images are cached by (tex, size, colour); main thread only.
//

import AppKit
import SwiftMath

public enum WBMathRenderer {
    nonisolated(unsafe) private static var imageCache: [String: NSImage] = [:]
    nonisolated(unsafe) private static var failedSources: Set<String> = []
    private static let cacheLock = NSLock()

    /// Measure math as SwiftMath draws it (call once at launch / before tests lay out).
    public static func install() {
        WBMeasure.mathSizeProvider = { texSource, fontSize in
            if let image = image(tex: texSource, fontSize: fontSize, color: .black) { return image.size }
            let measured = WBMeasure.textSize(texSource, font: WBMeasure.monospacedFont(size: fontSize), maximumWidth: 100_000)
            return measured
        }
    }

    /// The typeset formula, or nil when SwiftMath can't parse it.
    public static func image(tex: String, fontSize: CGFloat, color: NSColor) -> NSImage? {
        let colorKey = color.usingColorSpace(.sRGB).map { "\($0.redComponent),\($0.greenComponent),\($0.blueComponent)" } ?? "?"
        let cacheKey = "\(fontSize)|\(colorKey)|\(tex)"
        cacheLock.lock()
        if let cachedImage = imageCache[cacheKey] {
            cacheLock.unlock()
            return cachedImage
        }
        let isKnownFailure = failedSources.contains(tex)
        cacheLock.unlock()
        guard !isKnownFailure else { return nil }

        let mathImage = MTMathImage(latex: tex, fontSize: fontSize, textColor: color, labelMode: .display, textAlignment: .center)
        let (error, renderedImage) = mathImage.asImage()
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard error == nil, let renderedImage, renderedImage.size.width > 0, renderedImage.size.height > 0 else {
            failedSources.insert(tex)
            return nil
        }
        imageCache[cacheKey] = renderedImage
        return renderedImage
    }
}
