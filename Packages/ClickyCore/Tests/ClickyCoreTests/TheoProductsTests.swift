//
//  TheoProductsTests.swift
//  ClickyCoreTests
//

import ClickyCore
import Testing

struct TheoProductsTests {
    @Test func anUpdateKeepsAnExistingMacAsItWas() {
        // Setup finished before products were a choice: everything stays on.
        #expect(TheoProductChoice.isOn(stored: nil, setupCompleted: true))
        // A new user starts with nothing on.
        #expect(!TheoProductChoice.isOn(stored: nil, setupCompleted: false))
        // A choice someone made always wins.
        #expect(!TheoProductChoice.isOn(stored: false, setupCompleted: true))
        #expect(TheoProductChoice.isOn(stored: true, setupCompleted: false))
    }

    @Test func setupNeedsAtLeastOneProduct() {
        #expect(!TheoProductChoice.canFinish([]))
        #expect(TheoProductChoice.canFinish([.dictation]))
    }

    @Test func dictationIsBlockedWithoutAKey() {
        #expect(DictationAccess.of(productOn: false, hasSarvamKey: true) == .off)
        #expect(DictationAccess.of(productOn: false, hasSarvamKey: false) == .off)
        #expect(DictationAccess.of(productOn: true, hasSarvamKey: false) == .needsKey)
        #expect(DictationAccess.of(productOn: true, hasSarvamKey: true) == .ready)
        // With no key the shortcut is still heard, so a press can say what's missing; off means nothing at all.
        #expect(DictationAccess.needsKey.listensForShortcut)
        #expect(!DictationAccess.off.listensForShortcut)
        #expect(DictationAccess.needsKey.message?.contains("Sarvam API key") == true)
        #expect(DictationAccess.ready.message == nil)
        #expect(TheoProduct.dictation.requirement?.contains("Sarvam API key") == true)
    }

    @Test func eachProductOwnsItsDeviceFeatures() {
        #expect(TheoProduct.owning(.dictation) == .dictation)
        #expect(TheoProduct.owning(.clicky) == .clicky)
        #expect(TheoProduct.owning(.voice) == .clicky)
        #expect(TheoProduct.owning(.routines) == .theo)
        // Clicky's helpers are bots, so bots aren't turned off with Theo.
        #expect(TheoProduct.owning(.bots) == nil)
        #expect(TheoProduct.owning(.studioScreens) == nil)
        // No feature belongs to two products.
        let all = TheoProduct.allCases.flatMap(\.deviceFeatures)
        #expect(Set(all).count == all.count)
    }

    @Test func clickyAndTheoAreSeparateChoices() {
        #expect(Set(TheoProduct.allCases.map(\.settingKey)).count == 3)
        #expect(TheoProduct.clicky.settingKey != TheoProduct.theo.settingKey)
        for product in TheoProduct.allCases {
            #expect(!product.tagline.isEmpty)
            #expect(product.points.count == 3)
        }
    }

    @Test func setupStepsFollowTheProductsPicked() {
        #expect(SetupStep.shown(for: []) == SetupStep.allCases)
        #expect(SetupStep.shown(for: [.dictation]) == [.welcome, .products, .permissions, .keys, .done])
        #expect(SetupStep.shown(for: [.clicky]) == SetupStep.allCases)
        #expect(SetupStep.shown(for: [.theo, .dictation]) == SetupStep.allCases)
        #expect(SetupStep.next(after: .permissions, products: [.dictation]) == .keys)
        #expect(SetupStep.next(after: .keys, products: [.dictation]) == .done)
        #expect(SetupStep.previous(before: .done, products: [.dictation]) == .keys)
        #expect(SetupStep.next(after: .done, products: [.theo]) == nil)
        #expect(SetupStep.previous(before: .welcome, products: [.theo]) == nil)
        #expect(SetupStep.next(after: .welcome, products: []) == .products)
    }

    @Test func demoClockLoopsAndTypes() {
        let clock = ProductDemoClock(.clicky)
        #expect(clock.moment(elapsed: 0) == 0)
        #expect(clock.moment(elapsed: -3) == 0)
        #expect(abs(clock.moment(elapsed: clock.loopSeconds + 1.5) - 1.5) < 0.0001)
        #expect(ProductDemoClock.progress(1, from: 2, to: 4) == 0)
        #expect(ProductDemoClock.progress(3, from: 2, to: 4) == 0.5)
        #expect(ProductDemoClock.progress(9, from: 2, to: 4) == 1)
        #expect(ProductDemoClock.typed("Friday.", progress: 0) == "")
        #expect(ProductDemoClock.typed("Friday.", progress: 0.5) == "Fri")
        #expect(ProductDemoClock.typed("Friday.", progress: 2) == "Friday.")
    }

    @Test func aMissingKeyNoteLeadsToTheKey() {
        #expect(ComposerDictationProblem.needsKey.opensKeySettings)
        #expect(!ComposerDictationProblem.needsKey.needsPermission)
        #expect(!ComposerDictationProblem.needsKey.isBrief)
        #expect(ComposerDictationProblem.needsKey.message.contains("Sarvam API key"))
    }
}
