//
//  WBRepairRequest.swift
//  ClickyCore
//
//  The last resort for a board the local repair ladder couldn't save
//  (WBParseStats.isTooBroken): one isolated, tool-less CLI call that rewrites
//  the broken text into a JSON-schema-constrained board. This file only
//  builds the call (argv, working directory, environment, stdin) and reads
//  its answer; running it is the app's job. The model is passed in (the
//  app's main model), and the argv comes from ClaudeArgs so the call is
//  isolated exactly like every other one.
//

import Foundation

public struct WBRepairRequest: Equatable, Sendable {
    public static let systemPromptFileName = "whiteboard-repair.txt"
    /// At most this much broken text is sent.
    public static let maximumBrokenTextLength = 30_000

    public let arguments: [String]
    public let workingDirectoryURL: URL
    /// Sent on stdin (the CLI's -p prompt).
    public let standardInputText: String

    public init(brokenBoardText: String, model: String, systemPromptFileURL: URL) {
        let baseArguments = ClaudeArgs(model: model, systemPromptFileURL: systemPromptFileURL).arguments
        arguments = Self.oneShotArguments(from: baseArguments) + ["--json-schema", Self.boardJSONSchema]
        workingDirectoryURL = ClaudeArgs.sessionWorkingDirectoryURL
        standardInputText = "Broken whiteboard:\n" + String(brokenBoardText.prefix(Self.maximumBrokenTextLength))
    }

    public var environment: [String: String] { ClaudeArgs.environment() }

    /// ClaudeArgs' streaming flags swapped for one JSON result.
    static func oneShotArguments(from baseArguments: [String]) -> [String] {
        var oneShotArguments: [String] = []
        var argumentIndex = 0
        while argumentIndex < baseArguments.count {
            let argument = baseArguments[argumentIndex]
            switch argument {
            case "--input-format":
                argumentIndex += 2
                continue
            case "--output-format":
                oneShotArguments += ["--output-format", "json"]
                argumentIndex += 2
                continue
            case "--verbose", "--include-partial-messages":
                argumentIndex += 1
                continue
            default:
                oneShotArguments.append(argument)
                argumentIndex += 1
            }
        }
        return oneShotArguments
    }

    public static let systemPromptText = """
        You repair whiteboards. The user message is a whiteboard a model wrote as JSON lines that a parser could not read. Rewrite it as one JSON object matching the schema: keep every title, section, element, id, text and step it contains, fix the syntax, and map anything unusual onto the allowed kinds and values. Never add content that isn't there. Elements: el is one of box, arrow, text, list, code, math, chart, table, callout, flow, divider; arrows use from/to ids of other elements; steps list the element ids they show, in order.
        """

    /// The board object the repair call must return: header fields plus
    /// "elements" and "steps" lists (the wrapper form WBNormalizer reads).
    public static let boardJSONSchema: String = {
        let stringType = #"{"type":"string"}"#
        let stringArrayType = #"{"type":"array","items":{"type":"string"}}"#
        let elementProperties = [
            #""el":{"type":"string","enum":["box","arrow","text","list","code","math","chart","table","callout","flow","divider"]}"#,
            #""id":\#(stringType)"#,
            #""sec":\#(stringType)"#,
            #""text":\#(stringType)"#,
            #""shape":{"type":"string","enum":["rect","round","pill","diamond","circle","cyl","note"]}"#,
            #""color":{"type":"string","enum":["blue","green","orange","red","purple","gray","yellow"]}"#,
            #""icon":\#(stringType)"#,
            #""from":\#(stringType)"#,
            #""to":\#(stringType)"#,
            #""style":\#(stringType)"#,
            #""head":{"type":"string","enum":["end","both","none"]}"#,
            #""size":{"type":"string","enum":["s","m","l","xl"]}"#,
            #""near":\#(stringType)"#,
            #""pos":{"type":"string","enum":["top","bottom","left","right"]}"#,
            #""title":\#(stringType)"#,
            #""items":\#(stringArrayType)"#,
            #""ordered":{"type":"boolean"}"#,
            #""lang":\#(stringType)"#,
            #""hl":{"type":"array","items":{"type":"integer"}}"#,
            #""tex":\#(stringType)"#,
            #""kind":{"type":"string","enum":["bar","line","pie"]}"#,
            #""data":{"type":"array","items":{"type":"array","prefixItems":[{"type":"string"},{"type":"number"}],"minItems":2,"maxItems":2}}"#,
            #""cols":\#(stringArrayType)"#,
            #""rows":{"type":"array","items":\#(stringArrayType)}"#,
            #""target":\#(stringType)"#,
            #""src":\#(stringType)"#
        ]
        let stepProperties = [
            #""step":{"type":"integer"}"#,
            #""show":\#(stringArrayType)"#,
            #""hl":\#(stringArrayType)"#,
            #""say":\#(stringType)"#,
            #""cue":{"type":"object","additionalProperties":{"type":"string"}}"#,
            #""point":\#(stringType)"#,
            #""focus":\#(stringType)"#
        ]
        let sectionSchema = #"{"type":"object","properties":{"id":{"type":"string"},"title":{"type":"string"},"q":{"type":"string"}},"required":["id","title"]}"#
        return """
            {"type":"object","properties":{"title":{"type":"string"},"dir":{"type":"string","enum":["TB","LR"]},"sections":{"type":"array","maxItems":8,"items":\(sectionSchema)},"elements":{"type":"array","maxItems":60,"items":{"type":"object","properties":{\(elementProperties.joined(separator: ","))},"required":["el","id"]}},"steps":{"type":"array","maxItems":20,"items":{"type":"object","properties":{\(stepProperties.joined(separator: ","))},"required":["show"]}}},"required":["title","sections","elements","steps"]}
            """
    }()

