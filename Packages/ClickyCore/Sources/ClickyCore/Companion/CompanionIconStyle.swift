//
//  CompanionIconStyle.swift
//  ClickyCore
//
//  The companion's look (Setup › Spark style): the big spark's shape, its
//  gradient, an optional halo ring, the sub-agent minis' colour, and how it
//  moves while thinking (spin speed, a pulse, a twinkle, the halo turning
//  the other way). Styles in the spirit of each brain (original shapes, not
//  the companies' logos) plus custom ones. Shapes are single filled paths so
//  the Core Animation spin, breathing, orbit and flight work for every style.
//

import CoreGraphics
import Foundation
import SwiftUI

public enum CompanionIconStyle: String, CaseIterable, Sendable {
    case claude
    case codex
    case antigravity
    case grok
    case nebula
    case prism
    case comet
    case atom

    public var displayName: String {
        switch self {
        case .claude: return "Claude spark"
        case .codex: return "Codex-style knot"
        case .antigravity: return "Antigravity-style sparkle"
        case .grok: return "Grok-style horizon"
        case .nebula: return "Nebula swirl"
        case .prism: return "Prism"
        case .comet: return "Comet"
        case .atom: return "Atom"
        }
    }

    public enum Halo: Sendable {
        case none
        /// A dashed ring that turns the other way while thinking.
        case dashedRing
        /// A ring of dots that turns the other way while thinking.
        case dotRing
    }

    /// Gradient stops (sRGB hex), top-left to bottom-right; one stop = a solid fill.
    public var gradientHexes: [UInt32] {
        switch self {
        case .claude: return [0xD97757]
        case .codex: return [0xFFFFFF, 0xB8F2DE, 0x10A37F]
        case .antigravity: return [0x4F8DFD, 0x9B6BF6, 0xF25FAE]
        case .grok: return [0xFFFFFF, 0xC9CDD2, 0x6E7681]
        case .nebula: return [0xB06CFF, 0x5A7BFF, 0x37E2E0]
        case .prism: return [0xFFD45A, 0xFF7A59, 0xE24BD0]
        case .comet: return [0xFFF1A8, 0xFFB238, 0xFF5E3A]
        case .atom: return [0x7CF7C8, 0x2EC4D6, 0x2F7BFF]
        }
    }

    /// The solid fill (the first stop) and glow.
    public var fillHex: UInt32 { gradientHexes[gradientHexes.count / 2] }

    public var glowHex: UInt32 {
        switch self {
        case .claude: return 0xD97757
        case .codex: return 0x10A37F
        case .antigravity: return 0xB86BF0
        case .grok: return 0xFFFFFF
        case .nebula: return 0x6D7BFF
        case .prism: return 0xFF7A59
        case .comet: return 0xFF9A3A
        case .atom: return 0x2EC4D6
        }
    }

    /// The sub-agent minis' colour (the gradient's last stop: they read as "helpers").
    public var miniHex: UInt32 { gradientHexes.last ?? fillHex }

    public var halo: Halo {
        switch self {
        case .codex, .nebula: return .dashedRing
        case .grok, .atom: return .dotRing
        default: return .none
        }
    }

    /// Thinking spin speed relative to the Claude spark.
    public var spinSpeedMultiplier: Double {
        switch self {
        case .claude: return 1
        case .codex: return 0.45
        case .antigravity: return 0.8
        case .grok: return 1.7
        case .nebula: return 1.1
        case .prism: return 0.6
        case .comet: return 2.2
        case .atom: return 1.3
        }
    }

    /// While thinking: a heartbeat pulse in scale.
    public var pulsesWhileThinking: Bool { [.codex, .grok, .nebula, .atom].contains(self) }
    /// While thinking: a twinkle in brightness.
    public var twinklesWhileThinking: Bool { [.antigravity, .prism, .comet].contains(self) }

    public static func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    /// The filled shape in `rect` (y-down, like SwiftUI).
    public func path(in rect: CGRect) -> CGPath {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let path = CGMutablePath()
        func stroke(_ shape: CGPath, _ width: CGFloat) {
            path.addPath(shape.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 1))
        }
        switch self {
        case .claude:
            return ClaudeSparkShape().path(in: rect).cgPath

        case .codex:
            // Three interlocking rounded links at 0°, 60° and 120°: a hexagonal knot.
            for index in 0..<3 {
                var transform = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: CGFloat(index) * .pi / 3)
                let link = CGPath(roundedRect: CGRect(x: -radius * 0.82, y: -radius * 0.34, width: radius * 1.64, height: radius * 0.68),
                                  cornerWidth: radius * 0.34, cornerHeight: radius * 0.34, transform: &transform)
                stroke(link, radius * 0.17)
            }

        case .antigravity:
            // A four-point sparkle, a small companion sparkle, and a dot: a little constellation.
            addSparkle(to: path, center: CGPoint(x: center.x - radius * 0.08, y: center.y + radius * 0.08), radius: radius * 0.86, waist: 0.16)
            addSparkle(to: path, center: CGPoint(x: center.x + radius * 0.62, y: center.y - radius * 0.62), radius: radius * 0.32, waist: 0.2)
            path.addEllipse(in: CGRect(x: center.x - radius * 0.86, y: center.y - radius * 0.86, width: radius * 0.2, height: radius * 0.2))

