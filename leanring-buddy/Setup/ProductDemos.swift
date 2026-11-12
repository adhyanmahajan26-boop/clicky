//
//  ProductDemos.swift
//  leanring-buddy
//
//  The short looping demos a new user sees for each product (Setup › Pick products, Settings › Products, and a product's
//  own page while it's off). Each is drawn live in SwiftUI from a script (ClickyCore `ProductDemoClock`), so it follows
//  the look and the accent, costs nothing while hidden, and needs no video files. They're illustrations: no mic, no
//  screen capture, nothing runs.
//

import ClickyCore
import SwiftUI

struct ProductDemoView: View {
    let product: TheoProduct
    /// Its width; the height follows (the demos are drawn on a 320 × 200 stage).
    var width: CGFloat = 320
    @State private var startedAt = Date()

    static let stage = CGSize(width: 320, height: 200)

    /// A test profile can hold a demo at one moment for a screenshot (`test.demos.time`, seconds into the loop).
    private var frozenTime: Double? {
        guard TheoProfile.isTest, let value = UserDefaults.standard.object(forKey: "test.demos.time") as? Double else { return nil }
        return value
    }

    var body: some View {
        let scale = width / Self.stage.width
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
            let clock = ProductDemoClock(product)
            let time = frozenTime ?? clock.moment(elapsed: context.date.timeIntervalSince(startedAt))
            stage(time: time)
                .frame(width: Self.stage.width, height: Self.stage.height)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: width, height: Self.stage.height * scale, alignment: .topLeading)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(product.title) demo")
        .accessibilityHint(product.tagline)
    }

    @ViewBuilder private func stage(time: Double) -> some View {
        ZStack {
            LinearGradient(colors: [DS.Colors.accentSoft, DS.Colors.background], startPoint: .topLeading, endPoint: .bottomTrailing)
            switch product {
            case .dictation: DictationDemoStage(time: time)
            case .clicky: ClickyDemoStage(time: time)
            case .theo: TheoDemoStage(time: time)
            }
        }
    }
}

// MARK: - Shared pieces

/// A small window: title bar with three dots and a title.
private struct DemoWindow<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(DS.Colors.borderStrong).frame(width: 5, height: 5) }
                Spacer()
                Text(title).font(.system(size: 7.5, weight: .semibold)).foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Color.clear.frame(width: 23, height: 5)
            }
            .padding(.horizontal, 7).frame(height: 15)
            Rectangle().fill(DS.Colors.borderSubtle).frame(height: 0.5)
            content()
        }
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(DS.Colors.surface1))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(DS.Colors.borderStrong, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    }
}

private struct DemoKeyCap: View {
    let label: String
    let pressed: Bool
    var body: some View {
        Text(label).font(.system(size: 7.5, weight: .semibold, design: .rounded))
            .foregroundColor(pressed ? DS.Colors.textOnAccent : DS.Colors.textPrimary)
            .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 15)
            .background(RoundedRectangle(cornerRadius: 3.5, style: .continuous).fill(pressed ? DS.Colors.accent : DS.Colors.surface))
            .overlay(RoundedRectangle(cornerRadius: 3.5, style: .continuous).strokeBorder(DS.Colors.borderStrong, lineWidth: 0.5))
            .offset(y: pressed ? 1 : 0)
    }
}

private struct DemoBubble: View {
    let text: String
    var mine = false
    var body: some View {
        Text(text).font(.system(size: 7.5)).foregroundColor(mine ? DS.Colors.textOnAccent : DS.Colors.textPrimary)
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(mine ? DS.Colors.accent : DS.Colors.surface))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Fades a piece in at `from` and out at `until`.
private func shown(_ time: Double, from: Double, until: Double = .infinity, fade: Double = 0.25) -> Double {
    min(ProductDemoClock.progress(time, from: from, to: from + fade), 1 - ProductDemoClock.progress(time, from: until, to: until + fade))
}

private typealias Clock = ProductDemoClock

// MARK: - Dictation

/// Hold Control + Fn, talk, let go: the rough words go to Sarvam, come back tidied, and are typed at the cursor.
private struct DictationDemoStage: View {
    let time: Double

