//
//  SpaceSpeakers.swift
//  ClickyCore
//
//  Who is talking in an X Space, from what the bot's browser shows, the way a person would tell by looking: the speaker's
//  tile has X's speaking indicator (a coloured ring that moves around the avatar while they talk), and their name is
//  written under it. The app captures the browser's window a few times a second while someone talks and reads the text
//  with Apple Vision; this is the part with no capture or Vision in it: finding the ring in the pixels, the name under
//  it, and the name seen most often while those words were said. Nothing on the page is ever clicked or read as a page.
//

import Foundation

/// A captured window, small: 8-bit RGBA, rows from the top.
public struct RGBAFrame: Sendable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}

/// A box on a frame, in 0...1 of its width and height, from the top left.
public struct SpaceBox: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
}

/// A speaking ring found on a frame, and how sure the finder is of it.
public struct SpaceSpeakingRing: Equatable, Sendable {
    public var box: SpaceBox
    public var score: Double
}

/// A line of text Vision read on the frame.
public struct SpaceTextLine: Equatable, Sendable {
    public var text: String
    public var box: SpaceBox

    public init(text: String, box: SpaceBox) {
        self.text = text
        self.box = box
    }
}

public enum SpaceSpeakingIndicator {
    /// How vivid a pixel must be to be part of an indicator: avatars and page chrome are mostly greys and skin tones.
    static let leastSaturation = 0.42
    static let leastBrightness = 0.32
    /// A ring's size, as a share of the frame's width: an avatar on a Space's speaker grid or its docked bar.
    static let smallestRing = 0.02
    static let largestRing = 0.3
    /// Of the ring's bounding box, how much is ring: a ring is hollow, a button or a filled badge isn't.
    static let leastFill = 0.05
    static let mostFill = 0.6
    /// Of the middle of the box (the avatar's face), how much may be vivid.
    static let mostVividInside = 0.22
    /// Of eight slices around the middle, how many the ring must reach (a mic badge can cover part of it).
    static let leastSlicesReached = 6

    /// The speaking rings on `frame`, best first. `previous`: the frame before, the same size, for whether a ring moves
    /// (X's indicator does while someone talks; a static coloured outline scores lower).
    public static func rings(in frame: RGBAFrame, previous: RGBAFrame? = nil) -> [SpaceSpeakingRing] {
        let width = frame.width, height = frame.height
        guard width > 8, height > 8, frame.pixels.count >= width * height * 4 else { return [] }
        var vivid = [Bool](repeating: false, count: width * height)
        var purple = [Bool](repeating: false, count: width * height)
        frame.pixels.withUnsafeBufferPointer { pixels in
            for index in 0..<(width * height) {
                let red = Double(pixels[index * 4]), green = Double(pixels[index * 4 + 1]), blue = Double(pixels[index * 4 + 2])
                let brightest = max(red, green, blue), darkest = min(red, green, blue)
                guard brightest > 0 else { continue }
                let saturation = (brightest - darkest) / brightest
                guard saturation >= leastSaturation, brightest / 255 >= leastBrightness else { continue }
                vivid[index] = true
                purple[index] = isPurpleOrBlue(red: red, green: green, blue: blue)
            }
        }
        var found: [SpaceSpeakingRing] = []
        for component in components(of: vivid, width: width, height: height) {
            guard let ring = ringScore(component, vivid: vivid, purple: purple, frame: frame, previous: previous) else { continue }
            found.append(ring)
        }
        return withoutNested(found).sorted { $0.score > $1.score }
    }

    /// X's speaking colour is a violet; blue covers its lighter themes. Hue between about 200° and 300°.
    static func isPurpleOrBlue(red: Double, green: Double, blue: Double) -> Bool {
        let brightest = max(red, green, blue), darkest = min(red, green, blue)
        let range = brightest - darkest
        guard range > 0 else { return false }
        var hue: Double
        if brightest == red {
            hue = 60 * ((green - blue) / range).truncatingRemainder(dividingBy: 6)
        } else if brightest == green {
            hue = 60 * ((blue - red) / range + 2)
        } else {
            hue = 60 * ((red - green) / range + 4)
        }
        if hue < 0 { hue += 360 }
        return hue >= 200 && hue <= 300
    }

