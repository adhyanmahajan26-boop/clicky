import Testing
@testable import Clicky

@MainActor
struct TerminalSessionTests {
    /// Runs a command in a TerminalSession with no window and reads its output from the screen buffer.
    @Test func shellOutputReachesScreenText() async throws {
        let session = TerminalSessions.shared.start(id: "test:echo", title: "echo", command: "/bin/zsh",
                                                    arguments: ["-lc", "echo theo-ok; sleep 1"])
        let terminal = try #require(session)
        for _ in 0..<40 where !terminal.screenText().contains("theo-ok") {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(terminal.screenText().contains("theo-ok"))
        TerminalSessions.shared.close("test:echo")
    }
}
