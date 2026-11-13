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
        case .studioScreens: return "The hidden screens, on one Mac. Experimental, and off until you turn them on in Settings › Studio."
        case .researchBrowser: return "Where Researcher opens blocked pages in your Chrome."
        case .clicky: return "Seeing your screen, pointing, answering."
        case .dictation: return "Talking into the chat box, and the shortcut in any app."
        case .voice: return "Listening for \u{201C}hey Theo\u{201D}."
        }
    }

    public var defaultChoice: DeviceChoice { .any }

    /// Work the other Mac can be asked to do. The rest simply doesn't happen here.
    public var canBeSentAcross: Bool { self == .bots || self == .routines || self == .researchBrowser }

    /// With two Macs linked, one of them does this for both, so "Any" means the Mac that's always on (`DeviceRouting.alwaysOnMacIsThisOne`).
    public var isDoneByOneMac: Bool { self == .routines || self == .studioScreens || self == .researchBrowser }

    /// What "Any" means for this feature, in the Settings picker.
    public var anyChoiceTitle: String {
        if self == .bots { return "The Mac you're using" }
        return isDoneByOneMac ? "The always-on Mac" : "Any"
    }
}

/// Each Mac keeps its own choices, so these are said from the Mac that holds them.
public enum DeviceChoice: String, CaseIterable, Identifiable, Codable, Sendable {
    case thisMac, otherMac, any

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .thisMac: return "This Mac"
        case .otherMac: return "The other Mac"
        case .any: return "Any"
        }
    }

    /// A saved choice. Builds before this one knew only a Mac Studio and a MacBook Air, and saved "macStudio" or "macBookAir":
    /// on the Mac reading it, that is this Mac or the other one, by what this Mac is. Every Mac that wasn't a Mac Studio counted
    /// as the MacBook Air, so "macBookAir" on any Mac but a Studio is this Mac.
    public static func fromSaved(_ saved: String, thisMacWasMacStudio: Bool) -> DeviceChoice? {
        switch saved {
        case "macStudio": return thisMacWasMacStudio ? .thisMac : .otherMac
        case "macBookAir": return thisMacWasMacStudio ? .otherMac : .thisMac
        default: return DeviceChoice(rawValue: saved)
        }
    }
}

/// One Mac, as the routing rules need to know it.
public struct LinkedMac: Codable, Equatable, Sendable {
    /// The Mac's own id. It doesn't change when the Mac is renamed, and no two Macs share it.
    public var id: String
    /// Its full name, as Theo Link knows it.
    public var name: String
    /// No battery: a Mac Studio, Mac mini, iMac or Mac Pro, the kind that stays on.
    public var isDesktop: Bool
    /// This Mac's own Routines choice, said from its side. Nil when it isn't known (a build from before it was shared).
    public var routinesChoice: DeviceChoice?

    public init(id: String, name: String, isDesktop: Bool, routinesChoice: DeviceChoice? = nil) {
        self.id = id
        self.name = name
        self.isDesktop = isDesktop
        self.routinesChoice = routinesChoice
    }
}

/// This Mac and, when two are linked, the other one.
public struct MacPair: Equatable, Sendable {
    public var thisMac: LinkedMac
    /// The other Mac as last heard from. Nil: there's no other Mac, or nothing has been heard from it yet.
    public var otherMac: LinkedMac?
    public var paired: Bool
    public var otherMacOnline: Bool

