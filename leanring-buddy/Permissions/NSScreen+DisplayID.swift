//
//  NSScreen+DisplayID.swift
//  leanring-buddy
//

import AppKit

extension NSScreen {
    /// The Core Graphics display number for this screen.
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) } ?? CGMainDisplayID()
    }
}
