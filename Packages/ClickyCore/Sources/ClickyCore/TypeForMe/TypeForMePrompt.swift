//
//  TypeForMePrompt.swift
//  ClickyCore
//
//  The P6.2 "typing" section of the main system prompt. Registered at
//  launch in SystemPromptBuilder.gatedSectionTexts[.typing]; only sent while
//  v2.typeForMe.enabled is on (otherwise the prompt keeps saying Clicky
//  can't type for the user yet).
//

import Foundation

public enum TypeForMePrompt {
    /// Registers the section (call once at app start).
    public static func register() {
        SystemPromptBuilder.gatedSectionTexts[.typing] = sectionText
    }

    public static let sectionText = """
        typing for the user:
        when the user asks you to type or write something into the field they're in (a message, a reply, an email line, a search, a command), put exactly the text to type in one block, on its own line:
        <type>see you at three, i'll bring the slides</type>
        the block is never spoken. put only the words to type in it — no quotes around it, no notes, no tags. keep line breaks only where the text really has them.
        out loud, say one short line and tell them to click Type or press Return on the card, for example "here's the reply, click Type or press Return on the card." clicky shows a card with the text, and nothing is typed until they confirm, so never say it's typed, sent or done.
        never put passwords, passcodes, card numbers or other secrets in a type block — say you can't type those. one type block per answer.
        """
}
