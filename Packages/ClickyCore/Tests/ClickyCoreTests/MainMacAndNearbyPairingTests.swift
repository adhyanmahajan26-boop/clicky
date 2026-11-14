//
//  MainMacAndNearbyPairingTests.swift
//  ClickyCoreTests
//
//  The main Mac the owner picks in Settings › Devices, and one-click linking between two Macs nearby.
//

import CryptoKit
import XCTest
@testable import ClickyCore

final class MainMacTests: XCTestCase {
    private let desktop = LinkedMac(id: "B-DESK", name: "Desk Mac", isDesktop: true)
    private let laptop = LinkedMac(id: "A-LAP", name: "Lap Mac", isDesktop: false)

    private func pair(_ thisMac: LinkedMac, _ otherMac: LinkedMac?) -> MacPair {
        MacPair(thisMac: thisMac, otherMac: otherMac, paired: true, otherMacOnline: true)
    }

    private func picked(_ mac: LinkedMac, main: String?, at seconds: TimeInterval) -> LinkedMac {
        var copy = mac
        copy.mainMacID = main
        copy.mainMacChosenAt = Date(timeIntervalSince1970: seconds)
        return copy
    }

    func testWithoutAPickTheDesktopIsMain() {
        XCTAssertTrue(DeviceRouting.alwaysOnMacIsThisOne(pair(desktop, laptop)))
        XCTAssertFalse(DeviceRouting.alwaysOnMacIsThisOne(pair(laptop, desktop)))
    }

    func testAPickedLaptopIsMainOnBothMacs() {
        let laptopSays = picked(laptop, main: laptop.id, at: 100)
        XCTAssertTrue(DeviceRouting.alwaysOnMacIsThisOne(pair(laptopSays, desktop)))
        XCTAssertFalse(DeviceRouting.alwaysOnMacIsThisOne(pair(desktop, laptopSays)))
    }

    func testTheNewerPickWins() {
        let laptopSays = picked(laptop, main: laptop.id, at: 100)
        let desktopSays = picked(desktop, main: desktop.id, at: 200)
        XCTAssertTrue(DeviceRouting.alwaysOnMacIsThisOne(pair(desktopSays, laptopSays)))
        XCTAssertFalse(DeviceRouting.alwaysOnMacIsThisOne(pair(laptopSays, desktopSays)))
    }

    func testAPickOfAMacThatIsGoneIsIgnored() {
        let stale = picked(laptop, main: "C-OLD", at: 100)
        XCTAssertNil(DeviceRouting.pickedMainMacID(pair(stale, desktop)))
        XCTAssertFalse(DeviceRouting.alwaysOnMacIsThisOne(pair(stale, desktop)))
    }

    func testBeforeHearingFromTheOtherMacAPickStillCounts() {
        XCTAssertTrue(DeviceRouting.alwaysOnMacIsThisOne(pair(picked(laptop, main: laptop.id, at: 1), nil)))
        XCTAssertFalse(DeviceRouting.alwaysOnMacIsThisOne(pair(picked(desktop, main: laptop.id, at: 1), nil)))
    }

    func testRoutinesAndVMScreensFollowTheMainMac() {
        let laptopSays = picked(laptop, main: laptop.id, at: 100)
        XCTAssertEqual(DeviceRouting.route(.routines, choice: .any, pair: pair(laptopSays, desktop)), .runHere)
        XCTAssertEqual(DeviceRouting.route(.studioScreens, choice: .any, pair: pair(desktop, laptopSays)), .notHere)
        XCTAssertEqual(DeviceFeature.studioScreens.title, "VM screens")
        XCTAssertEqual(DeviceFeature.routines.anyChoiceTitle, "The main Mac")
    }

    func testTheSnapshotCarriesThePick() {
        let at = Date(timeIntervalSince1970: 500)
        let snapshot = DeviceSnapshot(name: "Lap Mac", projectsFolder: "/p", projects: [], harnesses: [:], hasScreens: false, deviceID: laptop.id, isDesktop: false,
                                      mainMacID: laptop.id, mainMacChosenAt: at)
        let decoded = try! LinkCoding.decoder.decode(DeviceSnapshot.self, from: LinkCoding.encoder.encode(snapshot))
        XCTAssertEqual(decoded.linkedMac.mainMacID, laptop.id)
        XCTAssertEqual(decoded.linkedMac.mainMacChosenAt, at)
        // A snapshot from an older build has no pick.
        let old = try! LinkCoding.decoder.decode(DeviceSnapshot.self, from: Data(#"{"name":"Old","projectsFolder":"/p","projects":[],"harnesses":{},"hasScreens":true}"#.utf8))
        XCTAssertNil(old.linkedMac.mainMacID)
    }
}

final class NearbyPairingTests: XCTestCase {
    func testBothSidesAgreeOnTheKeyAndTheCheckNumber() {
        let asking = Curve25519.KeyAgreement.PrivateKey()
        let asked = Curve25519.KeyAgreement.PrivateKey()
        let onAsking = NearbyPairing.agree(myPrivateKey: asking, theirPublicKeyBase64: asked.publicKey.rawRepresentation.base64EncodedString())!
        let onAsked = NearbyPairing.agree(myPrivateKey: asked, theirPublicKeyBase64: asking.publicKey.rawRepresentation.base64EncodedString())!
        XCTAssertEqual(onAsking.checkNumber, onAsked.checkNumber)
        XCTAssertEqual(onAsking.checkNumber.count, 6)
        let code = LinkPairing.newCode()
        let sealed = NearbyPairing.seal(code: code, with: onAsking.key)!
        XCTAssertEqual(NearbyPairing.open(sealed: sealed, with: onAsked.key), code)
    }

    func testSomeoneInTheMiddleGetsADifferentNumberAndCantOpenTheCode() {
        let asking = Curve25519.KeyAgreement.PrivateKey()
        let asked = Curve25519.KeyAgreement.PrivateKey()
        let middle = Curve25519.KeyAgreement.PrivateKey()
        let onAsking = NearbyPairing.agree(myPrivateKey: asking, theirPublicKeyBase64: middle.publicKey.rawRepresentation.base64EncodedString())!
        let onAsked = NearbyPairing.agree(myPrivateKey: asked, theirPublicKeyBase64: middle.publicKey.rawRepresentation.base64EncodedString())!
        XCTAssertNotEqual(onAsking.checkNumber, onAsked.checkNumber)
        let sealed = NearbyPairing.seal(code: LinkPairing.newCode(), with: onAsking.key)!
        XCTAssertNil(NearbyPairing.open(sealed: sealed, with: onAsked.key))
    }

    func testBadInputIsRefused() {
        let key = Curve25519.KeyAgreement.PrivateKey()
        XCTAssertNil(NearbyPairing.agree(myPrivateKey: key, theirPublicKeyBase64: "not a key"))
        XCTAssertNil(NearbyPairing.decode(Data(repeating: 0x20, count: NearbyPairing.maximumMessageBytes + 1)))
        XCTAssertEqual(NearbyPairing.spaced("482913"), "482 913")
    }

    func testMessagesRoundTrip() {
        let message = NearbyPairing.Message(kind: .hello, name: "Lap Mac", deviceID: "A", publicKey: "abc")
        var reader = LinkFrameReader()
        let frames = reader.feed(NearbyPairing.encode(message)!)!
        XCTAssertEqual(NearbyPairing.decode(frames[0]), message)
    }
}
