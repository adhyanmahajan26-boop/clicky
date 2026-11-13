//
//  SparkOverlay.swift
//  leanring-buddy
//
//  The see-through layer over every screen that carries Theo's spark: it rides
//  next to the pointer (or sits docked on Theo's screen), turns into a level
//  meter while you talk, flies to whatever Theo points at and back, and hosts
//  the live marks and the spoken-caption bubble. One click-through window per
//  screen; only the screen the spark is on draws it.
//

import AppKit
import ClickyCore
import Combine
import SwiftUI

/// A borderless, click-through panel covering one screen, above everything. A non-activating panel (like the
/// notch) rather than a plain window: with Theo in the Dock (a regular app) a plain window can be kept off other
/// apps' full-screen Spaces, and the spark then isn't at the pointer there.
final class SparkOverlayWindow: NSPanel {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Puts a spark layer on each screen, and rebuilds them when screens change.
@MainActor
final class SparkOverlayManager {
    private var windows: [SparkOverlayWindow] = []
    /// The first show of a launch fades the spark in and says hello.
    var hasShownOverlayBefore = false
    private weak var companionManager: CompanionManager?
    private var screensObserver: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []

    init() {
        screensObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isShowingOverlay(), let companionManager = self.companionManager else { return }
                self.showOverlay(onScreens: NSScreen.ownerScreens, companionManager: companionManager)
            }
        }
        // Waking, unlocking or changing Space can leave the layer ordered out while Theo still counts it as shown.
        // Put it back in front each time (cheap: only windows that aren't visible are touched).
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification,
                     NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification] {
            workspaceObservers.append(workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.bringBackIfOrderedOut() }
            })
        }
    }

    /// Re-fronts any spark window macOS took off screen while the layer is meant to be up.
    func bringBackIfOrderedOut() {
        for window in windows where !window.isVisible {
            window.orderFrontRegardless()
        }
    }

    func showOverlay(onScreens screens: [NSScreen], companionManager: CompanionManager) {
        self.companionManager = companionManager
        hideOverlay()
        let greets = !hasShownOverlayBefore
        hasShownOverlayBefore = true
        for screen in screens {
            let window = SparkOverlayWindow(screen: screen)
            let host = NSHostingView(rootView: SparkScreenLayer(screenFrame: screen.frame, greets: greets, companionManager: companionManager))
            host.sizingOptions = []
            host.frame = CGRect(origin: .zero, size: screen.frame.size)
            window.contentView = host
            windows.append(window)
            window.orderFrontRegardless()
        }
    }

    func hideOverlay() {
        companionManager?.sparkClickTarget.reset()
        for window in windows {
            window.orderOut(nil)
            window.contentView = nil
        }
        windows.removeAll()
    }

    func fadeOutAndHideOverlay(duration: TimeInterval = 0.4) {
        let fading = windows
        windows.removeAll()
        companionManager?.sparkClickTarget.reset()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            fading.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: {
            fading.forEach { $0.orderOut(nil); $0.contentView = nil }
        })
    }

    func isShowingOverlay() -> Bool { !windows.isEmpty }
}

/// Where the spark is (overlay-local points). A plain reference the big layer
/// doesn't observe, so a moving pointer only re-renders the small readers.
final class CursorFollowPosition: ObservableObject {
    @Published var position: CGPoint
    init(_ position: CGPoint) { self.position = position }
}

private struct FollowReader<Content: View>: View {
    @ObservedObject var follow: CursorFollowPosition
    let content: (CGPoint) -> Content
    var body: some View { content(follow.position) }
}

/// One screen's spark, marks and caption.
struct SparkScreenLayer: View {
    let screenFrame: CGRect
    let greets: Bool
    @ObservedObject var companionManager: CompanionManager

    private enum Motion { case riding, flying, pointing }

    /// Down and to the right of the pointer tip, so the spark never covers what you click.
    private static let rideOffset = CGSize(width: 32, height: 26)
    private static let pointHoldSeconds = 3.5

