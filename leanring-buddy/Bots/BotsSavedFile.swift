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
        // What can still be read of the damaged file: everything up to the last whole record. A file cut short keeps
        // what came before the cut, which can be newer than the last good copy (that one is from this launch's start).
        let rescued = readablePart(of: data, as: T.self, decoder: decoder)
        let old = (try? Data(contentsOf: lastGood(file))).flatMap { data in (try? decoder.decode(T.self, from: data)).map { (data, $0) } }
        if let rescued, rescued.data.count >= (old?.0.count ?? 0) {
            try? rescued.data.write(to: file, options: .atomic)
            note("Theo couldn't read all of \(what), so it kept everything that could still be read. The damaged file is kept as \(aside.lastPathComponent).")
            return rescued.value
        }
        if let (good, value) = old {
            try? good.write(to: file, options: .atomic)
            note("Theo couldn't read \(what), so it used the last copy that read fine. The unreadable file is kept as \(aside.lastPathComponent).")
            return value
        }
        note("Theo couldn't read \(what) and had no earlier copy to use. Nothing was deleted: the file is kept as \(aside.lastPathComponent).")
        return nil
    }

    /// The longest start of damaged JSON that still decodes: cut after a whole record in a list, with every bracket
    /// still open closed. Tries the latest cuts first, and only so many.
    static func readablePart<T: Decodable>(of data: Data, as type: T.Type, decoder: JSONDecoder, attempts: Int = 64) -> (data: Data, value: T)? {
        let bytes = [UInt8](data)
        var stack: [UInt8] = []
        var inString = false
        var escaped = false
        var cuts: [(end: Int, closers: [UInt8])] = []
        for (index, byte) in bytes.enumerated() {
            if inString {
                if escaped { escaped = false } else if byte == UInt8(ascii: "\\") { escaped = true } else if byte == UInt8(ascii: "\"") { inString = false }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "["), UInt8(ascii: "{"): stack.append(byte)
            case UInt8(ascii: "]"), UInt8(ascii: "}"):
                guard !stack.isEmpty else { return nil }
                stack.removeLast()
                // A whole record that sits in a list: a place to cut.
                if stack.last == UInt8(ascii: "[") {
                    cuts.append((index + 1, stack.reversed().map { $0 == UInt8(ascii: "[") ? UInt8(ascii: "]") : UInt8(ascii: "}") }))
                }
            default: break
            }
        }
        for cut in cuts.reversed().prefix(attempts) {
            let candidate = Data(bytes[..<cut.end] + cut.closers)
            if let value = try? decoder.decode(T.self, from: candidate) { return (candidate, value) }
        }
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
