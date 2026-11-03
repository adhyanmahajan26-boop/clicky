//
//  ComposerDictationTests.swift
//  ClickyCoreTests
//
//  Dictating into the chat box: words land at the cursor, cancelling restores the text, the steps, silence and keys.
//

import XCTest
@testable import ClickyCore

final class ComposerDictationTests: XCTestCase {
    // MARK: Words at the cursor

    func testWordsGoAtTheEndWithNoCursorKnown() {
        var draft = ComposerDictationDraft(text: "Hello")
        draft.hear("there friend")
        XCTAssertEqual(draft.text, "Hello there friend")
        XCTAssertEqual(draft.cursorAfterWords, 18)
    }

    func testWordsGoInTheMiddleAndKeepWhatWasTyped() {
        var draft = ComposerDictationDraft(text: "Send the report", selection: (location: 5, length: 0))
        draft.hear("over")
        XCTAssertEqual(draft.text, "Send over the report")
        XCTAssertEqual(draft.cursorAfterWords, 9)
    }

    func testEmptyFieldNeedsNoSpaces() {
        var draft = ComposerDictationDraft(text: "")
        draft.hear("hi")
        XCTAssertEqual(draft.text, "hi")
        XCTAssertEqual(draft.cursorAfterWords, 2)
    }

    func testExistingSpacesArentDoubled() {
        var draft = ComposerDictationDraft(text: "one  two", selection: (location: 4, length: 0))
        draft.hear("and")
        XCTAssertEqual(draft.text, "one and two")
    }

    func testNoSpaceBeforePunctuation() {
        var before = ComposerDictationDraft(text: "Fine", selection: nil)
        before.hear(", thanks")
        XCTAssertEqual(before.text, "Fine, thanks")
        var after = ComposerDictationDraft(text: "Fine.", selection: (location: 4, length: 0))
        after.hear("thanks")
        XCTAssertEqual(after.text, "Fine thanks.")
    }

    func testASelectionIsKeptAndTheWordsFollowIt() {
        var draft = ComposerDictationDraft(text: "keep this text", selection: (location: 5, length: 4))
        draft.hear("and that")
        XCTAssertEqual(draft.text, "keep this and that text")
    }

    func testCursorIsClampedToTheText() {
        var draft = ComposerDictationDraft(text: "abc", selection: (location: 99, length: 0))
        draft.hear("d")
        XCTAssertEqual(draft.text, "abc d")
        XCTAssertEqual(ComposerDictationDraft(text: "abc", selection: (location: -4, length: 0)).cursor, 0)
    }

    func testCursorInsideAnEmojiMovesPastIt() {
        var draft = ComposerDictationDraft(text: "a😀b", selection: (location: 2, length: 0))
        draft.hear("x")
        XCTAssertEqual(draft.text, "a😀 x b")
    }

    func testHindiStaysWhole() {
        var draft = ComposerDictationDraft(text: "नमस्ते", selection: nil)
        draft.hear("दोस्त")
        XCTAssertEqual(draft.text, "नमस्ते दोस्त")
    }

    func testPartialsReviseRatherThanPile() {
        var draft = ComposerDictationDraft(text: "")
        draft.hear("the qui")
        draft.hear("the quick")
        draft.hear("the quick brown fox")
        XCTAssertEqual(draft.text, "the quick brown fox")
    }

    func testRecognizerStartingOverKeepsWhatItHeard() {
        var draft = ComposerDictationDraft(text: "")
        draft.hear("this first sentence is done")
        draft.hear("and")
        draft.hear("and another one")
        XCTAssertEqual(draft.spoken, "this first sentence is done and another one")
    }

    func testAShorterRevisionIsNotAFreshStart() {
        var draft = ComposerDictationDraft(text: "")
        draft.hear("the quick brown fox jumps over")
        draft.hear("the quick")
        XCTAssertEqual(draft.spoken, "the quick")
    }

