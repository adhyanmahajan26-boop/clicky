//
//  PixelLook.swift
//  ClickyCore
//
//  What a Pixel bot wears, and how a saved CrewLook maps onto it. CrewLook and its saved JSON stay as they are, so nobody
//  loses a bot: the mapping happens when the bot is drawn. Three colours change on the way so that no bot ever wears a
//  status colour (mint becomes slate; lime, amber and red trims become cyan, ember and pink).
//

import Foundation

/// The parts of one Pixel face, by the names in pixel-faces.json.
public struct PixelLook: Equatable, Sendable {
    /// One of `PixelLook.finishOrder`.
    public var finish: String
    /// The trim colour as 0xRRGGBB.
    public var trim: UInt32
    /// One of `PixelFaces.eyeStyles`.
    public var eye: String
    /// An antenna (`PixelLook.antennas`) or a hat (`PixelLook.hats`). A hat wins over an antenna.
    public var top: String
    /// One of `PixelLook.extras`.
    public var extra: String

    public init(finish: String, trim: UInt32, eye: String, top: String, extra: String) {
        self.finish = finish
        self.trim = trim
        self.eye = eye
        self.top = top
        self.extra = extra
    }

    public static let finishOrder = ["bone", "graphite", "onyx", "sand", "sky", "lilac", "blush", "slate", "cocoa"]
    public static let antennas = ["none", "ball", "twin", "handle", "dish", "flag", "bolt", "heart", "cursor"]
    public static let hats = ["hardhat", "cap", "beanie", "beret", "tophat", "crown", "headset"]
    public static let extras = ["none", "bowtie", "tie", "scarf", "bezel", "pencil", "star"]
    /// The seven trims, in the order Make your bot shows them.
    public static let trimOrder: [(name: String, hex: UInt32)] = [
        ("ember", 0xFF7A45), ("pink", 0xF06FB0), ("cyan", 0x45C8E6), ("blue", 0x5B8DEF), ("violet", 0x9B7BF0), ("white", 0xF4F4F5), ("peach", 0xF4D7C4),
    ]

    public var hasHat: Bool { Self.hats.contains(top) }
}

extension CrewLook {
    /// The old body names that changed, and mint, which is too close to the working green.
    static let finishForShell: [String: String] = [
        "white": "bone", "black": "onyx", "cream": "sand", "mint": "slate",
    ]

    /// Old screen glows and hat colours, as Pixel trims. Lime, amber and red would read as a status, so they move.
    static let trimForColor: [String: UInt32] = [
        "ff7a45": 0xFF7A45, "ff6f9f": 0xF06FB0, "34d3e6": 0x45C8E6, "60a5fa": 0x5B8DEF, "a78bfa": 0x9B7BF0, "f4f4f5": 0xF4F4F5,
        "a3e635": 0x45C8E6, "f5b03c": 0xFF7A45, "f87171": 0xF06FB0,
    ]

    static let eyeForEyes: [Eyes: String] = [.pill: "tall", .round: "round", .pixel: "block", .visor: "wide", .hearts: "heart"]
    static let extraForExtra: [Extra: String] = [
        .none: "none", .tie: "tie", .bowtie: "bowtie", .scarf: "scarf", .pencil: "pencil", .glasses: "bezel", .badge: "star",
    ]

    /// A colour as a Pixel trim. Known old colours map across; any other colour (a Pixel trim, Clicky's own orange) is kept.
    public static func pixelTrim(_ color: String) -> UInt32 {
        let key = color.lowercased().replacingOccurrences(of: "#", with: "")
        return trimForColor[key] ?? hex(color)
    }

    /// This look as a Pixel face.
    public var pixel: PixelLook {
        let finish = Self.finishForShell[shell] ?? (PixelLook.finishOrder.contains(shell) ? shell : "bone")
        let top = hat != .none ? hat.rawValue : antenna.rawValue
        // The trim is the glow on a bare head and the hat's colour under a hat.
        let trim = Self.pixelTrim(hat != .none ? hatColor : glow)
        return PixelLook(finish: finish, trim: trim, eye: Self.eyeForEyes[eyes] ?? "block", top: top, extra: Self.extraForExtra[extra] ?? "none")
    }
}

/// What is true of a bot right now, from which `PixelStatePriority` picks the one face to show.
public struct PixelStateFacts: Equatable, Sendable {
    public var isOn = true
    /// A run paused on a question, an open call card, the researcher stuck on a human check, or a connector this bot
    /// reached for that needs a sign-in.
    public var isWaitingOnOwner = false
    /// The bot's last run or reply failed and the owner hasn't opened it, retried or given it new work since.
    public var hasUnseenFailure = false
    public var isTyping = false
    /// Theo or Clicky only, while the microphone is open.
    public var isListening = false
    /// A live run, or a reply that has something to show.
    public var isWorking = false
    /// Thinking, or replying with nothing streamed yet.
    public var isThinking = false
    /// The last message is younger than `doneSeconds`, or there's a result the owner hasn't read.
    public var finishedRecently = false
    /// Younger than `dozeSeconds`, or Theo and Clicky when calm.
    public var isAwake = false

