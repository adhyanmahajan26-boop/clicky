import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import ClickyCore

/// Offscreen renders of MarkSceneView (no window, nothing on screen) into
/// ~/Library/Logs/Clicky/renders/p1c/, at scale 1 and 2. Each render checks
/// that the orange strokes' bounding box contains the target.
@MainActor
struct MarkRenderTests {
    static let outputDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Clicky/renders/p1c", isDirectory: true)

    struct Case {
        let name: String
        let display: MarkSceneDisplay
        let inputs: [MarkSceneInput]
        /// Checked for orange coverage (nil: spot, whose orange-free cut-out is the point).
        let checkedTargets: [CGRect]
    }

    static let smallDisplay = MarkSceneDisplay(displayID: 1, bounds: CGRect(x: 0, y: 0, width: 800, height: 500),
                                               visible: CGRect(x: 0, y: 25, width: 800, height: 405))

    static func input(_ style: MarkStyleKind, _ rect: CGRect, _ text: String?, tentative: Bool = false, order: Int = 0) -> MarkSceneInput {
        MarkSceneInput(id: UUID(), style: style, rectCG: rect, displayText: text, isTentative: tentative, order: order)
    }

    static var cases: [Case] {
        let display = smallDisplay
        var allCases: [Case] = [
            Case(name: "icon-ring", display: display, inputs: [input(.circle, CGRect(x: 380, y: 230, width: 24, height: 24), nil)],
                 checkedTargets: [CGRect(x: 380, y: 230, width: 24, height: 24)]),
            Case(name: "text-pill", display: display, inputs: [input(.circle, CGRect(x: 300, y: 240, width: 180, height: 22), "Deploy failed")],
                 checkedTargets: [CGRect(x: 300, y: 240, width: 180, height: 22)]),
            Case(name: "big-box", display: display, inputs: [input(.box, CGRect(x: 120, y: 90, width: 520, height: 300), "This panel")],
                 checkedTargets: [CGRect(x: 120, y: 90, width: 520, height: 300)]),
            Case(name: "steps-1-3", display: display, inputs: [
                input(.step(1), CGRect(x: 120, y: 200, width: 70, height: 26), "Search", order: 0),
                input(.step(2), CGRect(x: 360, y: 150, width: 90, height: 26), "Build settings", order: 1),
                input(.step(3), CGRect(x: 560, y: 300, width: 26, height: 26), "Gear", order: 2)
            ], checkedTargets: [CGRect(x: 120, y: 200, width: 70, height: 26), CGRect(x: 360, y: 150, width: 90, height: 26), CGRect(x: 560, y: 300, width: 26, height: 26)]),
            Case(name: "underline", display: display, inputs: [input(.underline, CGRect(x: 250, y: 250, width: 220, height: 18), nil)],
                 checkedTargets: []),
            Case(name: "spot", display: display, inputs: [input(.spot, CGRect(x: 330, y: 220, width: 120, height: 40), "Here")], checkedTargets: []),
            Case(name: "tentative", display: display, inputs: [input(.circle, CGRect(x: 360, y: 230, width: 60, height: 30), "Maybe this", tentative: true)],
                 checkedTargets: [CGRect(x: 360, y: 230, width: 60, height: 30)]),
            Case(name: "corner-ring", display: display, inputs: [input(.circle, CGRect(x: 0, y: 0, width: 30, height: 22), nil)],
                 checkedTargets: [])
        ]
        // An arrow at each edge and corner.
        let size = CGSize(width: 40, height: 24)
        let arrowSpots: [(String, CGPoint)] = [
            ("top", CGPoint(x: 380, y: 30)), ("bottom", CGPoint(x: 380, y: 400)), ("left", CGPoint(x: 4, y: 240)), ("right", CGPoint(x: 756, y: 240)),
            ("top-left", CGPoint(x: 4, y: 28)), ("top-right", CGPoint(x: 756, y: 28)), ("bottom-left", CGPoint(x: 4, y: 404)), ("bottom-right", CGPoint(x: 756, y: 404))
        ]
        for (spotName, origin) in arrowSpots {
            allCases.append(Case(name: "arrow-\(spotName)", display: display,
                                 inputs: [input(.arrow, CGRect(origin: origin, size: size), "Run")], checkedTargets: []))
        }
        return allCases
    }

    /// Pixels close to the orange stroke colour.
    static func orangeBoundingBox(of image: CGImage) -> CGRect? {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        for pixelY in 0..<height {
            for pixelX in 0..<width {
                let offset = (pixelY * width + pixelX) * 4
                let alpha = Int(pixels[offset + 3])
                guard alpha > 200 else { continue }
                let red = Int(pixels[offset]), green = Int(pixels[offset + 1]), blue = Int(pixels[offset + 2])
                // Orange (incl. the 70 % tentative blend over grey): red well above blue.
                if red > 150 && red - blue > 50 && green < red - 25 {
                    minX = min(minX, pixelX); maxX = max(maxX, pixelX); minY = min(minY, pixelY); maxY = max(maxY, pixelY)
                }
            }
        }
        guard minX <= maxX else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    @Test func rendersEveryMarkStyleOffscreen() throws {
        try FileManager.default.createDirectory(at: Self.outputDirectory, withIntermediateDirectories: true)
        for renderCase in Self.cases {
            let drawings = MarkSceneBuilder.build(inputs: renderCase.inputs, displays: [renderCase.display])
            for scale in [1.0, 2.0] {
                let scene = MarkSceneView(drawings: drawings, displayBoundsCG: renderCase.display.bounds, drawsImmediately: true)
                    .background(Color(white: 0.93))
                let renderer = ImageRenderer(content: scene)
                renderer.scale = scale
                let image = try #require(renderer.cgImage, "no image for \(renderCase.name)")
                let fileURL = Self.outputDirectory.appendingPathComponent("\(renderCase.name)@\(Int(scale))x.png")
                let bitmap = NSBitmapImageRep(cgImage: image)
                try bitmap.representation(using: .png, properties: [:])?.write(to: fileURL)

                #expect(image.width == Int(renderCase.display.bounds.width * scale))
                for target in renderCase.checkedTargets {
                    let orangeBox = try #require(Self.orangeBoundingBox(of: image), "no orange in \(renderCase.name)")
                    let targetPx = CGRect(x: target.minX * scale, y: target.minY * scale, width: target.width * scale, height: target.height * scale)
                    // Some stroke sits on every side of every checked target (the union covers all targets).
                    #expect(orangeBox.insetBy(dx: -1, dy: -1).contains(targetPx), "\(renderCase.name)@\(scale)x: orange \(orangeBox) ⊉ target \(targetPx)")
                }
                if renderCase.checkedTargets.isEmpty && renderCase.name != "spot" {
                    #expect(Self.orangeBoundingBox(of: image) != nil, "\(renderCase.name): nothing drawn")
                }
            }
        }
    }
}
