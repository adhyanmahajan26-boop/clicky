//
//  HairlineIcon.swift
//  leanring-buddy
//
//  Theo's own icons: 1.5 pt line on a 24 grid, drawn as vectors from the design's markup. Each has one small detail that
//  lights up in the accent when it's selected or live, and it moves only while live: the Studio dot pulses, Clicky's
//  sparkle twinkles, the Routines hand turns, the group chat's dots type.
//

import AppKit
import ClickyCore
import QuartzCore
import SwiftUI

enum HairlineIcons {
    static let markup: [String: String] = [
        "home": #"<path class="fl" d="M4.5 10.3 12 4.5l7.5 5.8v8.2a1.5 1.5 0 0 1-1.5 1.5H6a1.5 1.5 0 0 1-1.5-1.5z"/><path class="ac door" d="M9.6 20v-3.6a2.4 2.4 0 0 1 4.8 0V20"/>"#,
        "search": #"<circle class="fl" cx="10.75" cy="10.75" r="6.25"/><path d="m15.5 15.5 4 4"/><path class="ac glint" d="M7.9 9.6a3.2 3.2 0 0 1 2.3-1.9"/>"#,
        "compose": #"<rect class="fl" x="3.5" y="8" width="13" height="11" rx="3.5"/><path d="M10 5.5V8"/><circle class="f eye" cx="7.6" cy="13.3" r="1"/><circle class="f eye" cx="12.4" cy="13.3" r="1"/><path class="ac" d="M19 3.5v5M16.5 6h5"/>"#,
        "bot": #"<rect class="fl" x="4" y="8" width="16" height="12" rx="4"/><path d="M12 5.8V8"/><circle class="f ac bob" cx="12" cy="4.2" r="1.5"/><circle class="f eye" cx="9" cy="13.4" r="1.1"/><circle class="f eye" cx="15" cy="13.4" r="1.1"/><path d="M10.6 16.6h2.8"/>"#,
        "team": #"<rect class="fl ac" x="9" y="3.5" width="6" height="5" rx="1.6"/><path d="M12 8.5v3M6.5 14.5V13a1.5 1.5 0 0 1 1.5-1.5h8a1.5 1.5 0 0 1 1.5 1.5v1.5"/><rect class="fl" x="3.5" y="14.5" width="6" height="5" rx="1.6"/><rect class="fl" x="14.5" y="14.5" width="6" height="5" rx="1.6"/>"#,
        "group": #"<path d="M15 8V6.5A2.5 2.5 0 0 0 12.5 4h-6A2.5 2.5 0 0 0 4 6.5v4A2.5 2.5 0 0 0 6.5 13H7v2.4L9.4 13"/><path class="fl" d="M11 11.5A2.5 2.5 0 0 1 13.5 9h4a2.5 2.5 0 0 1 2.5 2.5V15a2.5 2.5 0 0 1-2.5 2.5H17V20l-3-2.5h-.5A2.5 2.5 0 0 1 11 15z"/><circle class="f ac d1" cx="13.8" cy="13.25" r=".9"/><circle class="f ac d2" cx="15.5" cy="13.25" r=".9"/><circle class="f ac d3" cx="17.2" cy="13.25" r=".9"/>"#,
        "studio": #"<rect class="fl" x="3" y="4.5" width="18" height="12.5" rx="2.5"/><path d="M12 4.5V17M12 17v3.5M8.5 20.5h7"/><circle class="f ac rec" cx="17.6" cy="7.9" r="1.3"/>"#,
        "routines": #"<path d="M19.5 12A7.5 7.5 0 1 1 17.3 6.7"/><path d="M13.9 6.8h3.6V3.2"/><path class="ac hand" d="M12 8.6V12l2.3 1.5"/>"#,
        "notes": #"<path class="fl" d="M6.5 3.5h7.5l4.5 4.5v10.5a2 2 0 0 1-2 2h-10a2 2 0 0 1-2-2v-13a2 2 0 0 1 2-2z"/><path d="M13.5 3.5V8h5M8 12.5h8M8 16h5"/><path class="ac" d="M8 9h3"/>"#,
        "connectors": #"<path class="ac zap" d="M9 3.5v4M15 3.5v4"/><path class="fl" d="M6.5 7.5h11v3a5.5 5.5 0 0 1-11 0z"/><path d="M12 16v4.5"/>"#,
        "clicky": #"<path class="fl ac spk" d="M10.5 3.5c.6 4.2 2.8 6.4 7 7-4.2.6-6.4 2.8-7 7-.6-4.2-2.8-6.4-7-7 4.2-.6 6.4-2.8 7-7z"/><path class="ac tw" d="M18.5 15.5v4M16.5 17.5h4"/>"#,
        "settings": #"<path d="M4 7.5h7.5M16.5 7.5H20M4 16.5h3.5M12.5 16.5H20"/><circle class="fl ac knob" cx="14" cy="7.5" r="2.5"/><circle class="fl" cx="10" cy="16.5" r="2.5"/>"#,
        "paint": #"<circle class="fl" cx="12" cy="12" r="8"/><path class="f ac" d="M12 4a8 8 0 0 1 0 16z"/>"#,
        "term": #"<rect class="fl" x="3" y="4.5" width="18" height="15" rx="3"/><path d="m7 10 2.5 2L7 14"/><path class="ac caret" d="M12 14.5h4.5"/>"#,
        "key": #"<circle class="fl" cx="8.5" cy="15.5" r="4"/><path d="m11.4 12.6 8.1-8.1M17 7l2.5 2.5M14.6 9.4l1.6 1.6"/><circle class="f ac" cx="8.5" cy="15.5" r="1.2"/>"#,
        "voice": #"<path d="M5 10v4M8.5 7.5v9M15.5 7.5v9M19 10v4"/><path class="ac vb" d="M12 4.5v15"/>"#,
        "lock": #"<path class="fl" d="M12 3.5 19 6v5.5c0 4.2-2.9 7.6-7 9-4.1-1.4-7-4.8-7-9V6z"/><path class="ac" d="m9 12 2.2 2.2 4-4.2"/>"#,
        "info": #"<circle class="fl" cx="12" cy="12" r="8.5"/><path d="M12 11v5"/><circle class="f ac" cx="12" cy="8" r="1.1"/>"#,
        "mic": #"<rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5.5 11a6.5 6.5 0 0 0 13 0M12 17.5V21"/><path class="ac" d="M12 7v3"/>"#,
        "send": #"<path d="M12 19V5M6 11l6-6 6 6"/>"#,
        "plus": #"<path d="M12 5v14M5 12h14"/>"#,
        "at": #"<circle cx="12" cy="12" r="3.5"/><path d="M15.5 12v1.5a2.5 2.5 0 0 0 5 0V12a8.5 8.5 0 1 0-3.5 6.9"/>"#,
        "open": #"<path d="M8 16 16 8M9.5 8H16v6.5"/>"#,
        "share": #"<path d="M12 15V4M8 7.5 12 3.5 16 7.5"/><path d="M5.5 12v6a2 2 0 0 0 2 2h9a2 2 0 0 0 2-2v-6"/>"#,
        "expand": #"<path d="M14 4h6v6M10 20H4v-6M20 4l-7 7M4 20l7-7"/>"#,
        "stop": #"<rect x="7" y="7" width="10" height="10" rx="2"/>"#,
        "check": #"<path d="m5.5 12.5 4.5 4.5 8.5-10"/>"#,
        "close": #"<path d="m6.5 6.5 11 11M17.5 6.5l-11 11"/>"#,
        "eye": #"<path d="M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12z"/><circle cx="12" cy="12" r="2.8"/>"#,
        "chev": #"<path d="m9 6 6 6-6 6"/>"#,
        "more": #"<circle class="f" cx="6" cy="12" r="1.5"/><circle class="f" cx="12" cy="12" r="1.5"/><circle class="f" cx="18" cy="12" r="1.5"/>"#,
        // Three more in the same hand, for Settings pages the set didn't cover.
        "screen": #"<rect class="fl" x="3" y="4.5" width="18" height="12.5" rx="2.5"/><path d="M12 17v3.5M8.5 20.5h7"/><path class="ac" d="M7 8.5h4"/>"#,
        "link": #"<path d="M9.5 14.5 14.5 9.5"/><path d="M11 6.5l1.3-1.3a4.2 4.2 0 0 1 6 6L17 12.5"/><path class="ac" d="M13 17.5l-1.3 1.3a4.2 4.2 0 0 1-6-6L7 11.5"/>"#,
        "updates": #"<circle class="fl" cx="12" cy="12" r="8.5"/><path class="ac" d="M12 7.5v8M8.5 12.5l3.5 3.5 3.5-3.5"/>"#,
    ]

