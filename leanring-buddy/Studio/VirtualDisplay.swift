//
//  VirtualDisplay.swift
//  leanring-buddy
//
//  One hidden screen: a CoreGraphics virtual display that nothing but Theo's own windows goes on. CGVirtualDisplay is a
//  private class with no header in the SDK, so it's reached through the Objective-C runtime; if a future macOS drops it,
//  `init?` fails and Studio says so instead of crashing.
//

import AppKit
import ClickyCore

@MainActor
final class VirtualDisplay {
    let id: CGDirectDisplayID
    /// Keeping this alive keeps the display. Letting go removes it.
    private var object: NSObject?

    init?(name: String, serial: UInt32, size: CGSize, hiDPI: Bool = false, refresh: Double = 60) {
        guard let descriptorClass = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type,
              let settingsClass = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type,
              let modeClass: AnyObject = NSClassFromString("CGVirtualDisplayMode"),
              let displayClass: AnyObject = NSClassFromString("CGVirtualDisplay") else { return nil }

        let descriptor = descriptorClass.init()
        descriptor.setValue(name, forKey: "name")
        let pixelScale: CGFloat = hiDPI ? 2 : 1
        descriptor.setValue(UInt32(size.width * pixelScale), forKey: "maxPixelsWide")
        descriptor.setValue(UInt32(size.height * pixelScale), forKey: "maxPixelsHigh")
        descriptor.setValue(NSValue(size: CGSize(width: size.width / 4.2, height: size.height / 4.2)), forKey: "sizeInMillimeters")
        descriptor.setValue(UInt32(0x7468), forKey: "vendorID")
        descriptor.setValue(UInt32(0x5354), forKey: "productID")
        descriptor.setValue(serial, forKey: "serialNum")
        let setQueue = NSSelectorFromString("setDispatchQueue:")
        guard descriptor.responds(to: setQueue) else { return nil }
        descriptor.perform(setQueue, with: DispatchQueue.main)

        // -[CGVirtualDisplayMode initWithWidth:height:refreshRate:] takes plain numbers, so it needs its real signature.
        let initMode = NSSelectorFromString("initWithWidth:height:refreshRate:")
        guard let blankMode = modeClass.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(), blankMode.responds(to: initMode) else { return nil }
        typealias ModeInit = @convention(c) (AnyObject, Selector, UInt, UInt, Double) -> Unmanaged<AnyObject>
        let makeMode = unsafeBitCast(blankMode.method(for: initMode), to: ModeInit.self)
        var mode = makeMode(blankMode, initMode, UInt(size.width), UInt(size.height), refresh).takeRetainedValue()
        // Macs drop real monitors out of HDR while a plain virtual display exists. Modes can name a transfer function, which
        // may be the way round that. Test profile only, until it's been tried.
        if TheoProfile.isTest, let wanted = UserDefaults.standard.object(forKey: "test.studio.transferFunction") as? Int {
            let initHDR = NSSelectorFromString("initWithWidth:height:refreshRate:transferFunction:")
            if let blank = modeClass.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(), blank.responds(to: initHDR) {
                typealias ModeInitHDR = @convention(c) (AnyObject, Selector, UInt32, UInt32, Double, UInt32) -> Unmanaged<AnyObject>
                mode = unsafeBitCast(blank.method(for: initHDR), to: ModeInitHDR.self)(blank, initHDR, UInt32(size.width), UInt32(size.height), refresh, UInt32(wanted)).takeRetainedValue()
            }
        }

        let settings = settingsClass.init()
        // One to one pixels unless the owner asks otherwise: a Retina screen takes four times the memory.
        settings.setValue(UInt32(hiDPI ? 1 : 0), forKey: "hiDPI")
        settings.setValue([mode], forKey: "modes")

        let initDisplay = NSSelectorFromString("initWithDescriptor:")
        guard let blank = displayClass.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(), blank.responds(to: initDisplay),
              let made = blank.perform(initDisplay, with: descriptor)?.takeRetainedValue() as? NSObject else { return nil }

        let apply = NSSelectorFromString("applySettings:")
        guard made.responds(to: apply) else { return nil }
        typealias ApplySettings = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        guard unsafeBitCast(made.method(for: apply), to: ApplySettings.self)(made, apply, settings) else { return nil }
        guard let number = made.value(forKey: "displayID") as? NSNumber, number.uint32Value != 0 else { return nil }
        id = number.uint32Value
        object = made
    }

    func remove() { object = nil }

    /// The NSScreen it became, once AppKit has noticed it.
    var screen: NSScreen? {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
    }

    /// Moves them and puts the real monitors back, until logout at the longest: nothing goes into the owner's saved
    /// arrangement. (macOS answers "not implemented" for an app-only change of position.)
    /// Nil when it worked, else what macOS said.
    static func arrange(_ displays: [VirtualDisplay], at origins: [CGPoint], restoring real: [CGDirectDisplayID: CGPoint]) -> String? {
        var config: CGDisplayConfigRef?
        let begun = CGBeginDisplayConfiguration(&config)
        guard begun == .success, let config else { return "begin \(begun.rawValue)" }
        var moves = real
        for (display, origin) in zip(displays, origins) { moves[display.id] = origin }
        for (id, origin) in moves {
            let moved = CGConfigureDisplayOrigin(config, id, Int32(origin.x), Int32(origin.y))
            guard moved == .success else {
                CGCancelDisplayConfiguration(config)
                return "move \(id) \(moved.rawValue)"
            }
        }
        // No fade effect here: asking for one, even of nothing, makes the whole change fail with "not implemented".
        let done = CGCompleteDisplayConfiguration(config, .forSession)
        return done == .success ? nil : "complete \(done.rawValue)"
    }
}

extension NSScreen {
    /// The owner's real monitors: everything but Theo's hidden Studio screens. Use this for anything that follows the
    /// owner's screens (Clicky, numbering, pickers).
    @MainActor static var ownerScreens: [NSScreen] {
        screens.filter { screen in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return true }
            return !StudioDisplays.virtualIDs.contains(id)
        }
    }
}
