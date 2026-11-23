//
//  Fingerspelling.swift
//  ClickyCore
//
//  Spell to text: the camera's hand joints become letters (finger-spelling), letters become words, and the
//  words go to Vello, Pointer Assistant or the app in front. Pure, like HandSigns.swift: joints come in as
//  numbers, so every rule here is tested without a camera.
//
//  Three parts:
//  - HandShapeMeasure: 16 numbers that describe one hand's shape the same way whether it's a left or a right
//    hand, near or far, so a shape can be compared with a stored one.
//  - ASLFingerspelling: the 24 still letters of the American manual alphabet (J and Z move, so they aren't
//    here), written as those 16 numbers, read by the nearest shape. Checked against real photos of hands
//    (docs/SIGN-LANGUAGE.md has the numbers): about 87% of letters right on a person it was not tuned on.
//  - TaughtSignBook: signs the owner teaches by showing them a few times, one hand or two, any letter or word.
//    Indian Sign Language spells most letters with two hands; nothing built in reads those yet, so ISL is
//    taught.
//
//  FingerspellingSession turns each frame's reading into events: a letter held still counts once, the hand
//  leaving the picture ends a word, an open hand with the fingers spread (the "5" shape) held a second sends,
//  thumbs down deletes the last letter.
//

import Foundation

// MARK: - Measuring a hand's shape

public enum HandShapeMeasure {
    /// What each of the 16 numbers is, in palm lengths (wrist to the middle finger's knuckle). "Thumb side" is
    /// across the palm toward the thumb; "up" is from the wrist toward the fingers.
    public static let measureNames = [
        "index reach", "middle reach", "ring reach", "little reach",
        "thumb tip toward the thumb side", "thumb tip up the hand",
        "thumb tip to index tip", "thumb tip to middle tip",
        "index tip to middle tip", "index tip beside middle tip",
        "hand tilt sideways", "hand tilt upright",
        "index straightness", "middle straightness", "ring straightness", "little straightness"
    ]

    /// How much each number normally varies from hand to hand, so each counts about the same in a comparison.
    public static let usualSpread: [Double] = [0.73, 0.96, 0.83, 0.60, 0.82, 0.61, 0.48, 0.54, 0.45, 0.29, 0.39, 0.20, 0.31, 0.31, 0.27, 0.27]

    private static let fingerJoints: [[HandJoint]] = [
        [.indexMCP, .indexPIP, .indexDIP, .indexTip],
        [.middleMCP, .middlePIP, .middleDIP, .middleTip],
        [.ringMCP, .ringPIP, .ringDIP, .ringTip],
        [.littleMCP, .littlePIP, .littleDIP, .littleTip]
    ]

    /// Most joints that may be hidden and filled in. Some letters hide joints on purpose (M and N tuck the thumb
    /// under the fingers), and Vision leaves out what it can't see.
    public static let mostFilledInJoints = 3

    /// Puts back a few hidden joints from the ones beside them on the same finger: a hidden tip carries on the
    /// finger's last bone, a hidden middle joint goes halfway between its neighbours. Nil when the wrist or a
    /// knuckle the palm is measured from is missing, or too much is hidden.
    public static func fillingInHiddenJoints(_ pose: HandPose) -> HandPose? {
        let frameJoints: [HandJoint] = [.wrist, .indexMCP, .middleMCP, .littleMCP]
        guard frameJoints.allSatisfy({ pose[$0] != nil }) else { return nil }
        let missingCount = HandJoint.allCases.filter { pose[$0] == nil }.count
        if missingCount == 0 { return pose }
        guard missingCount <= mostFilledInJoints else { return nil }
        var joints = pose.joints
        let chains: [[HandJoint]] = [[.thumbCMC, .thumbMP, .thumbIP, .thumbTip]] + fingerJoints
        func midpoint(_ first: HandPoint, _ second: HandPoint) -> HandPoint { HandPoint(x: (first.x + second.x) / 2, y: (first.y + second.y) / 2) }
        for chain in chains {
            // The base of the thumb, if hidden, sits between the wrist and the index knuckle.
            if joints[chain[0]] == nil, let wrist = joints[.wrist], let indexKnuckle = joints[.indexMCP] { joints[chain[0]] = midpoint(wrist, indexKnuckle) }
            // Middle joints between two seen ones, then a hidden tip from the last bone.
            for position in 1..<3 where joints[chain[position]] == nil {
                if let before = joints[chain[position - 1]], let after = joints[chain[position + 1]] { joints[chain[position]] = midpoint(before, after) }
            }
            if joints[chain[3]] == nil, let endJoint = joints[chain[2]], let middleJoint = joints[chain[1]] {
                joints[chain[3]] = HandPoint(x: endJoint.x + (endJoint.x - middleJoint.x) * 0.8, y: endJoint.y + (endJoint.y - middleJoint.y) * 0.8)
            }
            for position in 1..<3 where joints[chain[position]] == nil {
                if let before = joints[chain[position - 1]], let tip = joints[chain[3]] { joints[chain[position]] = midpoint(before, tip) }
            }
        }
        guard HandJoint.allCases.allSatisfy({ joints[$0] != nil }) else { return nil }
        return HandPose(joints: joints)
    }

