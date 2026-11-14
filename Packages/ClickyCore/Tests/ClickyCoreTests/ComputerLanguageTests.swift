//
//  ComputerLanguageTests.swift
//  ClickyCoreTests
//
//  Calls start from the computer's language; only a Mac set to Hindi or an Indian region starts on the Hinglish mix.
//

import Foundation
import Testing
@testable import ClickyCore

struct ComputerLanguageTests {
    @Test func theRecognizerFollowsTheComputer() {
        #expect(ComputerLanguage.recognizerLocale(preferredLanguage: "en-US") == "en-US")
        #expect(ComputerLanguage.recognizerLocale(preferredLanguage: "en_GB") == "en-GB")
        #expect(ComputerLanguage.recognizerLocale(preferredLanguage: "fr") == "fr-FR")
        #expect(ComputerLanguage.recognizerLocale(preferredLanguage: "zh-Hans-CN") == "zh-CN")
        #expect(ComputerLanguage.recognizerLocale(preferredLanguage: nil) == "en-US")
        #expect(ComputerLanguage.recognizerLocale(preferredLanguage: "") == "en-US")
    }

    @Test func onlyAnIndianMacStartsOnHinglish() {
        #expect(ComputerLanguage.isIndian(preferredLanguage: "en-IN"))
        #expect(ComputerLanguage.isIndian(preferredLanguage: "hi"))
        #expect(!ComputerLanguage.isIndian(preferredLanguage: "en-US"))
        #expect(!ComputerLanguage.isIndian(preferredLanguage: "de-DE"))
    }

    @Test func englishIsTheComputersOwnEnglish() {
        #expect(ComputerLanguage.englishLocale(preferredLanguage: "en-GB") == "en-GB")
        #expect(ComputerLanguage.englishLocale(preferredLanguage: "en-IN") == "en-IN")
        #expect(ComputerLanguage.englishLocale(preferredLanguage: "es-ES") == "en-US")
    }

    @Test func aMacSetUpBeforeKeepsHinglish() {
        #expect(ComputerLanguage.migratedCallLanguage(savedValueExists: false, setupCompleted: true) == "hinglish")
        #expect(ComputerLanguage.migratedCallLanguage(savedValueExists: false, setupCompleted: false) == nil)
        #expect(ComputerLanguage.migratedCallLanguage(savedValueExists: true, setupCompleted: true) == nil)
    }
}
