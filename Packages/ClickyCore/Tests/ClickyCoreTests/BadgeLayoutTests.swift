import CoreGraphics
import Foundation
import Testing
@testable import ClickyCore

private func intersectionArea(_ first: CGRect, _ second: CGRect) -> CGFloat {
    first.intersection(second).area
}

@Test func singleElementBadgeSitsOutsideTopLeftWhenThereIsRoom() {
    let elementRect = CGRect(x: 500, y: 400, width: 100, height: 50)
    let placements = BadgeLayout.place(
        candidates: [BadgeLayout.Candidate(elementID: 1, rectPx: elementRect)],
        allElementRectsPx: [elementRect],
        imageSize: CGSize(width: 2000, height: 837)
    )

    #expect(placements.count == 1)
    guard let placement = placements.first else { return }
    #expect(placement.elementID == 1)
    #expect(placement.fontSize == BadgeLayout.defaultFontSize)
    // Outside top-left: entirely above and to the left of the element.
    #expect(placement.badgeRectPx.maxX <= elementRect.minX)
    #expect(placement.badgeRectPx.maxY <= elementRect.minY)
    #expect(CGRect(x: 0, y: 0, width: 2000, height: 837).contains(placement.badgeRectPx))
}

@Test func denseToolbarKeepsBadgesInsideTheImageAndUncoveredAndNonOverlapping() {
    let imageSize = CGSize(width: 800, height: 400)
    let icons = (0..<30).map { index in CGRect(x: 10 + CGFloat(index) * 22, y: 100, width: 20, height: 20) }
    let candidates = icons.enumerated().map { index, rect in BadgeLayout.Candidate(elementID: index + 1, rectPx: rect) }

    let placements = BadgeLayout.place(candidates: candidates, allElementRectsPx: icons, imageSize: imageSize)
    let imageBounds = CGRect(origin: .zero, size: imageSize)

    #expect(placements.count >= 20)
    for placement in placements {
        #expect(imageBounds.contains(placement.badgeRectPx))
        for icon in icons {
            let covered = intersectionArea(placement.badgeRectPx, icon)
            #expect(covered <= BadgeLayout.maximumCoveredFraction * icon.area,
                    "badge \(placement.elementID) covers too much of an icon")
        }
    }
    for (firstIndex, first) in placements.enumerated() {
        for second in placements.dropFirst(firstIndex + 1) {
            #expect(!first.badgeRectPx.intersects(second.badgeRectPx),
                    "badges \(first.elementID) and \(second.elementID) overlap")
        }
    }
}

@Test func elementInTopLeftCornerStillGetsAnInImageBadge() {
    let imageSize = CGSize(width: 800, height: 400)
    let elementRect = CGRect(x: 0, y: 0, width: 40, height: 20)
    let placements = BadgeLayout.place(
        candidates: [BadgeLayout.Candidate(elementID: 7, rectPx: elementRect)],
        allElementRectsPx: [elementRect],
        imageSize: imageSize
    )

    #expect(placements.count == 1)
    guard let placement = placements.first else { return }
    #expect(CGRect(origin: .zero, size: imageSize).contains(placement.badgeRectPx))
    #expect(intersectionArea(placement.badgeRectPx, elementRect) <= BadgeLayout.maximumCoveredFraction * elementRect.area)
}

@Test func badgeSizeGrowsWithDigitsAndSitsInsideTheFontSize() {
    let oneDigit = BadgeLayout.badgeSize(for: 3, fontSize: BadgeLayout.defaultFontSize)
    let threeDigits = BadgeLayout.badgeSize(for: 123, fontSize: BadgeLayout.defaultFontSize)
    #expect(threeDigits.width > oneDigit.width)
    #expect(oneDigit.height == (BadgeLayout.defaultFontSize + 3).rounded(.up))
}

@Test func renderReturnsAnImageOfTheSameSize() throws {
    let width = 320
    let height = 200
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())

    let elementRect = CGRect(x: 40, y: 60, width: 120, height: 40)
    let placements = BadgeLayout.place(
        candidates: [BadgeLayout.Candidate(elementID: 12, rectPx: elementRect)],
        allElementRectsPx: [elementRect],
        imageSize: CGSize(width: width, height: height)
    )
    let rendered = try #require(BadgeRenderer.render(
        onto: image,
        placements: placements,
        outlinedRectsPx: [12: elementRect],
        cursorPx: CGPoint(x: 100, y: 80)
    ))

    #expect(rendered.width == width)
    #expect(rendered.height == height)

    let emptyRender = try #require(BadgeRenderer.render(onto: image, placements: [], outlinedRectsPx: [:], cursorPx: nil))
    #expect(emptyRender.width == width)
    #expect(emptyRender.height == height)
}
