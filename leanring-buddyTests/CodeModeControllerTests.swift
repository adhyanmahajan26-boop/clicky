//
//  CodeModeControllerTests.swift
//  leanring-buddyTests
//
//  App-side Code mode checks that need no window, voice or network: a bad
//  <codetask> body is refused (AnswerSession then says "I couldn't read that
//  code task."), PR numbers come out of `gh pr create` URLs, and the review
//  panel's content renders offscreen. Compiled by build-for-testing; the
//  logic that runs processes is covered by ClickyCore's swift tests.
//

import AppKit
import ClickyCore
import Foundation
import SwiftUI
import Testing
@testable import Clicky

@MainActor
struct CodeModeControllerTests {
    @Test func refusesUndecodableCodeTask() {
        var spokenLines: [String] = []
        let controller = CodeModeController { spokenLines.append($0) }
        #expect(!controller.handleCodeTaskBlock(#"{"action":"push_everything","repo":"x","instructions":"y"}"#, context: CodeTurnContext(transcript: "t")))
        #expect(!controller.handleCodeTaskBlock("not json", context: CodeTurnContext(transcript: "t")))
        #expect(spokenLines.isEmpty)
        #expect(!controller.isBusy)
    }

    @Test func pullRequestNumberFromCreateURL() {
        #expect(CodeModeController.pullRequestNumber(fromURL: "https://github.com/acme/altron-engine/pull/42") == 42)
        #expect(CodeModeController.pullRequestNumber(fromURL: "https://github.com/acme/altron-engine") == nil)
    }

    @Test func reviewPanelRendersOffscreen() throws {
        let content = CodeReviewContent(repositoryFullName: "acme/altron-engine", pullRequestNumber: 12, oldOID: "1111111", newOID: "2222222",
                                        summary: "Summary", buttons: [.init(id: "push", title: "Push", gatedAction: .push, commands: [], isPrimary: true)])
        let renderer = ImageRenderer(content: ReviewPanelView(state: ReviewPanelState(content: content), usesStaticButtons: true).frame(width: 700, height: 500))
        #expect(renderer.nsImage != nil)
    }
}
