//
//  TargetResolver.swift
//  ClickyCore
//
//  Turns a tag's target into a real frame on screen (CG points):
//
//   #n[@x,y]  the registry element, refreshed. If the model's hint is far
//             off and its name doesn't match, a much better-matching
//             element near the hint wins; a near-duplicate of the same kind
//             close by can be re-snapped to. An unlabelled id is never
//             overridden. (0.98)
//   #a-#b     union of the refreshed frames, one display only. (0.95)
//   "text"    AX text ranges (AXBoundsForRange) and OCR words, exact before
//             fuzzy; ~k picks the k-th in front-window/reading order, else
//             the one nearest the cursor; "in #n" limits the search. (0.95 /
//             0.8 fuzzy)
//   x,y / box the smallest small element containing the point (+6 pt), else
//             the nearest within R; snap when 0.6·sim + 0.4·(1 − d/R) ≥ 0.55
//             (0.85), else the raw point (0.5).
//

import CoreGraphics
import Foundation

public struct ResolvedTarget: Sendable {
    public enum Method: String, Sendable {
        case element, elementResnapped, elementAlternative, span, textExact, textFuzzy, snapped, raw
    }

    public var frameCG: CGRect
    public var pointCG: CGPoint
    public var confidence: Double
    public var method: Method
    public var elementID: Int?
    public var displayID: CGDirectDisplayID
    public var label: String?
    public var processIdentifier: pid_t?
    public var axNode: AXNodeReference?
    /// Filled in by HitTestVerifier.
    public var verified: Bool?
    public var occludedByPID: pid_t?
}

/// Live reads the resolver needs (the app implements these with AX).
public protocol GroundingLiveLookup {
    /// The element's current frame, or nil if it's gone.
    func refreshedFrame(of element: GroundingElement) -> CGRect?
    /// Frames of `query` inside an AX text element (AXBoundsForRange).
    func textRanges(of query: String, in element: GroundingElement) -> [(frameCG: CGRect, isFuzzy: Bool)]
}

public struct TargetResolver {
    public let registry: ElementRegistry
    public let framesByScreenNumber: [Int: CaptureFrame]
    public let cursorCG: CGPoint
    public let windowStack: WindowStack?
    public let lookup: GroundingLiveLookup

    public init(registry: ElementRegistry, framesByScreenNumber: [Int: CaptureFrame], cursorCG: CGPoint, windowStack: WindowStack?, lookup: GroundingLiveLookup) {
        self.registry = registry
        self.framesByScreenNumber = framesByScreenNumber
        self.cursorCG = cursorCG
        self.windowStack = windowStack
        self.lookup = lookup
    }

    public func resolve(_ tag: ParsedTag) -> ResolvedTarget? {
        switch tag.target {
        case .none:
            return nil
        case .element(let elementID, let hint):
            return resolveElement(elementID: elementID, hint: hint, tag: tag)
        case .span(let fromID, let toID):
            return resolveSpan(fromID: fromID, toID: toID)
        case .text(let query, let occurrence, let scopeID):
            return resolveText(query: query, occurrence: occurrence, scopeID: scopeID)
        case .point(let modelPixel):
            guard let frame = framesByScreenNumber[tag.effectiveScreenNumber] else { return nil }
            return resolvePoint(frame.cg(fromModelPx: modelPixel), rawRect: nil, name: tag.name, frame: frame)
        case .box(let modelRect):
            guard let frame = framesByScreenNumber[tag.effectiveScreenNumber] else { return nil }
            let rawRect = frame.cgRect(fromModelPxRect: modelRect)
            return resolvePoint(rawRect.center, rawRect: rawRect, name: tag.name, frame: frame)
        }
    }

    // MARK: - Element

