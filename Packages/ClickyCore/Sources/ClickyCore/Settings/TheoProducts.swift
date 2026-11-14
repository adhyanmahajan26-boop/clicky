//
//  TheoProducts.swift
//  ClickyCore
//
//  Theo comes as three products a new user picks from: Theo (bots, teams, routines and coding runs), Clicky (the screen
//  companion) and Dictation (talk, and the words are typed). Each is on or off by itself. A Sarvam API key makes Dictation
//  better (Sarvam's words, Indian languages); with none saved it uses Apple's dictation on this Mac.
//
//  This file is the rules only (what each product owns, the default for an install from before the choice existed,
//  which Setup steps a choice needs, what blocks dictation). The app keeps the choice in UserDefaults and applies it.
//

import Foundation

public enum TheoProduct: String, CaseIterable, Identifiable, Sendable {
    case dictation, clicky, theo

    public var id: String { rawValue }

    /// Where the choice is kept.
    public var settingKey: String { "v4.products.\(rawValue)" }

    public var title: String {
        switch self {
        case .dictation: return "Dictation"
        case .clicky: return "Clicky"
        case .theo: return "Theo"
        }
    }

    /// One line under the name.
    public var tagline: String {
        switch self {
        case .dictation: return "Talk in any app. Clean, punctuated words are typed where your cursor is."
        case .clicky: return "A companion on your screen that sees what you see, points at things and answers out loud."
        case .theo: return "Your own team of bots that chat, run routines and hand coding work to your agents."
        }
    }

    /// What you get, shortest first.
    public var points: [String] {
        switch self {
        case .dictation:
            return ["Hold Control + Fn anywhere, talk, let go",
                    "Fillers and \u{201C}um\u{201D}s are tidied away",
                    "Hindi, Hinglish and 10 Indian languages"]
        case .clicky:
            return ["Say \u{201C}hey Theo\u{201D} or hold Control + Option",
                    "Flies to the button you need and circles it",
                    "Draws boards and researches links for you"]
        case .theo:
            return ["Make bots from stencils, with teams and schedules",
                    "Hand a fix to Claude Code, Codex, Cursor and more",
                    "Runs come back with a branch and a draft PR"]
        }
    }

    /// What it needs before it works, shown on its card. Nil: nothing beyond the usual permissions.
    public var requirement: String? {
        switch self {
        case .dictation: return "Works with Apple's dictation; a Sarvam API key makes it better"
        case .clicky: return "Uses your Claude subscription or any API key"
        case .theo: return nil
        }
    }

    /// The Settings › Devices features that belong to this product, so turning the product off turns them off here too.
    public var deviceFeatures: [DeviceFeature] {
        switch self {
        case .dictation: return [.dictation]
        case .clicky: return [.clicky, .voice]
        case .theo: return [.routines]
        }
    }

    /// The product a device feature belongs to. Bots stay out: Clicky's own helpers are bots and keep working for it.
    public static func owning(_ feature: DeviceFeature) -> TheoProduct? {
        allCases.first { $0.deviceFeatures.contains(feature) }
    }
}

public enum TheoProductChoice {
    /// A product with no saved choice is on only for a setup finished before the choice existed, so an update leaves
    /// an existing Mac as it was. A new user starts with nothing on and picks.
    public static func isOn(stored: Bool?, setupCompleted: Bool) -> Bool {
        stored ?? setupCompleted
    }

    /// Setup can only be finished with at least one product on.
    public static func canFinish(_ products: Set<TheoProduct>) -> Bool { !products.isEmpty }
}

/// Whether dictation can run now, and on what. Without a Sarvam key it still works, on Apple's dictation.
public enum DictationAccess: Equatable, Sendable {
    /// `appleOnly`: on, with no Sarvam key, so Apple's recognizer on this Mac does the listening. `ready`: on, with Sarvam.
    case off, appleOnly, ready

    public static func of(productOn: Bool, hasSarvamKey: Bool) -> DictationAccess {
        guard productOn else { return .off }
        return hasSarvamKey ? .ready : .appleOnly
    }

    public var listensForShortcut: Bool { self != .off }

    public var message: String? {
        switch self {
        case .off: return "Dictation is off. Turn it on in Settings \u{203A} Products."
        case .appleOnly, .ready: return nil
        }
    }
}

/// The first-run guide's steps. Which ones show depends on the products picked.
public enum SetupStep: Int, CaseIterable, Sendable {
    case welcome, products, permissions, harnesses, keys, voice, done

    public var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .products: return "Pick products"
        case .permissions: return "Permissions"
        case .harnesses: return "Brain"
        case .keys: return "API keys"
        case .voice: return "Voice"
        case .done: return "Done"
        }
    }

    /// The brain step (an API key first, then coding agents) is for Theo and Clicky; Voice is how Theo and Clicky sound. Dictation needs
    /// neither; its optional Sarvam key is on the keys step. Before anything is picked, every step shows, so the list doesn't jump about.
    public static func shown(for products: Set<TheoProduct>) -> [SetupStep] {
        guard !products.isEmpty else { return allCases }
        let talks = products.contains(.theo) || products.contains(.clicky)
        return allCases.filter { step in
            switch step {
            case .harnesses, .voice: return talks
            default: return true
            }
        }
    }

    /// The step after this one among those shown (nil at the end).
    public static func next(after step: SetupStep, products: Set<TheoProduct>) -> SetupStep? {
        let steps = shown(for: products)
        return steps.first { $0.rawValue > step.rawValue }
    }

    public static func previous(before step: SetupStep, products: Set<TheoProduct>) -> SetupStep? {
        let steps = shown(for: products)
        return steps.last { $0.rawValue < step.rawValue }
    }
}

/// The demos' scripts: what happens when, in seconds from the start of a loop. Kept here so the timing is testable and
/// the views only draw a moment.
public struct ProductDemoClock: Equatable, Sendable {
    public let product: TheoProduct

    public init(_ product: TheoProduct) { self.product = product }

    /// One loop, including a short rest at the end.
    public var loopSeconds: Double {
        switch product {
        case .dictation: return 7.5
        case .clicky: return 8
        case .theo: return 9.5
        }
    }

    /// Where a running clock is within its loop.
    public func moment(elapsed: Double) -> Double {
        guard elapsed.isFinite, elapsed > 0 else { return 0 }
        return elapsed.truncatingRemainder(dividingBy: loopSeconds)
    }

    /// How far (0...1) a stretch from `start` to `end` has got at `time`.
    public static func progress(_ time: Double, from start: Double, to end: Double) -> Double {
        guard end > start else { return time >= end ? 1 : 0 }
        return min(1, max(0, (time - start) / (end - start)))
    }

    /// The first `count` characters of `text` at `progress`, for typing animations.
    public static func typed(_ text: String, progress: Double) -> String {
        let count = Int((Double(text.count) * min(1, max(0, progress))).rounded(.down))
        return String(text.prefix(count))
    }
}