    func testFinalWordsReplaceEverything() {
        var draft = ComposerDictationDraft(text: "Note:")
        draft.hear("um send it")
        draft.settle("Send it.")
        XCTAssertEqual(draft.text, "Note: Send it.")
    }

    // MARK: Cancel

    func testCancelGivesBackExactlyWhatWasTyped() {
        let typed = "  half a thought 😀\n"
        var draft = ComposerDictationDraft(text: typed, selection: (location: 7, length: 0))
        draft.hear("spoken words here")
        draft.settle("different words")
        XCTAssertEqual(draft.original, typed)
    }

    func testNoWordsLeaveTheTextAlone() {
        let draft = ComposerDictationDraft(text: "typed", selection: (location: 2, length: 0))
        XCTAssertEqual(draft.text, "typed")
        var heardNothing = draft
        heardNothing.hear("   ")
        XCTAssertEqual(heardNothing.text, "typed")
    }

    // MARK: Steps

    func testTheNormalWayThrough() {
        var machine = ComposerDictationMachine()
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertTrue(machine.handle(.start))
        XCTAssertEqual(machine.phase, .listening)
        XCTAssertTrue(machine.isActive)
        XCTAssertTrue(machine.handle(.stop))
        XCTAssertEqual(machine.phase, .finishing)
        XCTAssertTrue(machine.handle(.wordsLanded))
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertFalse(machine.isActive)
    }

    func testCancelFromListeningOrFinishing() {
        var machine = ComposerDictationMachine()
        machine.handle(.start)
        XCTAssertTrue(machine.handle(.cancel))
        XCTAssertEqual(machine.phase, .idle)
        machine.handle(.start)
        machine.handle(.stop)
        XCTAssertTrue(machine.handle(.cancel))
        XCTAssertEqual(machine.phase, .idle)
    }

    func testAMissingPermissionStopsItBeforeListening() {
        var machine = ComposerDictationMachine()
        XCTAssertTrue(machine.handle(.refused(.microphoneDenied)))
        XCTAssertEqual(machine.phase, .problem(.microphoneDenied))
        XCTAssertFalse(machine.isActive)
        XCTAssertTrue(machine.handle(.dismiss))
        XCTAssertEqual(machine.phase, .idle)
    }

    func testStartingAgainFromAProblem() {
        var machine = ComposerDictationMachine()
        machine.handle(.refused(.speechDenied))
        XCTAssertTrue(machine.handle(.start))
        XCTAssertEqual(machine.phase, .listening)
    }

    func testFailuresWhileRunning() {
        var machine = ComposerDictationMachine()
        machine.handle(.start)
        XCTAssertTrue(machine.handle(.failed(.microphoneFailed)))
        XCTAssertEqual(machine.phase, .problem(.microphoneFailed))
        machine.handle(.start)
        machine.handle(.stop)
        XCTAssertTrue(machine.handle(.failed(.nothingHeard)))
        XCTAssertEqual(machine.phase, .problem(.nothingHeard))
    }

    func testLateEventsDoNothing() {
        var machine = ComposerDictationMachine()
        XCTAssertFalse(machine.handle(.stop))
        XCTAssertFalse(machine.handle(.wordsLanded))
        XCTAssertFalse(machine.handle(.cancel))
        machine.handle(.start)
        XCTAssertFalse(machine.handle(.start))
        XCTAssertFalse(machine.handle(.wordsLanded))
        XCTAssertFalse(machine.handle(.refused(.busy)))
        machine.handle(.cancel)
        XCTAssertFalse(machine.handle(.wordsLanded))
        XCTAssertEqual(machine.phase, .idle)
    }

    // MARK: Permissions

