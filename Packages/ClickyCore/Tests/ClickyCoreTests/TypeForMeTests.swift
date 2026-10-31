//
//  TypeForMeTests.swift
//  ClickyCoreTests
//
//  P6.2 "Type this for me", the pure parts: the unicode chunker (≤ 20
//  UTF-16 units, whole Characters), text clean-up and the 5000 cap, the
//  refusal rules, terminal handling, the plain-⌘V menu finder, clipboard
//  restore, verification, the confirm gate (0.5 s window, auto-repeat,
//  tagged events, 30 s / focus expiry, one confirm = one insertion), the
//  synthesized events' tags and flags, the prompt section, the router, and
//  an offscreen render of the card. Nothing here posts an event or types.
//

import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import ClickyCore

struct TypeForMeTextTests {
    @Test func chunkerKeepsChunksWithinTwentyUTF16Units() throws {
        let text = String(repeating: "abcdefghij", count: 7) + "xyz"
        let chunks = try #require(UnicodeTypingChunker.chunks(of: text))
        #expect(chunks.joined() == text)
        #expect(chunks.allSatisfy { $0.utf16.count <= 20 })
        #expect(chunks.map { $0.utf16.count } == [20, 20, 20, 13])
    }

    @Test func chunkerNeverSplitsZWJEmojiCJKOrCombiningMarks() throws {
        let family = "👨‍👩‍👧‍👦" // 11 UTF-16 units, one Character
        let flag = "🇮🇳"
        let combining = "e\u{301}\u{302}\u{303}" // one Character, 4 units
        let cjk = "漢字かな交じり文"
        let text = "hi " + family + family + flag + combining + cjk + "𠜎𠜱" // astral CJK: 2 units each
        let chunks = try #require(UnicodeTypingChunker.chunks(of: text))
        #expect(chunks.joined() == text)
        #expect(chunks.allSatisfy { $0.utf16.count <= 20 })
        // Every chunk boundary is a Character boundary of the whole text.
        var characterCount = 0
        for chunk in chunks {
            characterCount += chunk.count
            #expect(chunk.unicodeScalars.first.map { !$0.properties.isGraphemeExtend } ?? true)
        }
        #expect(characterCount == text.count)
        #expect(chunks.contains { $0.contains(family) })
        #expect(!chunks.contains { $0.unicodeScalars.first == "\u{200D}" })
    }

    @Test func chunkerRefusesMultiLineAndOversizedCharacters() {
        #expect(UnicodeTypingChunker.chunks(of: "two\nlines") == nil)
        let hugeCharacter = "a" + String(repeating: "\u{301}", count: 25)
        #expect(hugeCharacter.count == 1)
        #expect(UnicodeTypingChunker.chunks(of: hugeCharacter) == nil)
        #expect(UnicodeTypingChunker.chunks(of: "") == [])
    }

    @Test func controlCharactersAreStrippedExceptNewlineAndTab() {
        let body = "\nhello\u{0007}\tworld\r\nnext\u{001B}[31m line\u{0000}\u{007F}\u{0085}end\n"
        let prepared = TypeForMeText.prepare(blockBody: body)
        #expect(prepared.text == "hello\tworld\nnext[31m lineend")
        #expect(!prepared.wasTruncated)
        #expect(TypeForMeText.stripControlCharacters("a\rb") == "a\nb")
    }

    @Test func textIsCappedAtFiveThousandCharacters() {
        let prepared = TypeForMeText.prepare(blockBody: String(repeating: "é", count: 6000))
        #expect(prepared.text.count == 5000)
        #expect(prepared.wasTruncated)
        #expect(TypeForMeText.prepare(blockBody: String(repeating: "x", count: 5000)).wasTruncated == false)
        #expect(prepared.preview.count == 300 && prepared.preview.hasSuffix("…"))
    }