    func resolveElement(elementID: Int, hint: CGPoint?, tag: ParsedTag) -> ResolvedTarget? {
        guard let element = registry[elementID] else {
            return tag.name.flatMap { resolveText(query: $0, occurrence: nil, scopeID: nil) }
        }
        guard let refreshedFrame = lookup.refreshedFrame(of: element) else {
            // The element went away: look for its text instead.
            return (element.label ?? tag.name).flatMap { resolveText(query: $0, occurrence: nil, scopeID: nil) }
        }
        var chosenElement = element
        var chosenFrame = refreshedFrame
        var chosenID = elementID
        var method = ResolvedTarget.Method.element

        let hasOwnLabel = element.label?.isEmpty == false
        if hasOwnLabel, let name = tag.name {
            let similarity = LabelSimilarity.labelSim(name, candidates: element.matchableTexts)
            let hintCG: CGPoint? = hint.flatMap { hintPixel in
                frame(forDisplay: element.displayID).map { $0.cg(fromModelPx: hintPixel) }
            }
            let farThreshold = max(80, 1.5 * hypot(refreshedFrame.width, refreshedFrame.height))
            if let hintCG, refreshedFrame.edgeDistance(to: hintCG) > farThreshold, similarity < 0.5 {
                // The id looks wrong: the model's name and hint agree on something else.
                let alternatives = registry.orderedIDs.compactMap { candidateID -> (Int, GroundingElement, Double, Double)? in
                    guard let candidate = registry[candidateID], candidate.displayID == element.displayID else { return nil }
                    let candidateSimilarity = LabelSimilarity.labelSim(name, candidates: candidate.matchableTexts)
                    let proximity = max(0, 1 - Double(candidate.visibleFrameCG.edgeDistance(to: hintCG)) / 400)
                    return (candidateID, candidate, candidateSimilarity, 0.7 * candidateSimilarity + 0.3 * proximity)
                }
                if let bestAlternative = alternatives.max(by: { $0.3 < $1.3 }), bestAlternative.2 >= 0.85 {
                    chosenID = bestAlternative.0
                    chosenElement = bestAlternative.1
                    chosenFrame = lookup.refreshedFrame(of: bestAlternative.1) ?? bestAlternative.1.visibleFrameCG
                    method = .elementAlternative
                }
            } else if similarity < 0.5 {
                // A same-kind neighbour within 150 pt that matches the name well.
                let nearbyMatch = registry.orderedIDs.compactMap { candidateID -> (Int, GroundingElement, CGFloat)? in
                    guard candidateID != elementID, let candidate = registry[candidateID], candidate.role == element.role,
                          candidate.displayID == element.displayID,
                          LabelSimilarity.labelSim(name, candidates: candidate.matchableTexts) >= 0.85 else { return nil }
                    let distance = hypot(candidate.visibleFrameCG.midX - refreshedFrame.midX, candidate.visibleFrameCG.midY - refreshedFrame.midY)
                    return distance <= 150 ? (candidateID, candidate, distance) : nil
                }.min { $0.2 < $1.2 }
                if let nearbyMatch {
                    chosenID = nearbyMatch.0
                    chosenElement = nearbyMatch.1
                    chosenFrame = lookup.refreshedFrame(of: nearbyMatch.1) ?? nearbyMatch.1.visibleFrameCG
                    method = .elementResnapped
                }
            }
        }

        return ResolvedTarget(frameCG: chosenFrame, pointCG: chosenFrame.center, confidence: 0.98, method: method, elementID: chosenID,
                              displayID: chosenElement.displayID, label: chosenElement.label, processIdentifier: chosenElement.processIdentifier,
                              axNode: chosenElement.axNode)
    }

    // MARK: - Span

    func resolveSpan(fromID: Int, toID: Int) -> ResolvedTarget? {
        let idRange = min(fromID, toID)...max(fromID, toID)
        let spanElements = idRange.compactMap { registry[$0] }
        guard let firstElement = spanElements.first else { return nil }
        let frames = spanElements
            .filter { $0.displayID == firstElement.displayID }
            .map { lookup.refreshedFrame(of: $0) ?? $0.visibleFrameCG }
        guard let unionFrame = frames.dropFirst().reduce(frames.first, { partialUnion, nextFrame in partialUnion?.union(nextFrame) }) else { return nil }
        return ResolvedTarget(frameCG: unionFrame, pointCG: unionFrame.center, confidence: 0.95, method: .span, elementID: idRange.lowerBound,
                              displayID: firstElement.displayID, label: firstElement.label, processIdentifier: firstElement.processIdentifier, axNode: nil)
    }

    // MARK: - Text

    struct TextCandidate {
        let frameCG: CGRect
        let isFuzzy: Bool
        let zIndex: Int
        let displayID: CGDirectDisplayID
        let processIdentifier: pid_t?
        let axNode: AXNodeReference?
        let elementID: Int?
    }