    func testPermissionProblems() {
        XCTAssertNil(ComposerDictationPermissions.problem(microphone: .granted, speech: .granted, hasCloudEars: false))
        XCTAssertEqual(ComposerDictationPermissions.problem(microphone: .denied, speech: .granted, hasCloudEars: false), .microphoneDenied)
        XCTAssertEqual(ComposerDictationPermissions.problem(microphone: .undecided, speech: .denied, hasCloudEars: false), .microphoneUndecided)
        XCTAssertEqual(ComposerDictationPermissions.problem(microphone: .granted, speech: .denied, hasCloudEars: false), .speechDenied)
        XCTAssertEqual(ComposerDictationPermissions.problem(microphone: .granted, speech: .undecided, hasCloudEars: false), .speechUndecided)
        XCTAssertNil(ComposerDictationPermissions.problem(microphone: .granted, speech: .denied, hasCloudEars: true))
        XCTAssertEqual(ComposerDictationPermissions.problem(microphone: .denied, speech: .granted, hasCloudEars: true), .microphoneDenied)
    }

    func testOnlyPermissionNotesStay() {
        XCTAssertTrue(ComposerDictationProblem.microphoneDenied.needsPermission)
        XCTAssertFalse(ComposerDictationProblem.microphoneDenied.isBrief)
        XCTAssertTrue(ComposerDictationProblem.speechUndecided.isUndecided)
        XCTAssertFalse(ComposerDictationProblem.nothingHeard.needsPermission)
        XCTAssertTrue(ComposerDictationProblem.nothingHeard.isBrief)
    }

    func testNoUsableMicrophoneIsItsOwnNote() {
        struct OtherError: Error {}
        XCTAssertEqual(ComposerDictationProblem(micStartError: DictationMicError.noUsableMicrophone), .noUsableMicrophone)
        XCTAssertEqual(ComposerDictationProblem(micStartError: OtherError()), .microphoneFailed)
        let problem = ComposerDictationProblem.noUsableMicrophone
        XCTAssertEqual(problem.message, "No usable microphone.")
        // Settings can't fix it, and it stays until it's dismissed.
        XCTAssertFalse(problem.needsPermission)
        XCTAssertFalse(problem.isBrief)
    }

    func testNoUsableMicrophoneNeverReachesListening() {
        var machine = ComposerDictationMachine()
        XCTAssertTrue(machine.handle(.refused(.noUsableMicrophone)))
        XCTAssertEqual(machine.phase, .problem(.noUsableMicrophone))
        XCTAssertFalse(machine.isActive)
        XCTAssertFalse(machine.handle(.stop))
        XCTAssertTrue(machine.handle(.dismiss))
        XCTAssertEqual(machine.phase, .idle)
    }

    // MARK: Silence

    func testStopsThreeSecondsAfterTheLastSpeech() {
        var rule = ComposerSilenceRule(seconds: 3, startedAt: 100)
        rule.note(level: 0.8, at: 101)
        rule.note(level: 0.1, at: 102)
        XCTAssertFalse(rule.shouldStop(at: 103.9))
        XCTAssertTrue(rule.shouldStop(at: 104))
    }

    func testNewWordsCountAsSpeechEvenWhenQuiet() {
        var rule = ComposerSilenceRule(seconds: 3, startedAt: 0)
        rule.noteWords(at: 5)
        XCTAssertFalse(rule.shouldStop(at: 7))
        XCTAssertTrue(rule.shouldStop(at: 8))
    }

    func testAQuietRoomGetsLongerToStart() {
        var rule = ComposerSilenceRule(seconds: 3, startedAt: 0)
        rule.note(level: 0.2, at: 4)
        XCTAssertFalse(rule.shouldStop(at: 5))
        XCTAssertEqual(rule.secondsBeforeSpeech, 9)
        XCTAssertTrue(rule.shouldStop(at: 9))
    }

    func testOffNeverStopsUntilTheLongLimit() {
        let rule = ComposerSilenceRule(seconds: nil, startedAt: 0)
        XCTAssertFalse(rule.shouldStop(at: 599))
        XCTAssertTrue(rule.shouldStop(at: 600))
    }

    // MARK: Keys

