//
//  ProcessSweep.swift
//  ClickyCore
//
//  Finds processes left behind by an agent run, even ones that escaped its
//  process group (setsid, double fork, daemons): anything whose working
//  directory or executable lives under the agent's worktree or ctx dir.
//  Uses libproc, which sees every process the user owns.
//

import Darwin
import Foundation

public enum ProcessSweep {
    /// Pids (never our own) whose cwd or executable is under any of `directories`.
    public static func processes(underDirectories directories: [String]) -> [pid_t] {
        let resolvedDirectories = directories.compactMap(resolvedPath)
        guard !resolvedDirectories.isEmpty else { return [] }
        let ownProcessIdentifier = getpid()
        return allProcessIdentifiers().filter { processIdentifier in
            guard processIdentifier > 0, processIdentifier != ownProcessIdentifier else { return false }
            if let workingDirectory = currentWorkingDirectory(of: processIdentifier),
               isPath(workingDirectory, underAnyOf: resolvedDirectories) { return true }
            if let executable = executablePath(of: processIdentifier),
               isPath(executable, underAnyOf: resolvedDirectories) { return true }
            return false
        }
    }

    /// SIGKILLs every match, waits up to `waitSeconds` for them to go, and
    /// returns whatever still matches (empty when the sweep worked).
    @discardableResult
    public static func killAll(underDirectories directories: [String], waitSeconds: TimeInterval = 2) -> [pid_t] {
        let giveUpTime = Date().addingTimeInterval(waitSeconds)
        var remainingProcesses = processes(underDirectories: directories)
        while !remainingProcesses.isEmpty {
            for processIdentifier in remainingProcesses { kill(processIdentifier, SIGKILL) }
            guard Date() < giveUpTime else { break }
            usleep(20_000)
            remainingProcesses = processes(underDirectories: directories)
        }
        return remainingProcesses
    }

    // MARK: - libproc

    static func allProcessIdentifiers() -> [pid_t] {
        // Ask for the count, then leave room for processes started meanwhile.
        let estimatedCount = max(Int(proc_listallpids(nil, 0)), 256) + 256
        var processIdentifiers = [pid_t](repeating: 0, count: estimatedCount)
        let foundCount = processIdentifiers.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard foundCount > 0 else { return [] }
        return Array(processIdentifiers.prefix(Int(foundCount)))
    }

    static func currentWorkingDirectory(of processIdentifier: pid_t) -> String? {
        var vnodePathInformation = proc_vnodepathinfo()
        let expectedSize = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let copiedSize = proc_pidinfo(processIdentifier, PROC_PIDVNODEPATHINFO, 0, &vnodePathInformation, expectedSize)
        guard copiedSize == expectedSize else { return nil }
        let workingDirectory = withUnsafeBytes(of: &vnodePathInformation.pvi_cdir.vip_path) { pathBytes in
            String(decoding: pathBytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return workingDirectory.isEmpty ? nil : workingDirectory
    }

    static func executablePath(of processIdentifier: pid_t) -> String? {
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let pathLength = proc_pidpath(processIdentifier, &pathBuffer, UInt32(pathBuffer.count))
        guard pathLength > 0 else { return nil }
        return String(decoding: pathBuffer.prefix(Int(pathLength)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    // MARK: - Paths

    /// libproc reports real paths (/private/var/...), so compare against those.
    static func resolvedPath(_ path: String) -> String? {
        guard !path.isEmpty, let resolvedPointer = realpath(path, nil) else { return nil }
        defer { free(resolvedPointer) }
        return String(cString: resolvedPointer)
    }

    static func isPath(_ path: String, underAnyOf directories: [String]) -> Bool {
        directories.contains { directory in
            let directoryWithSlash = directory.hasSuffix("/") ? directory : directory + "/"
            return path == directory || path.hasPrefix(directoryWithSlash)
        }
    }
}