    func resolveText(query: String, occurrence: Int?, scopeID: Int?) -> ResolvedTarget? {
        var candidates: [TextCandidate] = []

        for elementID in registry.orderedIDs {
            guard let element = registry[elementID], element.source == .accessibility else { continue }
            for textRange in lookup.textRanges(of: query, in: element) {
                candidates.append(TextCandidate(frameCG: textRange.frameCG, isFuzzy: textRange.isFuzzy, zIndex: element.windowZIndex,
                                                displayID: element.displayID, processIdentifier: element.processIdentifier,
                                                axNode: element.axNode, elementID: elementID))
            }
        }
        for ocrLine in registry.allOCRLines {
            let lineLength = LabelSimilarity.normalize(ocrLine.text).count
            for occurrenceMatch in LabelSimilarity.findOccurrences(of: query, in: ocrLine.text) {
                // A match covering all but ≤ 2 characters of the line is the
                // line (OCR often adds or drops a stray character at the end;
                // a proportional slice would just shift the box).
                let matchFrame = occurrenceMatch.range.count >= lineLength - 2
                    ? ocrLine.frameCG
                    : OCREngine.substringFrame(of: occurrenceMatch.range, inLineOfLength: lineLength, lineFrameCG: ocrLine.frameCG)
                // AX already covers this spot: keep the AX candidate.
                if candidates.contains(where: { $0.axNode != nil && $0.frameCG.intersectionOverUnion(with: matchFrame) > 0.5 }) { continue }
                let ownerWindow = windowStack?.windows.first { $0.isApplicationWindowLayer && $0.boundsCG.contains(matchFrame.center) }
                candidates.append(TextCandidate(frameCG: matchFrame, isFuzzy: occurrenceMatch.isFuzzy,
                                                zIndex: ownerWindow.flatMap { windowStack?.zIndex(of: $0.windowID) } ?? Int.max / 2,
                                                displayID: ocrLine.displayID, processIdentifier: ownerWindow?.processIdentifier,
                                                axNode: nil, elementID: nil))
            }
        }

        if let scopeID, let scopeElement = registry[scopeID] {
            let scopeFrame = (lookup.refreshedFrame(of: scopeElement) ?? scopeElement.visibleFrameCG).insetBy(dx: -4, dy: -4)
            candidates = candidates.filter { scopeFrame.contains($0.frameCG.center) }
        }
        let exactCandidates = candidates.filter { !$0.isFuzzy }
        let pool = exactCandidates.isEmpty ? candidates : exactCandidates
        guard !pool.isEmpty else { return nil }

        let chosen: TextCandidate
        if let occurrence, occurrence >= 1 {
            let ordered = pool.sorted { first, second in
                if first.zIndex != second.zIndex { return first.zIndex < second.zIndex }
                let firstLine = Int((first.frameCG.minY / 12).rounded(.down))
                let secondLine = Int((second.frameCG.minY / 12).rounded(.down))
                if firstLine != secondLine { return firstLine < secondLine }
                return first.frameCG.minX < second.frameCG.minX
            }
            chosen = ordered[min(occurrence, ordered.count) - 1]
        } else {
            chosen = pool.min { $0.frameCG.edgeDistance(to: cursorCG) < $1.frameCG.edgeDistance(to: cursorCG) }!
        }
        return ResolvedTarget(frameCG: chosen.frameCG, pointCG: chosen.frameCG.center, confidence: chosen.isFuzzy ? 0.8 : 0.95,
                              method: chosen.isFuzzy ? .textFuzzy : .textExact, elementID: chosen.elementID, displayID: chosen.displayID,
                              label: query, processIdentifier: chosen.processIdentifier, axNode: chosen.axNode)
    }

    // MARK: - Point / box

    func resolvePoint(_ pointCG: CGPoint, rawRect: CGRect?, name: String?, frame: CaptureFrame) -> ResolvedTarget {
        let screenRect = frame.display.boundsCG
        let searchRadius = max(24, 0.012 * screenRect.width)
        let smallElements = registry.orderedIDs.compactMap { elementID -> (Int, GroundingElement)? in
            guard let element = registry[elementID], element.displayID == frame.display.displayID,
                  element.visibleFrameCG.area < 0.25 * screenRect.area else { return nil }
            return (elementID, element)
        }

        let containing = smallElements
            .filter { $0.1.visibleFrameCG.insetBy(dx: -6, dy: -6).contains(pointCG) }
            .min { $0.1.visibleFrameCG.area < $1.1.visibleFrameCG.area }
        let nearest = containing ?? smallElements
            .map { ($0, $0.1.visibleFrameCG.edgeDistance(to: pointCG)) }
            .filter { $0.1 <= searchRadius }
            .min { $0.1 < $1.1 }?.0

        let rawResult = ResolvedTarget(frameCG: rawRect ?? CGRect(x: pointCG.x, y: pointCG.y, width: 0, height: 0), pointCG: pointCG,
                                       confidence: 0.5, method: .raw, elementID: nil, displayID: frame.display.displayID,
                                       label: name, processIdentifier: nil, axNode: nil)
        guard let (elementID, element) = nearest else { return rawResult }

        let distance = Double(element.visibleFrameCG.edgeDistance(to: pointCG))
        let similarity = name.map { LabelSimilarity.labelSim($0, candidates: element.matchableTexts) } ?? 0.5
        let snapScore = 0.6 * similarity + 0.4 * (1 - min(1, distance / Double(searchRadius)))
        guard snapScore >= 0.55 else { return rawResult }
        let snappedFrame = lookup.refreshedFrame(of: element) ?? element.visibleFrameCG
        return ResolvedTarget(frameCG: snappedFrame, pointCG: snappedFrame.center, confidence: 0.85, method: .snapped, elementID: elementID,
                              displayID: element.displayID, label: element.label, processIdentifier: element.processIdentifier, axNode: element.axNode)
    }

