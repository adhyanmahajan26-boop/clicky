//
//  NearbyPairing.swift
//  ClickyCore
//
//  One-click linking: a Mac with Theo open and not linked yet shows up on the other Macs nearby. Click Link on one, Allow on
//  the other, and they're linked, with no code typed. The pure parts are here: the messages, the keys and the check number.
//
//  The two Macs swap fresh X25519 keys and both show a check number made from them. Someone in the middle would have to
//  swap keys with each Mac separately, and then the two numbers wouldn't match. The link code itself only ever travels
//  sealed with the agreed key, and the Mac asked only takes it once its owner presses Allow.
//

import CryptoKit
import Foundation

public enum NearbyPairing {
    /// The Bonjour type a Mac that can be linked advertises. Test profiles use their own, so the owner's Macs never see them.
    public static let serviceType = "_theopair._tcp"
    public static let testServiceType = "_theopairtest._tcp"

    /// A pairing conversation is a handful of small messages: anything bigger isn't one.
    public static let maximumMessageBytes = 16 * 1024

    /// How long a request waits for Allow before it's dropped.
    public static let requestLifetimeSeconds: TimeInterval = 120

    public enum Kind: String, Codable, Sendable {
        /// Each side's name, id and public key.
        case hello
        /// The asking Mac's link code, sealed with the agreed key.
        case offer
        /// The asked Mac's owner pressed Allow and the code is saved.
        case accepted
        /// The asked Mac's owner said no, or the request timed out.
        case declined
    }

    public struct Message: Codable, Equatable, Sendable {
        public var kind: Kind
        public var name: String?
        public var deviceID: String?
        /// Raw X25519 public key, base64.
        public var publicKey: String?
        /// ChaChaPoly box of the link code, base64.
        public var sealed: String?
        /// Test profiles only: the link port the sender listens on, since test profiles link by address rather than Bonjour.
        public var testLinkPort: Int?

        public init(kind: Kind, name: String? = nil, deviceID: String? = nil, publicKey: String? = nil, sealed: String? = nil, testLinkPort: Int? = nil) {
            self.kind = kind
            self.name = name
            self.deviceID = deviceID
            self.publicKey = publicKey
            self.sealed = sealed
            self.testLinkPort = testLinkPort
        }
    }

    /// What both sides agree on once the keys are swapped.
    public struct Agreement: Sendable {
        public let key: SymmetricKey
        /// Six digits, shown on both Macs so the owner can see it's the same pair.
        public let checkNumber: String
    }

    /// Both sides get the same agreement whichever one asked, since the two public keys are taken in sorted order.
    public static func agree(myPrivateKey: Curve25519.KeyAgreement.PrivateKey, theirPublicKeyBase64: String) -> Agreement? {
        guard let theirRaw = Data(base64Encoded: theirPublicKeyBase64),
              let theirs = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirRaw),
              let shared = try? myPrivateKey.sharedSecretFromKeyAgreement(with: theirs) else { return nil }
        let mine = myPrivateKey.publicKey.rawRepresentation
        let bothKeys = [mine, theirRaw].sorted { $0.lexicographicallyPrecedes($1) }.reduce(Data(), +)
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("theo-pair-v1".utf8), sharedInfo: bothKeys + Data("key".utf8), outputByteCount: 32)
        let check = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("theo-pair-v1".utf8), sharedInfo: bothKeys + Data("check".utf8), outputByteCount: 8)
        let number = check.withUnsafeBytes { bytes in bytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) } } % 1_000_000
        return Agreement(key: key, checkNumber: String(format: "%06llu", number))
    }

    /// "482 913": easier to compare at a glance.
    public static func spaced(_ checkNumber: String) -> String {
        guard checkNumber.count == 6 else { return checkNumber }
        return "\(checkNumber.prefix(3)) \(checkNumber.suffix(3))"
    }

    public static func seal(code: String, with key: SymmetricKey) -> String? {
        (try? ChaChaPoly.seal(Data(code.utf8), using: key))?.combined.base64EncodedString()
    }

    /// The code, if it opens with this key and is a whole link code.
    public static func open(sealed: String, with key: SymmetricKey) -> String? {
        guard let combined = Data(base64Encoded: sealed),
              let box = try? ChaChaPoly.SealedBox(combined: combined),
              let opened = try? ChaChaPoly.open(box, using: key) else { return nil }
        return LinkPairing.normalized(String(decoding: opened, as: UTF8.self))
    }

    public static func encode(_ message: Message) -> Data? {
        (try? LinkCoding.encoder.encode(message)).map(LinkFrameReader.frame)
    }

    public static func decode(_ data: Data) -> Message? {
        guard data.count <= maximumMessageBytes else { return nil }
        return try? LinkCoding.decoder.decode(Message.self, from: data)
    }
}