    /// The 16 numbers, or nil when the hand can't be read: too much of it hidden, or too small.
    public static func measure(_ seenPose: HandPose) -> [Double]? {
        guard let pose = fillingInHiddenJoints(seenPose) else { return nil }
        guard let wrist = pose[.wrist], let middleKnuckle = pose[.middleMCP], let indexKnuckle = pose[.indexMCP], let littleKnuckle = pose[.littleMCP] else { return nil }
        let palmLength = wrist.distance(to: middleKnuckle)
        guard palmLength > 0.000_1 else { return nil }

        // The palm's own directions: up from the wrist to the middle knuckle, and across (up turned a quarter left).
        let upX = (middleKnuckle.x - wrist.x) / palmLength
        let upY = (middleKnuckle.y - wrist.y) / palmLength
        let acrossX = -upY
        let acrossY = upX
        // A right hand with its palm to an unmirrored camera has the index knuckle on the left of the little
        // knuckle, seen from the wrist: that turn is negative. A left hand, or a mirrored picture, turns the
        // other way, and is flipped so it reads as the same shape.
        let indexFromWristX = indexKnuckle.x - wrist.x, indexFromWristY = indexKnuckle.y - wrist.y
        let littleFromWristX = littleKnuckle.x - wrist.x, littleFromWristY = littleKnuckle.y - wrist.y
        let isFlipped = indexFromWristX * littleFromWristY - indexFromWristY * littleFromWristX > 0

        /// A joint in palm lengths: (toward the thumb side, up the hand).
        func inPalm(_ joint: HandJoint) -> HandPoint {
            let point = pose[joint]!
            let fromWristX = point.x - wrist.x, fromWristY = point.y - wrist.y
            let towardThumbSide = (fromWristX * acrossX + fromWristY * acrossY) / palmLength
            let upTheHand = (fromWristX * upX + fromWristY * upY) / palmLength
            return HandPoint(x: isFlipped ? -towardThumbSide : towardThumbSide, y: upTheHand)
        }

        let palmWrist = HandPoint(x: 0, y: 0)
        var reaches: [Double] = []
        var straightnesses: [Double] = []
        for joints in fingerJoints {
            let knuckle = inPalm(joints[0]), middleJoint = inPalm(joints[1]), endJoint = inPalm(joints[2]), tip = inPalm(joints[3])
            let boneLengths = knuckle.distance(to: middleJoint) + middleJoint.distance(to: endJoint) + endJoint.distance(to: tip)
            straightnesses.append(boneLengths > 0.000_1 ? knuckle.distance(to: tip) / boneLengths : 0)
            // How far the tip is beyond its knuckle, from the wrist: about 1 standing up, below 0 folded into the palm.
            reaches.append(tip.distance(to: palmWrist) - knuckle.distance(to: palmWrist))
        }
        let thumbTip = inPalm(.thumbTip), indexTip = inPalm(.indexTip), middleTip = inPalm(.middleTip)
        // Which way the hand points in the picture: (0, 1) fingers up; sideways is positive toward the little finger's side.
        let tiltSideways = isFlipped ? -upX : upX
        let tiltUpright = upY

        let thumbTipPlace: [Double] = [thumbTip.x, thumbTip.y]
        let tipDistances: [Double] = [thumbTip.distance(to: indexTip), thumbTip.distance(to: middleTip), indexTip.distance(to: middleTip), indexTip.x - middleTip.x]
        let tilt: [Double] = [tiltSideways, tiltUpright]
        return reaches + thumbTipPlace + tipDistances + tilt + straightnesses
    }

