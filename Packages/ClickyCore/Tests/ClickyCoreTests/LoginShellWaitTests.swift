import ClickyCore
import Foundation
import Testing

/// The harnesses' PATH is a `static let` whose initializer asks the login shell. If waiting for the shell ran the run loop,
/// work queued on that thread's run loop (on the main thread: main-actor jobs) would run inside that initializer and could
/// use the same `static let` again: dispatch_once then traps ("trying to lock recursively"). That crashed a fresh test
/// profile at launch. These run the wait on a thread with a run loop of its own, with work already queued on it.
struct LoginShellWaitTests {

    /// Runs `body` on a new thread that has a run loop with one block queued on it; says whether that block ran during `body`.
    private func ranQueuedWorkDuring(_ body: @escaping @Sendable () -> String?) -> (ranInside: Bool, output: String?) {
        final class Box: @unchecked Sendable { var ranInside = false; var output: String? }
        let box = Box()
        let finished = DispatchSemaphore(value: 0)
        let thread = Thread {
            RunLoop.current.perform { box.ranInside = true }
            box.output = body()
            finished.signal()
        }
        thread.start()
        _ = finished.wait(timeout: .now() + 20)
        return (box.ranInside, box.output)
    }

    @Test func waitingForACommandRunsNothingElseOnThatThread() {
        // The command closes its output first, so the wait for it to end is a real wait.
        let result = ranQueuedWorkDuring {
            LoginShell.commandOutput(executable: "/bin/sh", arguments: ["-c", "printf done; exec 1>&-; sleep 0.5"], timeout: 5)
        }
        #expect(result.output == "done")
        #expect(!result.ranInside, "work queued on the thread's run loop ran while the command was being waited for")
    }

    @Test func processWaitUntilExitDoesRunTheRunLoop() {
        // Why commandOutput doesn't use it: this is the re-entrancy that crashed the app.
        let result = ranQueuedWorkDuring {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "sleep 0.5"]
            try? process.run()
            process.waitUntilExit()
            return nil
        }
        #expect(result.ranInside)
    }

    @Test func aCommandThatHangsIsStoppedAtTheTimeout() {
        let started = Date()
        let output = LoginShell.commandOutput(executable: "/bin/sh", arguments: ["-c", "printf early; sleep 30"], timeout: 1)
        #expect(Date().timeIntervalSince(started) < 6)
        #expect(output == "early")
    }

    @Test func aCommandThatCannotStartGivesNil() {
        #expect(LoginShell.commandOutput(executable: "/nonexistent/shell", arguments: [], timeout: 1) == nil)
    }
}
