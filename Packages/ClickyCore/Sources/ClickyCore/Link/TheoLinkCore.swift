//
//  TheoLinkCore.swift
//  ClickyCore
//
//  The pure parts of Theo Link, which keeps two of the owner's Macs on the same bots, chats and memory: the pairing code,
//  how messages are framed on the wire, and how both sides merge so they end up identical whichever goes first.
//

import CryptoKit
import Foundation

public enum LinkPairing {
    private static let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")

    /// A new code, like "K7QM-2XPA-…": five groups of four, about 99 bits.
    public static func newCode() -> String {
        (0..<5).map { _ in String((0..<4).map { _ in alphabet.randomElement()! }) }.joined(separator: "-")
    }

    /// The code however it was typed or pasted. Nil when it can't be one.
    public static func normalized(_ typed: String) -> String? {
        let letters = typed.uppercased().filter { alphabet.contains($0) }
        guard letters.count == 20 else { return nil }
        return stride(from: 0, to: 20, by: 4).map { start in
            let begin = letters.index(letters.startIndex, offsetBy: start)
            return String(letters[begin..<letters.index(begin, offsetBy: 4)])
        }.joined(separator: "-")
    }

    /// The key both Macs prove they hold when they connect.
    public static func key(forCode code: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data("theo-link-v1".utf8), using: SymmetricKey(data: Data(code.utf8))))
    }
}

/// Length-prefixed messages over a stream.
public struct LinkFrameReader: Sendable {
    public static let maximumFrame = 64 * 1024 * 1024
    private var buffer = Data()

    public init() {}

    public static func frame(_ message: Data) -> Data {
        var length = UInt32(message.count).bigEndian
        return Data(bytes: &length, count: 4) + message
    }

    /// The whole messages now available. Nil when the stream can't be trusted any more.
    public mutating func feed(_ data: Data) -> [Data]? {
        buffer.append(data)
        var messages: [Data] = []
        while buffer.count >= 4 {
            let start = buffer.startIndex
            let length = buffer[start..<start + 4].reduce(0) { Int($0) << 8 | Int($1) }
            guard length <= Self.maximumFrame else { return nil }
            guard buffer.count >= 4 + length else { break }
            messages.append(Data(buffer[start + 4..<start + 4 + length]))
            buffer = Data(buffer[(start + 4 + length)...])
        }
        return messages
    }
}

public enum LinkCoding {
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func digest<T: Encodable>(_ value: T) -> String {
        digest((try? encoder.encode(value)) ?? Data())
    }
}

public enum LinkMerge {
    /// Everything on both sides, each thing once, oldest first. Things from before a cleared chat stay gone.
    /// `better` picks between two versions of the same thing; it must give the same answer on both sides.
    public static func union<T>(local: [T], remote: [T], id: (T) -> String, at: (T) -> Date, clearedAt: Date? = nil,
                                better: (T, T) -> T = { first, _ in first }) -> [T] {
        var byID: [String: T] = [:]
        for item in local + remote {
            let key = id(item)
            byID[key] = byID[key].map { better($0, item) } ?? item
        }
        return byID.values
            .filter { item in clearedAt.map { at(item) > $0 } ?? true }
            .sorted { at($0) != at($1) ? at($0) < at($1) : id($0) < id($1) }
    }

    /// When each thing last changed, and when things were removed.
    public struct Stamps: Codable, Equatable, Sendable {
        public var changed: [String: Date] = [:]
        public var gone: [String: Date] = [:]
        public init() {}
    }

    /// Whole things by id, in a stable order: the newer version wins, and a removal wins over anything older.
    public static func byID<T: Encodable>(local: [T], localStamps: Stamps, remote: [T], remoteStamps: Stamps, id: (T) -> String) -> (items: [T], stamps: Stamps) {
        var stamps = Stamps()
        for (key, date) in localStamps.changed.merging(remoteStamps.changed, uniquingKeysWith: max) { stamps.changed[key] = date }
        for (key, date) in localStamps.gone.merging(remoteStamps.gone, uniquingKeysWith: max) { stamps.gone[key] = date }
        func bytes(_ item: T) -> Data { (try? LinkCoding.encoder.encode(item)) ?? Data() }
        var merged: [String: T] = Dictionary(local.map { (id($0), $0) }, uniquingKeysWith: { first, _ in first })
        for item in remote {
            let key = id(item)
            guard let mine = merged[key] else {
                merged[key] = item
                continue
            }
            let mineAt = localStamps.changed[key] ?? .distantPast
            let theirsAt = remoteStamps.changed[key] ?? .distantPast
            if theirsAt > mineAt || (theirsAt == mineAt && bytes(item).lexicographicallyPrecedes(bytes(mine))) { merged[key] = item }
        }
        for (key, removedAt) in stamps.gone {
            if let changedAt = stamps.changed[key], changedAt > removedAt { stamps.gone[key] = nil } else { merged[key] = nil }
        }
        // Keep this side's order for what it has, so nothing jumps; what's new goes at the end, the same on both.
        let order = local.map(id) + remote.map(id).filter { key in !local.contains { id($0) == key } }.sorted()
        var seen = Set<String>()
        let items = order.compactMap { key -> T? in seen.insert(key).inserted ? merged[key] : nil }
        return (items, stamps)
    }

    /// What changed between two saves, for `byID`.
    public static func noteChanges<T: Encodable>(from old: [T], to new: [T], id: (T) -> String, stamps: inout Stamps, at now: Date = Date()) {
        func bytes(_ item: T) -> Data { (try? LinkCoding.encoder.encode(item)) ?? Data() }
        let before = Dictionary(old.map { (id($0), bytes($0)) }, uniquingKeysWith: { first, _ in first })
        let after = Dictionary(new.map { (id($0), bytes($0)) }, uniquingKeysWith: { first, _ in first })
        for (key, data) in after where before[key] != data {
            stamps.changed[key] = now
            stamps.gone[key] = nil
        }
        for key in before.keys where after[key] == nil { stamps.gone[key] = now }
    }
}

extension ClickyMemoryStore {
    /// Both logs, for the other Mac.
    public func everything() -> [ClickyMemoryEntry] { entries() + summaries() }

    /// Adds what the other Mac has, keeping each entry once and the logs in date order.
    public func merge(_ remote: [ClickyMemoryEntry]) {
        let key: (ClickyMemoryEntry) -> String = { "\($0.kind.rawValue)|\(Int($0.at.timeIntervalSince1970))|\($0.text)" }
        let merged = LinkMerge.union(local: everything(), remote: remote, id: key, at: { $0.at })
        replace(merged.filter { $0.kind == .said }, inSaidLog: true)
        replace(merged.filter { $0.kind != .said }, inSaidLog: false)
    }
}
