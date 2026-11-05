//
//  DeviceRouting.swift
//  ClickyCore
//
//  Which Mac does what. Each feature is set to a Mac, or to Any, and this says what that means on the Mac asking.
//

import Foundation

public enum DeviceFeature: String, CaseIterable, Identifiable, Sendable {
    case bots, routines, studioScreens, researchBrowser, clicky, dictation, voice

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .bots: return "Bots & coding"
        case .routines: return "Routines"
        case .studioScreens: return "Studio screens"
        case .researchBrowser: return "Research browser"
        case .clicky: return "Clicky"
        case .dictation: return "Dictation"
        case .voice: return "Voice"
        }
    }

    public var detail: String {
        switch self {
        case .bots: return "Where a bot answers, and where its folders and coding runs are. Chats stay the same on both Macs."
        case .routines: return "The Mac that fires your routines, so each one runs once. Best on a Mac that's always on."
        case .studioScreens: return "The hidden screens. Only a Mac Studio has them."
        case .researchBrowser: return "Where Researcher opens blocked pages in your Chrome."
        case .clicky: return "Seeing your screen, pointing, answering."
        case .dictation: return "Talking into the chat box, and the shortcut in any app."
        case .voice: return "Listening for \u{201C}hey Theo\u{201D}."
        }
    }

    public var defaultChoice: DeviceChoice {
        switch self {
        case .routines, .studioScreens, .researchBrowser: return .macStudio
        case .bots, .clicky, .dictation, .voice: return .any
        }
    }

    /// Work the other Mac can be asked to do. The rest simply doesn't happen here.
    public var canBeSentAcross: Bool { self == .bots || self == .routines || self == .researchBrowser }

    /// What "Any" means for this feature, in the Settings picker.
    public var anyChoiceTitle: String { self == .bots ? "The Mac you're using" : "Any" }
}

public enum DeviceChoice: String, CaseIterable, Identifiable, Sendable {
    case thisMac, macStudio, macBookAir, any

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .thisMac: return "This Mac"
        case .macStudio: return "Mac Studio"
        case .macBookAir: return "MacBook Air"
        case .any: return "Any"
        }
    }
}

public enum DeviceKind: Sendable {
    case macStudio, macBookAir
}

public enum DeviceRoute: Equatable, Sendable {
    case runHere
    /// The other Mac does it, and it's connected.
    case sendAcross
    /// The other Mac does it, and it isn't connected: it goes when it's back.
    case waitForOtherMac
    /// Not on this Mac, and nothing to send.
    case notHere
}

/// Where one bot's turn goes, once its engine is taken into account.
public enum BotTurnRoute: Equatable, Sendable {
    case runHere
    /// The owner set bots to the other Mac, and it's connected.
    case sendAcross
    /// The owner set bots to the other Mac, and it can't be reached. The chat says so at once, it goes when that Mac is back, and it's offered here meanwhile if this Mac can.
    case waitForOtherMac(canRunHere: Bool)
    /// It would run here, but its engine can't, and the other Mac's can: this one turn goes across, and the chat says why.
    case engineOnOtherMac
    /// Its engine can't run here and the other Mac can't help. It tries here, and says what's wrong.
    case tryHere
}

public enum DeviceRouting {
    /// The Mac travels, so nothing here may depend on the other Mac unless the owner set this to that Mac.
    public static func botTurn(choice: DeviceChoice, thisMac: DeviceKind, paired: Bool, otherMacOnline: Bool, engineHere: Bool, engineThere: Bool) -> BotTurnRoute {
        switch route(.bots, choice: choice, thisMac: thisMac, paired: paired, otherMacOnline: otherMacOnline) {
        case .sendAcross: return .sendAcross
        case .waitForOtherMac: return .waitForOtherMac(canRunHere: engineHere)
        case .runHere, .notHere:
            if engineHere { return .runHere }
            return paired && otherMacOnline && engineThere ? .engineOnOtherMac : .tryHere
        }
    }

    /// Said at once in the chat when something can't reach the Mac it's set to.
    public static func unreachableLine(otherMac: String, thisMac: String, engineProblem: String?) -> String {
        let reach = "Your \(otherMac) isn't reachable right now. This starts when it is."
        guard let engineProblem else { return reach }
        return "\(reach) It can't run on this \(thisMac) instead: \(engineProblem)."
    }

    /// A queued message or run this old isn't what the owner wants any more.
    public static let maximumWaitSeconds: TimeInterval = 24 * 60 * 60

    public static func hasWaitedTooLong(since: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(since) > maximumWaitSeconds
    }

    /// `paired` false: there's only this Mac, so it does everything it's able to.
    public static func route(_ feature: DeviceFeature, choice: DeviceChoice, thisMac: DeviceKind, paired: Bool, otherMacOnline: Bool) -> DeviceRoute {
        // Hidden screens exist only on a Mac Studio, whatever the setting says.
        if feature == .studioScreens, thisMac != .macStudio { return .notHere }
        let isHere: Bool
        switch choice {
        // The list of routines is the same on both Macs and each fires once, so "Any" can't mean both.
        case .any where feature == .routines && paired: isHere = thisMac == .macStudio
        case .any, .thisMac: isHere = true
        case .macStudio: isHere = thisMac == .macStudio
        case .macBookAir: isHere = thisMac == .macBookAir
        }
        if isHere || !paired { return .runHere }
        guard feature.canBeSentAcross else { return .notHere }
        return otherMacOnline ? .sendAcross : .waitForOtherMac
    }
}
