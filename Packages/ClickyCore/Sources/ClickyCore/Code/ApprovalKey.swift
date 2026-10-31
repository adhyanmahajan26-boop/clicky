//
//  ApprovalKey.swift
//  ClickyCore
//
//  Binds a click on the review panel to exactly what was reviewed: a
//  SHA-256 over the reviewed commit OID, each outward action's argv, each
//  body file (path + SHA-256 of its bytes) and the sorted acks. Every field
//  is length-prefixed, so ["ab","c"] and ["a","bc"] hash differently, and
//  any single changed byte gives a different key. Before running each
//  action the app recomputes the key from disk and refuses on a mismatch.
//

import CryptoKit
import Foundation

public struct ApprovalMaterial: Equatable, Sendable {
    public struct BodyFile: Equatable, Sendable {
        public var path: String
        public var contents: Data

        public init(path: String, contents: Data) {
            self.path = path
            self.contents = contents
        }
    }

    public var reviewOID: String
    /// One argv per outward action, in execution order.
    public var actionArguments: [[String]]
    /// Files passed with --body-file / -F (order doesn't matter; sorted by path).
    public var bodyFiles: [BodyFile]
    /// Ack identifiers (CodeGuardFinding.ackIdentifier); order doesn't matter.
    public var acks: [String]

    public init(reviewOID: String, actionArguments: [[String]], bodyFiles: [BodyFile], acks: [String]) {
        self.reviewOID = reviewOID
        self.actionArguments = actionArguments
        self.bodyFiles = bodyFiles
        self.acks = acks
    }

    /// Reads each body file from disk now (call again right before acting).
    public static func reading(reviewOID: String, actionArguments: [[String]], bodyFilePaths: [String], acks: [String]) throws -> ApprovalMaterial {
        let bodyFiles = try bodyFilePaths.map { bodyFilePath in
            BodyFile(path: bodyFilePath, contents: try Data(contentsOf: URL(fileURLWithPath: bodyFilePath)))
        }
        return ApprovalMaterial(reviewOID: reviewOID, actionArguments: actionArguments, bodyFiles: bodyFiles, acks: acks)
    }

    public var approvalKey: ApprovalKey { ApprovalKey(material: self) }
}

public struct ApprovalKey: Equatable, Hashable, Sendable, CustomStringConvertible {
    /// Lowercase hex SHA-256.
    public let hexDigest: String

    public init(hexDigest: String) {
        self.hexDigest = hexDigest
    }

    public init(material: ApprovalMaterial) {
        var hasher = SHA256()
        func append(_ bytes: Data) {
            var lengthBigEndian = UInt64(bytes.count).bigEndian
            hasher.update(data: Data(bytes: &lengthBigEndian, count: 8))
            hasher.update(data: bytes)
        }
        func append(_ text: String) { append(Data(text.utf8)) }
        func appendCount(_ count: Int) {
            var countBigEndian = UInt64(count).bigEndian
            hasher.update(data: Data(bytes: &countBigEndian, count: 8))
        }

        append("clicky-approval-v1")
        append("oid")
        append(material.reviewOID)
        append("actions")
        appendCount(material.actionArguments.count)
        for actionArgv in material.actionArguments {
            appendCount(actionArgv.count)
            actionArgv.forEach { append($0) }
        }
        append("bodies")
        let sortedBodyFiles = material.bodyFiles.sorted { $0.path < $1.path }
        appendCount(sortedBodyFiles.count)
        for bodyFile in sortedBodyFiles {
            append(bodyFile.path)
            append(Data(SHA256.hash(data: bodyFile.contents)))
        }
        append("acks")
        let sortedAcks = material.acks.sorted()
        appendCount(sortedAcks.count)
        sortedAcks.forEach { append($0) }

        hexDigest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public var description: String { hexDigest }

    /// True when `current` (rebuilt from disk right before the action) still
    /// matches the key the user approved. Compared in constant time.
    public func verify(current currentMaterial: ApprovalMaterial) -> Bool {
        let currentDigest = Array(ApprovalKey(material: currentMaterial).hexDigest.utf8)
        let approvedDigest = Array(hexDigest.utf8)
        guard currentDigest.count == approvedDigest.count else { return false }
        var difference: UInt8 = 0
        for (currentByte, approvedByte) in zip(currentDigest, approvedDigest) { difference |= currentByte ^ approvedByte }
        return difference == 0
    }

    /// Rebuilds the material from disk and verifies; false if any body file can't be read.
    public func verifyBeforeAction(reviewOID: String, actionArguments: [[String]], bodyFilePaths: [String], acks: [String]) -> Bool {
        guard let currentMaterial = try? ApprovalMaterial.reading(reviewOID: reviewOID, actionArguments: actionArguments, bodyFilePaths: bodyFilePaths, acks: acks) else { return false }
        return verify(current: currentMaterial)
    }
}
