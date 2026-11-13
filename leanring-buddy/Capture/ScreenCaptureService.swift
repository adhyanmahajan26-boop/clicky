//
//  ScreenCaptureService.swift
//  leanring-buddy
//
//  The one capture path for answers. Each display is captured at its native
//  pixel size (region x the display's real point-to-pixel scale), with
//  Clicky's own windows excluded, then resized to exactly the size Claude
//  will see it at (ClaudeImageSizing), so the model's pixel coordinates map
//  back through one CaptureFrame with no hidden rescaling.
//
//  The cursor screen is SCREEN 1; the rest follow left to right.
//

import AppKit
import ClickyCore
import CoreImage
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// One captured screen, ready to send.
struct ScreenCapture {
    let frame: CaptureFrame
    /// The full-resolution capture (OCR, block diffs, self-tests).
    let nativeImage: CGImage
    /// `nativeImage` resized to `frame.modelSize` (badges are drawn on this).
    let modelImage: CGImage
    /// The image sent to the model, JPEG q0.9 (badged when grounding drew them).
    var modelJPEGData: Data
    /// `SCREEN n "<name>" (<position>[, cursor here]) image WxH px`
    let header: String

    var screenNumber: Int { frame.screenNumber }
    var isCursorScreen: Bool { frame.screenNumber == 1 }
    var displayID: CGDirectDisplayID { frame.display.displayID }
}

/// Theo's own titled main windows on screen (Home with Settings, Agents, Setup): real windows the owner looks at, so
/// Clicky sees them and can point there. Panels and overlays (spark, notch, pill, confirm card, notes) stay out of
/// every capture. Before this, a question asked with Theo's window in front got a screenshot of the bare desktop.
@MainActor
enum TheoMainWindows {
    static func windows() -> [NSWindow] {
        NSApp.windows.filter { $0.isVisible && !($0 is NSPanel) && $0.styleMask.contains(.titled) && $0.level == .normal }
    }

    static func numbers() -> Set<CGWindowID> { Set(windows().map { CGWindowID($0.windowNumber) }) }

    static func contains(_ windowID: CGWindowID?) -> Bool {
        guard let windowID else { return false }
        return numbers().contains(windowID)
    }

    /// The front app window (layers 0–19) under a CG point is one of Theo's main windows.
    static func isOnTop(at pointCG: CGPoint) -> Bool {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        for info in windowList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer >= 0, layer < 20,
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary), bounds.contains(pointCG) else { continue }
            let owner = (info[kCGWindowOwnerPID as String] as? Int).map { pid_t($0) }
            let number = (info[kCGWindowNumber as String] as? Int).map { CGWindowID($0) }
            return owner == getpid() && contains(number)
        }
        return false
    }
}

struct ScreenCaptureError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
enum ScreenCaptureService {
    nonisolated static let modelJPEGQuality: CGFloat = 0.9

    struct Options {
        /// Tier for the cursor screen; other screens are always standard.
        var cursorScreenTier: ImageTier = ClickySettings.imageTier.cursorScreenTier
        /// From the tier probe, when the model sees less than we'd send.
        var effectiveMaxEdge: Int?
        /// Self-tests only: include Clicky's own windows in the capture.
        var includesOwnWindows = false
        /// Black-frame retry: never reuse the cached shareable content, and
        /// exclude Clicky by its windows instead of by application (a
        /// different SCContentFilter than the one that produced the frame).
        var forcesFreshContentAndWindowFilter = false
    }