    private func press(_ keyboard: inout ComposerDictationKeyboard, _ key: ComposerDictationKeyboard.Key, _ phase: ComposerDictationPhase,
                       focused: Bool = true, shortcut: ComposerDictationShortcut = .optionSpace, at time: Double = 0) -> ComposerDictationKeyboard.Action {
        keyboard.handle(key, phase: phase, composerFocused: focused, shortcut: shortcut, at: time)
    }

    func testOptionSpaceNeedsTheComposerFocused() {
        var keys = ComposerDictationKeyboard()
        XCTAssertEqual(press(&keys, .optionSpace, .idle, focused: false), .pass)
        XCTAssertEqual(press(&keys, .optionSpace, .idle, focused: true), .start)
    }

    func testATapStaysOnAndASecondTapKeeps() {
        var keys = ComposerDictationKeyboard()
        XCTAssertEqual(press(&keys, .optionSpace, .idle, at: 0), .start)
        XCTAssertEqual(press(&keys, .spaceUp, .listening, at: 0.1), .swallow)
        XCTAssertEqual(press(&keys, .optionSpace, .listening, at: 2), .keep)
        XCTAssertEqual(press(&keys, .spaceUp, .finishing, at: 2.1), .pass)
    }

    func testAHoldStopsOnRelease() {
        var keys = ComposerDictationKeyboard()
        XCTAssertEqual(press(&keys, .optionSpace, .idle, at: 0), .start)
        XCTAssertEqual(press(&keys, .optionSpaceRepeat, .listening, at: 0.5), .swallow)
        XCTAssertEqual(press(&keys, .spaceUp, .listening, at: 3), .keep)
    }

    func testAPlainSpaceUpIsLeftAlone() {
        var keys = ComposerDictationKeyboard()
        XCTAssertEqual(press(&keys, .spaceUp, .idle), .pass)
        XCTAssertEqual(press(&keys, .optionSpaceRepeat, .idle), .pass)
    }

    func testCommandShiftDWorksWithoutFocus() {
        var keys = ComposerDictationKeyboard()
        XCTAssertEqual(press(&keys, .commandShiftD, .idle, focused: false), .start)
        XCTAssertEqual(press(&keys, .commandShiftD, .listening, focused: false), .keep)
        XCTAssertEqual(press(&keys, .commandShiftD, .finishing), .swallow)
    }

    func testEscapeCancelsOrDismissesOrIsLeftAlone() {
        var keys = ComposerDictationKeyboard()
        XCTAssertEqual(press(&keys, .escape, .listening), .cancel)
        XCTAssertEqual(press(&keys, .escape, .finishing), .cancel)
        XCTAssertEqual(press(&keys, .escape, .problem(.microphoneDenied)), .dismiss)
        XCTAssertEqual(press(&keys, .escape, .idle), .pass)
    }

    func testEnterKeepsAndNeverReachesSend() {
        var keys = ComposerDictationKeyboard()
        XCTAssertEqual(press(&keys, .enter, .listening), .keep)
        XCTAssertEqual(press(&keys, .enter, .finishing), .swallow)
        XCTAssertEqual(press(&keys, .enter, .idle), .pass)
    }

    func testShortcutSettings() {
        var keys = ComposerDictationKeyboard()
        XCTAssertEqual(press(&keys, .optionSpace, .idle, shortcut: .commandShiftD), .pass)
        XCTAssertEqual(press(&keys, .commandShiftD, .idle, shortcut: .commandShiftD), .start)
        XCTAssertEqual(press(&keys, .optionSpace, .idle, shortcut: .micButtonOnly), .pass)
        XCTAssertEqual(press(&keys, .commandShiftD, .idle, shortcut: .micButtonOnly), .pass)
        XCTAssertEqual(press(&keys, .escape, .listening, shortcut: .micButtonOnly), .cancel)
    }

    func testTimerText() {
        XCTAssertEqual(ComposerDictationTimer.text(seconds: 7), "0:07")
        XCTAssertEqual(ComposerDictationTimer.text(seconds: 723), "12:03")
    }
}
