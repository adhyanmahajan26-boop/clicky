//
//  WBModel.swift
//  ClickyCore
//
//  The normalized whiteboard ("CWB v1") model: what the parser hands to the
//  layout and renderer once the model's coordinate-free JSONL has been
//  scanned, repaired and normalized. Everything here is plain data in arrival
//  order (never Dictionary/Set order), Codable for history and Equatable for
//  tests. WBJSONLSerializer writes a board back as contract JSONL that parses
//  to the same board (history, export, re-render).
//

import Foundation

// MARK: - Board

public struct WBBoard: Codable, Equatable, Sendable {
    public var title: String
    public var direction: WBDirection
    public var sections: [WBSection]
    /// In arrival order.
    public var elements: [WBElement]
    /// Numbered 1…n in arrival order.
    public var steps: [WBStep]

    public init(title: String = "", direction: WBDirection = .topToBottom, sections: [WBSection] = [], elements: [WBElement] = [], steps: [WBStep] = []) {
        self.title = title
        self.direction = direction
        self.sections = sections
        self.elements = elements
        self.steps = steps
    }

    public func element(withIdentifier elementIdentifier: String) -> WBElement? {
        elements.first { $0.id == elementIdentifier }
    }

    public func section(withIdentifier sectionIdentifier: String) -> WBSection? {
        sections.first { $0.id == sectionIdentifier }
    }

    /// Elements of one section, in arrival order.
    public func elements(inSection sectionIdentifier: String) -> [WBElement] {
        elements.filter { $0.sectionIdentifier == sectionIdentifier }
    }

    public var pageCount: Int { sections.map(\.page).max() ?? 1 }
}

public enum WBDirection: String, Codable, Equatable, Sendable {
    case topToBottom = "TB"
    case leftToRight = "LR"
}

public struct WBSection: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    /// The user's question this section answers ("q"), if given.
    public var question: String?
    /// 1-based; sections past the eighth overflow onto page 2, and so on.
    public var page: Int

    public init(id: String, title: String, question: String? = nil, page: Int = 1) {
        self.id = id
        self.title = title
        self.question = question
        self.page = page
    }
}

// MARK: - Elements

public struct WBElement: Codable, Equatable, Sendable {
    public var id: String
    public var sectionIdentifier: String
    public var payload: WBElementPayload

    public init(id: String, sectionIdentifier: String, payload: WBElementPayload) {
        self.id = id
        self.sectionIdentifier = sectionIdentifier
        self.payload = payload
    }

    public var kind: WBElementKind { payload.kind }
}

public enum WBElementKind: String, Codable, CaseIterable, Sendable {
    case box, arrow, text, list, code, math, chart, table, callout, flow, divider
}

public enum WBElementPayload: Codable, Equatable, Sendable {
    case box(WBBox)
    case arrow(WBArrow)
    case text(WBText)
    case list(WBList)
    case code(WBCode)
    case math(WBMath)
    case chart(WBChart)
    case table(WBTable)
    case callout(WBCallout)
    case flow(WBFlow)
    case divider

    public var kind: WBElementKind {
        switch self {
        case .box: return .box
        case .arrow: return .arrow
        case .text: return .text
        case .list: return .list
        case .code: return .code
        case .math: return .math
        case .chart: return .chart
        case .table: return .table
        case .callout: return .callout
        case .flow: return .flow
        case .divider: return .divider
        }
    }
}

public enum WBBoxShape: String, Codable, CaseIterable, Sendable {
    case rect, round, pill, diamond, circle, cyl, note
}

public enum WBColor: String, Codable, CaseIterable, Sendable {
    case blue, green, orange, red, purple, gray, yellow
}

public struct WBBox: Codable, Equatable, Sendable {
    public static let maximumTextLength = 80

    public var text: String
    public var shape: WBBoxShape
    public var color: WBColor?
    /// An SF Symbol name that passed the injected validity check.
    public var icon: String?
    /// Added at stream end for an arrow endpoint nobody defined.
    public var isPlaceholder: Bool

