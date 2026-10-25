//
//  WhiteboardPDFInspector.swift
//  ClickyCore
//
//  What's inside an exported board PDF, read with CoreGraphics only (no
//  poppler): pages and their sizes, the text layer (PDFKit), how the content
//  is drawn (text-show and path-paint operators vs image XObjects, with the
//  share of the page the images cover, through q/Q/cm and nested forms), and
//  every font with whether its glyphs are embedded (FontFile/2/3, or a Type3
//  font, whose glyphs are procedures in the file). Used by the PDF export
//  tests and `cwb-check --pdf <file>` (Tools/eval/pdf_check.sh).
//

import CoreGraphics
import Foundation
import PDFKit

public struct WhiteboardPDFReport: Sendable, Equatable {
    public struct Page: Sendable, Equatable {
        public var size: CGSize
        public var text: String
        public var textShowOperatorCount = 0
        public var pathPaintOperatorCount = 0
        public var imageDrawCount = 0
        /// Image XObjects / inline images drawn, as a share of the page area (0…1+).
        public var imageCoverage: CGFloat = 0
        /// Pixel size of the largest image drawn.
        public var largestImagePixels = 0
    }

    public struct Font: Sendable, Equatable, Hashable {
        public var name: String
        public var subtype: String
        public var isEmbedded: Bool
    }

    public var pages: [Page]
    public var fonts: [Font]

    public var pageCount: Int { pages.count }
    public var text: String { pages.map(\.text).joined(separator: "\n") }
    public var allFontsEmbedded: Bool { fonts.allSatisfy(\.isEmbedded) }

    /// Vector: every page draws text and paths, and images cover under a quarter of it
    /// (SF Symbols / small pictures are fine; one big bitmap of the board is not).
    public var isVector: Bool {
        pages.allSatisfy { $0.textShowOperatorCount > 0 && $0.pathPaintOperatorCount > 0 && $0.imageCoverage < 0.25 }
    }

    public var summary: String {
        let sizes = pages.map { "\(Int($0.size.width.rounded()))x\(Int($0.size.height.rounded()))" }.joined(separator: ",")
        let textOps = pages.map(\.textShowOperatorCount).reduce(0, +)
        let paintOps = pages.map(\.pathPaintOperatorCount).reduce(0, +)
        let images = pages.map(\.imageDrawCount).reduce(0, +)
        let coverage = pages.map(\.imageCoverage).max() ?? 0
        let notEmbedded = fonts.filter { !$0.isEmbedded }.map(\.name)
        return "pages=\(pageCount) sizes=\(sizes) textOps=\(textOps) paintOps=\(paintOps) images=\(images) " +
            "maxImageCoverage=\(String(format: "%.3f", Double(coverage))) fonts=\(fonts.count) notEmbedded=\(notEmbedded)"
    }
}

