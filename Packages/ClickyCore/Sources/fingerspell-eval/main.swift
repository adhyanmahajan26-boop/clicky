//
//  fingerspell-eval: how well Spell to text reads real hands, with Apple Vision's hand pose (the same as the
//  app's camera) on a folder of photos sorted by letter: <folder>/<letter or word>/<any>.jpg|png.
//
//  swift run fingerspell-eval asl <folder>             the built-in ASL letters
//  swift run fingerspell-eval teach <folder> [N]       teach N photos of each sign (default 5), read the rest
//  swift run fingerspell-eval shapes <folder>          each sign's middle shape (one hand), written as Swift, and
//                                                      how much each measure spreads: how the built-in shapes are made
//  swift run fingerspell-eval ... --dump <file.jsonl>  also write the joints Vision found, one photo a line
//
//  Nothing here ships in the app; the photos stay where they are.
//

import ClickyCore
import CoreGraphics
import Foundation
import ImageIO
import Vision

struct Photo {
    var label: String
    var path: String
    var hands: [HandPose]
}

let visionJointNames: [(VNHumanHandPoseObservation.JointName, HandJoint)] = [
    (.wrist, .wrist),
    (.thumbCMC, .thumbCMC), (.thumbMP, .thumbMP), (.thumbIP, .thumbIP), (.thumbTip, .thumbTip),
    (.indexMCP, .indexMCP), (.indexPIP, .indexPIP), (.indexDIP, .indexDIP), (.indexTip, .indexTip),
    (.middleMCP, .middleMCP), (.middlePIP, .middlePIP), (.middleDIP, .middleDIP), (.middleTip, .middleTip),
    (.ringMCP, .ringMCP), (.ringPIP, .ringPIP), (.ringDIP, .ringDIP), (.ringTip, .ringTip),
    (.littleMCP, .littleMCP), (.littlePIP, .littlePIP), (.littleDIP, .littleDIP), (.littleTip, .littleTip)
]

/// The same rules as HandSignCamera: joints Vision is at least 0.3 sure of, at least 16 of them, in pixels, y up.
func hands(inPhotoAt path: String) -> [HandPose] {
    let url = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return [] }
    let request = VNDetectHumanHandPoseRequest()
    request.maximumHandCount = 2
    let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
    guard (try? handler.perform([request])) != nil, let observations = request.results else { return [] }
    let width = Double(image.width), height = Double(image.height)
    return observations.compactMap { observation in
        guard let points = try? observation.recognizedPoints(.all) else { return nil }
        var joints: [HandJoint: HandPoint] = [:]
        for (visionName, joint) in visionJointNames {
            guard let point = points[visionName], point.confidence >= 0.3 else { continue }
            joints[joint] = HandPoint(x: Double(point.location.x) * width, y: Double(point.location.y) * height)
        }
        return joints.count >= 16 ? HandPose(joints: joints) : nil
    }
}

func loadPhotos(in folder: String) -> [Photo] {
    let fileManager = FileManager.default
    var photos: [Photo] = []
    let labels = ((try? fileManager.contentsOfDirectory(atPath: folder)) ?? []).sorted()
    for label in labels {
        let labelFolder = (folder as NSString).appendingPathComponent(label)
        var isFolder: ObjCBool = false
        guard fileManager.fileExists(atPath: labelFolder, isDirectory: &isFolder), isFolder.boolValue else { continue }
        let files = ((try? fileManager.contentsOfDirectory(atPath: labelFolder)) ?? []).sorted()
        for file in files where ["jpg", "jpeg", "png"].contains((file as NSString).pathExtension.lowercased()) {
            let path = (labelFolder as NSString).appendingPathComponent(file)
            photos.append(Photo(label: TaughtSignBook.cleanLabel(label), path: path, hands: hands(inPhotoAt: path)))
        }
    }
    return photos
}

func percent(_ part: Int, _ whole: Int) -> String {
    whole == 0 ? "-" : String(format: "%.0f%%", Double(part) * 100 / Double(whole))
}

var arguments = Array(CommandLine.arguments.dropFirst())
var dumpPath: String?
if let dumpIndex = arguments.firstIndex(of: "--dump"), dumpIndex + 1 < arguments.count {
    dumpPath = arguments[dumpIndex + 1]
    arguments.removeSubrange(dumpIndex...(dumpIndex + 1))
}
guard arguments.count >= 2, ["asl", "teach", "shapes"].contains(arguments[0]) else {
    print("usage: fingerspell-eval asl <folder> | teach <folder> [examples per sign] | shapes <folder> [--dump joints.jsonl]")
    exit(2)
}
let photos = loadPhotos(in: arguments[1])
let withHands = photos.filter { !$0.hands.isEmpty }
print("photos: \(photos.count), a hand found in \(withHands.count) (\(percent(withHands.count, photos.count))), two hands in \(photos.filter { $0.hands.count >= 2 }.count)")