    @State private var follow: CursorFollowPosition
    @State private var isPointerHere: Bool
    @State private var subscription: CursorFollowDriver.Subscription?
    @State private var motion: Motion = .riding
    @State private var isComingBack = false
    @State private var flightStartPointer: CGPoint = .zero
    @State private var flightScale: CGFloat = 1
    @State private var flightTimer: Timer?
    @State private var sparkOpacity: Double = 0
    @State private var fadeSeconds: Double = 0.25
    @State private var greeting = ""
    @State private var greetingOpacity: Double = 0

    init(screenFrame: CGRect, greets: Bool, companionManager: CompanionManager) {
        self.screenFrame = screenFrame
        self.greets = greets
        self.companionManager = companionManager
        let pointer = NSEvent.mouseLocation
        _follow = State(initialValue: CursorFollowPosition(Self.local(pointer, in: screenFrame, offset: Self.rideOffset)))
        _isPointerHere = State(initialValue: screenFrame.contains(pointer))
    }

    private var displayCG: CGRect { ScreenTopology.cg(fromAppKit: screenFrame, flipH: ScreenTopology.mainDisplayHeight) }

    /// Only one spark at a time: the one riding on this screen, or the one flying here.
    private var showsSpark: Bool {
        switch motion {
        case .riding: return companionManager.detectedElementScreenLocation == nil && isPointerHere
        case .flying, .pointing: return true
        }
    }