    struct Component {
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        var count = 0
        var purpleCount = 0
        var members: [Int] = []
    }

    /// Connected runs of vivid pixels (four neighbours).
    static func components(of mask: [Bool], width: Int, height: Int) -> [Component] {
        var seen = [Bool](repeating: false, count: mask.count)
        var result: [Component] = []
        var stack: [Int] = []
        for start in 0..<mask.count where mask[start] && !seen[start] {
            var component = Component()
            seen[start] = true
            stack.append(start)
            while let index = stack.popLast() {
                let x = index % width, y = index / width
                component.count += 1
                component.members.append(index)
                component.minX = min(component.minX, x); component.maxX = max(component.maxX, x)
                component.minY = min(component.minY, y); component.maxY = max(component.maxY, y)
                if x > 0, mask[index - 1], !seen[index - 1] { seen[index - 1] = true; stack.append(index - 1) }
                if x < width - 1, mask[index + 1], !seen[index + 1] { seen[index + 1] = true; stack.append(index + 1) }
                if y > 0, mask[index - width], !seen[index - width] { seen[index - width] = true; stack.append(index - width) }
                if y < height - 1, mask[index + width], !seen[index + width] { seen[index + width] = true; stack.append(index + width) }
            }
            if component.count >= 24 { result.append(component) }
        }
        return result
    }

    static func ringScore(_ component: Component, vivid: [Bool], purple: [Bool], frame: RGBAFrame, previous: RGBAFrame?) -> SpaceSpeakingRing? {
        let width = frame.width
        let boxWidth = component.maxX - component.minX + 1, boxHeight = component.maxY - component.minY + 1
        let side = Double(max(boxWidth, boxHeight))
        guard side >= Double(width) * smallestRing, side <= Double(width) * largestRing, side >= 10 else { return nil }
        let aspect = Double(boxWidth) / Double(boxHeight)
        guard aspect >= 0.75, aspect <= 1.33 else { return nil }
        let fill = Double(component.count) / Double(boxWidth * boxHeight)
        guard fill >= leastFill, fill <= mostFill else { return nil }
        // Hollow: the middle 40% of the box is the avatar, not the ring.
        let centerX = Double(component.minX + component.maxX) / 2, centerY = Double(component.minY + component.maxY) / 2
        let innerHalfWidth = Double(boxWidth) * 0.2, innerHalfHeight = Double(boxHeight) * 0.2
        var innerVivid = 0, innerTotal = 0
        for y in Int(centerY - innerHalfHeight)...Int(centerY + innerHalfHeight) {
            for x in Int(centerX - innerHalfWidth)...Int(centerX + innerHalfWidth) {
                innerTotal += 1
                if vivid[y * width + x] { innerVivid += 1 }
            }
        }
        guard innerTotal > 0, Double(innerVivid) / Double(innerTotal) <= mostVividInside else { return nil }
        // Round: its pixels sit about as far from the middle all the way around, in most of eight slices.
        var slices = Set<Int>()
        var purpleCount = 0
        var moved = 0
        let radius = side / 2
        var nearTheEdge = 0
        for index in component.members {
            let x = Double(index % width), y = Double(index / width)
            let dx = x - centerX, dy = y - centerY
            let distance = (dx * dx + dy * dy).squareRoot()
            if distance >= radius * 0.6 { nearTheEdge += 1 }
            let angle = atan2(dy, dx) + Double.pi
            slices.insert(min(Int(angle / (2 * Double.pi) * 8), 7))
            if purple[index] { purpleCount += 1 }
            if let previous, previous.width == frame.width, previous.height == frame.height {
                let offset = index * 4
                let change = abs(Int(frame.pixels[offset]) - Int(previous.pixels[offset]))
                    + abs(Int(frame.pixels[offset + 1]) - Int(previous.pixels[offset + 1]))
                    + abs(Int(frame.pixels[offset + 2]) - Int(previous.pixels[offset + 2]))
                if change > 60 { moved += 1 }
            }
        }
        guard slices.count >= leastSlicesReached, Double(nearTheEdge) / Double(component.count) >= 0.75 else { return nil }
        var score = 1.0
        score += 0.6 * Double(purpleCount) / Double(component.count)
        if previous != nil { score += min(Double(moved) / Double(component.count) * 2, 0.8) }
        let box = SpaceBox(x: Double(component.minX) / Double(width), y: Double(component.minY) / Double(frame.height),
                           width: Double(boxWidth) / Double(width), height: Double(boxHeight) / Double(frame.height))
        return SpaceSpeakingRing(box: box, score: score)
    }