    /// Two hands as one list: each hand's 16 numbers (the hand further left in the picture first), then where the
    /// second hand's middle knuckle is from the first's, and how close the hands come, in palm lengths.
    /// `mirrored` reads the same two hands as a mirrored camera would see them, so a two-hand sign taught on one
    /// camera reads on another.
    public static func measure(firstHand: HandPose, secondHand: HandPose, mirrored: Bool = false) -> [Double]? {
        guard let firstWrist = firstHand[.wrist], let secondWrist = secondHand[.wrist] else { return nil }
        let (leftHand, rightHand) = firstWrist.x <= secondWrist.x ? (firstHand, secondHand) : (secondHand, firstHand)
        guard let leftShape = measure(leftHand), let rightShape = measure(rightHand),
              let leftWrist = leftHand[.wrist], let leftKnuckle = leftHand[.middleMCP],
              let rightWrist = rightHand[.wrist], let rightKnuckle = rightHand[.middleMCP] else { return nil }
        let palmLength = (leftWrist.distance(to: leftKnuckle) + rightWrist.distance(to: rightKnuckle)) / 2
        guard palmLength > 0.000_1 else { return nil }
        let apartSideways = (rightKnuckle.x - leftKnuckle.x) / palmLength
        let apartUp = (rightKnuckle.y - leftKnuckle.y) / palmLength
        var closest = Double.greatestFiniteMagnitude
        for leftJoint in leftHand.joints.values {
            for rightJoint in rightHand.joints.values { closest = min(closest, leftJoint.distance(to: rightJoint)) }
        }
        let closestApart = closest / palmLength
        // In a mirror the right hand is now on the left: the hands swap places, and "up" from one to the other turns over.
        if mirrored { return rightShape + leftShape + [apartSideways, -apartUp, closestApart] }
        return leftShape + rightShape + [apartSideways, apartUp, closestApart]
    }

    /// The spread for two-hand lists: each hand's, then the hands' places and how close they come.
    public static let twoHandSpread: [Double] = usualSpread + usualSpread + [1.0, 1.0, 0.3]

    /// How far apart two shapes are, with each number counted against its usual spread. Under about 2.5 for one
    /// hand is "the same shape".
    public static func distance(_ firstShape: [Double], _ secondShape: [Double]) -> Double {
        guard firstShape.count == secondShape.count else { return .greatestFiniteMagnitude }
        let spread = firstShape.count == usualSpread.count ? usualSpread : twoHandSpread
        guard spread.count == firstShape.count else { return .greatestFiniteMagnitude }
        var sum = 0.0
        for index in firstShape.indices {
            let difference = (firstShape[index] - secondShape[index]) / spread[index]
            sum += difference * difference
        }
        return sum.squareRoot()
    }

    /// The most distance a one-hand list may be from a shape and still count as it. Two-hand lists are longer, so
    /// theirs grows with their length.
    public static func mostDistance(forShapeOfLength length: Int) -> Double {
        oneHandMostDistance * (Double(length) / Double(usualSpread.count)).squareRoot()
    }

    /// On real photos, 2.5 let about 9 in 10 letters through, and about 95% of those were right.
    public static let oneHandMostDistance = 2.5
}

// MARK: - What was read

public struct FingerspellingReading: Equatable, Sendable {
    /// A letter ("a"), a taught word ("thank you"), or one of the control labels.
    public var label: String
    /// How far the hand was from that shape (smaller is surer).
    public var distance: Double
    /// True when the owner taught it, false when it's built in.
    public var isTaught: Bool

