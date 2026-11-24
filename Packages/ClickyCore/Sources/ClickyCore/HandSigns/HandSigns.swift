//
//  HandSigns.swift
//  ClickyCore
//
//  Hand signs: the camera sees a hand (Apple Vision's hand pose, on this Mac), and a held sign
//  either drives Pointer Assistant (open palm: listen, fist: stop, thumbs up / down: yes / no to the
//  step waiting) or, in "Speak for me", is said out loud as its phrase for someone who signs.
//
//  Everything here is pure: the joints come in as numbers, so the rules are tested without a camera.
//  The app's side is leanring-buddy/HandSigns/ (camera, Vision, the preview panel, the actions).
//

import Foundation

// MARK: - Joints

/// The 21 joints Vision reports for a hand (`VNHumanHandPoseObservation.JointName`), named the same way.
public enum HandJoint: String, CaseIterable, Sendable {
    case wrist
    case thumbCMC, thumbMP, thumbIP, thumbTip
    case indexMCP, indexPIP, indexDIP, indexTip
    case middleMCP, middlePIP, middleDIP, middleTip
    case ringMCP, ringPIP, ringDIP, ringTip
    case littleMCP, littlePIP, littleDIP, littleTip
}

/// A point in the camera picture, in pixels (or any units where x and y are the same size), y up.
public struct HandPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }

    public func distance(to otherPoint: HandPoint) -> Double {
        ((x - otherPoint.x) * (x - otherPoint.x) + (y - otherPoint.y) * (y - otherPoint.y)).squareRoot()
    }
}

/// One hand as the camera saw it. Joints Vision wasn't sure of are left out.
public struct HandPose: Equatable, Sendable {
    public var joints: [HandJoint: HandPoint]
    public init(joints: [HandJoint: HandPoint]) { self.joints = joints }

    public subscript(joint: HandJoint) -> HandPoint? { joints[joint] }
}

// MARK: - Signs

/// The signs Vello reads. Static hand shapes only: a sign is one held shape, not a movement.
public enum HandSign: String, CaseIterable, Codable, Sendable {
    case openPalm
    case fist
    case thumbsUp
    case thumbsDown
    case pointingUp
    case peace
    case loveYou
    case callMe
    case okay

    /// What the owner sees in Settings and on the camera panel.
    public var displayName: String {
        switch self {
        case .openPalm: return "Open palm"
        case .fist: return "Fist"
        case .thumbsUp: return "Thumbs up"
        case .thumbsDown: return "Thumbs down"
        case .pointingUp: return "One finger up"
        case .peace: return "Peace (two fingers)"
        case .loveYou: return "I love you (thumb, index, little finger)"
        case .callMe: return "Call me (thumb and little finger)"
        case .okay: return "OK (thumb touches index)"
        }
    }

    public var emoji: String {
        switch self {
        case .openPalm: return "🖐"
        case .fist: return "✊"
        case .thumbsUp: return "👍"
        case .thumbsDown: return "👎"
        case .pointingUp: return "☝️"
        case .peace: return "✌️"
        case .loveYou: return "🤟"
        case .callMe: return "🤙"
        case .okay: return "👌"
        }
    }

    /// The words "Speak for me" says for this sign until the owner writes their own.
    public var defaultPhrase: String {
        switch self {
        case .openPalm: return "Hello!"
        case .fist: return "Please stop."
        case .thumbsUp: return "Yes."
        case .thumbsDown: return "No."
        case .pointingUp: return "Wait, one moment please."
        case .peace: return "Thank you."
        case .loveYou: return "I love you."
        case .callMe: return "Call me later."
        case .okay: return "I'm okay."
        }
    }

    /// How long the sign must be held before it counts. Open palm and fist are longer, since hands
    /// pass through them on their own (waving, resting on the desk).
    public var holdSeconds: Double {
        switch self {
        case .openPalm: return 1.0
        case .fist: return 0.8
        default: return 0.6
        }
    }
}

// MARK: - Reading a shape

/// How one finger is held.
public enum FingerState: String, Sendable {
    case extended
    case curled
    case unclear
}

/// Reads a sign from the joints. Distances are measured against the palm (wrist to the middle
/// finger's knuckle), so a hand near or far from the camera reads the same.
public enum HandSignClassifier {
    /// A straight finger's knuckle-to-tip distance is close to the sum of its bones.
    static let straightFingerRatio = 0.82
    /// The thumb counts as out when its tip is this many palms from the index knuckle…
    static let thumbOutPalms = 0.5
    /// …and it's straight: base to tip at least this share of the sum of its bones.
    static let thumbStraightRatio = 0.85
    /// OK: the thumb and index tips touch, within this many palms.
    static let touchingTipsPalms = 0.32
    /// Thumbs up / down: the thumb points this close to straight up or down (cosine).
    static let thumbVerticalCosine = 0.6

