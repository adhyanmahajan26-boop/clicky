//
//  EngineFailureText.swift
//  ClickyCore
//
//  What a bot's chat says when its engine's CLI fails: the CLI's own message in plain words, not the tail of its raw output.
//

import Foundation

public enum EngineFailureText {
    /// Grok's streaming JSON: a failed turn ends in {"type": "result", "is_error": true, "errors": ["Internal error: {\"message\": …}"]}.
    /// Returns the innermost "message" of the first error (or the error text itself), or nil when there's no error event.
    public static func grok(_ output: String) -> String? {
        for line in output.split(separator: "\n").reversed() {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  event["type"] as? String == "result", event["is_error"] as? Bool == true else { continue }
            var candidates = (event["errors"] as? [Any] ?? []).compactMap { $0 as? String }
            if let result = event["result"] as? String { candidates.append(result) }
            for candidate in candidates {
                let text = innermostMessage(candidate)
                if !text.isEmpty { return text }
            }
        }
        return nil
    }

    /// `Internal error: {"message": "API error (status 402 …): …", …}` → `API error (status 402 …): …`.
    static func innermostMessage(_ text: String) -> String {
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
           let object = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any] {
            if let message = object["message"] as? String, !message.isEmpty { return String(message.prefix(300)) }
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String, !message.isEmpty { return String(message.prefix(300)) }
            if let error = object["error"] as? String, !error.isEmpty { return String(error.prefix(300)) }
        }
        return String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
    }
}
