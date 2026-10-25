import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import ClickyCore

/// Offscreen renders of WhiteboardView (ImageRenderer, nothing on screen):
/// 12 real model boards × 3 themes, fully revealed, at a fixed panel size,
/// written to ~/Library/Logs/Clicky/renders/p4/<board>-<theme>.png and
/// compared with the goldens in Goldens/p4 (≤ 0.5 % of pixels differ).
/// A missing golden is written from the first render; every board is then
/// rendered a second time and compared, which proves the renders are
/// deterministic in the same run.
@MainActor
struct WhiteboardRenderTests {
    static let panelSize = CGSize(width: 1280, height: 860)
    static let maximumDifferingFraction = 0.005

    static let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    static let fixturesDirectory = testsDirectory.appendingPathComponent("Fixtures/boards", isDirectory: true)
    static let goldensDirectory = testsDirectory.appendingPathComponent("Goldens/p4", isDirectory: true)
    static let outputDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Clicky/renders/p4", isDirectory: true)

    nonisolated static let boardNames = ["https", "git", "compound-interest", "big-o", "public-key", "process-thread",
                             "photosynthesis", "recursion", "db-index", "electoral", "binary-search", "closures"]

    static func scene(named boardName: String) throws -> WhiteboardScene {
        WBMathRenderer.install()
        let answerText = try String(contentsOf: fixturesDirectory.appendingPathComponent("\(boardName).txt"), encoding: .utf8)
        let outcome = WBStreamParser.parse(WBBlockExtractor.whiteboardBody(in: answerText))
        #expect(outcome.isUsable, "\(boardName) should parse")
        return WhiteboardScene(board: outcome.board, viewportSize: WhiteboardScene.viewportSize(forPanelSize: panelSize))
    }

    static func rgbaPixels(_ image: CGImage) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixels
    }

    /// Fraction of pixels whose colour differs by more than 8 in any channel.
    static func differingFraction(_ first: CGImage, _ second: CGImage) -> Double {
        guard first.width == second.width, first.height == second.height else { return 1 }
        let firstPixels = rgbaPixels(first), secondPixels = rgbaPixels(second)
        var differing = 0
        for pixelIndex in stride(from: 0, to: firstPixels.count, by: 4) {
            for channel in 0..<4 where abs(Int(firstPixels[pixelIndex + channel]) - Int(secondPixels[pixelIndex + channel])) > 8 {
                differing += 1
                break
            }
        }
        return Double(differing) / Double(first.width * first.height)
    }

    static func loadPNG(_ url: URL) -> CGImage? {
        guard let data = try? Data(contentsOf: url), let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    @Test(arguments: boardNames)
    func rendersMatchGoldens(boardName: String) throws {
        try FileManager.default.createDirectory(at: Self.outputDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: Self.goldensDirectory, withIntermediateDirectories: true)
        let scene = try Self.scene(named: boardName)
        for theme in WhiteboardTheme.allCases {
            let fileName = "\(boardName)-\(theme.rawValue).png"
            let firstRender = try #require(WhiteboardExporter.panelImage(scene: scene, theme: theme, panelSize: Self.panelSize,
                                                                         subtitle: scene.board.steps.first?.say ?? ""))
            let firstData = try #require(WhiteboardExporter.pngData(firstRender))
            try firstData.write(to: Self.outputDirectory.appendingPathComponent(fileName))
            let goldenURL = Self.goldensDirectory.appendingPathComponent(fileName)
            if !FileManager.default.fileExists(atPath: goldenURL.path) { try firstData.write(to: goldenURL) }
            let golden = try #require(Self.loadPNG(goldenURL))

            let secondRender = try #require(WhiteboardExporter.panelImage(scene: scene, theme: theme, panelSize: Self.panelSize,
                                                                          subtitle: scene.board.steps.first?.say ?? ""))
            let difference = Self.differingFraction(secondRender, golden)
            #expect(difference <= Self.maximumDifferingFraction, "\(fileName) differs from its golden by \(difference * 100)%")
            #expect(Self.differingFraction(firstRender, secondRender) <= Self.maximumDifferingFraction, "\(fileName) isn't deterministic")
        }
    }

    /// The live-test sample (Tools/eval/boards/https.jsonl) parses and draws.
    @Test func evalSampleBoardRenders() throws {
        try FileManager.default.createDirectory(at: Self.outputDirectory, withIntermediateDirectories: true)
        WBMathRenderer.install()
        let sampleURL = Self.testsDirectory.appendingPathComponent("../../../../Tools/eval/boards/https.jsonl").standardizedFileURL
        let outcome = WBStreamParser.parse(try String(contentsOf: sampleURL, encoding: .utf8))
        #expect(outcome.isUsable && outcome.stats.droppedCount == 0)
        #expect(outcome.board.sections.map(\.id) == ["agenda", "q1", "q2", "q3", "recap"])
        let scene = WhiteboardScene(board: outcome.board, viewportSize: WhiteboardScene.viewportSize(forPanelSize: Self.panelSize))
        let image = try #require(WhiteboardExporter.panelImage(scene: scene, theme: .paper, panelSize: Self.panelSize))
        try WhiteboardExporter.pngData(image)?.write(to: Self.outputDirectory.appendingPathComponent("eval-https-paper.png"))
    }

    @Test func exportRendersWholeBoardAtTwiceTheSize() throws {
        try FileManager.default.createDirectory(at: Self.outputDirectory, withIntermediateDirectories: true)
        let scene = try Self.scene(named: "db-index")
        let image = try #require(WhiteboardExporter.exportImage(scene: scene, theme: .paper))
        #expect(abs(image.width - Int(scene.layout.bounds.width * 2)) <= 2)
        #expect(abs(image.height - Int((scene.layout.bounds.height + WhiteboardScene.headerHeight) * 2)) <= 2)
        // The chart drew something (bars, not a blank area).
        let chartRects = WhiteboardExporter.chartRects(in: scene, offsetY: WhiteboardScene.headerHeight, cameraScale: 1, translation: .zero)
        #expect(!chartRects.isEmpty)
        for chartRect in chartRects { #expect(!WhiteboardExporter.isBlank(image, rect: chartRect, scale: 2)) }
        try WhiteboardExporter.pngData(image)?.write(to: Self.outputDirectory.appendingPathComponent("export-db-index.png"))
    }
}