    @Test func terminalsGetNewlinesStrippedAndTwoConfirms() {
        #expect(TypeForMePolicy.isTerminal(bundleIdentifier: "com.apple.Terminal"))
        #expect(TypeForMePolicy.isTerminal(bundleIdentifier: "com.googlecode.iterm2"))
        #expect(TypeForMePolicy.isTerminal(bundleIdentifier: "dev.warp.Warp-Stable"))
        #expect(TypeForMePolicy.isTerminal(bundleIdentifier: "com.mitchellh.ghostty"))
        #expect(!TypeForMePolicy.isTerminal(bundleIdentifier: "com.apple.TextEdit"))
        #expect(!TypeForMePolicy.isTerminal(bundleIdentifier: nil))
        #expect(TypeForMePolicy.requiredConfirmCount(bundleIdentifier: "com.apple.Terminal") == 2)
        #expect(TypeForMePolicy.requiredConfirmCount(bundleIdentifier: "com.tinyspeck.slackmacgap") == 1)
        let prepared = TypeForMeText.prepare(blockBody: "git status\n\ngit log\r\n--oneline\n", stripsNewlines: true)
        #expect(prepared.text == "git status git log --oneline")
        #expect(prepared.isSingleLine)
    }
}

struct TypeForMePolicyTests {
    static let ownPID: Int32 = 500
    static let blocked: Set<String> = Set(ClickySettings.defaultTypeForMeBlockedBundleIDs)

    func facts(secureInput: Bool = false, bundle: String? = "com.apple.TextEdit", pid: Int32 = 900, focused: Bool = true,
               subrole: String? = nil, enabled: Bool = true) -> TypeForMeTargetFacts {
        TypeForMeTargetFacts(isFeatureEnabled: enabled, isSecureEventInputEnabled: secureInput, bundleIdentifier: bundle, processIdentifier: pid,
                             hasFocusedElement: focused, focusedElementRole: "AXTextArea", focusedElementSubrole: subrole)
    }

    func refusal(_ facts: TypeForMeTargetFacts) -> TypeForMeRefusal? {
        TypeForMePolicy.refusal(for: facts, ownBundleIdentifier: "com.clicky.app", ownProcessIdentifier: Self.ownPID, blockedBundleIdentifiers: Self.blocked)
    }

    @Test func allowsAnOrdinaryField() {
        #expect(refusal(facts()) == nil)
    }

    @Test func refusesSecureInputSecureFieldsOwnAppAndBlockedApps() {
        #expect(refusal(facts(secureInput: true)) == .secureEventInput)
        #expect(refusal(facts(subrole: "AXSecureTextField")) == .secureTextField)
        #expect(refusal(facts(pid: Self.ownPID)) == .ownApplication)
        #expect(refusal(facts(bundle: "com.clicky.app")) == .ownApplication)
        #expect(refusal(facts(bundle: "com.apple.keychainaccess")) == .blockedApplication(bundleIdentifier: "com.apple.keychainaccess"))
        #expect(refusal(facts(bundle: "com.1password.1password")) == .blockedApplication(bundleIdentifier: "com.1password.1password"))
        #expect(refusal(facts(focused: false)) == .noFocusedField)
        // Terminals are not blocked (they get a second confirm instead).
        #expect(refusal(facts(bundle: "com.apple.Terminal")) == nil)
    }

    @Test func disabledFeatureIsCopyOnlyButSecurityReasonsComeFirst() {
        #expect(refusal(facts(enabled: false)) == .featureDisabled)
        #expect(refusal(facts(secureInput: true, enabled: false)) == .secureEventInput)
        #expect(refusal(facts(subrole: "AXSecureTextField", enabled: false)) == .secureTextField)
    }

    @Test func blockedListSettingDefaultsToPasswordManagers() {
        #expect(ClickySettings.Keys.typeForMeBlockedBundleIDs == "v2.typeForMe.blockedBundleIDs")
        #expect(Self.blocked.contains("com.apple.keychainaccess"))
        #expect(Self.blocked.contains("com.apple.Passwords"))
        #expect(!Self.blocked.contains("com.apple.Terminal"))
    }
}