if let dumpPath {
    var lines: [String] = []
    for photo in photos {
        let handsJSON = photo.hands.map { hand in
            HandJoint.allCases.map { joint in hand[joint].map { [$0.x, $0.y] } ?? [] }
        }
        let record: [String: Any] = ["label": photo.label, "file": (photo.path as NSString).lastPathComponent, "hands": handsJSON]
        if let data = try? JSONSerialization.data(withJSONObject: record), let line = String(data: data, encoding: .utf8) { lines.append(line) }
    }
    try? lines.joined(separator: "\n").write(toFile: dumpPath, atomically: true, encoding: .utf8)
}

var confusions: [String: Int] = [:]
var perLabel: [String: (right: Int, read: Int, seen: Int)] = [:]
var right = 0, read = 0, seen = 0

func score(_ photo: Photo, _ reading: FingerspellingReading?) {
    seen += 1
    var tally = perLabel[photo.label] ?? (0, 0, 0)
    tally.seen += 1
    if let reading {
        read += 1
        tally.read += 1
        if reading.label == photo.label {
            right += 1
            tally.right += 1
        } else {
            confusions["\(photo.label)→\(reading.label)", default: 0] += 1
        }
    }
    perLabel[photo.label] = tally
}

func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return 0 }
    return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
}

if arguments[0] == "shapes" {
    var shapesByLabel: [String: [[Double]]] = [:]
    for photo in withHands { if let shape = HandShapeMeasure.measure(photo.hands[0]) { shapesByLabel[photo.label, default: []].append(shape) } }
    let allShapes = shapesByLabel.values.flatMap { $0 }
    print("measured: \(allShapes.count) of \(withHands.count) photos with a hand")
    for (label, shapes) in shapesByLabel.sorted(by: { $0.key < $1.key }) {
        let middle = (0..<16).map { index in (median(shapes.map { $0[index] }) * 10).rounded() / 10 }
        print("        (\"\(label)\", [" + middle.map { String(format: "%.1f", $0) }.joined(separator: ", ") + "]),  // \(shapes.count) photos")
    }
    let spreads = (0..<16).map { index -> Double in
        let values = allShapes.map { $0[index] }
        let mean = values.reduce(0, +) / Double(max(1, values.count))
        let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(max(1, values.count))
        return (variance.squareRoot() * 100).rounded() / 100
    }
    print("usualSpread: [" + spreads.map { String(format: "%.2f", $0) }.joined(separator: ", ") + "]")
    exit(0)
}

if arguments[0] == "asl" {
    for photo in withHands where photo.label.count == 1 {
        score(photo, FingerspellingReader.read(hands: [photo.hands[0]], alphabet: .asl, taughtSigns: TaughtSignBook()))
    }
} else {
    let examplesPerSign = arguments.count >= 3 ? Int(arguments[2]) ?? 5 : 5
    // Teach the first N photos of each sign (with the same number of hands as most of its photos), read the rest.
    var book = TaughtSignBook()
    var toRead: [Photo] = []
    var taughtCount: [String: Int] = [:]
    // A steady shuffle, so runs can be compared.
    let ordered = withHands.enumerated().sorted { ($0.offset * 7_919) % 1_009 < ($1.offset * 7_919) % 1_009 }.map(\.element)
    for photo in ordered {
        if taughtCount[photo.label, default: 0] < examplesPerSign {
            if book.addExample(label: photo.label, hands: photo.hands) { taughtCount[photo.label, default: 0] += 1 }
        } else {
            toRead.append(photo)
        }
    }
    for photo in toRead {
        score(photo, FingerspellingReader.read(hands: photo.hands, alphabet: .isl, taughtSigns: book))
    }
}

print("read as a sign: \(read) of \(seen) (\(percent(read, seen))); right: \(right) of \(read) read (\(percent(right, read))); right of all with a hand: \(percent(right, seen))")
print("per sign (right / read / photos with a hand):")
for (label, tally) in perLabel.sorted(by: { $0.key < $1.key }) {
    print("  \(label): \(tally.right)/\(tally.read)/\(tally.seen)")
}
print("most mixed up: " + confusions.sorted { $0.value > $1.value }.prefix(15).map { "\($0.key) ×\($0.value)" }.joined(separator: ", "))
