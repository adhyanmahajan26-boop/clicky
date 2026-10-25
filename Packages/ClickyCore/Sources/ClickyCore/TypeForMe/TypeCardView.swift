//
//  TypeCardView.swift
//  ClickyCore
//
//  The SwiftUI content of the "Type this for me" card: the target app's
//  name and icon, the field's role and title, a ≤300-character preview,
//  how it will be inserted, a status line (refusal, "press Return again",
//  expired) and the buttons Type (Return) / Copy / Cancel (Esc). The Type
//  button is an NSView so the real mouse NSEvents reach the confirm gate;
//  `usesStaticButtons` swaps it for a drawn one (ImageRenderer can't draw
//  NSView-backed views). TypeCardPlacement puts the card under the caret.
//

import AppKit
import SwiftUI

@MainActor
public final class TypeCardState: ObservableObject {
    @Published public var applicationName: String
    @Published public var applicationIcon: NSImage?
    @Published public var fieldDescription: String
    @Published public var preview: String
    @Published public var characterCountDescription: String
    @Published public var insertionMethodDescription: String
    /// nil when typing is allowed; otherwise why only Copy is offered.
    @Published public var refusalExplanation: String?
    @Published public var statusLine: String?
    @Published public var isTypeButtonEnabled: Bool

    public var onTypeButtonMouseEvent: (NSEvent, Bool) -> Void = { _, _ in }
    public var onCopy: () -> Void = {}
    public var onCancel: () -> Void = {}

    public init(applicationName: String, applicationIcon: NSImage?, fieldDescription: String, preview: String,
                characterCountDescription: String, insertionMethodDescription: String, refusalExplanation: String?, statusLine: String? = nil) {
        self.applicationName = applicationName
        self.applicationIcon = applicationIcon
        self.fieldDescription = fieldDescription
        self.preview = preview
        self.characterCountDescription = characterCountDescription
        self.insertionMethodDescription = insertionMethodDescription
        self.refusalExplanation = refusalExplanation
        self.statusLine = statusLine
        self.isTypeButtonEnabled = refusalExplanation == nil
    }

    public var offersTyping: Bool { refusalExplanation == nil }
}

public struct TypeCardView: View {
    @ObservedObject var state: TypeCardState
    var usesStaticButtons: Bool
    public static let cardWidth: CGFloat = 380

    public init(state: TypeCardState, usesStaticButtons: Bool = false) {
        self.state = state
        self.usesStaticButtons = usesStaticButtons
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Text(state.preview)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .lineLimit(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
            HStack(spacing: 6) {
                Image(systemName: state.offersTyping ? "keyboard" : "doc.on.doc")
                    .font(.system(size: 11))
                Text(state.offersTyping ? state.insertionMethodDescription : "Copy only")
                Spacer(minLength: 4)
                Text(state.characterCountDescription)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            if let explanation = state.refusalExplanation ?? state.statusLine {
                Text(explanation)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(state.refusalExplanation != nil ? Color.orange : Color.accentColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            buttons
        }
        .padding(14)
        .frame(width: Self.cardWidth)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.12)))
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let icon = state.applicationIcon {
                Image(nsImage: icon).resizable().frame(width: 28, height: 28)
            } else {
                Image(systemName: "app.dashed").font(.system(size: 22)).frame(width: 28, height: 28)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Type into \(state.applicationName)")
                    .font(.system(size: 13, weight: .semibold))
                Text(state.fieldDescription)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Button("Cancel (Esc)") { state.onCancel() }
            Button("Copy") { state.onCopy() }
            if state.offersTyping {
                if usesStaticButtons {
                    Text("Type (Return)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.accentColor))
                } else {
                    TypeConfirmButton(isEnabled: state.isTypeButtonEnabled, onMouseEvent: state.onTypeButtonMouseEvent)
                        .frame(width: 128, height: 28)
                }
            }
        }
    }
}

/// The Type button: forwards its real mouseDown/mouseUp (and whether the
/// release is still on the button) to the gate. No click-through.
public final class TypeConfirmButtonView: NSView {
    public var isEnabled = true { didSet { updateAppearance() } }
    public var onMouseEvent: (NSEvent, Bool) -> Void = { _, _ in }
    private let titleField = NSTextField(labelWithString: "Type (Return)")

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 7
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.alignment = .center
        titleField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleField)
        NSLayoutConstraint.activate([
            titleField.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setAccessibilityRole(.button)
        setAccessibilityLabel("Type")
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// A click on a non-key card only makes it key; it never presses Type.
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }
    public override func mouseDown(with event: NSEvent) { forward(event) }
    public override func mouseUp(with event: NSEvent) { forward(event) }

    private func forward(_ event: NSEvent) {
        guard isEnabled else { return }
        onMouseEvent(event, bounds.contains(convert(event.locationInWindow, from: nil)))
    }

    private func updateAppearance() {
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(isEnabled ? 1 : 0.35).cgColor
        titleField.textColor = .white
        titleField.alphaValue = isEnabled ? 1 : 0.6
        setAccessibilityEnabled(isEnabled)
    }
}

struct TypeConfirmButton: NSViewRepresentable {
    var isEnabled: Bool
    var onMouseEvent: (NSEvent, Bool) -> Void

    func makeNSView(context: Context) -> TypeConfirmButtonView {
        let view = TypeConfirmButtonView(frame: NSRect(x: 0, y: 0, width: 128, height: 28))
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: TypeConfirmButtonView, context: Context) {
        view.isEnabled = isEnabled
        view.onMouseEvent = onMouseEvent
    }
}

public enum TypeCardPlacement {
    static let gapBelowCaret: CGFloat = 8

    /// AppKit frame for a card of `cardSize` just below the caret rect
    /// (AppKit coordinates), flipped above it when there's no room, and
    /// kept inside the visible frame of the screen holding the caret.
    public static func frame(caretAppKit: CGRect, cardSize: CGSize, visibleFrames: [CGRect]) -> CGRect {
        let caretCenter = CGPoint(x: caretAppKit.midX, y: caretAppKit.midY)
        let visibleFrame = visibleFrames.first { $0.contains(caretCenter) } ?? visibleFrames.first ?? CGRect(origin: .zero, size: cardSize)
        var originX = caretAppKit.minX
        var originY = caretAppKit.minY - gapBelowCaret - cardSize.height
        if originY < visibleFrame.minY { originY = caretAppKit.maxY + gapBelowCaret }
        originX = min(max(originX, visibleFrame.minX), visibleFrame.maxX - cardSize.width)
        originY = min(max(originY, visibleFrame.minY), visibleFrame.maxY - cardSize.height)
        return CGRect(origin: CGPoint(x: originX, y: originY), size: cardSize)
    }
}
