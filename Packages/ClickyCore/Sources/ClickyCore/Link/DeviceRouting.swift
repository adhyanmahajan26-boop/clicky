//
//  DeviceRouting.swift
//  ClickyCore
//
//  Which Mac does what. Each feature is set to a Mac, or to Any, and this says what that means on the Mac asking.
//

import Foundation

public enum DeviceFeature: String, CaseIterable, Identifiable, Sendable {
    case bots, studioScreens, researchBrowser, clicky, dictation, voice

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .bots: return "Bots & routines"
        case .studioScreens: return "Studio screens"
        case .researchBrowser: return "Research browser"
        case .clicky: return "Clicky"
        case .dictation: return "Dictation"
        case .voice: return "Voice"
        }
    }

    public var detail: String {
        switch self {
        case .bots: return "Where bots, coding runs and routines actually run. Other Macs still show them and their chats."
        case .studioScreens: return "The hidden screens. Only a Mac Studio has them."
        case .researchBrowser: return "Where Researcher opens blocked pages in your Chrome."
        case .clicky: return "Seeing your screen, pointing, answering."
        case .dictation: return "Talking into the chat box, and the shortcut in any app."
        case .voice: return "Listening for \u{201C}hey Theo\u{201D}."
        }
    }

    public var defaultChoice: DeviceChoice {
        switch self {
        case .bots, .studioScreens, .researchBrowser: return .macStudio
        case .clicky, .dictation, .voice: return .any
        }
    }

    /// Work the other Mac can be asked to do. The rest simply doesn't happen here.
    public var canBeSentAcross: Bool { self == .bots }
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

public enum DeviceRouting {
    /// `paired` false: there's only this Mac, so it does everything it's able to.
    public static func route(_ feature: DeviceFeature, choice: DeviceChoice, thisMac: DeviceKind, paired: Bool, otherMacOnline: Bool) -> DeviceRoute {
        // Hidden screens exist only on a Mac Studio, whatever the setting says.
        if feature == .studioScreens, thisMac != .macStudio { return .notHere }
        let isHere: Bool
        switch choice {
        case .any, .thisMac: isHere = true
        case .macStudio: isHere = thisMac == .macStudio
        case .macBookAir: isHere = thisMac == .macBookAir
        }
        if isHere || !paired { return .runHere }
        guard feature.canBeSentAcross else { return .notHere }
        return otherMacOnline ? .sendAcross : .waitForOtherMac
    }
}
