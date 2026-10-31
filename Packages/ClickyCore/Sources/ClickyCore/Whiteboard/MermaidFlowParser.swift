//
//  MermaidFlowParser.swift
//  ClickyCore
//
//  Reads the Mermaid flowchart subset models actually write inside a
//  whiteboard "flow" element and turns it into board boxes and arrows, so a
//  flow is laid out and animated like any other part of the board:
//   - header `flowchart` / `graph` + TB, TD, BT, RL or LR;
//   - nodes `A[t]` rect, `A(t)` round, `A([t])` pill, `A{t}` diamond,
//     `A((t))` circle, `A[(t)]` cylinder ("t" may be quoted);
//   - links `-->` solid, `---` no head, `-.->` dashed, `==>` thick (longer
//     forms and `<-->` too), labels `-->|t|` and `-- t -->`;
//   - chains `A --> B --> C`, groups `A & B --> C`, `;` separators;
//   - `%%` comments, `subgraph id [title] … end` (a WBFlowGroup);
//   - style / classDef / class / linkStyle / click / direction lines are ignored.
//  Inner ids are "<flow id>.<node id>" so they stay unique on the board.
//  Unparseable statements are skipped; nothing here throws.
//

import Foundation

public enum MermaidFlowParser {
    public static func parse(_ source: String, flowIdentifier: String, sectionIdentifier: String) -> WBFlow {
        var builder = FlowBuilder(flowIdentifier: flowIdentifier, sectionIdentifier: sectionIdentifier)
        var direction = WBDirection.topToBottom
        var hasSeenHeader = false

        for rawLine in source.components(separatedBy: .newlines) {
            let lineWithoutComment = rawLine.components(separatedBy: "%%")[0]
            for rawStatement in splitStatements(lineWithoutComment) {
                let statement = rawStatement.trimmingCharacters(in: .whitespaces)
                guard !statement.isEmpty else { continue }
                let firstWord = statement.split(separator: " ", maxSplits: 1).first.map { String($0).lowercased() } ?? ""
                if !hasSeenHeader, firstWord == "flowchart" || firstWord == "graph" {
                    hasSeenHeader = true
                    let directionWord = statement.split(separator: " ").dropFirst().first.map { String($0).uppercased() } ?? "TB"
                    direction = (directionWord == "LR" || directionWord == "RL") ? .leftToRight : .topToBottom
                    continue
                }
                switch firstWord {
                case "subgraph":
                    builder.openGroup(String(statement.dropFirst("subgraph".count)).trimmingCharacters(in: .whitespaces))
                case "end":
                    builder.closeGroup()
                case "style", "classdef", "class", "linkstyle", "click", "direction":
                    continue
                default:
                    parseStatement(statement, into: &builder)
                }
            }
        }
        return WBFlow(source: source, direction: direction, elements: builder.boxes + builder.arrows, groups: builder.groups)
    }

    /// Splits at ";" outside brackets and quotes.
    private static func splitStatements(_ line: String) -> [String] {
        var statements: [String] = []
        var currentStatement = ""
        var bracketDepth = 0
        var isInsideQuotes = false
        for character in line {
            if character == "\"" { isInsideQuotes.toggle() }
            if !isInsideQuotes {
                if "[({".contains(character) { bracketDepth += 1 }
                if "])}".contains(character) { bracketDepth = max(0, bracketDepth - 1) }
                if character == ";", bracketDepth == 0 {
                    statements.append(currentStatement)
                    currentStatement = ""
                    continue
                }
            }
            currentStatement.append(character)
        }
        statements.append(currentStatement)
        return statements
    }

    // MARK: - Statements

    private struct ParsedNode {
        var identifier: String
        var text: String?
        var shape: WBBoxShape?
    }

    private struct ParsedLink {
        var style: WBArrowStyle
        var head: WBArrowHead
        var label: String?
    }

    /// `group (link group)*`, where a group is `node (& node)*`.
    private static func parseStatement(_ statement: String, into builder: inout FlowBuilder) {
        var cursor = Cursor(Array(statement))
        guard var previousGroup = parseNodeGroup(&cursor) else { return }
        for node in previousGroup { builder.mention(node) }
        while true {
            cursor.skipSpaces()
            guard !cursor.isAtEnd, let link = parseLink(&cursor) else { return }
            cursor.skipSpaces()
            guard let nextGroup = parseNodeGroup(&cursor) else { return }
            for node in nextGroup { builder.mention(node) }
            for fromNode in previousGroup {
                for toNode in nextGroup {
                    builder.link(from: fromNode.identifier, to: toNode.identifier, link: link)
                }
            }
            previousGroup = nextGroup
        }
    }

    private static func parseNodeGroup(_ cursor: inout Cursor) -> [ParsedNode]? {
        var nodes: [ParsedNode] = []
        while true {
            cursor.skipSpaces()
            guard let node = parseNode(&cursor) else { break }
            nodes.append(node)
            cursor.skipSpaces()
            guard cursor.peek() == "&" else { break }
            cursor.advance()
        }
        return nodes.isEmpty ? nil : nodes
    }