    /// A ring found inside another (its inner edge, or a badge's outline in it) is the same speaker: the outer one stays.
    static func withoutNested(_ rings: [SpaceSpeakingRing]) -> [SpaceSpeakingRing] {
        rings.filter { ring in
            !rings.contains { other in
                other != ring && other.box.width >= ring.box.width && other.box.x <= ring.box.midX && other.box.maxX >= ring.box.midX
                    && other.box.y <= ring.box.midY && other.box.maxY >= ring.box.midY && other.box.width > ring.box.width * 1.05
            }
        }
    }
}

public enum SpaceSpeakerLayout {
    /// The name shown with a speaking ring: the nearest line just under it, about centred on it (the speaker grid), or,
    /// failing that, the line just to its right at the same height (a list).
    public static func nameLine(for ring: SpaceSpeakingRing, among lines: [SpaceTextLine]) -> SpaceTextLine? {
        let box = ring.box
        let below = lines.filter { line in
            SpaceSpeakerName.cleaned(line.text) != nil
                && line.box.y >= box.maxY - box.height * 0.25 && line.box.y <= box.maxY + box.height * 1.1
                && line.box.midX >= box.x - box.width * 0.6 && line.box.midX <= box.maxX + box.width * 0.6
        }
        if let nearest = below.min(by: { ($0.box.y, abs($0.box.midX - box.midX)) < ($1.box.y, abs($1.box.midX - box.midX)) }) {
            return nearest
        }
        let beside = lines.filter { line in
            SpaceSpeakerName.cleaned(line.text) != nil
                && line.box.x >= box.maxX - box.width * 0.1 && line.box.x <= box.maxX + box.width * 2.5
                && line.box.midY >= box.y && line.box.midY <= box.maxY
        }
        return beside.min { ($0.box.x, $0.box.y) < ($1.box.x, $1.box.y) }
    }

    /// Every name with a speaking ring on a frame, the bot's own left out. `ownDisplayNames`: what the bot's account is
    /// called on X when that isn't its bot name ("Chotta Tirri"), since a Space shows display names, not handles.
    public static func speakingNames(rings: [SpaceSpeakingRing], lines: [SpaceTextLine], handle: String, botName: String,
                                     ownDisplayNames: [String] = []) -> [String] {
        var names: [String] = []
        for ring in rings {
            guard let line = nameLine(for: ring, among: lines), let name = SpaceSpeakerName.cleaned(line.text) else { continue }
            if SpaceSpeakerName.isTheBot(name, handle: handle, botName: botName) { continue }
            if ownDisplayNames.contains(where: { SpaceSpeakerName.isTheBot(name, handle: "", botName: $0) }) { continue }
            if !names.contains(name) { names.append(name) }
        }
        return names
    }
}

public enum SpaceSpeakerName {
    /// What a Space writes under or beside a name: roles and states, not names.
    static let notNames: Set<String> = ["host", "cohost", "co-host", "speaker", "speakers", "listener", "listeners", "listening",
                                        "speaking", "muted", "you", "admin", "requested", "request", "join", "leave", "follow",
                                        "following", "verified", "space", "spaces", "live"]
    /// A display name on X can be 50 characters; one this long is plenty to tell people apart, and keeps a name someone
    /// wrote to steer the bot from saying much.
    public static let longestName = 32