    public init(label: String, distance: Double, isTaught: Bool) {
        self.label = label
        self.distance = distance
        self.isTaught = isTaught
    }

    /// Open hand, fingers spread (the "5" shape), held: send what's been spelled.
    public static let sendLabel = "⏎send"
    /// Thumbs down, held: delete the last letter.
    public static let deleteLabel = "⌫delete"

    public var isControl: Bool { label == Self.sendLabel || label == Self.deleteLabel }
}

// MARK: - The ASL alphabet

/// Which alphabet the camera reads. ASL has its still letters built in. ISL (Indian Sign Language) spells most
/// letters with two hands, and nothing built in reads those yet, so it reads only what the owner taught.
public enum FingerspellingAlphabet: String, CaseIterable, Codable, Sendable {
    case asl
    case isl

    public var displayName: String {
        switch self {
        case .asl: return "ASL (American)"
        case .isl: return "ISL (Indian)"
        }
    }

    public var detail: String {
        switch self {
        case .asl: return "The 24 still letters are built in (J and Z move, so spell them another way for now). Signs you teach count too."
        case .isl: return "Reads the signs you teach it: show each letter or word a few times, one hand or two. Nothing is built in for ISL yet."
        }
    }
}

public enum ASLFingerspelling {
    /// Each still letter of the American manual alphabet as HandShapeMeasure's 16 numbers, in the same order as
    /// `HandShapeMeasure.measureNames`: four reaches, the thumb tip's place, thumb to index and middle tips, index
    /// to middle tip and which side, the hand's tilt, four straightnesses. A folded finger reaches below 0; a
    /// finger bent flat at the knuckle (M, N) stays straight but reaches little.
    public static let letterShapes: [(letter: String, shape: [Double])] = [
        ("a", [-0.2, -0.4, -0.4, -0.3, 0.4, 1.5, 0.7, 0.9, 0.3, 0.2, -0.2, 1.0, 0.3, 0.4, 0.5, 0.5]),
        ("b", [0.8, 0.9, 0.9, 0.7, 0.1, 0.9, 0.9, 1.1, 0.2, 0.2, -0.2, 1.0, 1.0, 1.0, 1.0, 1.0]),
        ("c", [0.9, 0.9, 0.9, 0.8, 1.1, 1.1, 0.8, 0.9, 0.1, 0.0, -0.6, 0.8, 1.0, 0.9, 0.9, 1.0]),
        ("d", [0.9, 0.4, 0.3, 0.4, 0.7, 1.0, 1.1, 0.2, 1.0, -0.1, -0.1, 1.0, 1.0, 0.8, 0.7, 0.8]),
        ("e", [0.0, -0.1, -0.1, -0.1, -0.1, 0.8, 0.4, 0.3, 0.2, 0.2, -0.2, 1.0, 0.1, 0.1, 0.1, 0.2]),
        ("f", [0.5, 0.8, 0.9, 0.6, 0.8, 1.2, 0.1, 0.6, 0.5, 0.2, 0.1, 1.0, 0.9, 0.9, 0.9, 0.9]),
        ("g", [1.0, -0.4, -0.5, -0.3, 0.5, 1.3, 1.0, 0.8, 1.5, -0.2, 0.6, 0.8, 1.0, 0.4, 0.6, 0.4]),
        ("h", [1.0, 1.1, -0.3, -0.3, -0.1, 1.1, 1.0, 1.1, 0.3, 0.2, 0.6, 0.8, 1.0, 1.0, 0.4, 0.6]),
        ("i", [-0.1, -0.2, -0.3, 0.8, -0.1, 1.1, 0.4, 0.3, 0.2, 0.2, -0.2, 1.0, 0.2, 0.3, 0.3, 1.0]),
        ("k", [1.0, 1.1, -0.2, -0.2, -0.1, 1.3, 1.0, 0.9, 0.7, 0.7, 0.0, 1.0, 1.0, 1.0, 0.3, 0.4]),
        ("l", [0.9, -0.4, -0.4, -0.3, 1.2, 1.2, 1.5, 1.2, 1.4, -0.2, -0.4, 0.9, 1.0, 0.4, 0.5, 0.4]),
        ("m", [0.6, 0.7, 0.6, 0.4, 0.5, -0.1, 0.5, 0.7, 0.4, 0.3, -0.1, 1.0, 1.0, 1.0, 1.0, 1.0]),
        ("n", [0.0, 0.2, -0.2, -0.3, 1.0, -0.2, 0.8, 1.1, 0.4, 0.2, -0.2, 1.0, 1.0, 1.0, 1.0, 0.9]),
        ("o", [0.5, 0.5, 0.4, 0.4, 0.7, 1.2, 0.2, 0.2, 0.1, 0.1, -0.2, 1.0, 0.8, 0.7, 0.7, 0.8]),
        ("p", [1.1, 0.3, 0.2, 0.2, -0.9, 0.9, 1.2, 0.2, 1.1, 0.3, 0.9, 0.5, 1.0, 0.7, 0.7, 0.8]),
        ("q", [0.9, 0.7, 0.3, 0.2, 1.1, 0.7, 0.9, 0.7, 0.3, 0.0, -0.8, 0.5, 1.0, 0.9, 0.7, 0.8]),
        ("r", [0.9, 1.0, -0.2, -0.2, -0.3, 1.0, 0.9, 1.0, 0.1, 0.0, -0.1, 1.0, 1.0, 1.0, 0.3, 0.4]),
        ("s", [-0.1, -0.2, -0.3, -0.2, -0.1, 1.0, 0.4, 0.3, 0.2, 0.2, -0.3, 1.0, 0.2, 0.2, 0.4, 0.4]),
        ("t", [0.4, -0.3, -0.3, -0.2, 0.8, 1.4, 0.7, 1.0, 0.8, 0.0, -0.4, 0.9, 0.9, 0.4, 0.4, 0.3]),
        ("u", [0.9, 1.1, -0.3, -0.3, -0.2, 1.0, 1.0, 1.1, 0.2, 0.2, -0.1, 1.0, 1.0, 1.0, 0.4, 0.5]),
        ("v", [1.0, 1.1, -0.2, -0.2, -0.2, 0.9, 1.3, 1.2, 0.6, 0.6, 0.0, 1.0, 1.0, 1.0, 0.4, 0.5]),
        ("w", [0.9, 1.0, 1.0, -0.2, -0.3, 0.8, 1.3, 1.2, 0.5, 0.5, -0.1, 1.0, 1.0, 1.0, 1.0, 0.4]),
        ("x", [0.6, -0.3, -0.3, -0.3, 0.0, 1.0, 0.7, 0.3, 0.9, 0.1, -0.1, 1.0, 1.0, 0.4, 0.5, 0.4]),
        ("y", [-0.3, -0.4, -0.4, 0.8, 1.1, 1.4, 1.0, 1.3, 0.2, 0.2, 0.0, 1.0, 0.4, 0.4, 0.4, 1.0])
    ]

