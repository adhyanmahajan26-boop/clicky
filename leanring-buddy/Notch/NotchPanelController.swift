//
//  NotchPanelController.swift
//  leanring-buddy
//
//  The Dynamic Island-style pill at the top centre of the screen
//  (v2.notch.*). It owns one NotchPanel (ClickyCore: borderless,
//  non-activating, never key or main) hosting ClickyCore's NotchView, and
//  feeds it from the state the app already has: CompanionManager's voice
//  state and caption, the AgentsCenter store the Agents window uses, and
//  CodeModeController's switch, plus the project bridge's few-seconds
//  "sent to project" status. Nothing is duplicated; a NotchContent is
//  rebuilt whenever one of those changes.
//
//  Hover: an .activeAlways tracking area on the hosting view (no key status
//  needed) feeds NotchPresentationStateMachine; it expands at once and
//  collapses 0.4 s after the pointer leaves. Growing sets the panel to the
//  expanded frame and SwiftUI springs the pill into it; shrinking springs
//  the pill first and trims the panel after the spring settles, so the
//  pill is never clipped and the panel never covers more than it shows for long.
//
//  Visibility: hidden while v2.notch.enabled is off and, with
//  v2.notch.hideOverFullscreen on (default), whenever a full-screen window
//  covers the pill's display (NotchFullScreenPolicy over the on-screen
//  window list, re-checked on Space/app switches and once a second).
//  Showing it uses orderFrontRegardless, which never activates Clicky.
//
//  Buttons go through the same paths as the existing UI: Cancel is
//  AgentsCenter.cancel (the dashboard's), Open review is
//  CodeModeController.showActiveReview, Agents opens AgentsWindowController
//  via CompanionManager.showAgentsDashboard, and the Code mode switch calls
//  CodeModeController.setEnabled exactly like the menu bar panel's switch.
//  There is no voice on/off setting in the app, so the pill has none.
//

import AppKit
import ClickyCore
import Combine
import SwiftUI

/// What the SwiftUI root view reads.
@MainActor
final class NotchViewModel: ObservableObject {
    @Published var content = NotchContent()
    @Published var layout = NotchLayout.sample(hasPhysicalNotch: false)
    @Published var isExpanded = false
}

@MainActor
final class NotchPanelController: NSObject {
    private unowned let companionManager: CompanionManager
    private let viewModel = NotchViewModel()
    private var panel: NotchPanel?
    private var hostingView: NotchHostingView?
    private var presentationStateMachine = NotchPresentationStateMachine(clock: { ProcessInfo.processInfo.systemUptime })
    private var selectedAgentID: String?

    private var stateCancellables: Set<AnyCancellable> = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var screenParametersObserver: NSObjectProtocol?
    private var refreshTimer: Timer?
    private var collapseCheckTask: Task<Void, Never>?
    private var panelShrinkTask: Task<Void, Never>?

