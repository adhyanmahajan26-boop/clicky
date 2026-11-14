//
//  TestProfileIsolationTests.swift
//  leanring-buddyTests
//
//  Unit tests host the app. They must run on the isolated `test-unittests` profile: its own defaults domain, home
//  folder and Keychain services, never the owner's com.personal.clicky, ~/Library/Application Support/Theo or keys.
//

import ClickyCore
import Foundation
import Testing
@testable import Clicky

@MainActor
struct TestProfileIsolationTests {

    @Test func hostedAppIsOnTheIsolatedUnitTestProfile() {
        #expect(TheoProfile.isHostingTests)
        #expect(TheoProfile.name == TheoProfile.unitTestsName)
        #expect(TheoProfile.isTest)
        #expect(TheoAppDelegate.isHostingUnitTests)
    }

    @Test func standardDefaultsAreTheTestDomain() {
        let key = "test.isolation.probe.\(UUID().uuidString)"
        UserDefaults.standard.set("here", forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let testDomain = UserDefaults(suiteName: TheoProfile.testDefaultsDomain)
        #expect(TheoProfile.testDefaultsDomain == "com.personal.clicky.test-unittests")
        #expect(testDomain?.string(forKey: key) == "here")
    }

    @Test func homeAndDataFoldersAreTheTestHome() {
        let testHome = TheoProfile.testHome.standardizedFileURL.path
        #expect(testHome.hasSuffix("/Library/Application Support/Theo-Test-unittests/home"))
        #expect(NSHomeDirectory() == testHome)
        #expect(FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path == testHome)
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].standardizedFileURL.path
        #expect(appSupport.hasPrefix(testHome))
        let realTheo = TheoProfile.realHome + "/Library/Application Support/Theo"
        #expect(!ConnectorHub.dataFolder.standardizedFileURL.path.hasPrefix(realTheo))
        #expect(!BotsStore.shared.folder.standardizedFileURL.path.hasPrefix(realTheo))
    }

    @Test func keychainServicesAreTheTestOnes() {
        #expect(ProviderKeychain.service == "com.theo.providers.test-unittests")
        #expect(TheoGatewayToken.service == "com.theo.gateway.test-unittests")
        #expect(ClickySecrets.serviceSuffix == ".test-unittests")
        #expect(ConnectorHub.keepsVaultKeyInFile)
    }
}