    private static let spoken = "um so the demo is uh ready for friday i'll send the link tonight"
    private static let written = "The demo is ready for Friday. I'll send the link tonight."

    private var holding: Bool { time > 0.6 && time < 3.5 }

    var body: some View {
        ZStack(alignment: .top) {
            DemoWindow(title: "New message") {
                VStack(alignment: .leading, spacing: 0) {
                    field("To", "Priya")
                    field("Subject", "Friday demo")
                    HStack(alignment: .top, spacing: 0) {
                        Text(Clock.typed(Self.written, progress: Clock.progress(time, from: 4.0, to: 5.9)))
                            .font(.system(size: 8.5)).foregroundColor(DS.Colors.textPrimary)
                        Rectangle().fill(DS.Colors.accent).frame(width: 1, height: 10)
                            .opacity(Int(time * 2.4).isMultiple(of: 2) ? 1 : 0.15)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(8)
                    Spacer(minLength: 0)
                }
            }
            .frame(width: 236, height: 116)
            .padding(.top, 14)

            keyBadge.frame(maxWidth: .infinity, alignment: .trailing).padding(.top, 6).padding(.trailing, 8)

            VStack(spacing: 5) {
                Spacer()
                Text(Clock.typed(Self.spoken, progress: Clock.progress(time, from: 1.0, to: 3.3)))
                    .font(.system(size: 7.5).italic()).foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 230).lineLimit(1).truncationMode(.head)
                    .opacity(shown(time, from: 1.0, until: 3.8))
                pill.opacity(shown(time, from: 0.75, until: 4.1, fade: 0.15))
                HStack(spacing: 4) {
                    Text("Hold").font(.system(size: 7.5)).foregroundColor(DS.Colors.textSecondary)
                    DemoKeyCap(label: "control", pressed: holding)
                    DemoKeyCap(label: "fn", pressed: holding)
                    Text(holding ? "talking…" : time >= 3.5 && time < 6.2 ? "let go" : "in any app").font(.system(size: 7.5)).foregroundColor(DS.Colors.textSecondary)
                }
                .padding(.bottom, 9)
            }
        }
    }

    private func field(_ label: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(label).font(.system(size: 7.5)).foregroundColor(DS.Colors.textTertiary).frame(width: 34, alignment: .leading)
                Text(value).font(.system(size: 8)).foregroundColor(DS.Colors.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 8).frame(height: 15)
            Rectangle().fill(DS.Colors.borderSubtle).frame(height: 0.5)
        }
    }

    private var keyBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "key.fill").font(.system(size: 6.5, weight: .bold))
            Text("Sarvam key").font(.system(size: 7, weight: .semibold))
        }
        .foregroundColor(DS.Colors.warningText)
        .padding(.horizontal, 5).frame(height: 13)
        .background(Capsule().fill(DS.Colors.warning.opacity(0.16)))
    }

    private var pill: some View {
        HStack(spacing: 2) {
            if time < 3.45 {
                ForEach(0..<14, id: \.self) { index in
                    let wave = abs(sin(time * 7 + Double(index) * 0.75)) * 0.75 + 0.25
                    Capsule().fill(Color.white.opacity(0.9)).frame(width: 2, height: 3 + 9 * wave)
                }
            } else {
                Text("Tidying up…").font(.system(size: 7.5, weight: .medium)).foregroundColor(.white.opacity(0.9))
            }
        }
        .padding(.horizontal, 9).frame(height: 20)
        .background(Capsule().fill(Color.black.opacity(0.85)))
    }
}

// MARK: - Clicky

/// "Hey Theo, how do I save this as a PDF?": the spark thinks, flies to Export, circles it and says what to do.
private struct ClickyDemoStage: View {
    let time: Double