    /// The "5" hand (all fingers up and spread, thumb out), which isn't a letter: held, it sends.
    public static let sendShape: [Double] = [0.9, 1.0, 0.9, 0.7, 1.0, 0.8, 1.0, 1.3, 0.5, 0.45, 0.0, 1.0, 1.0, 1.0, 1.0, 1.0]

    /// The nearest letter (or the send shape), if the hand is near enough to one.
    public static func read(_ pose: HandPose) -> FingerspellingReading? {
        guard let shape = HandShapeMeasure.measure(pose) else { return nil }
        return read(shape: shape)
    }

    public static func read(shape: [Double]) -> FingerspellingReading? {
        var nearestLabel = ""
        var nearestDistance = Double.greatestFiniteMagnitude
        for (letter, letterShape) in letterShapes {
            let distance = HandShapeMeasure.distance(shape, letterShape)
            if distance < nearestDistance { nearestDistance = distance; nearestLabel = letter }
        }
        let sendDistance = HandShapeMeasure.distance(shape, sendShape)
        if sendDistance < nearestDistance { nearestDistance = sendDistance; nearestLabel = FingerspellingReading.sendLabel }
        guard nearestDistance <= HandShapeMeasure.oneHandMostDistance else { return nil }
        return FingerspellingReading(label: nearestLabel, distance: nearestDistance, isTaught: false)
    }
}