public enum WhiteboardPDFInspector {
    public static func inspect(url: URL) -> WhiteboardPDFReport? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return inspect(data: data)
    }

    public static func inspect(data: Data) -> WhiteboardPDFReport? {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider) else { return nil }
        let textDocument = PDFDocument(data: data)
        var pages: [WhiteboardPDFReport.Page] = []
        var fonts = Set<WhiteboardPDFReport.Font>()
        guard document.numberOfPages > 0 else { return WhiteboardPDFReport(pages: [], fonts: []) }
        for pageNumber in 1...document.numberOfPages {
            guard let page = document.page(at: pageNumber) else { continue }
            let mediaBox = page.getBoxRect(.mediaBox)
            var report = WhiteboardPDFReport.Page(size: mediaBox.size, text: textDocument?.page(at: pageNumber - 1)?.string ?? "")
            let scanState = ScanState()
            if let pageDictionary = page.dictionary {
                var resources: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(pageDictionary, "Resources", &resources), let resources {
                    collectFonts(resources: resources, into: &fonts, depth: 0)
                }
            }
            let contentStream = CGPDFContentStreamCreateWithPage(page)
            scan(contentStream, state: scanState)
            report.textShowOperatorCount = scanState.textShowCount
            report.pathPaintOperatorCount = scanState.paintCount
            report.imageDrawCount = scanState.imageCount
            report.largestImagePixels = scanState.largestImagePixels
            let pageArea = max(1, mediaBox.width * mediaBox.height)
            report.imageCoverage = scanState.imageArea / pageArea
            pages.append(report)
        }
        return WhiteboardPDFReport(pages: pages, fonts: fonts.sorted { $0.name < $1.name })
    }

    // MARK: Content streams

    final class ScanState {
        var textShowCount = 0
        var paintCount = 0
        var imageCount = 0
        var imageArea: CGFloat = 0
        var largestImagePixels = 0
        var ctm = CGAffineTransform.identity
        var ctmStack: [CGAffineTransform] = []
        var streams: [CGPDFContentStreamRef] = []
        var depth = 0
    }

    private static func scan(_ contentStream: CGPDFContentStreamRef, state: ScanState) {
        guard state.depth < 12, let table = CGPDFOperatorTableCreate() else { return }
        for name in ["Tj", "TJ", "'", "\""] {
            CGPDFOperatorTableSetCallback(table, name) { _, info in
                guard let info else { return }
                Unmanaged<ScanState>.fromOpaque(info).takeUnretainedValue().textShowCount += 1
            }
        }
        for name in ["f", "F", "f*", "S", "s", "B", "B*", "b", "b*", "sh"] {
            CGPDFOperatorTableSetCallback(table, name) { _, info in
                guard let info else { return }
                Unmanaged<ScanState>.fromOpaque(info).takeUnretainedValue().paintCount += 1
            }
        }
        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            guard let info else { return }
            let state = Unmanaged<ScanState>.fromOpaque(info).takeUnretainedValue()
            state.ctmStack.append(state.ctm)
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            guard let info else { return }
            let state = Unmanaged<ScanState>.fromOpaque(info).takeUnretainedValue()
            if let restored = state.ctmStack.popLast() { state.ctm = restored }
        }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            guard let info else { return }
            let state = Unmanaged<ScanState>.fromOpaque(info).takeUnretainedValue()
            var values = [CGPDFReal](repeating: 0, count: 6)
            for index in (0..<6).reversed() {
                var value: CGPDFReal = 0
                guard CGPDFScannerPopNumber(scanner, &value) else { return }
                values[index] = value
            }
            let transform = CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5])
            state.ctm = transform.concatenating(state.ctm)
        }
        CGPDFOperatorTableSetCallback(table, "EI") { _, info in
            guard let info else { return }
            let state = Unmanaged<ScanState>.fromOpaque(info).takeUnretainedValue()
            state.imageCount += 1
            state.imageArea += WhiteboardPDFInspector.unitSquareArea(state.ctm)
        }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            guard let info else { return }
            let state = Unmanaged<ScanState>.fromOpaque(info).takeUnretainedValue()
            var namePointer: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &namePointer), let namePointer else { return }
            let contentStream = CGPDFScannerGetContentStream(scanner)
            guard let xObject = CGPDFContentStreamGetResource(contentStream, "XObject", namePointer) else { return }
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(xObject, .stream, &stream), let stream, let dictionary = CGPDFStreamGetDictionary(stream) else { return }
            var subtypePointer: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtypePointer), let subtypePointer else { return }
            let subtype = String(cString: subtypePointer)
            if subtype == "Image" {
                state.imageCount += 1
                state.imageArea += WhiteboardPDFInspector.unitSquareArea(state.ctm)
                var width: CGPDFInteger = 0, height: CGPDFInteger = 0
                CGPDFDictionaryGetInteger(dictionary, "Width", &width)
                CGPDFDictionaryGetInteger(dictionary, "Height", &height)
                state.largestImagePixels = max(state.largestImagePixels, width * height)
            } else if subtype == "Form" {
                var formResources: CGPDFDictionaryRef?
                CGPDFDictionaryGetDictionary(dictionary, "Resources", &formResources)
                let savedCTM = state.ctm
                var matrixArray: CGPDFArrayRef?
                if CGPDFDictionaryGetArray(dictionary, "Matrix", &matrixArray), let matrixArray, CGPDFArrayGetCount(matrixArray) == 6 {
                    var values = [CGPDFReal](repeating: 0, count: 6)
                    for index in 0..<6 { CGPDFArrayGetNumber(matrixArray, index, &values[index]) }
                    state.ctm = CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5]).concatenating(state.ctm)
                }
                let formStream = CGPDFContentStreamCreateWithStream(stream, formResources ?? dictionary, contentStream)
                state.depth += 1
                WhiteboardPDFInspector.scan(formStream, state: state)
                state.depth -= 1
                state.ctm = savedCTM
            }
        }
        let scanner = CGPDFScannerCreate(contentStream, table, Unmanaged.passUnretained(state).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFOperatorTableRelease(table)
    }

    static func unitSquareArea(_ transform: CGAffineTransform) -> CGFloat {
        abs(transform.a * transform.d - transform.b * transform.c)
    }

    // MARK: Fonts

    static func collectFonts(resources: CGPDFDictionaryRef, into fonts: inout Set<WhiteboardPDFReport.Font>, depth: Int) {
        guard depth < 12 else { return }
        var fontDictionary: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(resources, "Font", &fontDictionary), let fontDictionary {
            var found: [WhiteboardPDFReport.Font] = []
            withUnsafeMutablePointer(to: &found) { pointer in
                CGPDFDictionaryApplyBlock(fontDictionary, { _, object, info in
                    guard let info else { return true }
                    var font: CGPDFDictionaryRef?
                    if CGPDFObjectGetValue(object, .dictionary, &font), let font {
                        info.assumingMemoryBound(to: [WhiteboardPDFReport.Font].self).pointee.append(WhiteboardPDFInspector.describeFont(font))
                    }
                    return true
                }, pointer)
            }
            fonts.formUnion(found)
        }
        // Fonts used inside form XObjects (SwiftUI groups content in forms).
        var xObjects: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(resources, "XObject", &xObjects), let xObjects {
            var formResources: [CGPDFDictionaryRef] = []
            withUnsafeMutablePointer(to: &formResources) { pointer in
                CGPDFDictionaryApplyBlock(xObjects, { _, object, info in
                    guard let info else { return true }
                    var stream: CGPDFStreamRef?
                    guard CGPDFObjectGetValue(object, .stream, &stream), let stream, let dictionary = CGPDFStreamGetDictionary(stream) else { return true }
                    var resources: CGPDFDictionaryRef?
                    if CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources {
                        info.assumingMemoryBound(to: [CGPDFDictionaryRef].self).pointee.append(resources)
                    }
                    return true
                }, pointer)
            }
            for nested in formResources { collectFonts(resources: nested, into: &fonts, depth: depth + 1) }
        }
    }

    static func describeFont(_ font: CGPDFDictionaryRef) -> WhiteboardPDFReport.Font {
        func name(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
            var pointer: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dictionary, key, &pointer), let pointer else { return nil }
            return String(cString: pointer)
        }
        let subtype = name(font, "Subtype") ?? "?"
        let baseFont = name(font, "BaseFont") ?? (subtype == "Type3" ? "Type3" : "?")
        if subtype == "Type3" { return .init(name: baseFont, subtype: subtype, isEmbedded: true) }
        var descriptorOwner: CGPDFDictionaryRef? = font
        if subtype == "Type0" {
            var descendants: CGPDFArrayRef?
            var descendant: CGPDFDictionaryRef?
            if CGPDFDictionaryGetArray(font, "DescendantFonts", &descendants), let descendants,
               CGPDFArrayGetDictionary(descendants, 0, &descendant) { descriptorOwner = descendant }
        }
        var descriptor: CGPDFDictionaryRef?
        var isEmbedded = false
        if let descriptorOwner, CGPDFDictionaryGetDictionary(descriptorOwner, "FontDescriptor", &descriptor), let descriptor {
            var stream: CGPDFStreamRef?
            for key in ["FontFile", "FontFile2", "FontFile3"] where CGPDFDictionaryGetStream(descriptor, key, &stream) { isEmbedded = true }
        }
        return .init(name: baseFont, subtype: subtype, isEmbedded: isEmbedded)
    }
}