    /// Captures every display concurrently. SCREEN 1 is the cursor screen,
    /// the rest are ordered left to right.
    static func captureAllScreens(options requestedOptions: Options? = nil) async throws -> [ScreenCapture] {
        // Built here, not as a default argument (those run off the main actor).
        let options = requestedOptions ?? Options()
        let displays = ScreenTopology.current()
        guard let mainDisplay = displays.first(where: \.isMain) else {
            throw ScreenCaptureError(message: "No displays found")
        }
        let cursorCG = ScreenTopology.cg(fromAppKit: NSEvent.mouseLocation, flipH: ScreenTopology.mainDisplayHeight)
        let cursorDisplay = displays.first { $0.boundsCG.contains(cursorCG) } ?? mainDisplay
        let orderedDisplays = [cursorDisplay] + displays
            .filter { $0.displayID != cursorDisplay.displayID }
            .sorted { $0.boundsCG.minX < $1.boundsCG.minX }

        let shareableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        await ShareableContentCache.shared.store(shareableContent)

        // Start every display's capture before awaiting any of them; the
        // captures (and the resize + JPEG work) then overlap.
        var captureTasks: [Task<ScreenCapture, Error>] = []
        for (displayIndex, display) in orderedDisplays.enumerated() {
            let screenNumber = displayIndex + 1
            captureTasks.append(Task {
                try await captureScreen(
                    display: display,
                    screenNumber: screenNumber,
                    isCursorScreen: screenNumber == 1,
                    positionDescription: display.positionDescription(relativeTo: mainDisplay.boundsCG),
                    shareableContent: shareableContent,
                    options: options
                )
            })
        }

        var screenCaptures: [ScreenCapture] = []
        for captureTask in captureTasks {
            screenCaptures.append(try await captureTask.value)
        }
        return screenCaptures
    }