// MARK: - Signs the owner teaches

/// One sign the owner taught: what it means, how many hands, and each time they showed it.
public struct TaughtSign: Codable, Equatable, Sendable {
    public var label: String
    public var handCount: Int
    public var examples: [[Double]]

    public init(label: String, handCount: Int, examples: [[Double]]) {
        self.label = label
        self.handCount = handCount
        self.examples = examples
    }
}

/// The owner's taught signs, read by the nearest example. Kept as JSON in the app's settings.
public struct TaughtSignBook: Codable, Equatable, Sendable {
    public var signs: [TaughtSign]

    public init(signs: [TaughtSign] = []) { self.signs = signs }

    /// Most examples kept for one sign; the oldest go first.
    public static let mostExamplesPerSign = 30
    /// How many times to show a sign when teaching it.
    public static let examplesWhenTeaching = 6

    /// Words as they're stored: trimmed, lower case, so "A" and "a " are the same sign.
    public static func cleanLabel(_ label: String) -> String {
        label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Adds one example of what the hands show now. False when the hands can't be measured.
    @discardableResult
    public mutating func addExample(label: String, hands: [HandPose]) -> Bool {
        let cleanedLabel = Self.cleanLabel(label)
        guard !cleanedLabel.isEmpty, let shape = Self.shape(of: hands) else { return false }
        let handCount = min(hands.count, 2)
        if let index = signs.firstIndex(where: { $0.label == cleanedLabel && $0.handCount == handCount }) {
            signs[index].examples.append(shape)
            if signs[index].examples.count > Self.mostExamplesPerSign {
                signs[index].examples.removeFirst(signs[index].examples.count - Self.mostExamplesPerSign)
            }
        } else {
            signs.append(TaughtSign(label: cleanedLabel, handCount: handCount, examples: [shape]))
        }
        return true
    }

    public mutating func forget(label: String) {
        let cleanedLabel = Self.cleanLabel(label)
        signs.removeAll { $0.label == cleanedLabel }
    }

    /// One hand's 16 numbers, or two hands' 35. A third hand is left out.
    static func shape(of hands: [HandPose]) -> [Double]? {
        if hands.count >= 2 { return HandShapeMeasure.measure(firstHand: hands[0], secondHand: hands[1]) }
        if let onlyHand = hands.first { return HandShapeMeasure.measure(onlyHand) }
        return nil
    }

    /// The nearest taught sign with the same number of hands, if near enough. Two hands are also tried as a
    /// mirrored camera would see them.
    public func read(hands: [HandPose]) -> FingerspellingReading? {
        guard !signs.isEmpty, let shape = Self.shape(of: hands) else { return nil }
        let handCount = min(hands.count, 2)
        var shapesToTry = [shape]
        if handCount == 2, let mirroredShape = HandShapeMeasure.measure(firstHand: hands[0], secondHand: hands[1], mirrored: true) {
            shapesToTry.append(mirroredShape)
        }
        var nearestLabel = ""
        var nearestDistance = Double.greatestFiniteMagnitude
        for sign in signs where sign.handCount == handCount {
            for example in sign.examples {
                for shapeToTry in shapesToTry {
                    let distance = HandShapeMeasure.distance(shapeToTry, example)
                    if distance < nearestDistance { nearestDistance = distance; nearestLabel = sign.label }
                }
            }
        }
        guard nearestDistance <= HandShapeMeasure.mostDistance(forShapeOfLength: shape.count) else { return nil }
        return FingerspellingReading(label: nearestLabel, distance: nearestDistance, isTaught: true)
    }

    public static func decode(_ json: String?) -> TaughtSignBook {
        guard let data = json?.data(using: .utf8), let book = try? JSONDecoder().decode(TaughtSignBook.self, from: data) else { return TaughtSignBook() }
        return book
    }

    public func encode() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self), let json = String(data: data, encoding: .utf8) else { return "{\"signs\":[]}" }
        return json
    }
}