    public init(text: String, shape: WBBoxShape = .rect, color: WBColor? = nil, icon: String? = nil, isPlaceholder: Bool = false) {
        self.text = text
        self.shape = shape
        self.color = color
        self.icon = icon
        self.isPlaceholder = isPlaceholder
    }
}

public enum WBArrowStyle: String, Codable, CaseIterable, Sendable {
    case solid, dashed, thick
}

public enum WBArrowHead: String, Codable, CaseIterable, Sendable {
    case end, both, none
}

public struct WBArrow: Codable, Equatable, Sendable {
    public var fromIdentifier: String
    public var toIdentifier: String
    public var text: String?
    public var style: WBArrowStyle
    public var head: WBArrowHead

    public init(fromIdentifier: String, toIdentifier: String, text: String? = nil, style: WBArrowStyle = .solid, head: WBArrowHead = .end) {
        self.fromIdentifier = fromIdentifier
        self.toIdentifier = toIdentifier
        self.text = text
        self.style = style
        self.head = head
    }
}

public enum WBTextSize: String, Codable, CaseIterable, Sendable {
    case small = "s", medium = "m", large = "l", title = "xl"
}

public enum WBRelativePosition: String, Codable, CaseIterable, Sendable {
    case top, bottom, left, right
}

public struct WBText: Codable, Equatable, Sendable {
    public var text: String
    public var size: WBTextSize
    /// An element this text sits next to ("near"), and on which side ("pos").
    public var nearIdentifier: String?
    public var position: WBRelativePosition?

    public init(text: String, size: WBTextSize = .medium, nearIdentifier: String? = nil, position: WBRelativePosition? = nil) {
        self.text = text
        self.size = size
        self.nearIdentifier = nearIdentifier
        self.position = position
    }
}

public struct WBList: Codable, Equatable, Sendable {
    public static let maximumItemCount = 12

    public var title: String?
    public var items: [String]
    public var isOrdered: Bool

    public init(title: String? = nil, items: [String], isOrdered: Bool = false) {
        self.title = title
        self.items = items
        self.isOrdered = isOrdered
    }
}

public struct WBCode: Codable, Equatable, Sendable {
    public static let maximumLineCount = 40

    public var language: String?
    public var text: String
    /// 1-based line numbers to highlight, ascending, within the text.
    public var highlightedLines: [Int]

    public init(language: String? = nil, text: String, highlightedLines: [Int] = []) {
        self.language = language
        self.text = text
        self.highlightedLines = highlightedLines
    }
}

public struct WBMath: Codable, Equatable, Sendable {
    public var tex: String

    public init(tex: String) {
        self.tex = tex
    }
}

public enum WBChartKind: String, Codable, CaseIterable, Sendable {
    case bar, line, pie
}

public struct WBChartPoint: Codable, Equatable, Sendable {
    public var label: String
    public var value: Double

    public init(label: String, value: Double) {
        self.label = label
        self.value = value
    }
}

public struct WBChart: Codable, Equatable, Sendable {
    public static let maximumPointCount = 24

    public var kind: WBChartKind
    public var title: String?
    public var points: [WBChartPoint]

    public init(kind: WBChartKind = .bar, title: String? = nil, points: [WBChartPoint]) {
        self.kind = kind
        self.title = title
        self.points = points
    }
}

public struct WBTable: Codable, Equatable, Sendable {
    public static let maximumColumnCount = 6
    public static let maximumRowCount = 8

    public var columns: [String]
    /// Every row has exactly `columns.count` cells.
    public var rows: [[String]]

    public init(columns: [String], rows: [[String]]) {
        self.columns = columns
        self.rows = rows
    }
}

public enum WBCalloutStyle: String, Codable, CaseIterable, Sendable {
    case info, tip, warning, error
}

public struct WBCallout: Codable, Equatable, Sendable {
    public var targetIdentifier: String?
    public var style: WBCalloutStyle
    public var text: String

    public init(targetIdentifier: String? = nil, style: WBCalloutStyle = .info, text: String) {
        self.targetIdentifier = targetIdentifier
        self.style = style
        self.text = text
    }
}