struct TypeInsertionLogicTests {
    @Test func menuFinderPicksPlainCommandVAndSkipsVariants() throws {
        let items = [
            MenuItemDescriptor(title: "Paste and Match Style", commandCharacter: "V", commandModifiers: 3, isEnabled: true, path: [3, 6]), // ⌥⇧⌘V
            MenuItemDescriptor(title: "Paste Special", commandCharacter: "V", commandModifiers: 1, isEnabled: true, path: [3, 7]),          // ⇧⌘V
            MenuItemDescriptor(title: "Copy", commandCharacter: "C", commandModifiers: 0, isEnabled: true, path: [3, 4]),
            MenuItemDescriptor(title: "Paste", commandCharacter: "V", commandModifiers: 0, isEnabled: true, path: [3, 5])
        ]
        #expect(try #require(PasteMenuFinder.plainPasteItem(in: items)).title == "Paste")
        let withoutPlain = items.filter { $0.title != "Paste" }
        #expect(PasteMenuFinder.plainPasteItem(in: withoutPlain) == nil)
        let disabledPaste = [MenuItemDescriptor(title: "Paste", commandCharacter: "V", commandModifiers: 0, isEnabled: false, path: [1])]
        #expect(PasteMenuFinder.plainPasteItem(in: disabledPaste) == nil)
        let unknownModifiers = [MenuItemDescriptor(title: "Paste?", commandCharacter: "V", commandModifiers: nil, isEnabled: true, path: [1])]
        #expect(PasteMenuFinder.plainPasteItem(in: unknownModifiers) == nil)
    }

    @Test func clipboardIsRestoredOnlyWhenChangeCountUnchanged() {
        #expect(PasteboardRestorePolicy.shouldRestore(changeCountAfterOurWrite: 41, currentChangeCount: 41))
        #expect(!PasteboardRestorePolicy.shouldRestore(changeCountAfterOurWrite: 41, currentChangeCount: 42))
        #expect(PasteboardRestorePolicy.restoreDelay == 0.35)
        #expect(PasteboardRestorePolicy.transientTypeIdentifier == "org.nspasteboard.TransientType")
    }

    @Test func verificationDecidesWhetherToTryTheNextMethod() {
        #expect(InsertionVerification.evaluate(valueBefore: "Hi ", valueAfter: "Hi there", insertedText: "there") == .verified)
        #expect(InsertionVerification.evaluate(valueBefore: "Hi ", valueAfter: "Hi ", insertedText: "there") == .unchanged)
        #expect(InsertionVerification.evaluate(valueBefore: "Hi ", valueAfter: nil, insertedText: "there") == .unverifiable)
        #expect(InsertionVerification.evaluate(valueBefore: nil, valueAfter: "x", insertedText: "there") == .unverifiable)
        #expect(InsertionVerification.evaluate(valueBefore: "", valueAfter: "a\rb", insertedText: "a\nb") == .verified)
    }

    @Test func insertionLogKeepsTheLastTwentyWithoutText() {
        var log = TypeInsertionLog()
        for index in 0..<25 {
            log.append(TypeInsertionLogEntry(date: Date(), applicationName: "App\(index)", fieldRole: "AXTextArea", textLength: index,
                                             method: .paste, result: .inserted))
        }
        #expect(log.entries.count == 20)
        #expect(log.entries.first?.applicationName == "App5")
        #expect(log.entries.last?.summaryLine == "App24 AXTextArea len=24 method=paste result=inserted")
    }
}

struct TypeConfirmGateTests {
    let shownAt: TimeInterval = 1000

    @Test func returnConfirmsOnKeyUpAfterTheIgnoreWindow() {
        var gate = TypeConfirmGate(shownAt: shownAt, isTypingAllowed: true)
        #expect(gate.handle(TypeConfirmInput(kind: .returnKeyDown(isRepeat: false), timestamp: shownAt + 0.6)) == .pressStarted)
        #expect(gate.handle(TypeConfirmInput(kind: .returnKeyUp, timestamp: shownAt + 0.7)) == .confirmed)
        // One confirm = one insertion.
        #expect(gate.handle(TypeConfirmInput(kind: .returnKeyDown(isRepeat: false), timestamp: shownAt + 1)) == .rejected(.alreadyConfirmed))
    }

    @Test func inputInTheFirstHalfSecondIsIgnored() {
        var gate = TypeConfirmGate(shownAt: shownAt, isTypingAllowed: true)
        #expect(gate.handle(TypeConfirmInput(kind: .returnKeyDown(isRepeat: false), timestamp: shownAt + 0.3)) == .rejected(.shownTooRecently))
        // The keyUp of that early press doesn't confirm either.
        #expect(gate.handle(TypeConfirmInput(kind: .returnKeyUp, timestamp: shownAt + 0.6)) == .rejected(.releaseWithoutPress))
        #expect(gate.handle(TypeConfirmInput(kind: .mouseDown(isOnTypeButton: true), timestamp: shownAt + 0.49)) == .rejected(.shownTooRecently))
        #expect(gate.handle(TypeConfirmInput(kind: .mouseUp(isOnTypeButton: true), timestamp: shownAt + 0.55)) == .rejected(.releaseWithoutPress))
    }