        case .grok:
            // An event horizon: a thick ring, a slash cutting across it, and a bright core.
            let ring = CGMutablePath()
            ring.addEllipse(in: CGRect(x: center.x - radius * 0.72, y: center.y - radius * 0.72, width: radius * 1.44, height: radius * 1.44))
            stroke(ring, radius * 0.2)
            let slash = CGMutablePath()
            slash.move(to: CGPoint(x: center.x - radius * 0.98, y: center.y + radius * 0.98))
            slash.addLine(to: CGPoint(x: center.x + radius * 0.98, y: center.y - radius * 0.98))
            stroke(slash, radius * 0.2)
            path.addEllipse(in: CGRect(x: center.x - radius * 0.16, y: center.y - radius * 0.16, width: radius * 0.32, height: radius * 0.32))

        case .nebula:
            // Three tapered arms curling out of a core: a galaxy swirl.
            path.addEllipse(in: CGRect(x: center.x - radius * 0.26, y: center.y - radius * 0.26, width: radius * 0.52, height: radius * 0.52))
            for index in 0..<3 {
                let start = CGFloat(index) * 2 * .pi / 3
                let arm = CGMutablePath()
                for step in 0...14 {
                    let t = CGFloat(step) / 14
                    let angle = start + t * 2.2
                    let distance = radius * (0.2 + 0.78 * t)
                    let point = CGPoint(x: center.x + cos(angle) * distance, y: center.y + sin(angle) * distance)
                    if step == 0 { arm.move(to: point) } else { arm.addLine(to: point) }
                }
                stroke(arm, radius * 0.2)
            }

        case .prism:
            // A triangle frame with a smaller triangle floating inside, like a prism's facets.
            func triangle(_ size: CGFloat, _ rotation: CGFloat) -> CGPath {
                let triangle = CGMutablePath()
                for index in 0..<3 {
                    let angle = rotation + CGFloat(index) * 2 * .pi / 3 - .pi / 2
                    let point = CGPoint(x: center.x + cos(angle) * size, y: center.y + sin(angle) * size)
                    if index == 0 { triangle.move(to: point) } else { triangle.addLine(to: point) }
                }
                triangle.closeSubpath()
                return triangle
            }
            stroke(triangle(radius * 0.92, 0), radius * 0.16)
            path.addPath(triangle(radius * 0.34, .pi))

        case .comet:
            // A round head with a tapering tail sweeping behind it.
            path.addEllipse(in: CGRect(x: center.x + radius * 0.3, y: center.y - radius * 0.62, width: radius * 0.62, height: radius * 0.62))
            for (offset, width) in [(0.0, 0.22), (0.18, 0.12), (-0.18, 0.1)] as [(CGFloat, CGFloat)] {
                let tail = CGMutablePath()
                tail.move(to: CGPoint(x: center.x + radius * 0.5, y: center.y - radius * 0.2 + radius * offset))
                tail.addQuadCurve(to: CGPoint(x: center.x - radius * 0.95, y: center.y + radius * 0.7 + radius * offset),
                                  control: CGPoint(x: center.x - radius * 0.1, y: center.y + radius * 0.55 + radius * offset))
                stroke(tail, radius * width)
            }

        case .atom:
            // Three elliptical orbits around a nucleus.
            path.addEllipse(in: CGRect(x: center.x - radius * 0.2, y: center.y - radius * 0.2, width: radius * 0.4, height: radius * 0.4))
            for index in 0..<3 {
                let orbit = CGMutablePath()
                let transform = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: CGFloat(index) * .pi / 3)
                orbit.addEllipse(in: CGRect(x: -radius * 0.95, y: -radius * 0.36, width: radius * 1.9, height: radius * 0.72), transform: transform)
                stroke(orbit, radius * 0.1)
            }
        }
        return path
    }

    /// The halo ring's path (stroked by the view), a little outside the shape.
    public func haloPath(in rect: CGRect) -> CGPath? {
        guard halo != .none else { return nil }
        let inset = rect.insetBy(dx: -rect.width * 0.22, dy: -rect.height * 0.22)
        return CGPath(ellipseIn: inset, transform: nil)
    }

    private func addSparkle(to path: CGMutablePath, center: CGPoint, radius: CGFloat, waist: CGFloat) {
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

/// A SwiftUI preview of a style (Setup's picker): the gradient-filled shape and its halo.
public struct CompanionIconPreview: View {
    public let style: CompanionIconStyle
    public init(style: CompanionIconStyle) { self.style = style }

    public var body: some View {
        let colors = style.gradientHexes.map { Color(cgColor: CompanionIconStyle.color($0)) }
        ZStack {
            if style.halo != .none {
                Circle()
                    .stroke(Color(cgColor: CompanionIconStyle.color(style.glowHex, alpha: 0.6)),
                            style: StrokeStyle(lineWidth: 1.5, dash: style.halo == .dashedRing ? [4, 3] : [0.1, 5], dashPhase: 0))
                    .padding(-6)
            }
            CompanionIconShape(style: style)
                .fill(LinearGradient(colors: colors.count > 1 ? colors : colors + colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: Color(cgColor: CompanionIconStyle.color(style.glowHex)).opacity(0.8), radius: 5)
        }
    }
}

public struct CompanionIconShape: Shape {
    public let style: CompanionIconStyle
    public init(style: CompanionIconStyle) { self.style = style }
    public func path(in rect: CGRect) -> Path { Path(style.path(in: rect)) }
}
