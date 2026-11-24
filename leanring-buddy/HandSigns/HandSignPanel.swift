//
//  HandSignPanel.swift
//  leanring-buddy
//
//  The small camera panel shown whenever hand signs are on (so the camera is never on unseen): the
//  mirrored camera picture (or just a status line, if the owner hid the picture), the sign it sees with
//  a ring filling while it's held, the four modes, and what was last said or done, in big letters so the
//  person being talked to can read it too. In Spell to text it shows the letters spelled so far, with
//  Space, Delete, Clear and Send buttons. In Sign to text it shows the line as it builds (each word, a
//  finger-spelled word spelled out, a soft "?" for a sign it wasn't sure of), whether a sign is being made,
//  the countdown before the line sends by itself, Undo, Clear and Send, and the ASL / ISL choice. Bottom
//  right of the main screen; drag it anywhere. It never takes focus. The close button turns hand signs off.
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
    private var modeObserver: AnyCancellable?
    static let width: CGFloat = 272
    static let heightWithPicture: CGFloat = 352
    static let heightWithoutPicture: CGFloat = 176
    /// Spell to text adds the spelled line and its buttons.
    static let extraHeightForSpelling: CGFloat = 76
    /// Sign to text adds the language choice, the signed line and its buttons.
    static let extraHeightForSigns: CGFloat = 112
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
        modeObserver = controller.$mode.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.fitHeight(animated: true)
        }
    }

    func hide() {
        pictureSwitchObserver = nil
        modeObserver = nil
        panel?.orderOut(nil)
    }

    /// Grows or shrinks from the top edge, so the panel stays where it was put.
    private func fitHeight(animated: Bool) {
        guard let panel else { return }
        let pictureHeight = controller.showsCameraPicture ? Self.heightWithPicture : Self.heightWithoutPicture
        let extraHeight: CGFloat
        switch controller.mode {
        case .spell: extraHeight = Self.extraHeightForSpelling
        case .signs: extraHeight = Self.extraHeightForSigns
        case .control, .speakForMe: extraHeight = 0
        }
        let height = pictureHeight + extraHeight
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
            if controller.mode == .spell {
                spellingArea
            }
            if controller.mode == .signs {
                signsArea
            }
            Text(controller.lastLine.isEmpty ? " " : controller.lastLine)
                .font(.system(size: modeHasATextArea ? 12 : 18, weight: .semibold))
                .foregroundColor(modeHasATextArea ? .white.opacity(0.7) : .white)
                .lineLimit(modeHasATextArea ? 2 : 3)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: modeHasATextArea ? 18 : 44, alignment: .topLeading)
        }
        .padding(12)
        .frame(width: HandSignPanelController.width, alignment: .top)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Self.panelInk.opacity(0.94)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
    }

    /// Spell to text and Sign to text show their own text, so the last line under it is small.
    private var modeHasATextArea: Bool {
        controller.mode == .spell || controller.mode == .signs
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
                Circle().trim(from: 0, to: controller.mode == .signs ? controller.signsAutoSendProgress : controller.holdProgress)
                    .stroke(Self.ringColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(chipSymbol).font(.system(size: 14, weight: .bold)).foregroundColor(.white)
            }
            .frame(width: 30, height: 30)
            Text(chipWords).font(.system(size: 12, weight: .medium)).foregroundColor(.white).lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Capsule().fill(Color.black.opacity(0.55)))
    }

    private var chipSymbol: String {
        if controller.mode == .signs {
            if controller.isMakingASign { return "✋" }
            if controller.signReadingsInProgress > 0 { return "…" }
            return controller.handIsVisible ? "✋" : "·"
        }
        if controller.mode == .spell || controller.teachingLabel != nil {
            if let label = controller.seenSpellingLabel, controller.teachingLabel == nil {
                switch label {
                case FingerspellingReading.sendLabel: return "🖐"
                case FingerspellingReading.deleteLabel: return "👎"
                default: return label.count == 1 ? label.uppercased() : "★"
                }
            }
            return controller.handIsVisible ? "✋" : "·"
        }
        return controller.seenSign?.emoji ?? (controller.handIsVisible ? "✋" : "·")
    }

    private var chipWords: String {
        if let problem = controller.problem { return problem }
        if controller.teachingLabel != nil { return controller.teachingLine }
        if controller.mode == .signs {
            if controller.isLoadingSignModels { return "Loading the sign models…" }
            if let signModelsLoad = controller.signModelsLoad, !signModelsLoad.hasAnyModel {
                return "Sign to text isn't in this build yet"
            }
            if controller.isMakingASign { return "Signing…" }
            if controller.signReadingsInProgress > 0 { return "Reading the sign…" }
            let readsRunsOfSigns = controller.signModelsLoad?.sentenceModelSummary != nil
            return controller.handIsVisible ? (readsRunsOfSigns ? "Sign, in a row if you like, then rest" : "Sign, then rest your hands") : "Show me your hands"
        }
        if controller.mode == .spell {
            switch controller.seenSpellingLabel {
            case FingerspellingReading.sendLabel?: return "Hold to send"
            case FingerspellingReading.deleteLabel?: return "Hold to delete a letter"
            case let label?: return label.count == 1 ? "Letter \(label.uppercased())" : label
            case nil: return controller.handIsVisible ? "Spell a letter" : "Show me your hand"
            }
        }
        if let seenSign = controller.seenSign { return seenSign.displayName }
        return controller.handIsVisible ? "Hold a sign still" : "Show me your hand"
    }

    /// The letters spelled so far, big enough for the person across the desk, and what to do with them.
    private var spellingArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(controller.spelledText.text.isEmpty ? "…" : controller.spelledText.text.uppercased())
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(1)
                .truncationMode(.head)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                spellingButton("Space", systemImage: "space", help: "End the word") { controller.addSpaceToSpelledText() }
                spellingButton("Delete", systemImage: "delete.left", help: "Delete the last letter (or hold thumbs down)") { controller.deleteLastSpelledLetter() }
                spellingButton("Clear", systemImage: "xmark.circle", help: "Start again") { controller.clearSpelledText() }
                Spacer(minLength: 0)
                Button {
                    controller.sendSpelledText()
                } label: {
                    Text("Send").font(.system(size: 11.5, weight: .semibold)).foregroundColor(.black)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(Color.white))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain).pointerCursor()
                .help("Send to \(controller.destination.displayName) (or hold an open hand with the fingers spread)")
            }
        }
    }

    // MARK: Sign to text

    /// The language, the line as it builds, and what to do with it.
    private var signsArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(SignLanguage.allCases, id: \.self) { language in
                    signLanguageButton(language)
                }
                Spacer(minLength: 4)
                signingIndicator
            }
            signedLineView
            HStack(spacing: 6) {
                spellingButton("Undo", systemImage: "arrow.uturn.backward", help: "Take off the last sign") { controller.undoLastSign() }
                spellingButton("Clear", systemImage: "xmark.circle", help: "Start the line again") { controller.clearSignedLine() }
                Text(autoSendWords)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button {
                    controller.sendSignedLine()
                } label: {
                    Text("Send").font(.system(size: 11.5, weight: .semibold)).foregroundColor(.black)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(Color.white))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain).pointerCursor()
                .help("Send to \(controller.signsDestination.displayName)")
            }
        }
    }

    private func signLanguageButton(_ language: SignLanguage) -> some View {
        let isChosen = controller.signLanguage == language
        return Button {
            controller.signLanguage = language
        } label: {
            Text(language.rawValue.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(isChosen ? .black : .white.opacity(0.85))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(isChosen ? Color.white : Color.white.opacity(0.1)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain).pointerCursor()
        .help("Read \(language.fullName)")
    }

    /// A dot that lights while a sign is being made, and the words for it.
    private var signingIndicator: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(controller.isMakingASign ? Self.ringColor : Color.white.opacity(0.25))
                .frame(width: 7, height: 7)
            Text(controller.isMakingASign ? "Signing" : (controller.signReadingsInProgress > 0 ? "Reading" : "Resting"))
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
        }
    }

    /// Each word as a chip, newest on the right, scrolled so the newest shows.
    private var signedLineView: some View {
        ScrollViewReader { scrollProxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    if controller.signedEntries.isEmpty {
                        Text("…")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    ForEach(Array(controller.signedEntries.enumerated()), id: \.offset) { entryIndex, entry in
                        signedEntryChip(entry).id(entryIndex)
                    }
                }
                .frame(minHeight: 30)
            }
            .onChange(of: controller.signedEntries.count) { _, entryCount in
                guard entryCount > 0 else { return }
                scrollProxy.scrollTo(entryCount - 1, anchor: .trailing)
            }
        }
    }

    /// A word reads as a word; a finger-spelled word is spelled out letter by letter; a sign it wasn't sure of is
    /// a soft "?", so the signer knows it was seen but not read.
    @ViewBuilder
    private func signedEntryChip(_ entry: SignLiveLineEntry) -> some View {
        switch entry.kind {
        case .word:
            Text(entry.displayText)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.14)))
                .help(alternativesHelp(for: entry))
        case .spelled:
            Text(entry.displayText.uppercased().map(String.init).joined(separator: "·"))
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().strokeBorder(Color.white.opacity(0.45), lineWidth: 1))
                .help("Finger-spelled")
        case .unclear:
            Text(entry.displayText)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.45))
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(Capsule().strokeBorder(Color.white.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                .help("A sign I wasn't sure of. It won't be sent.")
        }
    }

    /// A signed word's tooltip: the other words it may have been, when the models gave any.
    private func alternativesHelp(for entry: SignLiveLineEntry) -> String {
        let alternativeTexts = entry.token?.alternativeTexts ?? []
        return alternativeTexts.isEmpty ? "Signed word" : "May also be: \(alternativeTexts.joined(separator: ", "))"
    }

    /// The countdown before the line sends by itself, or what's happening instead.
    private var autoSendWords: String {
        if controller.signsAutoSendSeconds <= 0 { return controller.signedEntries.isEmpty ? "" : "Send when ready" }
        if controller.signsAutoSendProgress > 0 {
            let secondsLeft = max(0, (1 - controller.signsAutoSendProgress) * controller.signsAutoSendSeconds)
            return String(format: "Sending in %.1f s", secondsLeft)
        }
        return ""
    }

    private func spellingButton(_ title: String, systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold)).foregroundColor(.white.opacity(0.85))
                .frame(width: 30, height: 24)
                .background(Capsule().fill(Color.white.opacity(0.1)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain).pointerCursor()
        .help(help)
        .accessibilityLabel(title)
    }

    private var modePicker: some View {
        // Four modes fit the panel's width with a little less room around each name.
        HStack(spacing: 4) {
            ForEach(HandSignMode.allCases, id: \.self) { mode in
                let isChosen = controller.mode == mode
                Button {
                    controller.mode = mode
                } label: {
                    Text(mode.shortName)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(isChosen ? .black : .white.opacity(0.85))
                        .padding(.horizontal, 8).padding(.vertical, 5)
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
