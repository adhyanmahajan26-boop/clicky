//
//  ClaudeImageSizing.swift
//  ClickyCore
//
//  What size an image reaches the model at. Claude's API downsizes images
//  that exceed its limits, and coordinates the model returns are in the size
//  it SAW, so Clicky sends images already at that size and maps from it.
//  `claudeResizedSize` ports the platform's `resized_size` rule: an image
//  fits when, counted in 28 px tiles, both sides fit the max edge and the
//  tile count fits the token budget.
//

import CoreGraphics
import Foundation

public enum ImageTier: String, Sendable, CaseIterable {
    case high
    case standard

    public var maxEdge: Int { self == .high ? 2576 : 1568 }
    public var maxTokens: Int { self == .high ? 4784 : 1568 }
}

public struct PixelSize: Equatable, Hashable, Sendable, CustomStringConvertible {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public init(_ size: CGSize) {
        self.init(width: Int(size.width.rounded()), height: Int(size.height.rounded()))
    }

    public var cgSize: CGSize { CGSize(width: width, height: height) }
    public var longEdge: Int { max(width, height) }
    public var description: String { "\(width)x\(height)" }
}

public enum ClaudeImageSizing {
    /// Claude Code itself downsizes images above this long edge (measured by
    /// the P1a transport probe: 2576x1078 was stored as 1999x837), so sending
    /// more only adds payload. Applied to every image as "CLI downscale".
    public static let claudeCodeCLIMaxLongEdge = 2000

    private static func tileCount(_ length: Int) -> Int {
        (length + 27) / 28
    }

    public static func fits(_ size: PixelSize, maxEdge: Int, maxTokens: Int) -> Bool {
        let widthTiles = tileCount(size.width)
        let heightTiles = tileCount(size.height)
        return widthTiles * 28 <= maxEdge && heightTiles * 28 <= maxEdge && widthTiles * heightTiles <= maxTokens
    }

    /// The size the model will see this image at.
    public static func claudeResizedSize(_ size: PixelSize, maxEdge: Int, maxTokens: Int) -> PixelSize {
        guard size.width > 0, size.height > 0 else { return size }
        if fits(size, maxEdge: maxEdge, maxTokens: maxTokens) { return size }

        // Work in landscape; transpose back at the end.
        let isPortrait = size.height > size.width
        let landscapeWidth = isPortrait ? size.height : size.width
        let landscapeHeight = isPortrait ? size.width : size.height
        let aspectRatio = Double(landscapeWidth) / Double(landscapeHeight)

        func heightFor(width candidateWidth: Int) -> Int {
            max(1, Int((Double(candidateWidth) / aspectRatio).rounded(.toNearestOrEven)))
        }
        func candidateFits(_ candidateWidth: Int) -> Bool {
            fits(PixelSize(width: candidateWidth, height: heightFor(width: candidateWidth)), maxEdge: maxEdge, maxTokens: maxTokens)
        }

        var lowWidth = 1
        var highWidth = landscapeWidth
        while lowWidth < highWidth {
            let middleWidth = (lowWidth + highWidth + 1) / 2
            if candidateFits(middleWidth) {
                lowWidth = middleWidth
            } else {
                highWidth = middleWidth - 1
            }
        }
        // Rounding can make the predicate non-monotonic near the edge; step
        // down until the result really fits so the output always does.
        while lowWidth > 1 && !candidateFits(lowWidth) {
            lowWidth -= 1
        }

        let resizedWidth = lowWidth
        let resizedHeight = heightFor(width: resizedWidth)
        return isPortrait
            ? PixelSize(width: resizedHeight, height: resizedWidth)
            : PixelSize(width: resizedWidth, height: resizedHeight)
    }

    public static func claudeResizedSize(_ size: PixelSize, tier: ImageTier) -> PixelSize {
        claudeResizedSize(size, maxEdge: tier.maxEdge, maxTokens: tier.maxTokens)
    }

    /// Scales so the long edge is at most `cap`, keeping the aspect ratio.
    public static func capLongEdge(_ size: PixelSize, cap: Int) -> PixelSize {
        guard size.longEdge > cap, cap > 0 else { return size }
        let scale = Double(cap) / Double(size.longEdge)
        if size.width >= size.height {
            return PixelSize(width: cap, height: max(1, Int((Double(size.height) * scale).rounded(.toNearestOrEven))))
        }
        return PixelSize(width: max(1, Int((Double(size.width) * scale).rounded(.toNearestOrEven))), height: cap)
    }

    /// The model image size for one screen: the region in points (rounded,
    /// never above native pixels), sized for the tier (the cursor screen gets
    /// `tierForCursorScreen`, others standard), then capped to a measured
    /// `effectiveMaxEdge` if the tier probe found the model sees less.
    public static func modelImageSize(regionInPoints: CGSize, nativePixels: PixelSize, isCursorScreen: Bool, tierForCursorScreen: ImageTier, effectiveMaxEdge: Int?) -> PixelSize {
        let baseSize = PixelSize(
            width: min(Int(regionInPoints.width.rounded()), nativePixels.width),
            height: min(Int(regionInPoints.height.rounded()), nativePixels.height)
        )
        var modelSize = claudeResizedSize(baseSize, tier: isCursorScreen ? tierForCursorScreen : .standard)
        modelSize = capLongEdge(modelSize, cap: min(effectiveMaxEdge ?? claudeCodeCLIMaxLongEdge, claudeCodeCLIMaxLongEdge))
        return modelSize
    }
}