    private static func parseNode(_ cursor: inout Cursor) -> ParsedNode? {
        var identifier = ""
        while let character = cursor.peek() {
            let isIdentifierCharacter = character.isLetter || character.isNumber || character == "_"
            // "-" only inside a name (my-node), never the start of a link.
            let isInnerHyphen = character == "-" && !identifier.isEmpty && (cursor.peek(offset: 1).map { $0.isLetter || $0.isNumber } ?? false)
            guard isIdentifierCharacter || isInnerHyphen else { break }
            identifier.append(character)
            cursor.advance()
        }
        guard !identifier.isEmpty else { return nil }
        var node = ParsedNode(identifier: identifier)
        let shapeOpeners: [(opener: String, closer: String, shape: WBBoxShape)] = [
            ("([", "])", .pill), ("[(", ")]", .cyl), ("((", "))", .circle), ("{{", "}}", .diamond),
            ("[/", "/]", .rect), ("[\\", "\\]", .rect), ("[", "]", .rect), ("(", ")", .round), ("{", "}", .diamond), (">", "]", .rect)
        ]
        for (opener, closer, shape) in shapeOpeners where cursor.hasPrefix(opener) {
            cursor.advance(by: opener.count)
            node.text = cleanedLabel(cursor.read(until: closer))
            node.shape = shape
            break
        }
        // ":::className" suffix.
        if cursor.hasPrefix(":::") {
            cursor.advance(by: 3)
            while let character = cursor.peek(), character.isLetter || character.isNumber || character == "_" || character == "-" { cursor.advance() }
        }
        return node
    }

    private static func parseLink(_ cursor: inout Cursor) -> ParsedLink? {
        let startPosition = cursor.position
        var hasStartHead = false
        if cursor.peek() == "<" || cursor.peek() == "o" && cursor.peek(offset: 1) == "-" || cursor.peek() == "x" && cursor.peek(offset: 1) == "-" {
            hasStartHead = cursor.peek() == "<"
            cursor.advance()
        }
        guard let lineCharacter = cursor.peek(), lineCharacter == "-" || lineCharacter == "=" else {
            cursor.position = startPosition
            return nil
        }
        var link: ParsedLink
        if lineCharacter == "-", cursor.peek(offset: 1) == "." {
            // -.-> / -.- / -. label .->
            cursor.advance()
            while cursor.peek() == "." { cursor.advance() }
            if cursor.peek() == " " {
                let labelText = cursor.read(untilAny: [".->", ".-"])
                link = ParsedLink(style: .dashed, head: cursor.lastMatchedTerminator == ".->" ? .end : .none, label: cleanedLabel(labelText))
            } else {
                while cursor.peek() == "-" { cursor.advance() }
                let hasEndHead = consumeEndHead(&cursor)
                link = ParsedLink(style: .dashed, head: hasEndHead ? .end : .none, label: nil)
            }
        } else {
            var lineLength = 0
            while cursor.peek() == lineCharacter {
                cursor.advance()
                lineLength += 1
            }
            let style: WBArrowStyle = lineCharacter == "=" ? .thick : .solid
            if consumeEndHead(&cursor) {
                link = ParsedLink(style: style, head: .end, label: nil)
            } else if lineLength >= 3 {
                link = ParsedLink(style: style, head: .none, label: nil)
            } else if lineLength == 2, cursor.peek() == " " {
                // -- label --> / == label ==>
                let doubled = String(repeating: String(lineCharacter), count: 2)
                let labelText = cursor.read(untilAny: [doubled + ">", doubled + String(lineCharacter), doubled])
                if cursor.lastMatchedTerminator == nil {
                    cursor.position = startPosition
                    return nil
                }
                while cursor.peek() == lineCharacter { cursor.advance() }
                let hasEndHead = cursor.lastMatchedTerminator == doubled + ">" || consumeEndHead(&cursor)
                link = ParsedLink(style: style, head: hasEndHead ? .end : .none, label: cleanedLabel(labelText))
            } else {
                cursor.position = startPosition
                return nil
            }
        }
        if hasStartHead { link.head = link.head == .end ? .both : .end }
        cursor.skipSpaces()
        if cursor.peek() == "|" {
            cursor.advance()
            link.label = cleanedLabel(cursor.read(until: "|"))
        }
        return link
    }

    private static func consumeEndHead(_ cursor: inout Cursor) -> Bool {
        guard let character = cursor.peek() else { return false }
        if character == ">" {
            cursor.advance()
            return true
        }
        // --o / --x end markers, when not the start of a node name.
        if character == "o" || character == "x", !(cursor.peek(offset: 1).map { $0.isLetter || $0.isNumber } ?? false) {
            cursor.advance()
            return true
        }
        return false
    }

    private static func cleanedLabel(_ rawLabel: String) -> String? {
        var label = rawLabel.trimmingCharacters(in: .whitespaces)
        if label.count >= 2, label.hasPrefix("\""), label.hasSuffix("\"") { label = String(label.dropFirst().dropLast()) }
        for lineBreak in ["<br/>", "<br />", "<br>", "\\n"] { label = label.replacingOccurrences(of: lineBreak, with: " ") }
        label = label.trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? nil : label
    }

