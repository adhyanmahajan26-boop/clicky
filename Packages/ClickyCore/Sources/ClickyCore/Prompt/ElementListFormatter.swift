//
//  ElementListFormatter.swift
//  ClickyCore
//
//  The text that introduces each screenshot to the model. P1b appends
//  element-list lines under the header (x,y = top-left, @x,y = centre).
//

import Foundation

public enum ElementListFormatter {
    /// `SCREEN 2 "DELL S2725QC (2)" (left of main) image 1456x819 px`
    /// `SCREEN 1 "DELL S3425DW" (main, cursor here) image 2576x1078 px`
    public static func header(screenNumber: Int, displayName: String, positionDescription: String, isCursorScreen: Bool, imageSize: PixelSize) -> String {
        let quotedName = displayName.replacingOccurrences(of: "\"", with: "'")
        let position = isCursorScreen ? "\(positionDescription), cursor here" : positionDescription
        return "SCREEN \(screenNumber) \"\(quotedName)\" (\(position)) image \(imageSize.width)x\(imageSize.height) px"
    }
}
