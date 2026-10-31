//
//  NotesThumbnailView.swift
//  leanring-buddy
//
//  Off-main, downsampled thumbnails for the Notes tab. Decoding happens on a
//  background queue with CGImageSource thumbnail options (never a full decode),
//  keyed by path + modification time, with an in-memory NSCache.
//

import AppKit
import ImageIO
import SwiftUI

enum NotesThumbnailCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 300
        return cache
    }()
    private static let queue = DispatchQueue(label: "theo.notes.thumbnails", qos: .userInitiated, attributes: .concurrent)

    private static func key(_ url: URL, _ modified: Date, _ maxPixel: Int) -> NSString {
        "\(url.path)|\(modified.timeIntervalSince1970)|\(maxPixel)" as NSString
    }

    static func cached(url: URL, modified: Date, maxPixel: Int) -> NSImage? {
        cache.object(forKey: key(url, modified, maxPixel))
    }

    static func load(url: URL, modified: Date, maxPixel: Int) async -> NSImage? {
        let cacheKey = key(url, modified, maxPixel)
        if let hit = cache.object(forKey: cacheKey) { return hit }
        return await withCheckedContinuation { continuation in
            queue.async {
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                ]
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                    continuation.resume(returning: nil)
                    return
                }
                let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                cache.setObject(image, forKey: cacheKey)
                continuation.resume(returning: image)
            }
        }
    }
}

/// A thumbnail that fills its frame; shows `placeholder` until the image is decoded off the main thread.
struct NotesThumbnailView<Placeholder: View>: View {
    let url: URL
    let modified: Date
    var maxPixel = 480
    @ViewBuilder var placeholder: () -> Placeholder
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                placeholder()
            }
        }
        .task(id: "\(url.path)|\(modified.timeIntervalSince1970)") {
            if let hit = NotesThumbnailCache.cached(url: url, modified: modified, maxPixel: maxPixel) { image = hit; return }
            image = await NotesThumbnailCache.load(url: url, modified: modified, maxPixel: maxPixel)
        }
    }
}