    var body: some View {
        let _ = OverlayPerfMonitor.shared.note(.overlayBodyEvaluations)
        ZStack {
            Color.black.opacity(0.001)

            MarkSceneView(drawings: companionManager.markDrawings, displayBoundsCG: displayCG)

            if showsSpark && companionManager.captionState.isVisible {
                let avoid = companionManager.markDrawings.filter { $0.style != .spot && !$0.isHidden }.flatMap(\.paintedRects)
                    + [companionManager.pointTargetCG].compactMap { $0 } + companionManager.upcomingTargetRectsCG
                FollowReader(follow: follow) { spot in
                    CaptionBubbleLayer(caption: companionManager.captionState, displayBoundsCG: displayCG, companionLocalCenter: spot,
                                       isCompanionFlying: motion == .flying, obstaclesCG: avoid, textObstaclesCG: companionManager.screenTextObstaclesCG)
                }
            }

            if isPointerHere && !greeting.isEmpty { bubble(greeting, opacity: greetingOpacity) }
            if isPointerHere && companionManager.showOnboardingPrompt && !companionManager.onboardingPromptText.isEmpty {
                bubble(companionManager.onboardingPromptText, opacity: companionManager.onboardingPromptOpacity)
            }

            let isListening = companionManager.voiceState == .listening
            let spark = ClaudeCompanionView(
                isCoordinatorThinking: companionManager.voiceState == .processing || companionManager.isCompanionCoordinatorThinking,
                activeCompanionWorkers: companionManager.visibleCompanionWorkers,
                isAnimationRunning: showsSpark,
                opacity: showsSpark && !isListening ? sparkOpacity : 0,
                opacityFadeSeconds: fadeSeconds,
                flightScale: flightScale
            )
            FollowReader(follow: follow) { spot in
                spark
                    .frame(width: ClaudeCompanionView.companionFrameDiameter, height: ClaudeCompanionView.companionFrameDiameter)
                    .position(spot)
                    .animation(motion == .riding ? .interactiveSpring(response: 0.18, dampingFraction: 0.7) : nil, value: spot)
            }
            .animation(.easeIn(duration: 0.25), value: companionManager.voiceState)

            let meter = LevelMeter(level: companionManager.currentAudioPowerLevel, isRunning: showsSpark && isListening)
                .opacity(showsSpark && isListening ? sparkOpacity : 0)
            FollowReader(follow: follow) { spot in
                meter.position(spot).animation(.interactiveSpring(response: 0.18, dampingFraction: 0.7), value: spot)
            }
            .animation(.easeIn(duration: 0.15), value: companionManager.voiceState)
        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear(perform: appear)
        .onDisappear {
            CursorFollowDriver.shared.unsubscribe(subscription)
            subscription = nil
            flightTimer?.invalidate()
            companionManager.sparkClickTarget.reset()
        }
        .onChange(of: companionManager.detectedElementScreenLocation) { _, target in
            guard let target, let display = companionManager.detectedElementDisplayFrame,
                  screenFrame.contains(CGPoint(x: display.midX, y: display.midY)) || display == screenFrame else { return }
            flyToTarget(target)
        }
    }

    private func bubble(_ text: String, opacity: Double) -> some View {
        FollowReader(follow: follow) { spot in
            Text(text)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(Capsule().fill(DS.Colors.overlayCompanionOrange).shadow(color: DS.Colors.overlayCompanionOrange.opacity(0.45), radius: 7))
                .fixedSize()
                // Left edge just right of the spark: a wide leading-aligned frame centred on purpose.
                .frame(width: 420, alignment: .leading)
                .position(x: spot.x + 14 + 210, y: spot.y + 20)
                .opacity(opacity)
                .animation(.easeOut(duration: 0.4), value: opacity)
        }
    }

    // MARK: Riding along

    private static func local(_ point: CGPoint, in frame: CGRect, offset: CGSize = .zero) -> CGPoint {
        CGPoint(x: point.x - frame.minX + offset.width, y: frame.maxY - point.y + offset.height)
    }

    private func appear() {
        let pointer = NSEvent.mouseLocation
        isPointerHere = screenFrame.contains(pointer)
        move(to: Self.local(pointer, in: screenFrame, offset: Self.rideOffset))
        startRiding()
        if greets && isPointerHere {
            fadeSeconds = 1.8
            withAnimation(.easeIn(duration: 1.8)) { sparkOpacity = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) {
                fadeSeconds = 0.25
                sayHello()
            }
        } else {
            sparkOpacity = 1
        }
    }

    private func move(to point: CGPoint) {
        guard follow.position != point else { return }
        follow.position = point
        OverlayPerfMonitor.shared.note(.cursorStateWrites)
    }

    private func startRiding() {
        CursorFollowDriver.shared.unsubscribe(subscription)
        subscription = CursorFollowDriver.shared.subscribe {
            // Docked: the spark lives at a fixed spot on Theo's screen.
            if ClickySettings.sparkMode == .docked, let dockScreen = ClaudiaScreen.forDockedSpark {
                let dock = ClaudiaScreen.dockedSparkPoint(on: dockScreen)
                let here = screenFrame.contains(dock)
                if isPointerHere != here { isPointerHere = here }
                if motion == .riding { move(to: Self.local(dock, in: screenFrame)) }
                return
            }
            let pointer = NSEvent.mouseLocation
            let here = screenFrame.contains(pointer)
            if isPointerHere != here { isPointerHere = here }

            // Flying home: a big pointer move cancels it and the spark just rejoins.
            if motion == .flying && isComingBack {
                let now = Self.local(pointer, in: screenFrame)
                if hypot(now.x - flightStartPointer.x, now.y - flightStartPointer.y) > 100 { land() }
                return
            }
            guard motion == .riding else {
                if here { companionManager.sparkClickTarget.reset() }
                return
            }
            let riding = Self.local(pointer, in: screenFrame, offset: Self.rideOffset)
            guard here, showsSpark, companionManager.voiceState != .listening, sparkOpacity > 0 else {
                companionManager.sparkClickTarget.reset()
                move(to: riding)
                return
            }
            // Holding the spark (click-and-hold on it) keeps it put.
            let ridingAppKit = CGPoint(x: screenFrame.minX + riding.x, y: screenFrame.maxY - riding.y)
            if let held = companionManager.sparkClickTarget.sparkCenterWhileHolding(mouseLocation: pointer, followingSparkCenter: ridingAppKit) {
                move(to: Self.local(held, in: screenFrame))
            } else {
                move(to: riding)
            }
        }
    }

    // MARK: Pointing

    private func flyToTarget(_ target: CGPoint) {
        guard greeting.isEmpty else { return }
        var destination = Self.local(target, in: screenFrame)
        destination.x = min(max(destination.x, 14), screenFrame.width - 14)
        destination.y = min(max(destination.y, 14), screenFrame.height - 14)
        flightStartPointer = Self.local(NSEvent.mouseLocation, in: screenFrame)
        motion = .flying
        isComingBack = false
        fly(to: destination) {
            guard motion == .flying else { return }
            motion = .pointing
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.pointHoldSeconds) {
                guard motion == .pointing else { return }
                flyHome()
            }
        }
    }