    /// The screen the pill is on now (its display id), and whether it's shown.
    private var currentDisplayID: CGDirectDisplayID?
    private var isPanelShown = false
    private var showsOverFullScreenApps = !ClickySettings.isNotchHiddenOverFullScreen
    /// The pill's frame in global AppKit points (the part the pointer counts on).
    private var visiblePillFrame: CGRect = .zero

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
    }

    // MARK: - Lifecycle

    func start() {
        bindState()
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for notificationName in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspaceObservers.append(workspaceCenter.addObserver(forName: notificationName, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshPlacementAndVisibility() }
            })
        }
        screenParametersObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.currentDisplayID = nil
                self?.refreshPlacementAndVisibility()
            }
        }
        // Settings, the cursor's display, full screen and the elapsed times.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshPlacementAndVisibility()
                if self.viewModel.isExpanded { self.rebuildContent() }
            }
        }
        rebuildContent()
        refreshPlacementAndVisibility()
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        collapseCheckTask?.cancel()
        panelShrinkTask?.cancel()
        stateCancellables.removeAll()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        if let screenParametersObserver { NotificationCenter.default.removeObserver(screenParametersObserver) }
        screenParametersObserver = nil
        panel?.orderOut(nil)
        isPanelShown = false
    }

    // MARK: - State

    /// Any change to the voice state, caption, agents or Code mode rebuilds
    /// the content. Delivered on the next main-queue turn, so every
    /// @Published value read during the rebuild is already the new one.
    private func bindState() {
        let codeModeController = companionManager.codeModeController
        let triggers: [AnyPublisher<Void, Never>] = [
            companionManager.$voiceState.map { _ in () }.eraseToAnyPublisher(),
            companionManager.$isCompanionCoordinatorThinking.map { _ in () }.eraseToAnyPublisher(),
            companionManager.$captionState.map { _ in () }.eraseToAnyPublisher(),
            companionManager.agentsCenter.$store.map { _ in () }.eraseToAnyPublisher(),
            codeModeController.$isEnabled.map { _ in () }.eraseToAnyPublisher(),
            companionManager.projectBridge.$notchStatusText.map { _ in () }.eraseToAnyPublisher()
        ]
        Publishers.MergeMany(triggers)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                MainActor.assumeIsolated { self?.rebuildContent() }
            }
            .store(in: &stateCancellables)
    }

    private func rebuildContent() {
        let voiceState = companionManager.voiceState
        let phase = NotchStatus.phase(isListening: voiceState == .listening, isProcessing: voiceState == .processing,
                                      isResponding: voiceState == .responding, isCoordinatorThinking: companionManager.isCompanionCoordinatorThinking)
        let agentsCenter = companionManager.agentsCenter
        let codeModeController = companionManager.codeModeController
        if let selectedAgentID, agentsCenter.store[selectedAgentID]?.status.isActive != true {
            self.selectedAgentID = nil
        }
        let newContent = NotchStatus.content(
            phase: phase,
            store: agentsCenter.store,
            captionText: NotchStatus.captionText(companionManager.captionState),
            isCodeModeOn: codeModeController.isEnabled,
            selectedAgentID: selectedAgentID,
            now: Date(),
            projectStatusText: companionManager.projectBridge.notchStatusText,
            canCancel: { agentsCenter.canCancel($0) },
            canOpenReview: { record in record.kind == .codeTask && codeModeController.activeReviewAgentID == record.id }
        )
        let sizeChanged = NotchView.pillSize(content: newContent, layout: viewModel.layout, isExpanded: viewModel.isExpanded)
            != NotchView.pillSize(content: viewModel.content, layout: viewModel.layout, isExpanded: viewModel.isExpanded)
        if newContent != viewModel.content { viewModel.content = newContent }
        if sizeChanged { applyPanelFrame() }
    }

    // MARK: - Placement and visibility

    private func targetScreen() -> NSScreen? {
        switch ClickySettings.notchDisplay {
        case .main:
            return NSScreen.screens.first
        case .cursor:
            let mouseLocation = NSEvent.mouseLocation
            return NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.screens.first
        }
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    private static func metrics(of screen: NSScreen) -> NotchScreenMetrics {
        NotchScreenMetrics(screenFrame: screen.frame, safeAreaTopInset: screen.safeAreaInsets.top,
                           auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea, auxiliaryTopRightArea: screen.auxiliaryTopRightArea)
    }

    private func refreshPlacementAndVisibility() {
        guard let screen = targetScreen(), let displayID = Self.displayID(of: screen) else {
            hidePanel()
            return
        }
        let isEnabled = ClickySettings.isNotchEnabled
        let hidesOverFullScreen = ClickySettings.isNotchHiddenOverFullScreen
        // The window list is only read when the answer can matter.
        let isFullScreenAppCovering = isEnabled && hidesOverFullScreen && Self.isFullScreenAppCovering(displayID: displayID)
        let shouldShow = NotchFullScreenPolicy.shouldShowNotch(isEnabled: isEnabled, hidesOverFullScreen: hidesOverFullScreen,
                                                               isFullScreenAppCovering: isFullScreenAppCovering)
        guard shouldShow else {
            hidePanel()
            return
        }

        let panel = panel ?? makePanel()
        if showsOverFullScreenApps != !hidesOverFullScreen {
            showsOverFullScreenApps = !hidesOverFullScreen
            panel.collectionBehavior = NotchPanel.collectionBehavior(showsOverFullScreenApps: showsOverFullScreenApps)
        }
        // Move to another display only while collapsed (never yank it from under the pointer).
        let newLayout = NotchGeometry.layout(for: Self.metrics(of: screen))
        if (displayID != currentDisplayID || newLayout != viewModel.layout) && !viewModel.isExpanded {
            currentDisplayID = displayID
            viewModel.layout = newLayout
            applyPanelFrame(immediately: true)
        }
        if !isPanelShown {
            isPanelShown = true
            applyPanelFrame(immediately: true)
            panel.orderFrontRegardless()
        }
    }

    /// Full screen on this display, from the on-screen window list (bounds,
    /// layers and owner pids; Clicky's own windows are left out).
    private static func isFullScreenAppCovering(displayID: CGDirectDisplayID) -> Bool {
        let windowStack = WindowListReader.read(displays: ScreenTopology.current())
        return NotchFullScreenPolicy.isFullScreenAppCovering(displayBoundsCG: CGDisplayBounds(displayID), windows: windowStack.windows,
                                                             frontmostProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier)
    }

    private func hidePanel() {
        guard isPanelShown else { return }
        isPanelShown = false
        panel?.orderOut(nil)
        collapseCheckTask?.cancel()
        presentationStateMachine.reset()
        viewModel.isExpanded = false
        currentDisplayID = nil
    }

    private func makePanel() -> NotchPanel {
        let initialFrame = NotchGeometry.panelFrame(layout: viewModel.layout, size: NotchGeometry.collapsedSize(layout: viewModel.layout))
        let newPanel = NotchPanel.make(contentRect: initialFrame, showsOverFullScreenApps: showsOverFullScreenApps)
        let rootView = NotchRootView(viewModel: viewModel, actions: makeActions())
        let newHostingView = NotchHostingView(rootView: rootView)
        // The panel's frame is Clicky's to set; SwiftUI never resizes it.
        newHostingView.sizingOptions = []
        newHostingView.onPointerActivity = { [weak self] in self?.pointerActivity() }
        newPanel.contentView = newHostingView
        panel = newPanel
        hostingView = newHostingView
        return newPanel
    }

    // MARK: - Frame

    /// Sizes the panel for the current presentation. Growing (or showing)
    /// sets the frame now and SwiftUI springs the pill into it; shrinking
    /// keeps the bigger frame until the spring has settled.
    private func applyPanelFrame(immediately: Bool = false) {
        guard let panel else { return }
        let layout = viewModel.layout
        let targetSize = NotchView.pillSize(content: viewModel.content, layout: layout, isExpanded: viewModel.isExpanded)
        let targetFrame = NotchGeometry.panelFrame(layout: layout, size: targetSize)
        visiblePillFrame = targetFrame
        panelShrinkTask?.cancel()

        let currentFrame = panel.frame
        let isShrinking = targetFrame.width < currentFrame.width - 0.5 || targetFrame.height < currentFrame.height - 0.5
        if immediately || !isShrinking || !isPanelShown {
            if currentFrame != targetFrame { panel.setFrame(targetFrame, display: true) }
            return
        }
        let holdingFrame = NotchGeometry.panelFrame(layout: layout, size: NotchGeometry.unionSize(currentFrame.size, targetSize))
        if currentFrame != holdingFrame { panel.setFrame(holdingFrame, display: true) }
        panelShrinkTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(NotchView.springSettleSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self, let panel = self.panel else { return }
            panel.setFrame(targetFrame, display: true)
        }
    }

    // MARK: - Hover and clicks

    /// From the tracking area (enter, exit, move). The pointer counts as on
    /// the pill only inside the pill's own frame, not the transparent rest of
    /// a panel that is still shrinking.
    private func pointerActivity() {
        // One point of slack above: a pointer pushed against the top edge reads as maxY.
        let hoverFrame = visiblePillFrame.insetBy(dx: 0, dy: -1)
        let isInside = hoverFrame.contains(NSEvent.mouseLocation)
        if isInside && !presentationStateMachine.isPointerInside {
            presentationStateMachine.pointerEntered()
            applyPresentation()
        } else if !isInside && presentationStateMachine.isPointerInside {
            presentationStateMachine.pointerExited()
            scheduleCollapseCheck()
        }
    }

    private func scheduleCollapseCheck() {
        collapseCheckTask?.cancel()
        guard let collapseDeadline = presentationStateMachine.collapseDeadline else { return }
        let delaySeconds = max(0, collapseDeadline - ProcessInfo.processInfo.systemUptime)
        collapseCheckTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000) + 5_000_000)
            guard !Task.isCancelled, let self else { return }
            if self.presentationStateMachine.update() {
                self.applyPresentation()
            } else if self.presentationStateMachine.collapseDeadline != nil {
                self.scheduleCollapseCheck()
            }
        }
    }

    private func applyPresentation() {
        let isExpanded = presentationStateMachine.isExpanded
        guard viewModel.isExpanded != isExpanded else { return }
        if isExpanded { rebuildContent() }
        viewModel.isExpanded = isExpanded
        applyPanelFrame()
    }

    private func makeActions() -> NotchActions {
        NotchActions(
            expand: { [weak self] in
                guard let self else { return }
                self.presentationStateMachine.clicked()
                self.applyPresentation()
                self.scheduleCollapseCheck()
            },
            selectAgent: { [weak self] agentID in
                self?.selectedAgentID = agentID
                self?.rebuildContent()
            },
            cancelAgent: { [weak self] agentID in
                guard let agentsCenter = self?.companionManager.agentsCenter, let record = agentsCenter.record(agentID), agentsCenter.canCancel(record) else { return }
                agentsCenter.cancel(record)
            },
            openReview: { [weak self] agentID in
                _ = self?.companionManager.codeModeController.showActiveReview(agentID: agentID)
            },
            showAgentsWindow: { [weak self] in
                self?.companionManager.showAgentsDashboard(activatesClicky: true)
            },
            setCodeModeEnabled: { [weak self] isEnabled in
                // The menu bar panel's switch does exactly this.
                self?.companionManager.codeModeController.setEnabled(isEnabled)
            }
        )
    }
}

/// Re-renders on every view-model change.
struct NotchRootView: View {
    @ObservedObject var viewModel: NotchViewModel
    let actions: NotchActions

    var body: some View {
        NotchView(content: viewModel.content, layout: viewModel.layout, isExpanded: viewModel.isExpanded, actions: actions)
    }
}

/// Hosts the pill. The panel is never key, so the first click must reach
/// SwiftUI directly; hover comes from an .activeAlways tracking area.
final class NotchHostingView: NSHostingView<NotchRootView> {
    var onPointerActivity: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for trackingArea in trackingAreas where trackingArea.owner === self && trackingArea.userInfo?["notch"] != nil {
            removeTrackingArea(trackingArea)
        }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: ["notch": true]))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onPointerActivity?()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onPointerActivity?()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onPointerActivity?()
    }
}
