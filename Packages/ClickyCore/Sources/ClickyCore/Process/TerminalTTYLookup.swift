//
//  TerminalTTYLookup.swift
//  ClickyCore
//
//  For "this repo" in Terminal: the working directory of the shell (or
//  foreground job) on a tty such as ttys003, read with libproc. Read-only:
//  it lists the user's own processes and reads their cwd, nothing else.
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

        public init(processIdentifier: pid_t, processGroupIdentifier: pid_t, foregroundProcessGroupIdentifier: pid_t, name: String, workingDirectory: String?) {
            self.processIdentifier = processIdentifier
            self.processGroupIdentifier = processGroupIdentifier
            self.foregroundProcessGroupIdentifier = foregroundProcessGroupIdentifier
            self.name = name
            self.workingDirectory = workingDirectory
        }

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
        guard ttyName.range(of: #"^ttys[0-9]{3,4}$"#, options: .regularExpression) != nil else { return nil }
        var deviceStatus = stat()
        guard stat("/dev/" + ttyName, &deviceStatus) == 0 else { return nil }
        let ttyDevice = UInt32(bitPattern: deviceStatus.st_rdev)
        let ownUserIdentifier = getuid()
        var processes: [TTYProcess] = []
        for processIdentifier in ProcessSweep.allProcessIdentifiers() where processIdentifier > 0 {
            var information = proc_bsdinfo()
            let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(processIdentifier, PROC_PIDTBSDINFO, 0, &information, expectedSize) == expectedSize else { continue }
            guard information.e_tdev == ttyDevice, information.pbi_uid == ownUserIdentifier else { continue }
            let name = withUnsafeBytes(of: &information.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            processes.append(TTYProcess(processIdentifier: processIdentifier, processGroupIdentifier: pid_t(information.pbi_pgid),
                                        foregroundProcessGroupIdentifier: pid_t(information.e_tpgid), name: name,
                                        workingDirectory: ProcessSweep.currentWorkingDirectory(of: processIdentifier)))
        }
        return pickWorkingDirectory(processes)
    }
}