// MARK: - Reading a frame

public enum FingerspellingReader {
    /// What the hands in one frame show: thumbs down is delete; otherwise the nearer of a taught sign and (for ASL)
    /// a built-in letter.
    public static func read(hands: [HandPose], alphabet: FingerspellingAlphabet, taughtSigns: TaughtSignBook) -> FingerspellingReading? {
        guard let firstHand = hands.first else { return nil }
        if hands.count == 1, HandSignClassifier.classify(firstHand) == .thumbsDown {
            return FingerspellingReading(label: FingerspellingReading.deleteLabel, distance: 0, isTaught: false)
        }
        let taughtReading = taughtSigns.read(hands: hands)
        var builtInReading: FingerspellingReading?
        if hands.count == 1 {
            switch alphabet {
            case .asl:
                builtInReading = ASLFingerspelling.read(firstHand)
            case .isl:
                // Only the send shape is built in for ISL.
                if let shape = HandShapeMeasure.measure(firstHand), HandShapeMeasure.distance(shape, ASLFingerspelling.sendShape) <= HandShapeMeasure.oneHandMostDistance {
                    builtInReading = FingerspellingReading(label: FingerspellingReading.sendLabel,
                                                           distance: HandShapeMeasure.distance(shape, ASLFingerspelling.sendShape), isTaught: false)
                }
            }
        }
        switch (taughtReading, builtInReading) {
        case let (taught?, builtIn?): return taught.distance <= builtIn.distance ? taught : builtIn
        case let (taught?, nil): return taught
        case let (nil, builtIn?): return builtIn
        case (nil, nil): return nil
        }
    }
}

// MARK: - From frames to text

/// What a run of frames adds up to.
public enum FingerspellingEvent: Equatable, Sendable {
    case letter(String)
    case wordBreak
    case send
    case deleteLast
}

/// Turns each frame's reading into events. A letter counts once it's held still for `letterHoldSeconds`; the
/// same letter twice needs the hand to let go of it in between (a small bounce is enough). The hand gone for
/// `wordBreakSeconds` ends the word. Send and delete are held longer, so a hand passing through them doesn't fire.
public struct FingerspellingSession: Sendable {
    public static let letterHoldSeconds = 0.5
    public static let sendHoldSeconds = 1.0
    public static let deleteHoldSeconds = 0.8
    public static let wordBreakSeconds = 1.0
    /// Frames Vision misses inside a hold (shorter than this) don't break it.
    public static let bridgedGapSeconds = 0.25
    /// After a label counted, the hand must be off it this long before it can count again.
    public static let releaseSeconds = 0.2

    public private(set) var heldLabel: String?
    public private(set) var heldSince: Double?
    private var lastSeenHeldLabelAt: Double?
    private var countedLabel: String?
    private var countedLabelLastSeenAt: Double?
    private var lastHandSeenAt: Double?
    private var hasLettersSinceWordBreak = false

    public init() {}

    public static func holdSeconds(for label: String) -> Double {
        switch label {
        case FingerspellingReading.sendLabel: return sendHoldSeconds
        case FingerspellingReading.deleteLabel: return deleteHoldSeconds
        default: return letterHoldSeconds
        }
    }

    /// 0 to 1: how far into the hold the current label is, for the panel's ring.
    public func holdProgress(at time: Double) -> Double {
        guard let heldLabel, let heldSince, heldLabel != countedLabel else { return 0 }
        return min(1, max(0, (time - heldSince) / Self.holdSeconds(for: heldLabel)))
    }