    @Test func autoRepeatIsIgnored() {
        var gate = TypeConfirmGate(shownAt: shownAt, isTypingAllowed: true)
        #expect(gate.handle(TypeConfirmInput(kind: .returnKeyDown(isRepeat: true), timestamp: shownAt + 2)) == .rejected(.autoRepeat))
        #expect(gate.handle(TypeConfirmInput(kind: .returnKeyUp, timestamp: shownAt + 2.1)) == .rejected(.releaseWithoutPress))
    }

    @Test func taggedEventsAreNeverConfirms() {
        var gate = TypeConfirmGate(shownAt: shownAt, isTypingAllowed: true)
        let tag = SyntheticEventTag.value
        #expect(gate.handle(TypeConfirmInput(kind: .returnKeyDown(isRepeat: false), timestamp: shownAt + 1, eventSourceUserData: tag)) == .rejected(.syntheticEvent))
        #expect(gate.handle(TypeConfirmInput(kind: .returnKeyDown(isRepeat: false), timestamp: shownAt + 1)) == .pressStarted)
        // A tagged release cancels the real press too.
        #expect(gate.handle(TypeConfirmInput(kind: .returnKeyUp, timestamp: shownAt + 1.1, eventSourceUserData: tag)) == .rejected(.syntheticEvent))
        #expect(gate.handle(TypeConfirmInput(kind: .returnKeyUp, timestamp: shownAt + 1.2)) == .rejected(.releaseWithoutPress))
        #expect(gate.handle(TypeConfirmInput(kind: .mouseDown(isOnTypeButton: true), timestamp: shownAt + 2, eventSourceUserData: tag)) == .rejected(.syntheticEvent))
    }

    @Test func mouseClickMustStartAndEndOnTheTypeButton() {
        var gate = TypeConfirmGate(shownAt: shownAt, isTypingAllowed: true)
        #expect(gate.handle(TypeConfirmInput(kind: .mouseDown(isOnTypeButton: false), timestamp: shownAt + 1)) == .rejected(.notOnTypeButton))
        #expect(gate.handle(TypeConfirmInput(kind: .mouseDown(isOnTypeButton: true), timestamp: shownAt + 1)) == .pressStarted)
        #expect(gate.handle(TypeConfirmInput(kind: .mouseUp(isOnTypeButton: false), timestamp: shownAt + 1.1)) == .rejected(.notOnTypeButton))
        #expect(gate.handle(TypeConfirmInput(kind: .mouseDown(isOnTypeButton: true), timestamp: shownAt + 2)) == .pressStarted)
        #expect(gate.handle(TypeConfirmInput(kind: .mouseUp(isOnTypeButton: true), timestamp: shownAt + 2.1)) == .confirmed)
    }

    @Test func confirmExpiresAfterThirtySecondsOrAFocusChange() {
        var gate = TypeConfirmGate(shownAt: shownAt, isTypingAllowed: true)
        #expect(!gate.isExpired(at: shownAt + 29.9))
        #expect(gate.isExpired(at: shownAt + 30))
        #expect(gate.handle(TypeConfirmInput(kind: .returnKeyDown(isRepeat: false), timestamp: shownAt + 31)) == .rejected(.expired))

        var focusGate = TypeConfirmGate(shownAt: shownAt, isTypingAllowed: true)
        #expect(focusGate.handle(TypeConfirmInput(kind: .returnKeyDown(isRepeat: false), timestamp: shownAt + 1)) == .pressStarted)
        focusGate.invalidateForFocusChange()
        #expect(focusGate.isExpired(at: shownAt + 1.05))
        #expect(focusGate.handle(TypeConfirmInput(kind: .returnKeyUp, timestamp: shownAt + 1.1)) == .rejected(.expired))
    }