    private static let rest = CGPoint(x: 62, y: 150)
    private static let target = CGPoint(x: 236, y: 46)

    var body: some View {
        ZStack(alignment: .topLeading) {
            DemoWindow(title: "Q3 report.pdf") {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 5) {
                        Spacer()
                        toolbarButton("Share")
                        toolbarButton("Export")
                        toolbarButton("•••")
                    }
                    .padding(.horizontal, 7).frame(height: 20)
                    Rectangle().fill(DS.Colors.borderSubtle).frame(height: 0.5)
                    VStack(alignment: .leading, spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(DS.Colors.textPrimary.opacity(0.55)).frame(width: 110, height: 6)
                        ForEach([200.0, 180, 205, 150, 190, 120], id: \.self) { width in
                            RoundedRectangle(cornerRadius: 1.5).fill(DS.Colors.borderStrong).frame(width: width, height: 4)
                        }
                    }
                    .padding(10)
                    Spacer(minLength: 0)
                }
            }
            .frame(width: 270, height: 150)
            .offset(x: 25, y: 14)

            // The circle Clicky draws around the button.
            Ellipse().trim(from: 0, to: Clock.progress(time, from: 3.6, to: 4.2))
                .stroke(DS.Colors.overlayCompanionOrange, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .frame(width: 40, height: 20)
                .position(x: Self.target.x, y: Self.target.y)
                .opacity(shown(time, from: 3.6, until: 7.4, fade: 0.05))

            DemoBubble(text: Clock.typed("Hey Theo, how do I save this as a PDF?", progress: Clock.progress(time, from: 0.4, to: 1.6)), mine: true)
                .frame(width: 150, alignment: .leading)
                .position(x: 165, y: 178)
                .opacity(shown(time, from: 0.35, until: 6.8))

            DemoBubble(text: Clock.typed("Click Export, then choose PDF.", progress: Clock.progress(time, from: 4.1, to: 5.1)))
                .frame(width: 120, alignment: .leading)
                .position(x: Self.target.x - 40, y: Self.target.y + 34)
                .opacity(shown(time, from: 4.0, until: 7.4))

            spark
        }
        .frame(width: ProductDemoView.stage.width, height: ProductDemoView.stage.height, alignment: .topLeading)
    }

    private func toolbarButton(_ title: String) -> some View {
        Text(title).font(.system(size: 7.5, weight: .medium)).foregroundColor(DS.Colors.textPrimary)
            .padding(.horizontal, 6).frame(height: 13)
            .background(RoundedRectangle(cornerRadius: 3.5, style: .continuous).fill(DS.Colors.hover))
    }

    /// Along an arc from where it rests to the button.
    private var sparkPosition: CGPoint {
        let flight = Clock.progress(time, from: 2.6, to: 3.6)
        let eased = flight * flight * (3 - 2 * flight)
        let start = Self.rest, end = CGPoint(x: Self.target.x + 22, y: Self.target.y + 8)
        let control = CGPoint(x: (start.x + end.x) / 2, y: min(start.y, end.y) - 40)
        let back = Clock.progress(time, from: 7.4, to: 7.9)
        let a = 1 - eased
        let flying = CGPoint(x: a * a * start.x + 2 * a * eased * control.x + eased * eased * end.x,
                             y: a * a * start.y + 2 * a * eased * control.y + eased * eased * end.y)
        return CGPoint(x: flying.x + (start.x - flying.x) * back, y: flying.y + (start.y - flying.y) * back)
    }

    private var spark: some View {
        let thinking = time > 1.7 && time < 2.7
        let breathe = 1 + 0.08 * sin(time * 3)
        return ClaudeSparkShape()
            .fill(DS.Colors.overlayCompanionOrange)
            .frame(width: 16, height: 16)
            .rotationEffect(.degrees(thinking ? (time - 1.7) * 540 : 0))
            .scaleEffect(breathe)
            .shadow(color: DS.Colors.overlayCompanionOrange.opacity(0.55), radius: 4)
            .position(sparkPosition)
    }
}

