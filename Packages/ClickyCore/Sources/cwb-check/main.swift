//
//  main.swift
//  cwb-check
//
//  `cwb-check <file>`: parses a raw model answer (or bare whiteboard JSONL)
//  the way the app will, without the Haiku repair call, and prints one JSON
//  line {ok, elements, steps, dropped, rungs, tooBroken} for evals
//  (Tools/eval/gen_boards.py). ok = at least one element and not too broken.
//  Exit status 0 when ok, 1 when not, 2 on a usage or read error.
//

import ClickyCore
import Foundation

let commandArguments = CommandLine.arguments
guard commandArguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: cwb-check <file>\n".utf8))
    exit(2)
}
guard let answerData = FileManager.default.contents(atPath: commandArguments[1]),
      let answerText = String(data: answerData, encoding: .utf8) else {
    FileHandle.standardError.write(Data("cwb-check: can't read \(commandArguments[1])\n".utf8))
    exit(2)
}

let boardBody = WBBlockExtractor.whiteboardBody(in: answerText)
let outcome = WBStreamParser.parse(boardBody)
let stats = outcome.stats
let rungMembers = WBRepairRung.allCases.map { "\"\($0.rawValue)\":\(stats.count(for: $0))" }
let isOk = outcome.isUsable
print("{\"ok\":\(isOk),\"elements\":\(stats.elementCount),\"steps\":\(stats.stepCount),\"dropped\":\(stats.droppedCount),\"rungs\":{\(rungMembers.joined(separator: ","))},\"tooBroken\":\(stats.isTooBroken)}")
exit(isOk ? 0 : 1)
