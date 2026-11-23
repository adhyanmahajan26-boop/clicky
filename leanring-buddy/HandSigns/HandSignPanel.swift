//
//  HandSignPanel.swift
//  leanring-buddy
//
//  The small camera panel shown whenever hand signs are on (so the camera is never on unseen): the
//  mirrored camera picture (or just a status line, if the owner hid the picture), the sign it sees with
//  a ring filling while it's held, the two modes, and what was last said or done, in big letters so the
//  person being talked to can read it too. Bottom right of the main screen; drag it anywhere. It never
//  takes focus. The close button turns hand signs off.
//

import AppKit
import AVFoundation
import ClickyCore
import Combine
import SwiftUI

final class HandSignPanelController {
    private unowned let controller: HandSignController
    private var panel: NSPanel?
    private var pictureSwitchObserver: AnyCancellable?
    static let width: CGFloat = 272
    static let heightWithPicture: CGFloat = 352
    static let heightWithoutPicture: CGFloat = 176
    private static let screenEdgeGap: CGFloat = 20

    init(controller: HandSignController) {
        self.controller = controller
    }

    func show() {
        let isNewPanel = panel == nil
        let panel = self.panel ?? makePanel()
        self.panel = panel
        fitHeight(animated: false)
        if isNewPanel, let screenFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screenFrame.maxX - panel.frame.width - Self.screenEdgeGap,
                                         y: screenFrame.minY + Self.screenEdgeGap))
        }
        panel.orderFrontRegardless()
        pictureSwitchObserver = controller.$showsCameraPicture.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.fitHeight(animated: true)
        }
    }

    func hide() {
        pictureSwitchObserver = nil
        panel?.orderOut(nil)
    }

    /// Grows or shrinks from the top edge, so the panel stays where it was put.
    private func fitHeight(animated: Bool) {
        guard let panel else { return }
        let height = controller.showsCameraPicture ? Self.heightWithPicture : Self.heightWithoutPicture
        var frame = panel.frame
        frame.origin.y += frame.height - height
        frame.size = NSSize(width: Self.width, height: height)
        panel.setFrame(frame, display: true, animate: animated)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.heightWithPicture),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.title = "Hand signs"
        panel.contentView = NSHostingView(rootView: HandSignPanelView(controller: controller))
        return panel
    }
}

struct HandSignPanelView: View {
    @ObservedObject var controller: HandSignController
    private static let panelInk = Color(red: 0.07, green: 0.07, blue: 0.08)
    private static let ringColor = Color(red: 0.85, green: 0.47, blue: 0.34)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if controller.showsCameraPicture {
                cameraPicture
            } else {
                statusLine
            }
            modePicker
            Text(controller.lastLine.isEmpty ? " " : controller.lastLine)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(3)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
        }
        .padding(12)
        .frame(width: HandSignPanelController.width, alignment: .top)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Self.panelInk.opacity(0.94)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("🖐").font(.system(size: 14))
            Text("Hand signs").font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
            Circle().fill(controller.isRunning ? Color.green : Color.gray).frame(width: 6, height: 6)
            Spacer(minLength: 4)
            Button {
                controller.showsCameraPicture.toggle()
            } label: {
                Image(systemName: controller.showsCameraPicture ? "video.slash" : "video")
                    .font(.system(size: 11, weight: .semibold)).foregroundColor(.white.opacity(0.75))
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerCursor()
            .help(controller.showsCameraPicture ? "Hide the camera picture (signs still work)" : "Show the camera picture")
            Button {
                controller.switchOffFromPanel()
            } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundColor(.white.opacity(0.75))
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerCursor()
            .help("Turn hand signs off")
        }
    }

    private var cameraPicture: some View {
        ZStack(alignment: .bottomLeading) {
            HandSignCameraPreview(captureSession: controller.camera.captureSession)
                .frame(height: 186)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            signChip.padding(8)
        }
    }

    private var statusLine: some View {
        signChip
    }

    /// The sign seen now, with a ring that fills while it's held.
    private var signChip: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.2), lineWidth: 3)
                Circle().trim(from: 0, to: controller.holdProgress)
                    .stroke(Self.ringColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(controller.seenSign?.emoji ?? (controller.handIsVisible ? "✋" : "·")).font(.system(size: 14))
            }
            .frame(width: 30, height: 30)
            Text(chipWords).font(.system(size: 12, weight: .medium)).foregroundColor(.white).lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Capsule().fill(Color.black.opacity(0.55)))
    }

    private var chipWords: String {
        if let problem = controller.problem { return problem }
        if let seenSign = controller.seenSign { return seenSign.displayName }
        return controller.handIsVisible ? "Hold a sign still" : "Show me your hand"
    }

    private var modePicker: some View {
        HStack(spacing: 6) {
            ForEach(HandSignMode.allCases, id: \.self) { mode in
                let isChosen = controller.mode == mode
                Button {
                    controller.mode = mode
                } label: {
                    Text(mode == .control ? "Control" : "Speak for me")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(isChosen ? .black : .white.opacity(0.85))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(isChosen ? Color.white : Color.white.opacity(0.1)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain).pointerCursor()
                .help(mode.detail)
            }
        }
    }
}

/// The camera, mirrored like a mirror so raising your right hand shows on the right.
struct HandSignCameraPreview: NSViewRepresentable {
    let captureSession: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        previewLayer.videoGravity = .resizeAspectFill
        if let connection = previewLayer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        previewLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer = CALayer()
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.layer?.addSublayer(previewLayer)
        previewLayer.frame = view.bounds
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.layer?.sublayers?.first?.frame = nsView.bounds
    }
}
