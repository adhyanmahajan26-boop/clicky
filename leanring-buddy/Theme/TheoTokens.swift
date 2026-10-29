//
//  TheoTokens.swift
//  leanring-buddy
//
//  Theo's colours and corner sizes for its dark floating surfaces (the menu-bar
//  panel, diagnostics, small indicators), plus the pointing-hand cursor modifier.
//  `DS` is the short name the views use.
//

import AppKit
import SwiftUI

enum DS {
    enum Colors {
        static let background = Color(white: 0.075)
        static let surface = Color(white: 0.12)
        static let surface1 = Color(white: 0.095)
        static let surface3 = Color(white: 0.17)
        static let borderSubtle = Color.white.opacity(0.09)
        static let textPrimary = Color.white.opacity(0.94)
        static let textSecondary = Color.white.opacity(0.66)
        static let textTertiary = Color.white.opacity(0.44)
        static let textOnAccent = Color.white
        /// Theo's coral, from the spark.
        static let accent = Color(red: 0.93, green: 0.42, blue: 0.36)
        static let accentText = Color(red: 1.0, green: 0.62, blue: 0.52)
        static let overlayCompanionOrange = Color(red: 0.85, green: 0.47, blue: 0.34)
        static let blue = Color(red: 0.36, green: 0.56, blue: 1.0)
        static let blue400 = Color(red: 0.45, green: 0.63, blue: 1.0)
        static let success = Color(red: 0.30, green: 0.80, blue: 0.52)
        static let warning = Color(red: 0.98, green: 0.72, blue: 0.27)
        static let destructiveText = Color(red: 1.0, green: 0.45, blue: 0.42)
    }

    enum CornerRadius {
        static let small: CGFloat = 6
        static let medium: CGFloat = 10
        static let large: CGFloat = 14
    }
}

extension View {
    /// Shows the pointing hand while the pointer is over this view.
    func pointerCursor(isEnabled: Bool = true) -> some View {
        onHover { isInside in
            guard isEnabled else { return }
            if isInside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}
