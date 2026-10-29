//
//  CaptureFrame.swift
//  ClickyCore
//
//  The single description of "this image shows this part of the screen".
//  Every image <-> screen conversion goes through one of these, crops
//  included, so a pixel the model names maps to exactly one CG point.
//
//  Three spaces:
//   - CG global points (canonical)
//   - native pixels: the captured image (region x pixelsPerPoint)
//   - model pixels: the (usually smaller) image actually sent to Claude
//

import CoreGraphics
import Foundation

public struct CaptureFrame: Equatable, Sendable {
    public let display: DisplayInfo
    /// SCREEN n as shown to the model (1 = cursor screen), 0 for crops/self-tests.
    public let screenNumber: Int
    /// The captured area in CG global points (defaults to the whole display).
    public let regionCG: CGRect
    /// Captured image size in pixels.
    public let native: PixelSize
    /// Size of the image sent to the model; nil means it saw the native image.
    public let model: PixelSize?

    public init(display: DisplayInfo, screenNumber: Int, regionCG: CGRect? = nil, native: PixelSize, model: PixelSize?) {
        self.display = display
        self.screenNumber = screenNumber
        self.regionCG = regionCG ?? display.boundsCG
        self.native = native
        self.model = model
    }

    public var modelSize: PixelSize { model ?? native }

    public var nativePixelsPerPoint: CGFloat {
        ScreenTopology.pixelsPerPoint(nativeWidthInPixels: CGFloat(native.width), regionWidthInPoints: regionCG.width)
    }

    // MARK: Model pixels

    /// Model pixel (top-left origin) → CG point at that pixel's centre.
    /// Out-of-range coordinates are clamped to the image.
    public func cg(fromModelPx modelPixel: CGPoint) -> CGPoint {
        Self.cg(fromPixel: modelPixel, imageSize: modelSize, regionCG: regionCG)
    }

    /// CG point → model pixel coordinate (fractional; the inverse of cg(fromModelPx:)).
    public func modelPx(fromCG cgPoint: CGPoint) -> CGPoint {
        Self.pixel(fromCG: cgPoint, imageSize: modelSize, regionCG: regionCG)
    }

    /// Model-pixel rect (top-left origin, edges in pixel units) → CG rect.
    public func cgRect(fromModelPxRect modelRect: CGRect) -> CGRect {
        Self.cgRect(fromPixelRect: modelRect, imageSize: modelSize, regionCG: regionCG)
    }

    public func modelPxRect(fromCG cgRect: CGRect) -> CGRect {
        let scaleX = CGFloat(modelSize.width) / regionCG.width
        let scaleY = CGFloat(modelSize.height) / regionCG.height
        return CGRect(x: (cgRect.minX - regionCG.minX) * scaleX, y: (cgRect.minY - regionCG.minY) * scaleY,
                      width: cgRect.width * scaleX, height: cgRect.height * scaleY)
    }

    // MARK: Native pixels

    public func cg(fromNativePx nativePixel: CGPoint) -> CGPoint {
        Self.cg(fromPixel: nativePixel, imageSize: native, regionCG: regionCG)
    }

    public func nativePx(fromCG cgPoint: CGPoint) -> CGPoint {
        Self.pixel(fromCG: cgPoint, imageSize: native, regionCG: regionCG)
    }

    public func cgRect(fromNativePxRect nativeRect: CGRect) -> CGRect {
        Self.cgRect(fromPixelRect: nativeRect, imageSize: native, regionCG: regionCG)
    }

    // MARK: Vision

    /// A Vision bounding box (normalised 0...1, bottom-left origin, relative
    /// to a crop of the native image) → CG rect. Flips within the crop, adds
    /// the crop's native-pixel origin, then converts native pixels to CG.
    public func cgRect(visionBox normalizedBox: CGRect, cropPx: CGRect) -> CGRect {
        let nativeRect = CGRect(
            x: cropPx.minX + normalizedBox.minX * cropPx.width,
            y: cropPx.minY + (1 - normalizedBox.maxY) * cropPx.height,
            width: normalizedBox.width * cropPx.width,
            height: normalizedBox.height * cropPx.height
        )
        return cgRect(fromNativePxRect: nativeRect)
    }

    // MARK: Shared maths

    private static func cg(fromPixel pixel: CGPoint, imageSize: PixelSize, regionCG: CGRect) -> CGPoint {
        let clampedX = min(max(pixel.x, 0), CGFloat(imageSize.width - 1))
        let clampedY = min(max(pixel.y, 0), CGFloat(imageSize.height - 1))
        return CGPoint(
            x: regionCG.minX + (clampedX + 0.5) * regionCG.width / CGFloat(imageSize.width),
            y: regionCG.minY + (clampedY + 0.5) * regionCG.height / CGFloat(imageSize.height)
        )
    }

    private static func pixel(fromCG cgPoint: CGPoint, imageSize: PixelSize, regionCG: CGRect) -> CGPoint {
        CGPoint(
            x: (cgPoint.x - regionCG.minX) * CGFloat(imageSize.width) / regionCG.width - 0.5,
            y: (cgPoint.y - regionCG.minY) * CGFloat(imageSize.height) / regionCG.height - 0.5
        )
    }

    private static func cgRect(fromPixelRect pixelRect: CGRect, imageSize: PixelSize, regionCG: CGRect) -> CGRect {
        let scaleX = regionCG.width / CGFloat(imageSize.width)
        let scaleY = regionCG.height / CGFloat(imageSize.height)
        return CGRect(x: regionCG.minX + pixelRect.minX * scaleX, y: regionCG.minY + pixelRect.minY * scaleY,
                      width: pixelRect.width * scaleX, height: pixelRect.height * scaleY)
    }
}