    public init(isOn: Bool = true, isWaitingOnOwner: Bool = false, hasUnseenFailure: Bool = false, isTyping: Bool = false,
                isListening: Bool = false, isWorking: Bool = false, isThinking: Bool = false, finishedRecently: Bool = false,
                isAwake: Bool = false) {
        self.isOn = isOn
        self.isWaitingOnOwner = isWaitingOnOwner
        self.hasUnseenFailure = hasUnseenFailure
        self.isTyping = isTyping
        self.isListening = isListening
        self.isWorking = isWorking
        self.isThinking = isThinking
        self.finishedRecently = finishedRecently
        self.isAwake = isAwake
    }
}

/// Which face shows. The first rule that matches wins, in the order of `PixelState.priority`.
public enum PixelStatePriority {
    public static func state(for facts: PixelStateFacts) -> PixelState {
        if !facts.isOn { return .off }
        if facts.isWaitingOnOwner { return .needs }
        if facts.hasUnseenFailure { return .failed }
        if facts.isTyping { return .talking }
        if facts.isListening { return .listening }
        if facts.isWorking { return .working }
        if facts.isThinking { return .thinking }
        if facts.finishedRecently { return .done }
        if facts.isAwake { return .awake }
        return .idle
    }

    /// The most urgent of several states, for a count (the menu bar) or a group.
    public static func mostUrgent(_ states: [PixelState]) -> PixelState? {
        states.min { (PixelState.priority.firstIndex(of: $0) ?? 99) < (PixelState.priority.firstIndex(of: $1) ?? 99) }
    }
}

extension PixelState {
    /// The old poses, for anything that still speaks in them. `needs` is yellow now; only `failed` is red.
    public init(_ pose: CrewPose) {
        switch pose {
        case .sleep: self = .idle
        case .awake: self = .awake
        case .working: self = .working
        case .needs: self = .needs
        case .done: self = .done
        case .talking: self = .talking
        }
    }

    /// Where a bot's row goes in the urgent-first list.
    public enum Lane: Int, CaseIterable, Sendable {
        case needsYou, failed, working, done, quiet

        public var title: String {
            switch self {
            case .needsYou: return "Needs you"
            case .failed: return "Failed"
            case .working: return "Working"
            case .done: return "Done"
            case .quiet: return "Quiet"
            }
        }
    }

    public var lane: Lane {
        switch self {
        case .needs: return .needsYou
        case .failed: return .failed
        case .working, .thinking, .talking, .listening: return .working
        case .done: return .done
        case .awake, .idle, .off: return .quiet
        }
    }
}

/// One bot's last failure, kept until the owner opens its chat, retries, or gives it new work.
public struct BotFailureRecord: Codable, Equatable, Sendable {
    /// Plain words: what went wrong.
    public var reason: String
    public var at: Date
    /// The run step that failed ("Push"), when it was a coding run.
    public var step: String?
    /// The run it came from, so Retry can find it.
    public var runID: String?

    public init(reason: String, at: Date = Date(), step: String? = nil, runID: String? = nil) {
        self.reason = reason
        self.at = at
        self.step = step
        self.runID = runID
    }

    /// The first sentence of the reason, for the status line ("Failed · <this>").
    public var firstSentence: String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
        if let stop = line.range(of: ". ") { return String(line[..<stop.lowerBound]) }
        return line.hasSuffix(".") ? String(line.dropLast()) : line
    }
}

/// Which failures count. A coding agent that is signed out is something the owner does (needs you), not a failure; and a
/// failure that happens in the chat the owner is looking at has been seen.
public enum FailureTriage {
    /// The harness a sign-in error names ("Grok isn't signed in", "Claude Code is signed out"), by id, if that's what it is.
    public static func signInHarness(in reason: String, harnesses: [(id: String, label: String)]) -> String? {
        let lower = reason.lowercased()
        let saysSignIn = ["not signed in", "isn't signed in", "is not signed in", "signed out", "not logged in", "log in", "login", "not authenticated", "authentication required"]
            .contains(where: lower.contains)
        guard saysSignIn else { return nil }
        return harnesses.first { lower.contains($0.label.lowercased()) || lower.contains($0.id.lowercased()) }?.id
    }

    /// Whether a failure turns the bot red until the owner sees it.
    public static func marksUnseen(botID: String, viewing: String?, isWatching: Bool, isSignIn: Bool) -> Bool {
        if isSignIn { return false }
        if isWatching, viewing == botID { return false }
        return true
    }
}
