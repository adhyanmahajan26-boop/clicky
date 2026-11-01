// Prints the text in an image, one JSON line per piece, with its box in image pixels (top left origin).
// Used by theoui.py to find a control by its words, the way a person does.
import AppKit
import Foundation
import Vision

guard CommandLine.arguments.count > 1, let image = NSImage(contentsOfFile: CommandLine.arguments[1]),
      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { exit(1) }
let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = false
try VNImageRequestHandler(cgImage: cgImage).perform([request])
let width = Double(cgImage.width), height = Double(cgImage.height)
for observation in request.results ?? [] {
    guard let text = observation.topCandidates(1).first?.string else { continue }
    let box = observation.boundingBox
    let line: [String: Any] = ["text": text, "x": box.minX * width, "y": (1 - box.maxY) * height, "w": box.width * width, "h": box.height * height]
    if let data = try? JSONSerialization.data(withJSONObject: line) { print(String(decoding: data, as: UTF8.self)) }
}
