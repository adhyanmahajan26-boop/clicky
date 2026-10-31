//
//  TerminalTTYLookup.swift
//  ClickyCore
//
//  For "this repo" in Terminal: the working directory of the shell (or
//  foreground job) on a tty such as ttys003, read with libproc. Read-only:
//  it lists the user's own processes and reads their cwd, nothing else.
//  P8: also what the tty's foreground process group runs (Claude Code, a
//  shell, something else) — the same read `ps -t ttys003 -o comm=` gives,
//  without spawning ps — and the ttys under a terminal app's process.
//

import Darwin
import Foundation

public enum TerminalTTYLookup {
    /// One process on the tty, as the picker sees it.
    public struct TTYProcess: Equatable, Sendable {
        public var processIdentifier: pid_t
        public var processGroupIdentifier: pid_t
        /// The tty's foreground process group.
        public var foregroundProcessGroupIdentifier: pid_t
        public var name: String
        public var workingDirectory: String?
        /// The executable's full path (proc_pidpath), when readable.
        public var executablePath: String?

        public init(processIdentifier: pid_t, processGroupIdentifier: pid_t, foregroundProcessGroupIdentifier: pid_t, name: String, workingDirectory: String?,
                    executablePath: String? = nil) {
            self.processIdentifier = processIdentifier
            self.processGroupIdentifier = processGroupIdentifier
            self.foregroundProcessGroupIdentifier = foregroundProcessGroupIdentifier
            self.name = name
            self.workingDirectory = workingDirectory
            self.executablePath = executablePath
        }

        var isForeground: Bool { processGroupIdentifier == foregroundProcessGroupIdentifier }

        var isShell: Bool { ["zsh", "bash", "fish", "sh", "-zsh", "-bash", "-fish", "-sh", "tcsh", "ksh"].contains(name) }
        var isLogin: Bool { name == "login" }
    }

    /// The cwd to use: the foreground job's, else the newest shell's.
    public static func pickWorkingDirectory(_ processes: [TTYProcess]) -> String? {
        let candidates = processes.filter { !$0.isLogin && $0.workingDirectory?.isEmpty == false }
        if let foreground = candidates.filter({ $0.processGroupIdentifier == $0.foregroundProcessGroupIdentifier }).max(by: { $0.processIdentifier < $1.processIdentifier }) {
            return foreground.workingDirectory
        }
        return candidates.filter(\.isShell).max(by: { $0.processIdentifier < $1.processIdentifier })?.workingDirectory
    }

    /// "ttys003" → the cwd of the shell on /dev/ttys003, or nil.
    public static func workingDirectory(ttyName: String) -> String? {
        guard let processes = processes(ttyName: ttyName, readsWorkingDirectories: true) else { return nil }
        return pickWorkingDirectory(processes)
    }

    // MARK: - Foreground program (P8)

    /// Claude Code's CLI: `claude`, or the versioned native binary
    /// (~/.local/share/claude/versions/2.1.301, whose comm is the version).
    public static func isClaudeCode(name: String, executablePath: String?) -> Bool {
        let loweredName = name.lowercased()
        if loweredName == "claude" || loweredName.hasPrefix("claude-code") { return true }
        guard let path = executablePath?.lowercased() else { return false }
        if path.contains("/claude/versions/") || path.contains("/claude-code/") || path.contains("@anthropic-ai/claude-code") { return true }
        return (path as NSString).lastPathComponent == "claude"
    }

    /// What the tty's foreground process group runs; nil when nothing is on it.
    public static func classifyForeground(_ processes: [TTYProcess]) -> ActionTerminalForeground? {
        let candidates = processes.filter { !$0.isLogin }
        guard !candidates.isEmpty else { return nil }
        let foreground = candidates.filter(\.isForeground)
        if foreground.contains(where: { isClaudeCode(name: $0.name, executablePath: $0.executablePath) }) { return .claudeCode }
        let nonShell = foreground.filter { !$0.isShell }
        if let program = nonShell.max(by: { $0.processIdentifier < $1.processIdentifier }) { return .otherCommand(program.name) }
        return .shell
    }

    /// "ttys003" → what its foreground job is.
    public static func foreground(ttyName: String) -> ActionTerminalForeground? {
        processes(ttyName: ttyName, readsWorkingDirectories: false).flatMap(classifyForeground)
    }

    /// The ttys ("ttys003") of the processes under a terminal app (its tabs' shells), sorted.
    public static func ttyNames(underApplication applicationProcessIdentifier: pid_t) -> [String] {
        let ownUserIdentifier = getuid()
        var parentByProcess: [pid_t: pid_t] = [:]
        var deviceByProcess: [pid_t: UInt32] = [:]
        for processIdentifier in ProcessSweep.allProcessIdentifiers() where processIdentifier > 0 {
            guard let information = bsdInfo(processIdentifier), information.pbi_uid == ownUserIdentifier else { continue }
            parentByProcess[processIdentifier] = pid_t(information.pbi_ppid)
            deviceByProcess[processIdentifier] = information.e_tdev
        }
        var names: Set<String> = []
        for (processIdentifier, device) in deviceByProcess where device != UInt32.max && device != 0 {
            var ancestor = parentByProcess[processIdentifier]
            var hops = 0
            while let current = ancestor, current > 1, hops < 12 {
                if current == applicationProcessIdentifier {
                    if let name = devname(dev_t(bitPattern: device), S_IFCHR).map({ String(cString: $0) }), isTTYName(name) { names.insert(name) }
                    break
                }
                ancestor = parentByProcess[current]
                hops += 1
            }
        }
        return names.sorted()
    }

    static func isTTYName(_ ttyName: String) -> Bool {
        ttyName.range(of: #"^ttys[0-9]{3,4}$"#, options: .regularExpression) != nil
    }

    private static func bsdInfo(_ processIdentifier: pid_t) -> proc_bsdinfo? {
        var information = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(processIdentifier, PROC_PIDTBSDINFO, 0, &information, expectedSize) == expectedSize else { return nil }
        return information
    }

    private static func executablePath(of processIdentifier: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(processIdentifier, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// The user's own processes on /dev/<ttyName>.
    private static func processes(ttyName: String, readsWorkingDirectories: Bool) -> [TTYProcess]? {
        guard isTTYName(ttyName) else { return nil }
        var deviceStatus = stat()
        guard stat("/dev/" + ttyName, &deviceStatus) == 0 else { return nil }
        let ttyDevice = UInt32(bitPattern: deviceStatus.st_rdev)
        let ownUserIdentifier = getuid()
        var processes: [TTYProcess] = []
        for processIdentifier in ProcessSweep.allProcessIdentifiers() where processIdentifier > 0 {
            guard var information = bsdInfo(processIdentifier) else { continue }
            guard information.e_tdev == ttyDevice, information.pbi_uid == ownUserIdentifier else { continue }
            let name = withUnsafeBytes(of: &information.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            processes.append(TTYProcess(processIdentifier: processIdentifier, processGroupIdentifier: pid_t(information.pbi_pgid),
                                        foregroundProcessGroupIdentifier: pid_t(information.e_tpgid), name: name,
                                        workingDirectory: readsWorkingDirectories ? ProcessSweep.currentWorkingDirectory(of: processIdentifier) : nil,
                                        executablePath: readsWorkingDirectories ? nil : executablePath(of: processIdentifier)))
        }
        return processes
    }
}
