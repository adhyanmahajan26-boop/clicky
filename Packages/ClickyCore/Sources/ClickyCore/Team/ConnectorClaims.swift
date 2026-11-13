import Foundation

/// A claude.ai connector can still be loading, or its sign-in refreshing, when a bot's turn starts. The bot is then told those tools
/// were removed and writes "the Gmail connector has disconnected" without trying. On 7 and 9 Nov the evening mailbox routine did
/// exactly that, while the same routine worked on 6 and 8 Nov. Theo spots that claim and gives the turn one more go.
public enum ConnectorClaims {
    /// The connector names, of those `names`, that `text` says are disconnected or unavailable.
    public static func saysMissing(_ text: String, names: [String]) -> [String] {
        let lower = text.lowercased()
        let missing = #"(dis ?connected|isn't connected|is not connected|not connected|no longer available|isn't available|is not available|unavailable|not reachable|isn't reachable|can't reach|cannot reach|needs reconnecting|needs to be reconnected)"#
        return names.filter { name in
            let escaped = NSRegularExpression.escapedPattern(for: name.lowercased())
            let nameThenClaim = "\(escaped)[^.\\n]{0,40}\(missing)"
            let claimThenName = "\(missing)[^.\\n]{0,25}\(escaped)"
            return lower.range(of: nameThenClaim, options: .regularExpression) != nil || lower.range(of: claimThenName, options: .regularExpression) != nil
        }
    }

    /// What the bot is told on its second go.
    public static func retryNote(_ names: [String]) -> String {
        "(Theo: \(names.joined(separator: " and ")) is connected. It was still loading when you started, which is why it looked gone. " +
            "Load its tools with ToolSearch now and do the task. Only if a tool call itself fails, say so, quoting the error.)"
    }
}