/// A Mermaid flowchart, kept as source (what the serializer writes back) and
/// as the boxes + arrows MermaidFlowParser made of it. Inner ids are
/// "<flow id>.<node id>", so they never clash with board ids.
public struct WBFlow: Codable, Equatable, Sendable {
    public var source: String
    public var direction: WBDirection
    /// Boxes in first-mention order, then arrows in source order.
    public var elements: [WBElement]
    /// subgraph … end blocks.
    public var groups: [WBFlowGroup]

    public init(source: String, direction: WBDirection = .topToBottom, elements: [WBElement] = [], groups: [WBFlowGroup] = []) {
        self.source = source
        self.direction = direction
        self.elements = elements
        self.groups = groups
    }
}

public struct WBFlowGroup: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    /// Inner box ids, in first-mention order.
    public var memberIdentifiers: [String]

    public init(id: String, title: String, memberIdentifiers: [String]) {
        self.id = id
        self.title = title
        self.memberIdentifiers = memberIdentifiers
    }
}

// MARK: - Steps

public struct WBCue: Codable, Equatable, Sendable {
    /// The element that appears / lights up when `word` is spoken.
    public var elementIdentifier: String
    public var word: String

    public init(elementIdentifier: String, word: String) {
        self.elementIdentifier = elementIdentifier
        self.word = word
    }
}

public enum WBFocus: Codable, Equatable, Sendable {
    case element(String)
    case section(String)
    case board
}

public struct WBStep: Codable, Equatable, Sendable {
    public var number: Int
    public var shownIdentifiers: [String]
    public var highlightedIdentifiers: [String]
    public var say: String
    /// Ordered by where the word first appears in `say`, then by id.
    public var cues: [WBCue]
    public var pointIdentifier: String?
    public var focus: WBFocus?

    public init(number: Int, shownIdentifiers: [String] = [], highlightedIdentifiers: [String] = [], say: String = "", cues: [WBCue] = [], pointIdentifier: String? = nil, focus: WBFocus? = nil) {
        self.number = number
        self.shownIdentifiers = shownIdentifiers
        self.highlightedIdentifiers = highlightedIdentifiers
        self.say = say
        self.cues = cues
        self.pointIdentifier = pointIdentifier
        self.focus = focus
    }
}

// MARK: - JSONL serializer