    /// `structured_output` from the CLI's `--output-format json` result, or
    /// nil for an error result / missing field / unreadable JSON.
    public static func structuredOutput(fromCLIResult resultText: String) -> WBJSONValue? {
        let trimmedResult = resultText.trimmingCharacters(in: .whitespacesAndNewlines)
        // The result is one JSON object; take the last line that is one.
        let candidateLines = [trimmedResult] + trimmedResult.split(whereSeparator: \.isNewline).reversed().map(String.init)
        for candidateLine in candidateLines {
            guard let resultObject = WBRepair.strictParse(candidateLine), case .object(let resultMembers) = resultObject else { continue }
            if case .bool(true)? = resultMembers["is_error"] { return nil }
            if let structuredOutput = resultMembers["structured_output"], case .object = structuredOutput { return structuredOutput }
            // Some versions put the JSON in "result" as text.
            if case .string(let resultString)? = resultMembers["result"], let parsedResult = WBRepair.strictParse(resultString), case .object = parsedResult {
                return parsedResult
            }
            return nil
        }
        return nil
    }

    /// The repair for a brain with no `--json-schema` (Codex, Cursor, OpenCode, an API key): the same instructions, with
    /// the schema written out and a plain JSON answer asked for.
    public static var systemPromptTextForAnyBrain: String {
        systemPromptText + "\n\nAnswer with only the JSON object, no other words and no code fence. It must match this JSON schema:\n" + boardJSONSchema
    }

    /// The repaired board from a plain text answer: the JSON object in it (a code fence or words around it are ignored),
    /// normalized like any streamed one. Nil when there's no readable object.
    public static func board(fromAnswerText answerText: String, isValidSymbol: @escaping @Sendable (String) -> Bool = WBNormalizer.defaultSymbolCheck) -> WBParseOutcome? {
        guard let firstBrace = answerText.firstIndex(of: "{"), let lastBrace = answerText.lastIndex(of: "}"), firstBrace < lastBrace else { return nil }
        let objectText = String(answerText[firstBrace...lastBrace])
        guard let parsedObject = WBRepair.strictParse(objectText), case .object = parsedObject else { return nil }
        var normalizer = WBNormalizer(isValidSymbol: isValidSymbol)
        normalizer.ingest(WBRepairResult(values: [parsedObject], rung: .strict))
        return normalizer.finish()
    }

    /// The repaired board, normalized like any streamed one.
    public static func board(fromCLIResult resultText: String, isValidSymbol: @escaping @Sendable (String) -> Bool = WBNormalizer.defaultSymbolCheck) -> WBParseOutcome? {
        guard let structuredOutput = structuredOutput(fromCLIResult: resultText) else { return nil }
        var normalizer = WBNormalizer(isValidSymbol: isValidSymbol)
        normalizer.ingest(WBRepairResult(values: [structuredOutput], rung: .strict))
        return normalizer.finish()
    }
}