    // MARK: - Cursor

    private struct Cursor {
        let characters: [Character]
        var position = 0
        var lastMatchedTerminator: String?

        init(_ characters: [Character]) { self.characters = characters }

        var isAtEnd: Bool { position >= characters.count }

        func peek(offset: Int = 0) -> Character? {
            let index = position + offset
            return index < characters.count ? characters[index] : nil
        }

        mutating func advance(by count: Int = 1) { position = min(characters.count, position + count) }

        mutating func skipSpaces() {
            while let character = peek(), character == " " || character == "\t" { advance() }
        }

        func hasPrefix(_ prefix: String) -> Bool {
            let prefixCharacters = Array(prefix)
            guard position + prefixCharacters.count <= characters.count else { return false }
            return Array(characters[position..<(position + prefixCharacters.count)]) == prefixCharacters
        }

        /// Reads up to `terminator` (consumed), skipping over "…" quotes;
        /// reads to the end when it never appears.
        mutating func read(until terminator: String) -> String {
            read(untilAny: [terminator])
        }

        mutating func read(untilAny terminators: [String]) -> String {
            var text = ""
            var isInsideQuotes = false
            lastMatchedTerminator = nil
            while !isAtEnd {
                if !isInsideQuotes, let matchedTerminator = terminators.first(where: { hasPrefix($0) }) {
                    advance(by: matchedTerminator.count)
                    lastMatchedTerminator = matchedTerminator
                    return text
                }
                let character = characters[position]
                if character == "\"" { isInsideQuotes.toggle() }
                text.append(character)
                advance()
            }
            return text
        }
    }

    // MARK: - Builder

    private struct FlowBuilder {
        let flowIdentifier: String
        let sectionIdentifier: String
        var boxes: [WBElement] = []
        var arrows: [WBElement] = []
        var groups: [WBFlowGroup] = []
        var openGroupIndices: [Int] = []
        /// Node id → explicit shape seen (a bare mention never overrides one).
        var nodesWithExplicitShape: Set<String> = []

        init(flowIdentifier: String, sectionIdentifier: String) {
            self.flowIdentifier = flowIdentifier
            self.sectionIdentifier = sectionIdentifier
        }

        func innerIdentifier(_ nodeIdentifier: String) -> String { "\(flowIdentifier).\(nodeIdentifier)" }

        mutating func mention(_ node: ParsedNode) {
            let boxIdentifier = innerIdentifier(node.identifier)
            let boxText = WBNormalizer.truncated(node.text ?? node.identifier, to: WBBox.maximumTextLength)
            if let existingIndex = boxes.firstIndex(where: { $0.id == boxIdentifier }) {
                if let shape = node.shape, !nodesWithExplicitShape.contains(boxIdentifier) {
                    boxes[existingIndex].payload = .box(WBBox(text: boxText, shape: shape))
                    nodesWithExplicitShape.insert(boxIdentifier)
                }
            } else {
                boxes.append(WBElement(id: boxIdentifier, sectionIdentifier: sectionIdentifier, payload: .box(WBBox(text: boxText, shape: node.shape ?? .rect))))
                if node.shape != nil { nodesWithExplicitShape.insert(boxIdentifier) }
                if let innermostGroupIndex = openGroupIndices.last {
                    groups[innermostGroupIndex].memberIdentifiers.append(boxIdentifier)
                }
            }
        }

        mutating func link(from fromNodeIdentifier: String, to toNodeIdentifier: String, link: ParsedLink) {
            let arrow = WBArrow(fromIdentifier: innerIdentifier(fromNodeIdentifier), toIdentifier: innerIdentifier(toNodeIdentifier), text: link.label, style: link.style, head: link.head)
            arrows.append(WBElement(id: "\(flowIdentifier).e\(arrows.count + 1)", sectionIdentifier: sectionIdentifier, payload: .arrow(arrow)))
        }

        /// `subgraph id [title]`, `subgraph id["title"]` or `subgraph title words`.
        mutating func openGroup(_ header: String) {
            var groupIdentifier = header
            var groupTitle = header
            if let bracketIndex = header.firstIndex(of: "[") {
                groupIdentifier = String(header[..<bracketIndex]).trimmingCharacters(in: .whitespaces)
                let titlePart = header[header.index(after: bracketIndex)...]
                groupTitle = cleanedLabel(String(titlePart.hasSuffix("]") ? titlePart.dropLast() : titlePart)) ?? groupIdentifier
            } else if let cleanedHeader = cleanedLabel(header) {
                groupTitle = cleanedHeader
                groupIdentifier = cleanedHeader.contains(" ") ? "g\(groups.count + 1)" : cleanedHeader
            }
            if groupIdentifier.isEmpty { groupIdentifier = "g\(groups.count + 1)" }
            groups.append(WBFlowGroup(id: innerIdentifier(WBNormalizer.sanitizedIdentifier(groupIdentifier) ?? "g\(groups.count + 1)"), title: groupTitle, memberIdentifiers: []))
            openGroupIndices.append(groups.count - 1)
        }

        mutating func closeGroup() {
            _ = openGroupIndices.popLast()
        }
    }
}