    public struct Reading: Equatable, Sendable {
        public var index: FingerState
        public var middle: FingerState
        public var ring: FingerState
        public var little: FingerState
        public var thumbIsOut: Bool
        /// +1 straight up, -1 straight down, in the camera picture.
        public var thumbVerticalDirection: Double
        public var thumbAndIndexTipsTouch: Bool
    }

    public static func classify(_ pose: HandPose) -> HandSign? {
        guard let reading = read(pose) else { return nil }
        return sign(for: reading)
    }

    public static func sign(for reading: Reading) -> HandSign? {
        let index = reading.index, middle = reading.middle, ring = reading.ring, little = reading.little
        let fourFingersCurled = [index, middle, ring, little].allSatisfy { $0 == .curled }
        let fourFingersExtended = [index, middle, ring, little].allSatisfy { $0 == .extended }

        // OK first: the index is bent round to the thumb, so it reads as neither extended nor curled.
        if reading.thumbAndIndexTipsTouch, middle == .extended, ring == .extended, little == .extended { return .okay }
        // A flat hand counts with the thumb out or held in.
        if fourFingersExtended { return .openPalm }
        if fourFingersCurled {
            if reading.thumbIsOut {
                if reading.thumbVerticalDirection >= thumbVerticalCosine { return .thumbsUp }
                if reading.thumbVerticalDirection <= -thumbVerticalCosine { return .thumbsDown }
                return nil
            }
            return .fist
        }
        if index == .extended, middle == .curled, ring == .curled, little == .extended, reading.thumbIsOut { return .loveYou }
        if index == .curled, middle == .curled, ring == .curled, little == .extended, reading.thumbIsOut { return .callMe }
        if index == .extended, middle == .curled, ring == .curled, little == .curled { return .pointingUp }
        if index == .extended, middle == .extended, ring == .curled, little == .curled { return .peace }
        return nil
    }

    public static func read(_ pose: HandPose) -> Reading? {
        guard let wrist = pose[.wrist], let middleKnuckle = pose[.middleMCP] else { return nil }
        let palmLength = wrist.distance(to: middleKnuckle)
        guard palmLength > 0.000_1 else { return nil }

        func fingerState(_ knuckle: HandJoint, _ middleJoint: HandJoint, _ endJoint: HandJoint, _ tip: HandJoint) -> FingerState {
            guard let knucklePoint = pose[knuckle], let middlePoint = pose[middleJoint], let endPoint = pose[endJoint], let tipPoint = pose[tip] else {
                return .unclear
            }
            let boneLengths = knucklePoint.distance(to: middlePoint) + middlePoint.distance(to: endPoint) + endPoint.distance(to: tipPoint)
            guard boneLengths > 0.000_1 else { return .unclear }
            let straightness = knucklePoint.distance(to: tipPoint) / boneLengths
            let tipFromWrist = tipPoint.distance(to: wrist)
            let middleJointFromWrist = middlePoint.distance(to: wrist)
            // Folded: the tip has come back nearer the wrist than the finger's middle joint.
            if tipFromWrist < middleJointFromWrist { return .curled }
            if straightness >= straightFingerRatio && tipFromWrist > middleJointFromWrist * 1.1 { return .extended }
            // Bent hard but the tip still a little beyond the joint (a loose fist seen side on).
            if straightness < 0.6 { return .curled }
            return .unclear
        }

        let index = fingerState(.indexMCP, .indexPIP, .indexDIP, .indexTip)
        let middle = fingerState(.middleMCP, .middlePIP, .middleDIP, .middleTip)
        let ring = fingerState(.ringMCP, .ringPIP, .ringDIP, .ringTip)
        let little = fingerState(.littleMCP, .littlePIP, .littleDIP, .littleTip)

        // The thumb is out when it's straight (base to tip close to the sum of its bones; tucked into a fist it
        // bends at both joints) and its tip has left the index knuckle.
        var thumbIsOut = false
        var thumbVerticalDirection = 0.0
        if let thumbTip = pose[.thumbTip], let indexKnuckle = pose[.indexMCP] {
            let thumbChain = [pose[.thumbCMC], pose[.thumbMP], pose[.thumbIP], thumbTip].compactMap { $0 }
            if thumbChain.count >= 3, let thumbBase = thumbChain.first {
                var thumbBones = 0.0
                for chainIndex in 1..<thumbChain.count { thumbBones += thumbChain[chainIndex - 1].distance(to: thumbChain[chainIndex]) }
                let thumbIsStraight = thumbBones > 0 && thumbBase.distance(to: thumbTip) / thumbBones >= thumbStraightRatio
                thumbIsOut = thumbIsStraight && thumbTip.distance(to: indexKnuckle) / palmLength >= thumbOutPalms
                // Up or down is read from the thumb's last two bones, the part that shows.
                let thumbPointingFrom = pose[.thumbMP] ?? thumbBase
                let thumbLength = thumbPointingFrom.distance(to: thumbTip)
                if thumbLength > 0 { thumbVerticalDirection = (thumbTip.y - thumbPointingFrom.y) / thumbLength }
            }
        }

        var tipsTouch = false
        if let thumbTip = pose[.thumbTip], let indexTip = pose[.indexTip] {
            tipsTouch = thumbTip.distance(to: indexTip) / palmLength <= touchingTipsPalms
        }

        return Reading(index: index, middle: middle, ring: ring, little: little, thumbIsOut: thumbIsOut,
                       thumbVerticalDirection: thumbVerticalDirection, thumbAndIndexTipsTouch: tipsTouch)
    }
}

