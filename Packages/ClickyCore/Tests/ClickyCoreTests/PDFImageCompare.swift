import CoreGraphics
import Foundation

/// Offscreen PDF page renders and a small perceptual diff (downsampled luma:
/// mean absolute difference and an 8×8-block SSIM), for the PDF export tests.
enum PDFImageCompare {
    /// The page drawn into a bitmap at `scale` (white under it, as a viewer shows it).
    static func render(page: CGPDFPage, scale: CGFloat) -> CGImage? {
        let mediaBox = page.getBoxRect(.mediaBox)
        let width = Int((mediaBox.width * scale).rounded()), height = Int((mediaBox.height * scale).rounded())
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -mediaBox.minX, y: -mediaBox.minY)
        context.drawPDFPage(page)
        return context.makeImage()
    }

    /// Luma (0…1) of `image` cropped to `rect` (pixels, top-left origin) and scaled to `size`.
    static func luma(_ image: CGImage, crop rect: CGRect? = nil, size: (width: Int, height: Int)) -> [Double] {
        let source = rect.flatMap { image.cropping(to: $0.integral) } ?? image
        var pixels = [UInt8](repeating: 0, count: size.width * size.height * 4)
        guard let context = CGContext(data: &pixels, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: size.width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        // Opaque white under transparent pixels, like a PDF viewer.
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        return stride(from: 0, to: pixels.count, by: 4).map { index in
            (0.2126 * Double(pixels[index]) + 0.7152 * Double(pixels[index + 1]) + 0.0722 * Double(pixels[index + 2])) / 255
        }
    }

    struct Score: CustomStringConvertible {
        let meanAbsoluteDifference: Double
        let ssim: Double
        var description: String { String(format: "mad=%.4f ssim=%.3f", meanAbsoluteDifference, ssim) }
    }

    static func compare(_ first: [Double], _ second: [Double], width: Int, height: Int) -> Score {
        guard first.count == second.count, first.count == width * height, !first.isEmpty else { return Score(meanAbsoluteDifference: 1, ssim: 0) }
        let mad = zip(first, second).map { abs($0 - $1) }.reduce(0, +) / Double(first.count)
        let c1 = 0.0001, c2 = 0.0009
        var ssimSum = 0.0, blockCount = 0
        for blockY in stride(from: 0, through: height - 8, by: 8) {
            for blockX in stride(from: 0, through: width - 8, by: 8) {
                var a: [Double] = [], b: [Double] = []
                for y in blockY..<(blockY + 8) {
                    for x in blockX..<(blockX + 8) {
                        a.append(first[y * width + x])
                        b.append(second[y * width + x])
                    }
                }
                let meanA = a.reduce(0, +) / 64, meanB = b.reduce(0, +) / 64
                var varA = 0.0, varB = 0.0, covariance = 0.0
                for index in 0..<64 {
                    varA += (a[index] - meanA) * (a[index] - meanA)
                    varB += (b[index] - meanB) * (b[index] - meanB)
                    covariance += (a[index] - meanA) * (b[index] - meanB)
                }
                varA /= 63; varB /= 63; covariance /= 63
                ssimSum += ((2 * meanA * meanB + c1) * (2 * covariance + c2)) / ((meanA * meanA + meanB * meanB + c1) * (varA + varB + c2))
                blockCount += 1
            }
        }
        return Score(meanAbsoluteDifference: mad, ssim: blockCount > 0 ? ssimSum / Double(blockCount) : 0)
    }

    /// Mean luma and the luma spread between the board's background and its ink (legibility).
    static func contrast(_ values: [Double]) -> (mean: Double, inkContrast: Double) {
        guard !values.isEmpty else { return (0, 0) }
        let sorted = values.sorted()
        let mean = values.reduce(0, +) / Double(values.count)
        // Background = the median; ink = the 0.2nd / 99.8th percentile furthest from it
        // (a mostly empty page still has its text in that tail).
        let median = sorted[sorted.count / 2]
        let low = sorted[sorted.count / 500], high = sorted[sorted.count * 499 / 500]
        return (mean, max(abs(median - low), abs(high - median)))
    }
}