    private static var parsed: [String: [SVGElement]] = [:]

    @MainActor static func elements(_ name: String) -> [SVGElement] {
        if let known = parsed[name] { return known }
        let elements = SVGElement.parse(markup[name] ?? "")
        parsed[name] = elements
        return elements
    }
}

struct HairlineIcon: View {
    let name: String
    var size: CGFloat = 20
    var color: Color = DS.Colors.textSecondary
    /// The accent detail lights up.
    var selected = false
    /// The accent detail lights up and moves.
    var live = false

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if live && DS.Motion.level == .lively {
                // Moving icons run in Core Animation, so they cost nothing per frame.
                LiveIconRepresentable(name: name, size: size, color: NSColor(color), isDark: scheme == .dark)
            } else {
                drawing()
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func drawing() -> some View {
        let elements = HairlineIcons.elements(name)
        let lit = selected || live
        return Canvas { context, canvas in
            let scale = canvas.width / 24
            context.scaleBy(x: scale, y: scale)
            for element in elements {
                let ink = lit && element.has("ac") ? DS.Colors.accent : color
                let shape = Path(element.path)
                if element.has("f") {
                    context.fill(shape, with: .color(ink))
                } else {
                    context.stroke(shape, with: .color(ink), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }
}

private struct LiveIconRepresentable: NSViewRepresentable {
    let name: String
    let size: CGFloat
    let color: NSColor
    let isDark: Bool

    func makeNSView(context: Context) -> LiveIconNSView { LiveIconNSView() }
    func updateNSView(_ view: LiveIconNSView, context: Context) { view.configure(name: name, size: size, color: color) }
}

/// An icon whose accent detail moves: the design's little loops, each its own Core Animation.
private final class LiveIconNSView: NSView {
    private var key = ""
    private var color: NSColor = .labelColor
    private let root = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
        root.isGeometryFlipped = true
        root.anchorPoint = .zero
        layer?.addSublayer(root)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() { rebuild() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        rebuild()
    }

    func configure(name: String, size: CGFloat, color: NSColor) {
        let next = "\(name) \(size)"
        self.color = color
        guard next != key else { return }
        key = next
        rebuild()
    }

    private func rebuild() {
        let parts = key.split(separator: " ")
        guard parts.count == 2, let size = Double(parts[1]).map({ CGFloat($0) }) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        root.sublayers?.forEach { $0.removeFromSuperlayer() }
        root.frame = CGRect(x: 0, y: 0, width: size, height: size)
        root.contentsScale = window?.backingScaleFactor ?? 2
        let k = size / 24
        var ink = color.cgColor
        var accent = NSColor(DS.Colors.accent).cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            ink = color.usingColorSpace(.sRGB)?.cgColor ?? ink
            accent = NSColor(DS.Colors.accent).usingColorSpace(.sRGB)?.cgColor ?? accent
        }
        for element in HairlineIcons.elements(String(parts[0])) {
            let shape = CAShapeLayer()
            shape.anchorPoint = .zero
            shape.bounds = .zero
            shape.position = .zero
            shape.contentsScale = root.contentsScale
            var scale = CGAffineTransform(scaleX: k, y: k)
            shape.path = element.path.copy(using: &scale)
            let tint = element.has("ac") ? accent : ink
            if element.has("f") {
                shape.fillColor = tint
            } else {
                shape.fillColor = nil
                shape.strokeColor = tint
                shape.lineWidth = 1.5 * k
                shape.lineCap = .round
                shape.lineJoin = .round
            }
            root.addSublayer(shape)
            animate(shape, element, k: k)
        }
    }

    private func animate(_ shape: CAShapeLayer, _ element: SVGElement, k: CGFloat) {
        let box = element.path.boundingBoxOfPath
        let center = CGPoint(x: box.midX * k, y: box.midY * k)
        func about(_ point: CGPoint, _ inner: CGAffineTransform) -> CATransform3D {
            CATransform3DMakeAffineTransform(CGAffineTransform(translationX: -point.x, y: -point.y).concatenating(inner).concatenating(CGAffineTransform(translationX: point.x, y: point.y)))
        }
        func loop(_ path: String, _ values: [Any], _ seconds: Double, delay: Double = 0, stepped: Bool = false) {
            let animation = CAKeyframeAnimation(keyPath: path)
            animation.values = values
            animation.duration = seconds
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = false
            animation.timeOffset = seconds - delay
            animation.calculationMode = stepped ? .discrete : .linear
            shape.add(animation, forKey: path)
        }
        func t(_ value: CATransform3D) -> NSValue { NSValue(caTransform3D: value) }
        if element.has("rec") { loop("opacity", [1, 0.25, 1], 1.6) }
        if element.has("glint") { loop("opacity", [1, 0.25, 1], 1.8) }
        if element.has("tw") { loop("opacity", [1, 0.25, 1], 2.4, delay: 0.6) }
        if element.has("zap") { loop("opacity", [1, 0.25], 0.9, stepped: true) }
        if element.has("caret") { loop("opacity", [1, 0], 1, stepped: true) }
        if element.has("bob") { loop("transform", [t(CATransform3DIdentity), t(CATransform3DMakeTranslation(0, -1.2 * k, 0)), t(CATransform3DIdentity)], 1.4) }
        if element.has("knob") { loop("transform", [t(CATransform3DIdentity), t(CATransform3DMakeTranslation(-4 * k, 0, 0)), t(CATransform3DIdentity)], 2.4) }
        if element.has("hand") {
            let pivot = CGPoint(x: 12 * k, y: 12 * k)
            loop("transform", (0...4).map { t(about(pivot, CGAffineTransform(rotationAngle: CGFloat($0) * .pi / 2))) }, 4)
        }
        if element.has("spk") {
            let small = about(center, CGAffineTransform(scaleX: 0.82, y: 0.82).rotated(by: 12 * .pi / 180))
            loop("transform", [t(CATransform3DIdentity), t(small), t(CATransform3DIdentity)], 2.4)
        }
        if element.has("vb") {
            let low = about(center, CGAffineTransform(scaleX: 1, y: 0.35))
            loop("transform", [t(low), t(CATransform3DIdentity), t(low)], 1)
        }
        for (index, dot) in ["d1", "d2", "d3"].enumerated() where element.has(dot) {
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.values = [0.25, 1, 0.25, 0.25]
            animation.keyTimes = [0, 0.3, 0.6, 1]
            animation.duration = 1.2
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = false
            animation.timeOffset = 1.2 - Double(index) * 0.15
            shape.add(animation, forKey: "typing")
        }
    }
}