// MARK: - Holding a sign

/// Turns a stream of per-frame readings into one event per sign: the sign has to be held for its
/// `holdSeconds`, fires once, and fires again only after the hand let it go (another shape or no hand
/// for `releaseSeconds`). A frame or two with no reading inside a hold doesn't break it.
public struct HandSignHoldTracker: Sendable {
    /// Gaps shorter than this inside a hold (Vision missing a frame) are bridged.
    public static let bridgedGapSeconds = 0.3
    /// After a sign fired, the hand must leave it this long before it can fire again.
    public static let releaseSeconds = 0.4
    /// Nothing fires within this long of the last sign, so one movement can't fire two signs.
    public static let cooldownSeconds = 0.8

    public private(set) var heldSign: HandSign?
    public private(set) var heldSince: Double?
    private var lastSeenHeldSignAt: Double?
    private var firedSign: HandSign?
    private var firedSignLastSeenAt: Double?
    private var lastFiredAt: Double?

    public init() {}

    /// How far into the current hold, 0 to 1, for the panel's ring.
    public func holdProgress(at time: Double) -> Double {
        guard let heldSign, let heldSince, firedSign != heldSign else { return 0 }
        return min(1, max(0, (time - heldSince) / heldSign.holdSeconds))
    }

    /// One frame. Returns the sign when this frame completes its hold.
    public mutating func observe(_ sign: HandSign?, at time: Double) -> HandSign? {
        // The sign that fired stays "used" while the hand keeps it (with short gaps bridged).
        if let firedSign {
            if sign == firedSign {
                firedSignLastSeenAt = time
            } else if let lastSeen = firedSignLastSeenAt, time - lastSeen >= Self.releaseSeconds {
                self.firedSign = nil
                firedSignLastSeenAt = nil
            }
        }

        guard let sign else {
            // No reading: keep the hold through a short gap, else drop it.
            if let lastSeen = lastSeenHeldSignAt, time - lastSeen > Self.bridgedGapSeconds {
                heldSign = nil
                heldSince = nil
                lastSeenHeldSignAt = nil
            }
            return nil
        }

        if sign != heldSign {
            heldSign = sign
            heldSince = time
        }
        lastSeenHeldSignAt = time

        guard sign != firedSign, let heldSince, time - heldSince >= sign.holdSeconds else { return nil }
        if let lastFiredAt, time - lastFiredAt < Self.cooldownSeconds { return nil }
        firedSign = sign
        firedSignLastSeenAt = time
        lastFiredAt = time
        return sign
    }

    public mutating func reset() { self = HandSignHoldTracker() }
}

// MARK: - What a sign does

/// What the signs are for, picked in Settings › Accessibility. Declared in the order Settings and the panel show them:
/// Sign to text first. The raw values are what's saved, so the order can change without losing anyone's choice.
public enum HandSignMode: String, CaseIterable, Codable, Sendable {
    /// Signed words and finger-spelling on the move (ASL or ISL) become a line of text, read by small Core ML models
    /// from the hands, body and face (ClickyCore SignLanguage/, Tools/signs/SPEC.md), sent on to the same places as
    /// Spell to text. The signs below don't act in this mode either.
    case signs
    /// Finger-spelled letters (and taught signs) become text, sent on to Vello, Pointer Assistant or the app in
    /// front. Fingerspelling.swift reads them; the signs below don't act in this mode.
    case spell
    /// Every sign is said out loud as its phrase, for someone who signs.
    case speakForMe
    /// Signs drive Pointer Assistant.
    case control