    /// Native-resolution capture of a display (or a CG region of it).
    static func captureNativeImage(of display: DisplayInfo, regionCG requestedRegionCG: CGRect? = nil, includesOwnWindows: Bool, shareableContent: SCShareableContent? = nil,
                                   excludesOwnWindowsByWindow: Bool = false) async throws -> (image: CGImage, regionCG: CGRect) {
        let content: SCShareableContent
        if let shareableContent {
            content = shareableContent
        } else if let cachedContent = await ShareableContentCache.shared.recentContent(maximumAge: 3) {
            content = cachedContent
        } else {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
        guard let screenCaptureKitDisplay = content.displays.first(where: { $0.displayID == display.displayID }) else {
            throw ScreenCaptureError(message: "Display \(display.displayID) isn't available to ScreenCaptureKit")
        }

        let contentFilter = makeContentFilter(display: screenCaptureKitDisplay, shareableContent: content, includesOwnWindows: includesOwnWindows,
                                              excludesOwnWindowsByWindow: excludesOwnWindowsByWindow)
        let regionCG = requestedRegionCG ?? display.boundsCG
        let pointPixelScale = CGFloat(SCShareableContent.info(for: contentFilter).pointPixelScale)
        let outputSize = RecheckMath.pixelSize(region: regionCG, pointPixelScale: pointPixelScale)

        let configuration = SCStreamConfiguration()
        // Display-local points, top-left origin.
        configuration.sourceRect = RecheckMath.sourceRect(region: regionCG, displayBounds: display.boundsCG)
        configuration.width = outputSize.width
        configuration.height = outputSize.height
        configuration.showsCursor = false
        configuration.captureResolution = .best
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB

        let capturedImage = try await SCScreenshotManager.captureImage(contentFilter: contentFilter, configuration: configuration)
        return (cropLetterboxing(from: capturedImage, regionAspectRatio: regionCG.width / regionCG.height), regionCG)
    }

    /// One screen, for the key-up refresh. Reuses the shareable-content list
    /// from the last full capture when it's under 3 s old (fetching it costs
    /// ~30 ms; displays and Clicky's own app entry don't change in between).
    /// `encodesJPEG: false` skips the model JPEG when the caller re-encodes
    /// anyway (badges).
    static func captureScreen(display: DisplayInfo, screenNumber: Int, isCursorScreen: Bool, positionDescription: String,
                              options requestedOptions: Options? = nil, encodesJPEG: Bool = true) async throws -> ScreenCapture {
        let options = requestedOptions ?? Options()
        let shareableContent: SCShareableContent
        if !options.forcesFreshContentAndWindowFilter, let cachedContent = await ShareableContentCache.shared.recentContent(maximumAge: 3) {
            shareableContent = cachedContent
        } else {
            shareableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            await ShareableContentCache.shared.store(shareableContent)
        }
        return try await captureScreen(display: display, screenNumber: screenNumber, isCursorScreen: isCursorScreen,
                                       positionDescription: positionDescription, shareableContent: shareableContent,
                                       options: options, encodesJPEG: encodesJPEG)
    }

    // MARK: - Private

    private static func captureScreen(display: DisplayInfo, screenNumber: Int, isCursorScreen: Bool, positionDescription: String, shareableContent: SCShareableContent, options: Options, encodesJPEG: Bool = true) async throws -> ScreenCapture {
        let (nativeImage, regionCG) = try await captureNativeImage(
            of: display,
            includesOwnWindows: options.includesOwnWindows,
            shareableContent: shareableContent,
            excludesOwnWindowsByWindow: options.forcesFreshContentAndWindowFilter
        )
        let nativeSize = PixelSize(width: nativeImage.width, height: nativeImage.height)
        let modelSize = ClaudeImageSizing.modelImageSize(
            regionInPoints: regionCG.size,
            nativePixels: nativeSize,
            isCursorScreen: isCursorScreen,
            tierForCursorScreen: options.cursorScreenTier,
            effectiveMaxEdge: options.effectiveMaxEdge
        )
        let (modelImage, modelJPEGData) = try await Task.detached(priority: .userInitiated) {
            let resizedImage = try resizeToModelSize(nativeImage, modelSize: modelSize)
            return (resizedImage, encodesJPEG ? try encodeJPEG(resizedImage, quality: modelJPEGQuality) : Data())
        }.value

        let frame = CaptureFrame(display: display, screenNumber: screenNumber, regionCG: regionCG, native: nativeSize, model: modelSize)
        let header = ElementListFormatter.header(
            screenNumber: screenNumber,
            displayName: display.localizedName,
            positionDescription: positionDescription,
            isCursorScreen: isCursorScreen,
            imageSize: modelSize
        )
        return ScreenCapture(frame: frame, nativeImage: nativeImage, modelImage: modelImage, modelJPEGData: modelJPEGData, header: header)
    }

    /// Excludes Clicky by application (all its windows, present and future).
    /// If Clicky somehow isn't in the app list, falls back to excluding the
    /// windows owned by this process.
    private static func makeContentFilter(display: SCDisplay, shareableContent: SCShareableContent, includesOwnWindows: Bool,
                                          excludesOwnWindowsByWindow: Bool = false) -> SCContentFilter {
        if includesOwnWindows {
            return SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        }
        let ownProcessIdentifier = getpid()
        // Theo's main windows are the owner's content too; only the overlays and panels are left out.
        let mainWindowNumbers = TheoMainWindows.numbers()
        let ownOverlayWindows = shareableContent.windows.filter {
            $0.owningApplication?.processID == ownProcessIdentifier && !mainWindowNumbers.contains($0.windowID)
        }
        if excludesOwnWindowsByWindow {
            return SCContentFilter(display: display, excludingWindows: ownOverlayWindows)
        }
        if let ownApplication = shareableContent.applications.first(where: { $0.processID == ownProcessIdentifier }) {
            let ownMainWindows = shareableContent.windows.filter {
                $0.owningApplication?.processID == ownProcessIdentifier && mainWindowNumbers.contains($0.windowID)
            }
            return SCContentFilter(display: display, excludingApplications: [ownApplication], exceptingWindows: ownMainWindows)
        }
        print("⚠️ ScreenCaptureService: own app not in SCShareableContent; excluding own windows by pid")
        return SCContentFilter(display: display, excludingWindows: ownOverlayWindows)
    }

    /// If the image's aspect ratio doesn't match the region (letterboxing),
    /// crop to the centred aspect-fit area so the frame maps edge to edge.
    private static func cropLetterboxing(from capturedImage: CGImage, regionAspectRatio: CGFloat) -> CGImage {
        let imageWidth = CGFloat(capturedImage.width)
        let imageHeight = CGFloat(capturedImage.height)
        guard abs(imageWidth / imageHeight - regionAspectRatio) >= 1 / imageHeight else { return capturedImage }

        let contentRect: CGRect
        if imageWidth / imageHeight > regionAspectRatio {
            let contentWidth = (imageHeight * regionAspectRatio).rounded()
            contentRect = CGRect(x: ((imageWidth - contentWidth) / 2).rounded(), y: 0, width: contentWidth, height: imageHeight)
        } else {
            let contentHeight = (imageWidth / regionAspectRatio).rounded()
            contentRect = CGRect(x: 0, y: ((imageHeight - contentHeight) / 2).rounded(), width: imageWidth, height: contentHeight)
        }
        print("⚠️ ScreenCaptureService: letterboxed capture \(capturedImage.width)x\(capturedImage.height), cropping to \(contentRect)")
        return capturedImage.cropping(to: contentRect) ?? capturedImage
    }
}

/// Resizes (sRGB, high-quality interpolation) to the model size.
nonisolated func resizeToModelSize(_ nativeImage: CGImage, modelSize: PixelSize) throws -> CGImage {
    if nativeImage.width == modelSize.width && nativeImage.height == modelSize.height { return nativeImage }
    guard let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let resizeContext = CGContext(data: nil, width: modelSize.width, height: modelSize.height, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: sRGBColorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
        throw ScreenCaptureError(message: "Couldn't create a resize context")
    }
    resizeContext.interpolationQuality = .high
    resizeContext.draw(nativeImage, in: CGRect(x: 0, y: 0, width: modelSize.width, height: modelSize.height))
    guard let resizedImage = resizeContext.makeImage() else {
        throw ScreenCaptureError(message: "Couldn't resize the capture")
    }
    return resizedImage
}

/// JPEG-encodes an image as is. Runs off the main actor.
nonisolated func encodeJPEG(_ image: CGImage, quality: CGFloat) throws -> Data {
    let jpegData = NSMutableData()
    guard let imageDestination = CGImageDestinationCreateWithData(jpegData, UTType.jpeg.identifier as CFString, 1, nil) else {
        throw ScreenCaptureError(message: "Couldn't create a JPEG encoder")
    }
    CGImageDestinationAddImage(imageDestination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(imageDestination) else {
        throw ScreenCaptureError(message: "JPEG encoding failed")
    }
    return jpegData as Data
}

/// Resize + JPEG in one go (probes, self-tests).
nonisolated func encodeModelJPEG(from nativeImage: CGImage, modelSize: PixelSize, quality: CGFloat) throws -> Data {
    try encodeJPEG(try resizeToModelSize(nativeImage, modelSize: modelSize), quality: quality)
}

/// The last full capture's shareable-content list, kept only when it lists
/// Clicky's own app (so the cached filter still excludes all Clicky windows).
actor ShareableContentCache {
    static let shared = ShareableContentCache()
    private var content: SCShareableContent?
    private var fetchDate: Date?

    func store(_ shareableContent: SCShareableContent) {
        let ownProcessIdentifier = getpid()
        guard shareableContent.applications.contains(where: { $0.processID == ownProcessIdentifier }) else { return }
        content = shareableContent
        fetchDate = Date()
    }

    func recentContent(maximumAge: TimeInterval) -> SCShareableContent? {
        guard let fetchDate, Date().timeIntervalSince(fetchDate) < maximumAge else { return nil }
        return content
    }

    /// Forget the cached list (a black frame, an app launched or quit, the
    /// display layout changed): the next capture fetches a fresh one.
    func invalidate() {
        content = nil
        fetchDate = nil
    }
}
