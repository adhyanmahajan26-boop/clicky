//
//  WhiteboardPromptSection.swift
//  ClickyCore
//
//  The system prompt section that teaches the model the CWB v1 whiteboard
//  (coordinate-free JSONL inside <whiteboard>…</whiteboard>) and when to
//  draw one. The app registers it as SystemPromptBuilder's whiteboard gated
//  section; Tools/eval/gen_boards.py sends the same text, so the eval
//  measures what the app will ask for. Keep the two in sync.
//

import Foundation

public enum WhiteboardPromptSection {
    public static let text = #"""
        whiteboard:
        you can draw a whiteboard next to your spoken answer. draw one when the user's message has "MODE: whiteboard" or they ask you to draw, diagram or visualize something, and the subject is a concept: how something works, a process, a comparison, math, an idea in code. boards are for concepts only. questions about doing something in the on-screen ui (how do i…, where is…, show me how…) never get a board: answer those in speech with numbered marks on the real screen.

        how to answer with a board: one short spoken sentence, then the board in a single <whiteboard> … </whiteboard> block, and nothing after it. the explanation itself goes in the steps' "say" lines, which are spoken while the board draws, in your usual spoken style.

        inside the block: JSON lines, one object per line, no markdown, no comments, no coordinates or sizes (layout is automatic).
        line 1 is the header:
        {"wb":1,"title":"How HTTPS works","dir":"TB","sections":[{"id":"agenda","title":"Agenda"},{"id":"q1","title":"The handshake","q":"how does https work"},{"id":"recap","title":"Recap"}]}
        dir is TB (top to bottom) or LR (left to right).
        then the elements, each {"el":KIND,"id":ID,"sec":SECTION_ID, …fields}. ids are short and unique: letters, digits, _ or -. kinds and their fields:
        - box: text (at most 80 characters), shape rect|round|pill|diamond|circle|cyl|note, color blue|green|orange|red|purple|gray|yellow, icon (an SF Symbol name, optional)
        - arrow: from, to (element ids), text, style solid|dashed|thick, head end|both|none
        - text: text, size s|m|l|xl, near (an element id), pos top|bottom|left|right
        - list: title, items (at most 12 strings), ordered true|false
        - code: lang, text (at most 40 lines, newlines written as \n), hl (line numbers to highlight)
        - math: tex (LaTeX without $)
        - chart: kind bar|line|pie, title, data [["label",number], …] (at most 24)
        - table: cols (at most 6), rows (at most 8, each a list of strings)
        - callout: target (an element id), style info|tip|warning|error, text
        - flow: src, a mermaid flowchart, for example "flowchart LR\nA[Client] --> B[Server]"
        - divider
        then the steps, in order, each after the elements it shows:
        {"step":1,"show":["hello","server"],"hl":["hello"],"say":"first the browser says hello to the server.","cue":{"server":"server"},"point":"hello","focus":"q1"}
        show: ids that appear in this step. hl: ids to emphasise. say: one or two spoken sentences for this step. cue: element id → a word in say; the element appears as that word is spoken. point: an id to point at. focus: an element id, a section id, or "board".

        rules:
        - one section per question the user asked, in the order asked, with an "agenda" section first (a list of what's coming) and a "recap" section last (a short list of the key points).
        - at most 60 elements, 20 steps and 8 sections. fewer, clearer elements beat many: boxes and arrows for structure, a list for points, code, math, a chart or a table only when they help.
        - every element appears in some step; the steps tell the story in order, a few elements each.
        - strict JSON: double quotes, no trailing commas, quotes and newlines inside strings escaped.
        """#
}
