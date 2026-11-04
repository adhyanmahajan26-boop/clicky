//
//  PrismEval.swift
//  leanring-buddy
//
//  Test profile only: runs a file of labelled cases through the same questions the app asks Prism, one after another,
//  and writes each answer and its time to a file. `uiPrismEval {cases, out}`. Also records what today's rules decide,
//  for the decisions that have rules.
//

import ClickyCore
import Foundation

enum PrismEval {
    static func run(casesPath: String, outPath: String) async -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: casesPath),
              let file = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cases = file["cases"] as? [[String: Any]] else { return ["error": "Can't read the cases"] }
        let leader = file["leader"] as? String ?? "Theo"
        let team = (file["team"] as? [[String: String]] ?? []).map {
            FastDecisionTeammate(id: $0["id"] ?? "", name: $0["name"] ?? "", job: $0["job"] ?? "")
        }
        var rows: [[String: Any]] = []
        for item in cases {
            let kind = item["kind"] as? String ?? ""
            guard let question = question(for: item, kind: kind, leader: leader, team: team) else { continue }
            var row = item
            do {
                let outcome = try await PrismClient.ask(question, timeout: 30)
                row["answer"] = outcome.answer.choice
                row["p"] = outcome.answer.probability
                row["probabilities"] = outcome.answer.probabilities
                row["ms"] = outcome.milliseconds
            } catch {
                row["error"] = error.localizedDescription
            }
            if kind == "research" { row["rulesAnswer"] = ResearchTrigger.parse(item["text"] as? String ?? "") != nil ? "true" : "false" }
            rows.append(row)
        }
        let output = ["rows": rows]
        if let json = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted]) {
            FileManager.default.createFile(atPath: outPath, contents: json)
        }
        let failed = rows.filter { $0["error"] != nil }
        return ["rows": rows.count, "errors": failed.count, "firstError": failed.first?["error"] ?? ""]
    }

    private static func question(for item: [String: Any], kind: String, leader: String, team: [FastDecisionTeammate]) -> FastDecisionQuestion? {
        let text = item["text"] as? String ?? ""
        switch kind {
        case "who": return FastDecisions.whoTakesIt(message: text, leader: leader, team: team)
        case "research": return FastDecisions.needsResearch(transcript: text)
        case "run": return FastDecisions.runSucceeded(status: item["status"] as? String ?? "completed", filesChanged: item["files"] as? Int ?? 0, tests: item["tests"] as? String, report: text)
        case "routine": return FastDecisions.routineNeedsToAct(name: item["name"] as? String ?? "", instruction: text, lastResult: item["last"] as? String, now: item["now"] as? String ?? "Monday 09:00")
        case "dictation": return FastDecisions.dictationNeedsCleanup(text: text)
        default: return nil
        }
    }
}