// MARK: - Theo

/// A message to Theo becomes a coding run, which comes back with a draft PR.
private struct TheoDemoStage: View {
    let time: Double

    var body: some View {
        DemoWindow(title: "Theo") {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    member("Theo", TileColors.indigo, selected: true)
                    member("Builder", TileColors.lime)
                    member("Researcher", TileColors.sky)
                    member("Clicky", TileColors.ember)
                    Spacer()
                }
                .padding(6).frame(width: 74).background(DS.Colors.sidebar)
                Rectangle().fill(DS.Colors.borderSubtle).frame(width: 0.5)
                chat
            }
        }
        .frame(width: 290, height: 176)
    }

    private func member(_ name: String, _ colors: [Color], selected: Bool = false) -> some View {
        HStack(spacing: 4) {
            Circle().fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)).frame(width: 11, height: 11)
                .overlay(Text(String(name.prefix(1))).font(.system(size: 6, weight: .bold)).foregroundColor(.white))
            Text(name).font(.system(size: 7, weight: selected ? .semibold : .regular)).foregroundColor(DS.Colors.textPrimary).lineLimit(1)
        }
        .padding(.horizontal, 3).frame(height: 15, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 4).fill(selected ? DS.Colors.selected : .clear))
    }

    private var chat: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack { Spacer(minLength: 40); DemoBubble(text: "Fix the failing login test in my app", mine: true) }
                .opacity(shown(time, from: 0.5))
            if time > 1.2 && time < 2.0 {
                typingDots
            }
            DemoBubble(text: "On it. Handing it to Claude Code.").opacity(shown(time, from: 2.0))
            runCard.opacity(shown(time, from: 2.8))
            DemoBubble(text: "Done. The test passes and the PR is ready.").opacity(shown(time, from: 7.0))
            Spacer(minLength: 0)
        }
        .padding(7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var typingDots: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<3, id: \.self) { index in
                Circle().fill(DS.Colors.textTertiary).frame(width: 3.5, height: 3.5)
                    .opacity(0.35 + 0.65 * abs(sin(time * 6 - Double(index) * 0.7)))
            }
        }
        .padding(.horizontal, 6).frame(height: 14)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DS.Colors.surface))
    }

    private static let steps = ["Branch", "Code", "Tests", "Push", "PR"]

    private var runCard: some View {
        let progress = Clock.progress(time, from: 3.0, to: 6.4)
        let done = time >= 6.4
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: done ? "checkmark.circle.fill" : "terminal.fill").font(.system(size: 7.5))
                    .foregroundColor(done ? DS.Colors.success : DS.Colors.textSecondary)
                Text(done ? "Draft PR opened · 3 files" : "Claude Code · fix-login-test").font(.system(size: 7.5, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                Spacer()
                if !done { Text(String(format: "0:%02d", Int(progress * 41))).font(.system(size: 6.5).monospacedDigit()).foregroundColor(DS.Colors.textTertiary) }
            }
            HStack(spacing: 2.5) {
                ForEach(0..<5, id: \.self) { index in
                    let fill = min(1, max(0, progress * 5 - Double(index)))
                    GeometryReader { box in
                        ZStack(alignment: .leading) {
                            Capsule().fill(DS.Colors.borderStrong)
                            Capsule().fill(done ? DS.Colors.success : DS.Colors.accent).frame(width: box.size.width * fill)
                        }
                    }
                    .frame(height: 2.5)
                }
            }
            HStack(spacing: 2.5) {
                ForEach(Self.steps, id: \.self) { step in
                    Text(step).font(.system(size: 5.5)).foregroundColor(DS.Colors.textTertiary).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DS.Colors.surface))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(DS.Colors.borderSubtle, lineWidth: 0.5))
    }
}