    /// Shown with the word "Experimental" beside its name: it has only been shown to work for the signers it learned from.
    public var isExperimental: Bool { self == .signs }

    public var displayName: String {
        switch self {
        case .control: return "Control Pointer Assistant"
        case .speakForMe: return "Speak for me"
        case .spell: return "Spell to text"
        case .signs: return "Sign to text"
        }
    }

    /// The short name on the camera panel's buttons.
    public var shortName: String {
        switch self {
        case .control: return "Control"
        case .speakForMe: return "Speak"
        case .spell: return "Spell"
        case .signs: return "Signs"
        }
    }

    public var detail: String {
        switch self {
        case .control: return "Open palm: it listens and talks. Fist: stop. Thumbs up or down: yes or no to what it's asking. One finger up: tell me what's on my screen."
        case .speakForMe: return "Each sign is said out loud as its phrase and shown in big letters, so you can talk to someone with your hands."
        case .spell: return "Finger-spell letters and they become text. Hand out of the picture ends a word, thumbs down deletes a letter, an open hand with the fingers spread sends it."
        case .signs: return "Sign words, or finger-spell a word, and they become a line of text. Rest your hands between signs; the line is sent once they've rested a little longer."
        }
    }
}

public enum HandSignAction: Equatable, Sendable {
    /// Pointer Assistant starts listening (a hands-free session), so the owner can talk to it.
    case startListening
    /// Escape: stop talking, cancel the answer, end the session.
    case stopEverything
    /// Yes or no to the step waiting for a confirmation.
    case answer(yes: Bool)
    /// Ask Pointer Assistant these words as a turn, as if they'd been said.
    case ask(String)
    /// Say these words out loud and show them big.
    case speak(String)
    /// This sign does nothing in this mode.
    case nothing

    /// What the camera panel shows when it fires.
    public var panelLine: String {
        switch self {
        case .startListening: return "Listening. Talk to me."
        case .stopEverything: return "Stopped."
        case .answer(let yes): return yes ? "Yes" : "No"
        case .ask(let words): return words
        case .speak(let words): return words
        case .nothing: return ""
        }
    }
}

extension HandSignMode {
    /// Control and Speak for me work through Pointer Assistant (it listens, answers and speaks the phrases); Spell to
    /// text and Sign to text only write text, so they work whenever hand signs are on.
    public var needsPointerAssistant: Bool {
        switch self {
        case .control, .speakForMe: return true
        case .spell, .signs: return false
        }
    }
}

public enum HandSignActions {
    /// What Pointer Assistant is asked when one finger is held up in Control.
    public static let whatIsOnMyScreen = "What's on my screen right now? Tell me in a sentence or two."

    public static func action(for sign: HandSign, mode: HandSignMode, phrases: [HandSign: String]) -> HandSignAction {
        switch mode {
        case .spell, .signs:
            // Spelling reads letters and Sign to text reads signed words, not these signs (FingerspellingReader,
            // SignLiveReader).
            return .nothing
        case .speakForMe:
            let phrase = HandSignPhrases.phrase(for: sign, in: phrases)
            return phrase.isEmpty ? .nothing : .speak(phrase)
        case .control:
            switch sign {
            case .openPalm: return .startListening
            case .fist: return .stopEverything
            case .thumbsUp: return .answer(yes: true)
            case .thumbsDown: return .answer(yes: false)
            case .pointingUp: return .ask(whatIsOnMyScreen)
            case .peace, .loveYou, .callMe, .okay:
                // The rest still say their phrase, so a signer can talk while Control is on.
                let phrase = HandSignPhrases.phrase(for: sign, in: phrases)
                return phrase.isEmpty ? .nothing : .speak(phrase)
            }
        }
    }
}

/// The owner's own words for each sign, saved as JSON `{"peace": "Thanks a lot"}`. A sign that isn't
/// in it says its default; one saved as empty says nothing.
public enum HandSignPhrases {
    public static func phrase(for sign: HandSign, in phrases: [HandSign: String]) -> String {
        guard let ownPhrase = phrases[sign] else { return sign.defaultPhrase }
        return ownPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func decode(_ json: String?) -> [HandSign: String] {
        guard let data = json?.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        var phrases: [HandSign: String] = [:]
        for (key, value) in raw {
            if let sign = HandSign(rawValue: key) { phrases[sign] = value }
        }
        return phrases
    }

    public static func encode(_ phrases: [HandSign: String]) -> String {
        var raw: [String: String] = [:]
        for (sign, value) in phrases { raw[sign.rawValue] = value }
        guard let data = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }
}
