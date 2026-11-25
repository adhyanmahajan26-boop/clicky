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
    static func components(of mask: [Bool], width: Int, height: Int, smallest: Int = 24) -> [Component] {
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
            if component.count >= smallest { result.append(component) }
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

/// X's real speaking indicator in a Space (Studio, 25 Nov, docked Space panel in Brave): no ring around the avatar, but a
/// small violet sound-bars icon (three bars, about 5 by 6 to 24 pixels each at 1.5x) to the left of the speaker's role
/// ("ıll Host"), right under their name. A speaker who isn't talking has three violet dots there ("··· Host"), and a muted
/// one a red crossed-out mic, so only tall bars count.
public enum SpaceSpeakingBars {
    /// Where speaking bars are on `frame`, each cluster's box.
    public static func find(in frame: RGBAFrame) -> [SpaceBox] {
        let width = frame.width, height = frame.height
        guard width > 8, height > 8, frame.pixels.count >= width * height * 4 else { return [] }
        var violet = [Bool](repeating: false, count: width * height)
        frame.pixels.withUnsafeBufferPointer { pixels in
            for index in 0..<(width * height) {
                let red = Double(pixels[index * 4]), green = Double(pixels[index * 4 + 1]), blue = Double(pixels[index * 4 + 2])
                let brightest = max(red, green, blue), darkest = min(red, green, blue)
                guard brightest > 0, (brightest - darkest) / brightest >= 0.42, brightest / 255 >= 0.32 else { continue }
                violet[index] = SpaceSpeakingIndicator.isPurpleOrBlue(red: red, green: green, blue: blue)
            }
        }
        // Small violet pieces: a bar or a dot each.
        let pieces = SpaceSpeakingIndicator.components(of: violet, width: width, height: height, smallest: 3).filter { piece in
            let pieceWidth = piece.maxX - piece.minX + 1, pieceHeight = piece.maxY - piece.minY + 1
            return pieceWidth >= 2 && Double(pieceWidth) <= Double(width) * 0.01 && Double(pieceHeight) <= Double(width) * 0.045
        }.sorted { ($0.minX, $0.minY) < ($1.minX, $1.minY) }
        var used = Set<Int>()
        var clusters: [SpaceBox] = []
        for (index, piece) in pieces.enumerated() where !used.contains(index) {
            let pieceWidth = piece.maxX - piece.minX + 1
            // Its neighbours: about as wide, side by side, a bar's width or two apart, sharing a bottom line or a middle.
            var members = [index]
            var right = piece.maxX
            var changed = true
            while changed {
                changed = false
                for (other, candidate) in pieces.enumerated() where !members.contains(other) && !used.contains(other) {
                    let candidateWidth = candidate.maxX - candidate.minX + 1
                    let gap = candidate.minX - right
                    let middle = Double(candidate.minY + candidate.maxY) / 2, pieceMiddle = Double(piece.minY + piece.maxY) / 2
                    if gap >= 1, gap <= pieceWidth * 3, abs(candidateWidth - pieceWidth) <= max(2, pieceWidth / 2),
                       abs(middle - pieceMiddle) <= Double(max(piece.maxY - piece.minY, candidate.maxY - candidate.minY)) + 2 {
                        members.append(other)
                        right = candidate.maxX
                        changed = true
                    }
                }
            }
            guard (2...5).contains(members.count) else { continue }
            let group = members.map { pieces[$0] }
            // Bars, not dots: at least one is clearly taller than it is wide.
            guard group.contains(where: { Double($0.maxY - $0.minY + 1) >= 1.8 * Double($0.maxX - $0.minX + 1) }) else { continue }
            let minX = group.map(\.minX).min()!, maxX = group.map(\.maxX).max()!, minY = group.map(\.minY).min()!, maxY = group.map(\.maxY).max()!
            // The whole icon is taller than a bar is wide: dots smoothed by scaling can make one piece look tall.
            let widths = group.map { $0.maxX - $0.minX + 1 }.sorted()
            guard Double(maxY - minY + 1) >= 1.5 * Double(widths[widths.count / 2]) else { continue }
            members.forEach { used.insert($0) }
            clusters.append(SpaceBox(x: Double(minX) / Double(width), y: Double(minY) / Double(height),
                                     width: Double(maxX - minX + 1) / Double(width), height: Double(maxY - minY + 1) / Double(height)))
        }
        return clusters
    }

    /// Where the speaker's name is: the line just above the bars, over the same tile.
    public static func nameRegion(above bars: SpaceBox, frameAspect: Double) -> SpaceBox {
        // Measured from the icon's width, which stays put, not its height, which moves with the voice: sized by height,
        // the strip was too narrow when the bars were low and cut names to "hee" and "ngji" (Studio, 25 Nov). The tile is
        // about 5 icon-widths either side; the name sits within 3 icon-widths above.
        let iconWidth = max(bars.width, 0.006)
        let halfWidth = iconWidth * 4
        let above = iconWidth * 3 * frameAspect
        let top = max(0, bars.y - above)
        return SpaceBox(x: max(0, bars.midX - halfWidth), y: top, width: min(1, bars.midX + halfWidth) - max(0, bars.midX - halfWidth),
                        height: bars.y - top + bars.height * 0.1)
    }

    /// Where the speaker's role is: the words right of the bars, on the same row ("ıll Host").
    public static func roleRegion(beside bars: SpaceBox) -> SpaceBox {
        let iconWidth = max(bars.width, 0.006)
        let pad = bars.height * 0.6
        return SpaceBox(x: bars.maxX, y: max(0, bars.y - pad), width: min(1 - bars.maxX, iconWidth * 5), height: bars.height + pad * 2)
    }

    /// Whether a line read beside the bars is a Space role, so the violet bars are X's speaking icon and not something
    /// violet on a page behind the docked Space (a feed post, Studio 25 Nov, gave a speaker the name "Post").
    public static func isRole(_ text: String) -> Bool {
        let words = text.lowercased().split { !$0.isLetter && $0 != "-" }.map(String.init)
        let roles: Set<String> = ["host", "co-host", "cohost", "speaker", "होस्ट", "स्पीकर", "को-होस्ट"]
        return words.contains { roles.contains($0) || $0.hasPrefix("co-host") }
    }

    /// The name line for bars: the lowest line above them whose span covers or sits over the bars.
    public static func nameLine(above bars: SpaceBox, among lines: [SpaceTextLine], frameAspect: Double) -> SpaceTextLine? {
        let region = nameRegion(above: bars, frameAspect: frameAspect)
        let candidates = lines.filter { line in
            SpaceSpeakerName.cleaned(line.text) != nil && line.box.maxY <= bars.y + bars.height * 0.3 && line.box.y >= region.y - bars.height
                && line.box.maxX >= region.x && line.box.x <= region.maxX
        }
        // The row right above the bars; on it, the name nearest the tile's middle, which is a little right of the bars
        // (they start the role line under the name). Taking any line on the row named PEW "arfi", the end of the
        // neighbouring "Sam Garfi…" (a public Space, 25 Nov).
        guard let lowest = candidates.map(\.box.maxY).max() else { return nil }
        let tileMiddle = bars.midX + bars.width * 1.5
        return candidates.filter { lowest - $0.box.maxY <= bars.height * 0.8 }.min { abs($0.box.midX - tileMiddle) < abs($1.box.midX - tileMiddle) }
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
        let name = latinized(words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " .-_'")))
        guard name.count >= 2, name.contains(where: \.isLetter) else { return nil }
        return String(name.prefix(longestName)).trimmingCharacters(in: .whitespaces)
    }

    /// Cyrillic and Greek letters that look like Latin ones. Text reading wrote "@KPKPKP9828" as "@КРКРКР9828" (Studio,
    /// 25 Nov): every letter Cyrillic, every one a look-alike.
    static let latinLookAlikes: [Character: Character] = [
        "А": "A", "В": "B", "Е": "E", "К": "K", "М": "M", "Н": "H", "О": "O", "Р": "P", "С": "C", "Т": "T", "Х": "X", "У": "Y",
        "а": "a", "е": "e", "о": "o", "р": "p", "с": "c", "у": "y", "х": "x", "і": "i", "ј": "j", "ѕ": "s", "І": "I", "Ј": "J", "Ѕ": "S",
        "Α": "A", "Β": "B", "Ε": "E", "Ζ": "Z", "Η": "H", "Ι": "I", "Κ": "K", "Μ": "M", "Ν": "N", "Ο": "O", "Ρ": "P", "Τ": "T",
        "Υ": "Y", "Χ": "X", "ο": "o", "ν": "v", "ι": "i", "κ": "k", "α": "a", "τ": "t",
    ]

    /// A name with its Cyrillic and Greek look-alikes written in Latin, when every such letter in it has one. A real
    /// Cyrillic or Greek name ("Иван", "Δήμητρα") has letters with no look-alike and stays as it is.
    public static func latinized(_ name: String) -> String {
        let foreign = name.filter { character in
            character.unicodeScalars.contains { (0x0370...0x03FF).contains($0.value) || (0x0400...0x04FF).contains($0.value) }
        }
        guard !foreign.isEmpty, foreign.allSatisfy({ latinLookAlikes[$0] != nil }) else { return name }
        return String(name.map { latinLookAlikes[$0] ?? $0 })
    }

    /// A name for matching readings of it: Latin look-alikes, lower case, letters and digits only, and the letters text
    /// reading swaps for each other made one ("prlya" and "priya", "rnohan" and "mohan").
    public static func skeleton(_ name: String) -> String {
        var text = plain(latinized(name))
        for (from, to) in [("rn", "m"), ("vv", "w"), ("cl", "d")] { text = text.replacingOccurrences(of: from, with: to) }
        return String(text.map { character -> Character in
            switch character {
            case "l", "1", "|", "!": return "i"
            case "0": return "o"
            default: return character
            }
        })
    }

    /// The bot's own tile: its handle, or its display name with the bot's name in it ("Vello (AI)").
    public static func isTheBot(_ name: String, handle: String, botName: String) -> Bool {
        let plainName = plain(name)
        guard !plainName.isEmpty else { return false }
        // A cut-off piece of its own name ("a Tirri" of "Chotta Tirri").
        let plainBotName = plain(botName)
        if plainName.count >= 4, plainBotName.count > plainName.count, plainBotName.contains(plainName) { return true }
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
        String(latinized(text).lowercased().filter { $0.isLetter || $0.isNumber })
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

    /// A line is labelled with a name only when this many frames showed it...
    public static let leastFramesForAName = 2
    /// ...and it was this share of the frames that showed any name. Otherwise the line says "Someone": a wrong name is
    /// worse than none, since the bot answers people by it.
    public static let leastShareForAName = 0.6

    /// The name for words said between `start` and `end`, only when the frames agree on it (`leastFramesForAName`,
    /// `leastShareForAName`); nil ("Someone") otherwise.
    public func speaker(from start: Date, to end: Date) -> String? {
        let verdict = self.verdict(from: start, to: end)
        guard let name = verdict.name, verdict.frames >= Self.leastFramesForAName, verdict.share >= Self.leastShareForAName else { return nil }
        return name
    }

    /// The name seen in the most frames between `start` and `end` (a tie goes to the one seen last), how many frames
    /// showed it, and what share of the frames with any name that was.
    public func verdict(from start: Date, to end: Date) -> (name: String?, frames: Int, share: Double) {
        let leader = leadingName(from: start, to: end)
        return (leader.name, leader.frames, leader.framesWithAnyName == 0 ? 0 : Double(leader.frames) / Double(leader.framesWithAnyName))
    }

    private func leadingName(from start: Date, to end: Date) -> (name: String?, frames: Int, framesWithAnyName: Int) {
        let from = max(start.addingTimeInterval(-Self.leadSeconds), end.addingTimeInterval(-Self.longestStretchSeconds))
        var counts: [String: (count: Int, last: Date, spellings: [String: Int])] = [:]
        var framesWithAnyName = 0
        for vote in votes where vote.time >= from && vote.time <= end {
            if !vote.names.isEmpty { framesWithAnyName += 1 }
            for name in vote.names {
                var key = SpaceSpeakerName.skeleton(name)
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
        guard let best = counts.max(by: { ($0.value.count, $0.value.last) < ($1.value.count, $1.value.last) }) else { return (nil, 0, framesWithAnyName) }
        // The spelling read most often ("Priya" over a misread "Priva").
        return (best.value.spellings.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key, best.value.count, framesWithAnyName)
    }

    /// Who's talking now, for the call window: the name seen most in the last couple of seconds.
    public func current(at now: Date) -> String? {
        leadingName(from: now.addingTimeInterval(-2 + Self.leadSeconds), to: now).name
    }

    /// The label for a line: the name, or "Someone".
    public static func label(_ name: String?) -> String { name ?? "Someone" }
}

/// Who has been seen speaking in this Space, kept for the whole session, so a misreading in one frame ("Prlya") snaps to
/// the name read right in the others ("Priya"), and the bot knows who is on stage.
public struct SpaceSpeakerRoster: Sendable {
    struct Entry: Sendable {
        var spellings: [String: Int] = [:]
        var sightings = 0
        var firstSeen: Date
    }

    private var entries: [String: Entry] = [:]
    /// Seen this many times before a name counts as on stage: one frame can be a misreading.
    public static let sightingsToBeOnStage = 2

    public init() {}

    /// A reading of a name, recorded, and the name it is: the roster's spelling of the same person when it's close enough
    /// ("Prlya" → "Priya"), else the reading itself.
    public mutating func observe(_ reading: String, at time: Date) -> String {
        let key = matchingKey(for: reading) ?? SpaceSpeakerName.skeleton(reading)
        guard !key.isEmpty else { return reading }
        var entry = entries[key] ?? Entry(firstSeen: time)
        entry.sightings += 1
        entry.spellings[reading, default: 0] += 1
        entries[key] = entry
        return Self.bestSpelling(entry)
    }

    /// The roster's name for a reading, without recording it; nil when it's nobody seen yet.
    public func canonical(_ reading: String) -> String? {
        matchingKey(for: reading).flatMap { entries[$0] }.map(Self.bestSpelling)
    }

    /// Everyone seen speaking at least `sightingsToBeOnStage` times, in the order they first appeared.
    public var onStage: [String] {
        entries.values.filter { $0.sightings >= Self.sightingsToBeOnStage }.sorted { $0.firstSeen < $1.firstSeen }.map(Self.bestSpelling)
    }

    /// The entry a reading belongs to: the same skeleton, else the most-seen entry one letter away (two for long names),
    /// else a longer name it's a cut-off piece of ("hee" of "Sipahee", "ngji" of "Kongji").
    private func matchingKey(for reading: String) -> String? {
        let key = SpaceSpeakerName.skeleton(reading)
        guard !key.isEmpty else { return nil }
        if entries[key] != nil { return key }
        if let near = entries.filter({ SpaceSpeakerName.isMisreading(key, of: $0.key) }).max(by: { $0.value.sightings < $1.value.sightings })?.key {
            return near
        }
        return entries.filter { $0.key.count > key.count && key.count >= 2 && $0.key.contains(key) }.max { $0.value.sightings < $1.value.sightings }?.key
    }

    /// The fullest reading that's common enough to trust: the longest of those read at least a third as often as the
    /// most-read one, so a name read whole now and then wins over a frequent cut-off ("Sipahee" over "hee").
    private static func bestSpelling(_ entry: Entry) -> String {
        let most = entry.spellings.values.max() ?? 0
        return entry.spellings.filter { Double($0.value) >= Double(most) / 3 }
            .max { ($0.key.count, $0.value, $1.key) < ($1.key.count, $1.value, $0.key) }?.key ?? ""
    }
}