    /// A line Vision read with a speaker's tile, as a name: the role words ("Host", "Speaker") and anything that isn't
    /// part of a name taken off, an @handle without its @. Nil when nothing of a name is left.
    public static func cleaned(_ text: String) -> String? {
        guard let firstLine = text.split(whereSeparator: \.isNewline).first else { return nil }
        var kept = ""
        for character in firstLine {
            // Everything else (an @, emoji, a "·" between name and role, brackets someone put in their name) splits words.
            let isPartOfAName = character.isLetter || character.isNumber || character == "." || character == "'" || character == "-" || character == "_"
            kept.append(isPartOfAName ? character : " ")
        }
        var words = kept.split(separator: " ").map(String.init)
        while let last = words.last, notNames.contains(last.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))) { words.removeLast() }
        while let first = words.first, notNames.contains(first.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))) { words.removeFirst() }
        let name = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " .-_'"))
        guard name.count >= 2, name.contains(where: \.isLetter) else { return nil }
        return String(name.prefix(longestName)).trimmingCharacters(in: .whitespaces)
    }

    /// The bot's own tile: its handle, or its display name with the bot's name in it ("Vello (AI)").
    public static func isTheBot(_ name: String, handle: String, botName: String) -> Bool {
        let plainName = plain(name)
        guard !plainName.isEmpty else { return false }
        let plainHandle = plain(XHandle.normalized(handle))
        if !plainHandle.isEmpty, plainName == plainHandle || plainName.hasPrefix(plainHandle) { return true }
        let plainBot = plain(botName)
        if !plainBot.isEmpty, plainName == plainBot { return true }
        let words = name.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return !plainBot.isEmpty && words.contains(plainBot)
    }

    /// Whether two plain names are one name read two ways: one letter apart as text reading slips ("rhul" and "rahul"),
    /// two in a long name. Short names stay apart ("rahul" and "rohan" are two people).
    static func isMisreading(_ first: String, of second: String) -> Bool {
        guard first != second, min(first.count, second.count) >= 4 else { return false }
        return editDistance(first, second) <= (min(first.count, second.count) >= 8 ? 2 : 1)
    }

    static func editDistance(_ first: String, _ second: String) -> Int {
        let a = Array(first), b = Array(second)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + [Int](repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }

    /// Letters and digits only, lower case: "Priya K." and "priya k" are the same person to a vote.
    static func plain(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }
}

/// The names seen speaking, frame by frame, and the one seen most while a stretch of words was said.
public struct SpaceSpeakerVotes: Sendable {
    struct Vote: Sendable {
        var time: Date
        var names: [String]
    }

    private var votes: [Vote] = []
    /// Words count back this far at most: older frames belong to something said before.
    public static let longestStretchSeconds = 25.0
    /// The ears hand words over a little after they're said, and the ring can lag the voice: frames this long before the
    /// start still count.
    public static let leadSeconds = 0.6

    public init() {}

    public var isEmpty: Bool { votes.isEmpty }

    /// One frame's names (already cleaned and without the bot), or none when no ring was found.
    public mutating func record(names: [String], at time: Date) {
        votes.append(Vote(time: time, names: names))
        votes.removeAll { time.timeIntervalSince($0.time) > Self.longestStretchSeconds * 2 }
    }

    /// The name seen in the most frames between `start` and `end`; a tie goes to the one seen last. Nil: no name in
    /// any frame then ("Someone").
    public func speaker(from start: Date, to end: Date) -> String? {
        let from = max(start.addingTimeInterval(-Self.leadSeconds), end.addingTimeInterval(-Self.longestStretchSeconds))
        var counts: [String: (count: Int, last: Date, spellings: [String: Int])] = [:]
        for vote in votes where vote.time >= from && vote.time <= end {
            for name in vote.names {
                var key = SpaceSpeakerName.plain(name)
                guard !key.isEmpty else { continue }
                // A misread of a name already counted is the same person ("Prly" for "Priya", "Rhul" for "Rahul").
                if counts[key] == nil, let near = counts.keys.first(where: { SpaceSpeakerName.isMisreading(key, of: $0) }) { key = near }
                var entry = counts[key] ?? (0, vote.time, [:])
                entry.count += 1
                entry.last = max(entry.last, vote.time)
                entry.spellings[name, default: 0] += 1
                counts[key] = entry
            }
        }
        guard let best = counts.max(by: { ($0.value.count, $0.value.last) < ($1.value.count, $1.value.last) }) else { return nil }
        // The spelling read most often ("Priya" over a misread "Priva").
        return best.value.spellings.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
    }

    /// Who's talking now, for the call window: the name seen most in the last couple of seconds.
    public func current(at now: Date) -> String? {
        speaker(from: now.addingTimeInterval(-2 + Self.leadSeconds), to: now)
    }

    /// The label for a line: the name, or "Someone".
    public static func label(_ name: String?) -> String { name ?? "Someone" }
}