    @Test func terminalsNeedASecondConfirmWithItsOwnIgnoreWindow() {
        var gate = TypeConfirmGate(shownAt: shownAt, isTypingAllowed: true, requiredConfirmCount: 2)
        #expect(gate.handle(TypeConfirmInput(kind: .returnKeyDown(isRepeat: false), timestamp: shownAt + 1)) == .pressStarted)
        #expect(gate.handle(TypeConfirmInput(kind: .returnKeyUp, timestamp: shownAt + 1.1)) == .needsAnotherConfirm(remaining: 1))
        // A quick second tap within 0.5 s of the first confirm is ignored.
        #expect(gate.handle(TypeConfirmInput(kind: .returnKeyDown(isRepeat: false), timestamp: shownAt + 1.3)) == .rejected(.shownTooRecently))
        #expect(gate.handle(TypeConfirmInput(kind: .returnKeyDown(isRepeat: false), timestamp: shownAt + 1.8)) == .pressStarted)
        #expect(gate.handle(TypeConfirmInput(kind: .returnKeyUp, timestamp: shownAt + 1.9)) == .confirmed)
    }

    @Test func copyOnlyCardsNeverConfirm() {
        var gate = TypeConfirmGate(shownAt: shownAt, isTypingAllowed: false)
        #expect(gate.handle(TypeConfirmInput(kind: .returnKeyDown(isRepeat: false), timestamp: shownAt + 1)) == .rejected(.typingNotAllowed))
        #expect(gate.handle(TypeConfirmInput(kind: .returnKeyUp, timestamp: shownAt + 1.1)) == .rejected(.typingNotAllowed))
    }
}

