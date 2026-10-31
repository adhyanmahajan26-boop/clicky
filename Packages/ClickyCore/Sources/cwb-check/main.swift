//
//  main.swift
//  cwb-check
//
//  `cwb-check <file>`: parses a raw model answer (or bare whiteboard JSONL)
//  the way the app will, without the Haiku repair call, and prints one JSON
//  line {ok, elements, steps, dropped, rungs, tooBroken} for evals
//  (Tools/eval/gen_boards.py). ok = at least one element and not too broken.
//  Exit status 0 when ok, 1 when not, 2 on a usage or read error.
//  `cwb-check --pdf <file.pdf>…` inspects exported board PDFs instead
//  (Tools/eval/pdf_check.sh).
//

import ClickyCore
import Foundation

let commandArguments = CommandLine.arguments
// `cwb-check --pdf <file.pdf>…`: one JSON line per exported board PDF (WhiteboardPDFInspector):
// pages, sizes, text, vector, fonts embedded. Exit 0 when every file is vector with every font embedded.
if commandArguments.count >= 3, commandArguments[1] == "--pdf" {
    var allGood = true
    for path in commandArguments.dropFirst(2) {
        guard let report = WhiteboardPDFInspector.inspect(url: URL(fileURLWithPath: path)) else {
            FileHandle.standardError.write(Data("cwb-check: can't read PDF \(path)\n".utf8))
            exit(2)
        }
        let isGood = report.pageCount > 0 && report.isVector && report.allFontsEmbedded && !report.fonts.isEmpty
        allGood = allGood && isGood
        let object: [String: Any] = [
            "file": path, "ok": isGood, "pages": report.pageCount,
            "sizes": report.pages.map { "\(Int($0.size.width.rounded()))x\(Int($0.size.height.rounded()))" },
            "vector": report.isVector,
            "textOps": report.pages.map(\.textShowOperatorCount).reduce(0, +),
            "paintOps": report.pages.map(\.pathPaintOperatorCount).reduce(0, +),
            "images": report.pages.map(\.imageDrawCount).reduce(0, +),
            "maxImageCoverage": Double(report.pages.map(\.imageCoverage).max() ?? 0),
            "fonts": report.fonts.map { ["name": $0.name, "subtype": $0.subtype, "embedded": $0.isEmbedded] },
            "text": report.text
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
    exit(allGood ? 0 : 1)
}
guard commandArguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: cwb-check <file> | cwb-check --pdf <file.pdf>...\n".utf8))
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