    private func frame(forDisplay displayID: CGDirectDisplayID) -> CaptureFrame? {
        framesByScreenNumber.values.first { $0.display.displayID == displayID }
    }
}

// MARK: - Verification

/// Checks a resolved target is really what's at that spot (≤ 5 ms per tag):
/// an app-scoped hit test that reaches the element within 8 parents, else a
/// same-app hit whose label matches. Anything else on top is recorded as
/// the occluding app.
public enum HitTestVerifier {
    public static func verify(_ target: inout ResolvedTarget, ax: AXQuerying, ownProcessIdentifier: pid_t, windowStack: WindowStack?) {
        guard let targetPID = target.processIdentifier, targetPID != 0 else {
            target.verified = nil
            return
        }

        // One system-wide hit test usually settles it: whatever is on top.
        let systemWideHit = ax.systemWideElement(at: target.pointCG)
        let systemWideHitPID = systemWideHit.flatMap { ax.processIdentifier(of: $0) }

        if let systemWideHitPID, systemWideHitPID != targetPID {
            if systemWideHitPID == ownProcessIdentifier {
                // Our own overlay is on top: hit-test inside the target app and
                // decide coverage from the window stack.
                if let targetNode = target.axNode {
                    let applicationNode = ax.applicationNode(processIdentifier: targetPID)
                    if let appScopedHit = ax.element(at: target.pointCG, inApplication: applicationNode),
                       isTarget(targetNode, reachableFrom: appScopedHit, ax: ax, targetPID: targetPID, targetLabel: target.label) {
                        target.verified = true
                    }
                }
                applyWindowStackRule(&target, targetPID: targetPID, windowStack: windowStack)
            } else {
                // Another app's window covers it.
                target.verified = false
                target.occludedByPID = systemWideHitPID
            }
            return
        }

        if let targetNode = target.axNode, let systemWideHit {
            target.verified = isTarget(targetNode, reachableFrom: systemWideHit, ax: ax, targetPID: targetPID, targetLabel: target.label)
            if target.verified == true { return }
        }
        applyWindowStackRule(&target, targetPID: targetPID, windowStack: windowStack)
    }

    /// The hit is the target, one of its ≤ 8 ancestors is, or it's a
    /// same-app element whose label matches (> 0.8).
    private static func isTarget(_ targetNode: AXNodeReference, reachableFrom hitNode: AXNodeReference, ax: AXQuerying, targetPID: pid_t, targetLabel: String?) -> Bool {
        var currentNode: AXNodeReference? = hitNode
        for _ in 0...8 {
            guard let node = currentNode else { break }
            if ax.isEqual(node, targetNode) { return true }
            currentNode = ax.parent(of: node)
        }
        if ax.processIdentifier(of: hitNode) == targetPID, let targetLabel, let hitAttributes = ax.attributes(of: hitNode),
           LabelSimilarity.labelSim(targetLabel, candidates: [hitAttributes.title, hitAttributes.elementDescription]) > 0.8 {
            return true
        }
        return false
    }

    private static func applyWindowStackRule(_ target: inout ResolvedTarget, targetPID: pid_t, windowStack: WindowStack?) {
        guard let windowStack else { return }
        if windowStack.isBehind(point: target.pointCG, processIdentifier: targetPID) {
            target.verified = false
            target.occludedByPID = windowStack.windows.first { ($0.isApplicationWindowLayer || $0.layer == 101) && $0.boundsCG.contains(target.pointCG) }?.processIdentifier
        } else if target.verified == nil {
            target.verified = true
        }
    }
}