    public init(thisMac: LinkedMac, otherMac: LinkedMac?, paired: Bool, otherMacOnline: Bool) {
        self.thisMac = thisMac
        self.otherMac = otherMac
        self.paired = paired
        self.otherMacOnline = otherMacOnline
    }
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
    public static func botTurn(choice: DeviceChoice, pair: MacPair, engineHere: Bool, engineThere: Bool) -> BotTurnRoute {
        switch route(.bots, choice: choice, pair: pair) {
        case .sendAcross: return .sendAcross
        case .waitForOtherMac: return .waitForOtherMac(canRunHere: engineHere)
        case .runHere, .notHere:
            if engineHere { return .runHere }
            return pair.paired && pair.otherMacOnline && engineThere ? .engineOnOtherMac : .tryHere
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

    /// A coding run that waited longer than this for the other Mac doesn't start by itself when that Mac is back: the owner says
    /// Start first. On 5 Nov three runs queued on the Air over a morning all started at once on the Studio, hours later.
    public static let runStartsByItselfSeconds: TimeInterval = 10 * 60

    /// What happens to waiting items when the other Mac is back. Messages go. A run goes only if it's fresh; an older one waits for
    /// the owner. The same run asked for more than once (same title and words) is kept once, the latest.
    public struct WaitingItem: Equatable, Sendable {
        public var id: String
        public var action: String
        public var title: String?
        public var prompt: String?
        public var at: Date
        public init(id: String, action: String, title: String?, prompt: String?, at: Date) {
            self.id = id; self.action = action; self.title = title; self.prompt = prompt; self.at = at
        }
    }

    public struct WaitingPlan: Equatable, Sendable {
        public var send: [String] = []
        public var askFirst: [String] = []
        public var stale: [String] = []
        public var duplicates: [String] = []
    }

    /// "3 hours", "40 minutes": how long something waited, in a chat line.
    public static func waitedText(since: Date, now: Date = Date()) -> String {
        let minutes = max(1, Int(now.timeIntervalSince(since) / 60))
        if minutes < 60 { return minutes == 1 ? "a minute" : "\(minutes) minutes" }
        let hours = minutes / 60
        return hours == 1 ? "an hour" : "\(hours) hours"
    }

    public static func planForReconnect(_ items: [WaitingItem], now: Date = Date()) -> WaitingPlan {
        var plan = WaitingPlan()
        var latestRun: [String: String] = [:]
        for item in items where item.action == "run" {
            let key = "\(item.title ?? "")\u{1F}\(item.prompt ?? "")"
            if let earlier = latestRun[key], let previous = items.first(where: { $0.id == earlier }), previous.at > item.at { continue }
            latestRun[key] = item.id
        }
        let keep = Set(latestRun.values)
        for item in items {
            if item.action == "run", !keep.contains(item.id) { plan.duplicates.append(item.id); continue }
            if hasWaitedTooLong(since: item.at, now: now) { plan.stale.append(item.id); continue }
            if item.action == "run", now.timeIntervalSince(item.at) > runStartsByItselfSeconds { plan.askFirst.append(item.id); continue }
            plan.send.append(item.id)
        }
        return plan
    }

    /// `pair.paired` false: there's only this Mac, so it does everything it's able to.
    public static func route(_ feature: DeviceFeature, choice: DeviceChoice, pair: MacPair) -> DeviceRoute {
        guard pair.paired else { return .runHere }
        let isHere: Bool
        if feature == .routines {
            // The list of routines is the same on both Macs and each fires once, so both Macs have to agree on one of them.
            isHere = routinesFireHere(thisMacChoice: choice, pair: pair)
        } else {
            switch choice {
            case .thisMac: isHere = true
            case .otherMac: isHere = false
            case .any: isHere = feature.isDoneByOneMac ? alwaysOnMacIsThisOne(pair) : true
            }
        }
        if isHere { return .runHere }
        guard feature.canBeSentAcross else { return .notHere }
        return pair.otherMacOnline ? .sendAcross : .waitForOtherMac
    }

    /// Which of two linked Macs fires routines. Each Mac keeps its own Routines choice and tells the other, and both work this out
    /// from the same two choices, so they reach the same answer on their own. Each choice is a vote: "This Mac" for itself, "The other
    /// Mac" for the other one, "Any" for neither. More votes wins; a tie (two Anys, or both naming themselves, or both naming the
    /// other) goes to the Mac that's always on.
    public static func routinesFireHere(thisMacChoice: DeviceChoice, pair: MacPair) -> Bool {
        guard pair.paired else { return true }
        // Nothing heard from the other Mac yet, so its choice isn't known: only a desktop takes them meanwhile.
        guard let otherMac = pair.otherMac else { return pair.thisMac.isDesktop }
        let otherMacChoice = otherMac.routinesChoice ?? .any
        let votesForThisMac = (thisMacChoice == .thisMac ? 1 : 0) + (otherMacChoice == .otherMac ? 1 : 0)
        let votesForOtherMac = (thisMacChoice == .otherMac ? 1 : 0) + (otherMacChoice == .thisMac ? 1 : 0)
        if votesForThisMac != votesForOtherMac { return votesForThisMac > votesForOtherMac }
        return alwaysOnMacIsThisOne(pair)
    }

    /// Of two linked Macs, the one that does what one Mac does for both when nobody picked: a desktop over a laptop, since it's
    /// the one left on, and between two of a kind the smaller id. Both Macs know both ids, so they agree.
    public static func alwaysOnMacIsThisOne(_ pair: MacPair) -> Bool {
        guard pair.paired else { return true }
        guard let otherMac = pair.otherMac else { return pair.thisMac.isDesktop }
        if pair.thisMac.isDesktop != otherMac.isDesktop { return pair.thisMac.isDesktop }
        if pair.thisMac.id != otherMac.id { return pair.thisMac.id < otherMac.id }
        // The same id on both (it shouldn't happen): the names decide, and if those match too, both do it rather than neither.
        return pair.thisMac.name <= otherMac.name
    }
}
