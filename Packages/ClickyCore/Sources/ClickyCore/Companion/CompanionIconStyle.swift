//
//  CompanionIconStyle.swift
//  ClickyCore
//
//  The companion's look (Setup › Spark style): the shape and colour of the
//  big spark and its sub-agent minis, and how fast each spins. Styles in the
//  spirit of each brain (original shapes, not the companies' logos) plus a
//  few custom ones. All are drawn as one filled path, so the Core Animation
//  spin, breathing, orbit and flight work the same for every style.
//

import CoreGraphics
import Foundation
import SwiftUI

public enum CompanionIconStyle: String, CaseIterable, Sendable {
    case claude
    case codex
    case antigravity
    case grok
    case orb
    case star
    case atom

    public var displayName: String {
        switch self {
        case .claude: return "Claude spark"
        case .codex: return "Codex-style rosette"
        case .antigravity: return "Antigravity-style sparkle"
        case .grok: return "Grok-style slash"
        case .orb: return "Orb (custom)"
        case .star: return "Star (custom)"
        case .atom: return "Atom (custom)"
        }
    }

    /// Fill (sRGB hex) and glow.
    public var fillHex: UInt32 {
        switch self {
        case .claude: return 0xD97757
        case .codex: return 0xE8ECEF
        case .antigravity: return 0x5B8CFF
        case .grok: return 0xF2F2F2
        case .orb: return 0x8B7CF6
        case .star: return 0xF5C542
        case .atom: return 0x3FC1C9
        }
    }

    public var glowHex: UInt32 {
        switch self {
        case .codex: return 0x10A37F
        case .antigravity: return 0xE65AD1
        case .grok: return 0x9AA0A6
        default: return fillHex
        }
    }

    /// Thinking spin speed relative to the Claude spark (the rosette turns slowly, the slash fast).
    public var spinSpeedMultiplier: Double {
        switch self {
        case .claude: return 1
        case .codex: return 0.55
        case .antigravity: return 0.8
        case .grok: return 1.6
        case .orb: return 0.7
        case .star: return 0.9
        case .atom: return 1.2
        }
    }

    public static func color(_ hex: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    /// The filled shape in `rect` (y-down, like SwiftUI).
    public func path(in rect: CGRect) -> CGPath {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let path = CGMutablePath()
        switch self {
        case .claude:
            return ClaudeSparkShape().path(in: rect).cgPath

        case .codex:
            // Six rounded petals around a round centre (a rosette).
            for index in 0..<6 {
                let angle = CGFloat(index) * .pi / 3
                let petal = CGRect(x: -radius * 0.22, y: -radius * 0.92, width: radius * 0.44, height: radius * 0.78)
                var transform = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: angle)
                path.addPath(CGPath(roundedRect: petal, cornerWidth: radius * 0.22, cornerHeight: radius * 0.22, transform: &transform))
            }
            path.addEllipse(in: CGRect(x: center.x - radius * 0.2, y: center.y - radius * 0.2, width: radius * 0.4, height: radius * 0.4))

        case .antigravity:
            // A four-point sparkle with a smaller one tucked at its corner.
            addSparkle(to: path, center: center, radius: radius * 0.92, waist: 0.18)
            addSparkle(to: path, center: CGPoint(x: center.x + radius * 0.62, y: center.y - radius * 0.62), radius: radius * 0.3, waist: 0.22)

        case .grok:
            // A ring cut by a bold diagonal slash.
            let ring = CGMutablePath()
            ring.addEllipse(in: CGRect(x: center.x - radius * 0.8, y: center.y - radius * 0.8, width: radius * 1.6, height: radius * 1.6))
            path.addPath(ring.copy(strokingWithWidth: radius * 0.18, lineCap: .round, lineJoin: .round, miterLimit: 1))
            let slash = CGMutablePath()
            slash.move(to: CGPoint(x: center.x - radius * 0.95, y: center.y + radius * 0.95))
            slash.addLine(to: CGPoint(x: center.x + radius * 0.95, y: center.y - radius * 0.95))
            path.addPath(slash.copy(strokingWithWidth: radius * 0.24, lineCap: .round, lineJoin: .round, miterLimit: 1))

        case .orb:
            // A planet with an off-centre ring (the gap makes the spin visible).
            path.addEllipse(in: CGRect(x: center.x - radius * 0.48, y: center.y - radius * 0.48, width: radius * 0.96, height: radius * 0.96))
            let ring = CGMutablePath()
            ring.addArc(center: center, radius: radius * 0.82, startAngle: 0.35, endAngle: .pi * 2 - 0.35, clockwise: false)
            path.addPath(ring.copy(strokingWithWidth: radius * 0.14, lineCap: .round, lineJoin: .round, miterLimit: 1))

        case .star:
            // A soft five-point star.
            var points: [CGPoint] = []
            for index in 0..<10 {
                let angle = CGFloat(index) * .pi / 5 - .pi / 2
                let length = index.isMultiple(of: 2) ? radius * 0.98 : radius * 0.45
                points.append(CGPoint(x: center.x + cos(angle) * length, y: center.y + sin(angle) * length))
            }
            path.addLines(between: points)
            path.closeSubpath()

        case .atom:
            // Three elliptical orbits around a nucleus.
            path.addEllipse(in: CGRect(x: center.x - radius * 0.18, y: center.y - radius * 0.18, width: radius * 0.36, height: radius * 0.36))
            for index in 0..<3 {
                let orbit = CGMutablePath()
                var transform = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: CGFloat(index) * .pi / 3)
                orbit.addEllipse(in: CGRect(x: -radius * 0.95, y: -radius * 0.36, width: radius * 1.9, height: radius * 0.72), transform: transform)
                path.addPath(orbit.copy(strokingWithWidth: radius * 0.09, lineCap: .round, lineJoin: .round, miterLimit: 1))
            }
        }
        return path
    }

    private func addSparkle(to path: CGMutablePath, center: CGPoint, radius: CGFloat, waist: CGFloat) {
        // Four tips joined by curves that pinch in to `waist` of the radius.
        let tips = (0..<4).map { index -> CGPoint in
            let angle = CGFloat(index) * .pi / 2 - .pi / 2
            return CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
        }
        path.move(to: tips[0])
        for index in 0..<4 {
            let next = tips[(index + 1) % 4]
            let control = CGPoint(x: center.x + (tips[index].x + next.x - 2 * center.x) * waist,
                                  y: center.y + (tips[index].y + next.y - 2 * center.y) * waist)
            path.addQuadCurve(to: next, control: control)
        }
        path.closeSubpath()
    }
}

/// A SwiftUI shape for previews (Setup's style picker).
public struct CompanionIconShape: Shape {
    public let style: CompanionIconStyle
    public init(style: CompanionIconStyle) { self.style = style }
    public func path(in rect: CGRect) -> Path { Path(style.path(in: rect)) }
}
