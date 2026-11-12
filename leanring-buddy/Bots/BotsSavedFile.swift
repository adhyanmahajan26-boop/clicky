//
//  BotsSavedFile.swift
//  leanring-buddy
//
//  Reading Theo's saved bots, chats, groups and routines without ever losing them. A file that's there but can't be
//  read (cut short by a crash or a full disk, or written by a newer build) is moved aside, never overwritten, and the
//  last copy that read fine is used in its place.
//

import Foundation

enum BotsSavedFile {
    /// Files already copied to their last-good copy since launch: once is enough.
    nonisolated(unsafe) private static var keptThisLaunch = Set<String>()
    private static let lock = NSLock()

    /// What went wrong on load, to tell the owner once.
    nonisolated(unsafe) private(set) static var problems: [String] = []

    static func lastGood(_ file: URL) -> URL { file.appendingPathExtension("lastgood") }

    /// The decoded file; nil when there's no file yet, or when it was unreadable and no good copy could stand in.
    static func load<T: Decodable>(_ type: T.Type, from file: URL, decoder: JSONDecoder, what: String) -> T? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        if let value = try? decoder.decode(T.self, from: data) {
            keepGood(data, of: file)
            return value
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let aside = file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + ".unreadable-" + stamp)
        try? FileManager.default.moveItem(at: file, to: aside)
        if let old = try? Data(contentsOf: lastGood(file)), let value = try? decoder.decode(T.self, from: old) {
            try? old.write(to: file, options: .atomic)
            note("Theo couldn't read \(what), so it used the last copy that read fine. The unreadable file is kept as \(aside.lastPathComponent).")
            return value
        }
        note("Theo couldn't read \(what) and had no earlier copy to use. Nothing was deleted: the file is kept as \(aside.lastPathComponent).")
        return nil
    }

    private static func keepGood(_ data: Data, of file: URL) {
        let key = file.path
        let first = lock.withLock { keptThisLaunch.insert(key).inserted }
        guard first else { return }
        try? data.write(to: lastGood(file), options: .atomic)
    }

    private static func note(_ line: String) {
        lock.withLock { problems.append(line) }
        NSLog("Theo saved file: %@", line)
    }

    /// The problems so far, cleared: each is told once.
    static func takeProblems() -> [String] {
        lock.withLock { defer { problems.removeAll() }; return problems }
    }
}