    /// One frame. `handIsVisible` false means no hand at all; true with a nil label means a hand that isn't a sign
    /// (moving between letters).
    public mutating func observe(label: String?, handIsVisible: Bool, at time: Double) -> FingerspellingEvent? {
        if handIsVisible { lastHandSeenAt = time }

        // The label that counted stays used while the hand keeps it.
        if let countedLabel {
            if label == countedLabel {
                countedLabelLastSeenAt = time
            } else if let lastSeen = countedLabelLastSeenAt, time - lastSeen >= Self.releaseSeconds {
                self.countedLabel = nil
                countedLabelLastSeenAt = nil
            }
        }

        guard let label else {
            if let lastSeen = lastSeenHeldLabelAt, time - lastSeen > Self.bridgedGapSeconds {
                heldLabel = nil
                heldSince = nil
                lastSeenHeldLabelAt = nil
            }
            // No hand for a while after some letters: the word is done.
            if !handIsVisible, hasLettersSinceWordBreak, let lastHandSeenAt, time - lastHandSeenAt >= Self.wordBreakSeconds {
                hasLettersSinceWordBreak = false
                return .wordBreak
            }
            return nil
        }

        if label != heldLabel {
            heldLabel = label
            heldSince = time
        }
        lastSeenHeldLabelAt = time
        guard label != countedLabel, let heldSince, time - heldSince >= Self.holdSeconds(for: label) else { return nil }
        countedLabel = label
        countedLabelLastSeenAt = time
        switch label {
        case FingerspellingReading.sendLabel:
            hasLettersSinceWordBreak = false
            return .send
        case FingerspellingReading.deleteLabel:
            return .deleteLast
        default:
            hasLettersSinceWordBreak = true
            return .letter(label)
        }
    }

    public mutating func reset() { self = FingerspellingSession() }
}

/// The text being spelled. Letters join into words; a taught word comes in whole, with a space before it.
public struct SpelledText: Equatable, Sendable {
    public private(set) var text = ""

    public init(text: String = "") { self.text = text }

    public mutating func apply(_ event: FingerspellingEvent) {
        switch event {
        case .letter(let label): add(label)
        case .wordBreak: endWord()
        case .deleteLast: deleteLast()
        case .send: break
        }
    }

    public mutating func add(_ label: String) {
        if label.count == 1 {
            text += label
        } else {
            // A taught word or phrase: on its own, with spaces around it.
            if !text.isEmpty && !text.hasSuffix(" ") { text += " " }
            text += label + " "
        }
    }

    public mutating func endWord() {
        if !text.isEmpty && !text.hasSuffix(" ") { text += " " }
    }

    public mutating func deleteLast() {
        // A trailing space goes with the letter before it, so one delete undoes one letter.
        while text.hasSuffix(" ") { text.removeLast() }
        if !text.isEmpty { text.removeLast() }
    }

    public mutating func clear() { text = "" }

    /// What gets sent: trimmed, with runs of spaces made one.
    public var textToSend: String {
        text.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }
}

// MARK: - Where spelled text goes

public enum SpelledTextDestination: String, CaseIterable, Codable, Sendable {
    /// Vello's own chat, as the owner's message: Vello answers, and can pass it on to Pointer Assistant or a coding agent such as Cursor.
    case vello
    /// Straight to Pointer Assistant, with a look at the screen, as if it had been said.
    case pointerAssistant
    /// Typed into the app in front (Cursor's chat box, a document, a message).
    case frontApp

    public var displayName: String {
        switch self {
        case .vello: return "Vello"
        case .pointerAssistant: return "Pointer Assistant"
        case .frontApp: return "Type in the app in front"
        }
    }

    public var detail: String {
        switch self {
        case .vello: return "Goes to Vello's chat as your message. Vello answers, and passes it on to Pointer Assistant or Cursor when you ask it to."
        case .pointerAssistant: return "Pointer Assistant takes it as a question about your screen and answers out loud."
        case .frontApp: return "Typed where the cursor is, such as Cursor's chat box."
        }
    }
}

/// What Vello is told around the spelled words, so it knows they came from the camera and may have a wrong letter.
public enum SpelledTextMessage {
    public static func forVello(_ spelledText: String) -> String {
        "\(spelledText)\n\n(Finger-spelled to the camera, so a letter may be wrong: read it as the closest sensible words.)"
    }
}