    private func flyHome() {
        flightStartPointer = Self.local(NSEvent.mouseLocation, in: screenFrame)
        motion = .flying
        isComingBack = true
        fly(to: Self.local(NSEvent.mouseLocation, in: screenFrame, offset: Self.rideOffset)) { land() }
    }

    private func land() {
        flightTimer?.invalidate()
        flightTimer = nil
        flightScale = 1
        motion = .riding
        isComingBack = false
        companionManager.clearDetectedElementLocation()
    }

    /// A swoop: eased progress along a curve that bows sideways from the straight line,
    /// growing a little mid-flight. Driven at 60 fps so it's smooth on any screen.
    private func fly(to end: CGPoint, completion: @escaping () -> Void) {
        flightTimer?.invalidate()
        let start = follow.position
        let distance = hypot(end.x - start.x, end.y - start.y)
        let duration = min(max(Double(distance) / 900, 0.55), 1.3)
        // The bow: perpendicular to the path, up to 70 pt, always arcing upward on screen.
        var normal = CGPoint(x: -(end.y - start.y), y: end.x - start.x)
        let length = max(hypot(normal.x, normal.y), 1)
        normal = CGPoint(x: normal.x / length, y: normal.y / length)
        if normal.y > 0 { normal = CGPoint(x: -normal.x, y: -normal.y) }
        let bow = min(distance * 0.18, 70)
        let began = Date()
        flightTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { timer in
            let raw = min(Date().timeIntervalSince(began) / duration, 1)
            // Ease in and out (cubic).
            let eased = raw < 0.5 ? 4 * raw * raw * raw : 1 - pow(-2 * raw + 2, 3) / 2
            let lift = sin(eased * .pi) * bow
            move(to: CGPoint(x: start.x + (end.x - start.x) * eased + normal.x * lift,
                             y: start.y + (end.y - start.y) * eased + normal.y * lift))
            flightScale = 1 + 0.28 * sin(raw * .pi)
            if raw >= 1 {
                timer.invalidate()
                flightTimer = nil
                flightScale = 1
                completion()
            }
        }
    }

    // MARK: Hello

    private func sayHello() {
        let line = "hi, i'm \(ClickySettings.assistantName.lowercased())"
        greetingOpacity = 1
        for (index, _) in line.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.035) {
                greeting = String(line.prefix(index + 1))
            }
        }
        let typed = Double(line.count) * 0.035
        DispatchQueue.main.asyncAfter(deadline: .now() + typed + 1.8) { greetingOpacity = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + typed + 2.3) {
            greeting = ""
            companionManager.startOnboardingPromptStream()
        }
    }
}

/// Five rounded bars that bounce with your voice while push-to-talk is held.
private struct LevelMeter: View {
    let level: CGFloat
    let isRunning: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isRunning)) { timeline in
            let seconds = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<5, id: \.self) { bar in
                    let wobble = (sin(seconds * 9 + Double(bar) * 1.3) + 1) / 2
                    let weight: CGFloat = [0.55, 0.8, 1, 0.8, 0.55][bar]
                    Capsule()
                        .fill(LinearGradient(colors: [Color(red: 1, green: 0.66, blue: 0.5), DS.Colors.overlayCompanionOrange], startPoint: .top, endPoint: .bottom))
                        .frame(width: 3.5, height: 5 + 15 * weight * max(level, 0.08) * CGFloat(0.6 + 0.4 * wobble))
                }
            }
            .frame(width: 30, height: 24)
            .shadow(color: DS.Colors.overlayCompanionOrange.opacity(0.6), radius: 5)
        }
    }
}