@MainActor
struct TypeForMeEventTests {
    @Test func realReturnEventsMapAndSynthesizedOnesAreTagged() throws {
        let now = ProcessInfo.processInfo.systemUptime
        let returnDown = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: now, windowNumber: 1, context: nil,
                                                       characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        let repeatDown = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: now, windowNumber: 1, context: nil,
                                                       characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: true, keyCode: 76))
        let otherKey = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: now, windowNumber: 1, context: nil,
                                                     characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        #expect(TypeConfirmEventMapping.confirmInput(from: returnDown)?.kind == .returnKeyDown(isRepeat: false))
        #expect(TypeConfirmEventMapping.confirmInput(from: repeatDown)?.kind == .returnKeyDown(isRepeat: true))
        #expect(TypeConfirmEventMapping.confirmInput(from: otherKey) == nil)
        #expect(TypeConfirmEventMapping.isPhysicalInterruption(otherKey))

        // Every event Clicky would post is tagged; a tagged event can't confirm or count as physical input.
        let commandV = TypeForMeSyntheticEvents.commandVEvents()
        #expect(commandV.count == 2)
        #expect(commandV.allSatisfy { $0.getIntegerValueField(.eventSourceUserData) == SyntheticEventTag.value })
        #expect(commandV.allSatisfy { $0.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl]) == .maskCommand })
        let unicode = TypeForMeSyntheticEvents.unicodeEvents(for: "héllo 👋")
        #expect(unicode.count == 2)
        #expect(unicode.allSatisfy { $0.getIntegerValueField(.eventSourceUserData) == SyntheticEventTag.value })
        #expect(unicode.allSatisfy { TypeForMeSyntheticEvents.areNoModifiersHeld($0.flags) })
        #expect(TypeForMeSyntheticEvents.unicodeEvents(for: String(repeating: "a", count: 21)).isEmpty)

        let taggedReturn = try #require(SyntheticEvents.keyEvent(virtualKey: 36, keyDown: true))
        let taggedNSEvent = try #require(NSEvent(cgEvent: taggedReturn))
        let taggedInput = try #require(TypeConfirmEventMapping.confirmInput(from: taggedNSEvent))
        var gate = TypeConfirmGate(shownAt: 0, isTypingAllowed: true)
        #expect(gate.handle(TypeConfirmInput(kind: taggedInput.kind, timestamp: 5, eventSourceUserData: taggedInput.eventSourceUserData)) == .rejected(.syntheticEvent))
        #expect(!TypeConfirmEventMapping.isPhysicalInterruption(taggedNSEvent))
    }

    @Test func modifierCheckLooksOnlyAtControlOptionCommandShift() {
        #expect(TypeForMeSyntheticEvents.areNoModifiersHeld([]))
        #expect(TypeForMeSyntheticEvents.areNoModifiersHeld([.maskAlphaShift, .maskNumericPad]))
        #expect(!TypeForMeSyntheticEvents.areNoModifiersHeld(.maskCommand))
        #expect(!TypeForMeSyntheticEvents.areNoModifiersHeld(.maskShift))
        #expect(!TypeForMeSyntheticEvents.areNoModifiersHeld(.maskAlternate))
        #expect(!TypeForMeSyntheticEvents.areNoModifiersHeld(.maskControl))
    }

    @Test func cardSitsBelowTheCaretAndStaysOnScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let size = CGSize(width: 380, height: 220)
        let below = TypeCardPlacement.frame(caretAppKit: CGRect(x: 200, y: 500, width: 2, height: 18), cardSize: size, visibleFrames: [screen])
        #expect(below.maxY == 492 && below.minX == 200)
        let nearBottom = TypeCardPlacement.frame(caretAppKit: CGRect(x: 1300, y: 40, width: 2, height: 18), cardSize: size, visibleFrames: [screen])
        #expect(nearBottom.minY == 66) // flipped above the caret
        #expect(nearBottom.maxX == 1440)
    }

    @Test func rendersTypeCardOffscreen() throws {
        let prepared = TypeForMeText.prepare(blockBody: "sounds good — i'll send the deck over by three, and we can go through the numbers together tomorrow morning.")
        let state = TypeCardState(applicationName: "Slack", applicationIcon: NSImage(systemSymbolName: "bubble.left.and.bubble.right.fill", accessibilityDescription: nil),
                                  fieldDescription: "text area · Message to Adhyan", preview: prepared.preview,
                                  characterCountDescription: "\(prepared.text.count) characters",
                                  insertionMethodDescription: TypeForMePolicy.insertionMethodDescription(isTerminal: false, isSingleLine: prepared.isSingleLine),
                                  refusalExplanation: nil)
        let renderer = ImageRenderer(content: TypeCardView(state: state, usesStaticButtons: true).padding(12))
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        #expect(image.size.width >= TypeCardView.cardWidth)
        let outputDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Clicky/renders/p6", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: outputDirectory.appendingPathComponent("type-card.png"))

        let refused = TypeCardState(applicationName: "1Password", applicationIcon: nil, fieldDescription: "secure text field", preview: "hunter2",
                                    characterCountDescription: "7 characters", insertionMethodDescription: "",
                                    refusalExplanation: TypeForMeRefusal.secureTextField.cardExplanation)
        #expect(!refused.offersTyping)
        let refusedImage = try #require(ImageRenderer(content: TypeCardView(state: refused, usesStaticButtons: true)).nsImage)
        #expect(refusedImage.size.height > 80)
        if let refusedTIFF = refusedImage.tiffRepresentation, let refusedPNG = NSBitmapImageRep(data: refusedTIFF)?.representation(using: .png, properties: [:]) {
            try refusedPNG.write(to: outputDirectory.appendingPathComponent("type-card-refused.png"))
        }
    }
}

struct TypeForMePromptAndRouterTests {
    @Test func typingSectionIsGatedAndSaysToConfirmOnTheCard() {
        let texts: [SystemPromptBuilder.GatedSection: String] = [.typing: TypeForMePrompt.sectionText]
        let withTyping = SystemPromptBuilder.mainSystemPrompt(features: [.grounding, .typing], sectionTexts: texts)
        #expect(withTyping.contains("<type>"))
        #expect(withTyping.contains("click Type or press Return on the card"))
        #expect(withTyping.contains("never say it's typed"))
        #expect(!withTyping.contains("type for the user yet"))
        let withoutTyping = SystemPromptBuilder.mainSystemPrompt(features: [.grounding], sectionTexts: texts)
        #expect(!withoutTyping.contains("typing for the user:"))
        #expect(withoutTyping.contains("type for the user yet"))
    }

    @Test func routerHandsTypeBlocksToTheCard() {
        var router = ResponseRouter(blockConsumers: ["whiteboard", "type"])
        let outputs = router.feed("here you go, click Type or press Return on the card. <type>see you at 3</type> ") + router.finish()
        #expect(outputs.contains(.block(name: "type", body: "see you at 3")))
        #expect(!outputs.contains { if case .narration(let text) = $0 { return text.contains("see you") } else { return false } })
    }
}