/// Writes a board as contract JSONL: one header line, one line per element
/// (flows as their Mermaid source), one line per step. Parsing the output
/// gives back an equal board. Key order is fixed, so output is stable.
public enum WBJSONLSerializer {
    public static func serialize(_ board: WBBoard) -> String {
        var lines: [String] = []
        let sectionObjects = board.sections.map { section -> String in
            var sectionWriter = WBJSONObjectWriter()
            sectionWriter.add("id", string: section.id)
            sectionWriter.add("title", string: section.title)
            sectionWriter.add("q", optionalString: section.question)
            return sectionWriter.text
        }
        var headerWriter = WBJSONObjectWriter()
        headerWriter.add("wb", raw: "1")
        headerWriter.add("title", string: board.title)
        headerWriter.add("dir", string: board.direction.rawValue)
        headerWriter.add("sections", raw: "[" + sectionObjects.joined(separator: ",") + "]")
        lines.append(headerWriter.text)

        for element in board.elements {
            lines.append(serializeElement(element))
        }
        for step in board.steps {
            lines.append(serializeStep(step))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func serializeElement(_ element: WBElement) -> String {
        var writer = WBJSONObjectWriter()
        writer.add("el", string: element.kind.rawValue)
        writer.add("id", string: element.id)
        writer.add("sec", string: element.sectionIdentifier)
        switch element.payload {
        case .box(let box):
            writer.add("text", string: box.text)
            writer.add("shape", string: box.shape.rawValue)
            writer.add("color", optionalString: box.color?.rawValue)
            writer.add("icon", optionalString: box.icon)
            if box.isPlaceholder { writer.add("placeholder", raw: "true") }
        case .arrow(let arrow):
            writer.add("from", string: arrow.fromIdentifier)
            writer.add("to", string: arrow.toIdentifier)
            writer.add("text", optionalString: arrow.text)
            writer.add("style", string: arrow.style.rawValue)
            writer.add("head", string: arrow.head.rawValue)
        case .text(let text):
            writer.add("text", string: text.text)
            writer.add("size", string: text.size.rawValue)
            writer.add("near", optionalString: text.nearIdentifier)
            writer.add("pos", optionalString: text.position?.rawValue)
        case .list(let list):
            writer.add("title", optionalString: list.title)
            writer.add("items", raw: stringArrayText(list.items))
            writer.add("ordered", raw: list.isOrdered ? "true" : "false")
        case .code(let code):
            writer.add("lang", optionalString: code.language)
            writer.add("text", string: code.text)
            writer.add("hl", raw: "[" + code.highlightedLines.map(String.init).joined(separator: ",") + "]")
        case .math(let math):
            writer.add("tex", string: math.tex)
        case .chart(let chart):
            writer.add("kind", string: chart.kind.rawValue)
            writer.add("title", optionalString: chart.title)
            let pointTexts = chart.points.map { "[" + WBJSONObjectWriter.quoted($0.label) + "," + numberText($0.value) + "]" }
            writer.add("data", raw: "[" + pointTexts.joined(separator: ",") + "]")
        case .table(let table):
            writer.add("cols", raw: stringArrayText(table.columns))
            writer.add("rows", raw: "[" + table.rows.map(stringArrayText).joined(separator: ",") + "]")
        case .callout(let callout):
            writer.add("target", optionalString: callout.targetIdentifier)
            writer.add("style", string: callout.style.rawValue)
            writer.add("text", string: callout.text)
        case .flow(let flow):
            writer.add("src", string: flow.source)
        case .divider:
            break
        }
        return writer.text
    }

    static func serializeStep(_ step: WBStep) -> String {
        var writer = WBJSONObjectWriter()
        writer.add("step", raw: String(step.number))
        writer.add("show", raw: stringArrayText(step.shownIdentifiers))
        if !step.highlightedIdentifiers.isEmpty { writer.add("hl", raw: stringArrayText(step.highlightedIdentifiers)) }
        writer.add("say", string: step.say)
        if !step.cues.isEmpty {
            var cueWriter = WBJSONObjectWriter()
            for cue in step.cues { cueWriter.add(cue.elementIdentifier, string: cue.word) }
            writer.add("cue", raw: cueWriter.text)
        }
        writer.add("point", optionalString: step.pointIdentifier)
        switch step.focus {
        case .element(let elementIdentifier): writer.add("focus", string: elementIdentifier)
        case .section(let sectionIdentifier): writer.add("focus", string: sectionIdentifier)
        case .board: writer.add("focus", string: "board")
        case nil: break
        }
        return writer.text
    }

    static func stringArrayText(_ strings: [String]) -> String {
        "[" + strings.map(WBJSONObjectWriter.quoted).joined(separator: ",") + "]"
    }

    /// Integers without ".0"; otherwise Swift's shortest round-tripping form.
    static func numberText(_ value: Double) -> String {
        if value.isFinite, value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return value.isFinite ? "\(value)" : "0"
    }
}

/// Builds one JSON object with keys in insertion order.
struct WBJSONObjectWriter {
    private var members: [String] = []

    var text: String { "{" + members.joined(separator: ",") + "}" }

    mutating func add(_ key: String, raw rawJSONText: String) {
        members.append(Self.quoted(key) + ":" + rawJSONText)
    }

    mutating func add(_ key: String, string value: String) {
        add(key, raw: Self.quoted(value))
    }

    mutating func add(_ key: String, optionalString value: String?) {
        if let value { add(key, string: value) }
    }

    static func quoted(_ value: String) -> String {
        var quotedText = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": quotedText += "\\\""
            case "\\": quotedText += "\\\\"
            case "\n": quotedText += "\\n"
            case "\r": quotedText += "\\r"
            case "\t": quotedText += "\\t"
            default:
                if scalar.value < 0x20 {
                    quotedText += String(format: "\\u%04x", scalar.value)
                } else {
                    quotedText.unicodeScalars.append(scalar)
                }
            }
        }
        return quotedText + "\""
    }
}
