//
//  TerminalSession.swift
//  leanring-buddy
//
//  A real interactive terminal inside Theo: a SwiftTerm LocalProcessTerminalView that runs a command in a
//  pseudo-terminal. The NSView lives in the session (and the session in `TerminalSessions.shared`), so the
//  terminal keeps running and keeps its scrollback while its panel comes and goes, and can be shown in the
//  Project room, a pop-out window, or nowhere at all. Coding runs use it in place of tmux.
//

import AppKit
import Combine
import Foundation
import SwiftTerm

@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    let id: String
    let command: String
    let arguments: [String]
    let workingDirectory: String?
    let startedAt = Date()

    @Published private(set) var title: String
    @Published private(set) var isRunning = false
    @Published private(set) var exitCode: Int32?
    /// Set when the process could not be launched at all.
    @Published private(set) var launchError: String?

    /// The live terminal view. Hosted by `TerminalPanel`; kept alive here.
    let view: LocalProcessTerminalView
    private let bridge = TerminalSessionBridge()

    init(id: String, title: String, command: String, arguments: [String] = [], environment: [String: String]? = nil,
         workingDirectory: String? = nil, columns: Int = 140, rows: Int = 40) {
        self.id = id
        self.title = title
        self.command = command
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 1000, height: 640))
        view.font = font
        view.nativeBackgroundColor = NSColor(hex: 0x0E0E10, alpha: 1)
        view.nativeForegroundColor = NSColor(hex: 0xF2F2F4, alpha: 1)
        view.processDelegate = bridge
        bridge.owner = self

        var env = environment ?? Self.defaultEnvironment()
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["NO_COLOR"] = nil
        if let workingDirectory { env["PWD"] = workingDirectory }
        let pairs = env.map { "\($0.key)=\($0.value)" }
        view.startProcess(executable: command, args: arguments, environment: pairs, execName: nil, currentDirectory: workingDirectory)
        isRunning = view.process?.running ?? false
        if !isRunning, launchError == nil { launchError = "\(command) did not start." }
    }

    /// The harness-safe environment (Claude Code's own session variables scrubbed), with colour left on.
    static func defaultEnvironment() -> [String: String] {
        var env = HarnessCatalog.childEnvironment()
        env["NO_COLOR"] = nil
        return env
    }

    // MARK: Input

    /// Types raw text into the terminal as if the user had.
    func sendRaw(_ text: String) {
        guard isRunning, let process = view.process else { return }
        process.send(data: ArraySlice(Array(text.utf8)))
    }

    /// Pastes `text` (bracketed paste, so a TUI treats it as one paste and keeps its newlines) and then, after a
    /// short delay, presses Return.
    func send(text: String, submit: Bool = true) async {
        guard isRunning else { return }
        sendRaw("\u{1B}[200~" + text + "\u{1B}[201~")
        guard submit else { return }
        try? await Task.sleep(nanoseconds: 800_000_000)
        sendRaw("\r")
    }

    /// Presses Return (for a first-run "trust this folder" screen, for instance).
    func pressEnter() { sendRaw("\r") }

    func interrupt() { sendRaw("\u{03}") }

    func terminate() {
        guard isRunning else { return }
        view.terminate()
    }

    // MARK: Screen

    /// The text currently on screen (the visible rows, trailing blank lines trimmed), for idle and prompt detection.
    func screenText() -> String {
        guard let terminal = view.terminal else { return "" }
        var lines = (0..<terminal.rows).map { row in
            (terminal.getLine(row: row)?.translateToString(trimRight: true) ?? "").replacingOccurrences(of: "\u{0}", with: " ")
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    // MARK: Bridge callbacks

    fileprivate func didSetTitle(_ newTitle: String) {
        if !newTitle.isEmpty { title = newTitle }
    }

    fileprivate func didTerminate(_ code: Int32?) {
        exitCode = code ?? -1
        isRunning = false
    }

}

/// The process delegate, kept apart so the session can stay `@MainActor` with plain stored state.
private final class TerminalSessionBridge: LocalProcessTerminalViewDelegate, @unchecked Sendable {
    weak var owner: TerminalSession?

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        Task { @MainActor [weak self] in self?.owner?.didSetTitle(title) }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor [weak self] in self?.owner?.didTerminate(exitCode) }
    }
}

// MARK: - Registry

/// Every live terminal session, by run/session id. Holding the sessions here keeps their views alive.
@MainActor
final class TerminalSessions: ObservableObject {
    static let shared = TerminalSessions()

    @Published private(set) var sessions: [String: TerminalSession] = [:]

    func session(for runID: String) -> TerminalSession? { sessions[runID] }
    /// The ids of the live sessions (for the control inbox and tests).
    var allIDs: [String] { Array(sessions.keys).sorted() }

    /// Starts (and registers) a session. Returns nil when the process could not be launched.
    @discardableResult
    func start(id: String, title: String, command: String, arguments: [String] = [], environment: [String: String]? = nil,
               workingDirectory: String? = nil) -> TerminalSession? {
        sessions[id]?.terminate()
        let session = TerminalSession(id: id, title: title, command: command, arguments: arguments,
                                      environment: environment, workingDirectory: workingDirectory)
        guard session.launchError == nil else { return nil }
        sessions[id] = session
        return session
    }

    /// Stops the process and forgets the session.
    func close(_ id: String) {
        sessions[id]?.terminate()
        sessions[id]?.view.removeFromSuperview()
        sessions[id] = nil
    }
}
