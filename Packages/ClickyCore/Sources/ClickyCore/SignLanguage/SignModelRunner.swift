//
//  SignModelRunner.swift
//  ClickyCore
//
//  Sign to text, the models: finding them (`SignModelFiles`), loading one (`SignModelRunner`: a compiled
//  `.mlmodelc`, or an `.mlpackage` compiled once into a cache folder), and running them for the live reader
//  (`SignCoreMLScorer`, which is `SignStretchScoring`). Tools/signs/SPEC.md section 4 names the files and says what
//  each model reads; `Tools/signs/signs/export_coreml.py` writes them:
//
//  - inputs `features` [1, N, 117] float32 and `mask` [1, N] float32 (1 for a real frame, 0 for padding);
//  - a word model gives `scores` [1, words] and `description` [1, width];
//  - the moving finger-spelling model gives `scores` [1, N / 2, characters + 1] (log-probabilities, blank first);
//  - beside each model, `<name>.labels.json` (a JSON list of the words or characters) and, optionally,
//    `<name>.reading.json` (`{"leastWordProbability": 0.3, ...}`), which overrides `SignReadingSettings`.
//
//  Nothing here needs a model to exist: a missing one is said in plain words, and the reader runs without it.
//

import CoreML
import Foundation

// MARK: - Finding the files

public enum SignModelFiles {
    public static func wordModelName(for language: SignLanguage) -> String {
        language == .asl ? "SignWordsASL" : "SignWordsISL"
    }

    public static func spellingModelName(for language: SignLanguage) -> String {
        language == .asl ? "SignSpellASL" : "SignSpellISL"
    }

    /// The labels file beside a model: `SignWordsASL.mlpackage` → `SignWordsASL.labels.json`.
    public static func labelsFileURL(forModelAt modelURL: URL) -> URL {
        modelURL.deletingLastPathComponent().appendingPathComponent(modelBaseName(of: modelURL) + ".labels.json")
    }

    /// The optional reading settings beside a model: `SignWordsASL.reading.json`.
    public static func readingSettingsFileURL(forModelAt modelURL: URL) -> URL {
        modelURL.deletingLastPathComponent().appendingPathComponent(modelBaseName(of: modelURL) + ".reading.json")
    }

    static func modelBaseName(of modelURL: URL) -> String {
        modelURL.deletingPathExtension().lastPathComponent
    }

    /// What was found for one language, and what wasn't.
    public struct Found: Equatable, Sendable {
        public var language: SignLanguage
        public var wordModelURL: URL?
        public var spellingModelURL: URL?
        /// One plain line per missing piece ("the word model SignWordsASL.mlpackage").
        public var missingPieces: [String]

        public var hasAnyModel: Bool { wordModelURL != nil || spellingModelURL != nil }

        /// Nil when everything is there; else the missing pieces in one sentence fragment.
        public var missingDescription: String? {
            missingPieces.isEmpty ? nil : missingPieces.joined(separator: "; ")
        }
    }

    /// Looks in each folder in order (the first that has a model wins) for the language's word and spelling models.
    /// A compiled `.mlmodelc` is taken before an `.mlpackage` in the same folder. A model without its labels file
    /// counts as missing, since its scores would mean nothing.
    public static func find(in folders: [URL], language: SignLanguage) -> Found {
        let fileManager = FileManager.default
        func firstModel(named modelName: String) -> (modelURL: URL?, labelsAreMissing: Bool) {
            var foundModelWithoutLabels = false
            for folder in folders {
                for fileExtension in ["mlmodelc", "mlpackage"] {
                    let candidateURL = folder.appendingPathComponent("\(modelName).\(fileExtension)")
                    guard fileManager.fileExists(atPath: candidateURL.path) else { continue }
                    if fileManager.fileExists(atPath: labelsFileURL(forModelAt: candidateURL).path) {
                        return (candidateURL, false)
                    }
                    foundModelWithoutLabels = true
                }
            }
            return (nil, foundModelWithoutLabels)
        }

        let wordModelName = wordModelName(for: language)
        let spellingModelName = spellingModelName(for: language)
        let wordModel = firstModel(named: wordModelName)
        let spellingModel = firstModel(named: spellingModelName)
        var missingPieces: [String] = []
        if wordModel.modelURL == nil {
            missingPieces.append(wordModel.labelsAreMissing
                ? "the word model has no \(wordModelName).labels.json"
                : "no word model (\(wordModelName).mlpackage)")
        }
        if spellingModel.modelURL == nil {
            missingPieces.append(spellingModel.labelsAreMissing
                ? "the finger-spelling model has no \(spellingModelName).labels.json"
                : "no finger-spelling model (\(spellingModelName).mlpackage)")
        }
        return Found(language: language, wordModelURL: wordModel.modelURL, spellingModelURL: spellingModel.modelURL, missingPieces: missingPieces)
    }
}

// MARK: - One model

public struct SignModelError: Error, CustomStringConvertible {
    public var description: String
    public init(_ description: String) { self.description = description }
}

/// One loaded Core ML model with its labels. Prediction is not run from two threads at once: the reader's scoring
/// queue is the only caller.
public final class SignModelRunner {
    public static let featuresInputName = "features"
    public static let maskInputName = "mask"
    public static let scoresOutputName = "scores"

    public let sourceURL: URL
    public let name: String
    public let labels: [String]
    /// N: the frames the model reads (from its `features` input's shape).
    public let frameCount: Int
    /// From `<name>.reading.json`, when it says.
    public let leastWordProbabilityOverride: Float?
    private let model: MLModel

    /// - Parameters:
    ///   - modelURL: a compiled `.mlmodelc` (used as it is) or an `.mlpackage` / `.mlmodel` (compiled into
    ///     `compiledModelCacheFolder` the first time, and again whenever the package is newer than the compiled copy).
    ///   - compiledModelCacheFolder: where compiled copies are kept; made when needed.
    public init(modelURL: URL, compiledModelCacheFolder: URL, configuration: MLModelConfiguration = MLModelConfiguration()) throws {
        // Everything is worked out in locals first: a class can't read its own properties before all are set.
        let modelName = SignModelFiles.modelBaseName(of: modelURL)

        let labelsURL = SignModelFiles.labelsFileURL(forModelAt: modelURL)
        guard let labelsData = try? Data(contentsOf: labelsURL),
              let decodedLabels = try? JSONDecoder().decode([String].self, from: labelsData),
              !decodedLabels.isEmpty
        else { throw SignModelError("\(labelsURL.lastPathComponent) is missing or isn't a JSON list of words") }

        let compiledURL = try Self.compiledModelURL(for: modelURL, cacheFolder: compiledModelCacheFolder)
        let loadedModel: MLModel
        do {
            loadedModel = try MLModel(contentsOf: compiledURL, configuration: configuration)
        } catch {
            throw SignModelError("\(modelName) couldn't be loaded: \(error.localizedDescription)")
        }

        let modelDescription = loadedModel.modelDescription
        guard let featuresShape = modelDescription.inputDescriptionsByName[Self.featuresInputName]?.multiArrayConstraint?.shape,
              featuresShape.count == 3,
              featuresShape[2].intValue == SignFeatures.featureCount,
              featuresShape[1].intValue > 0
        else { throw SignModelError("\(modelName) doesn't take \(Self.featuresInputName) [1, N, \(SignFeatures.featureCount)]") }
        guard modelDescription.inputDescriptionsByName[Self.maskInputName] != nil else {
            throw SignModelError("\(modelName) doesn't take \(Self.maskInputName) [1, N]")
        }
        guard modelDescription.outputDescriptionsByName[Self.scoresOutputName] != nil else {
            throw SignModelError("\(modelName) doesn't give \(Self.scoresOutputName)")
        }

        sourceURL = modelURL
        name = modelName
        labels = decodedLabels
        frameCount = featuresShape[1].intValue
        leastWordProbabilityOverride = Self.leastWordProbability(fromReadingSettingsAt: SignModelFiles.readingSettingsFileURL(forModelAt: modelURL))
        model = loadedModel
    }

    /// Runs the model on one input. `features` must be `frameCount × 117` values and `mask` `frameCount` values.
    /// Returns `scores` flattened (row-major) and its shape.
    public func scores(features: [Float], mask: [Float]) throws -> (values: [Float], shape: [Int]) {
        guard features.count == frameCount * SignFeatures.featureCount, mask.count == frameCount else {
            throw SignModelError("\(name) needs \(frameCount) frames; got \(mask.count)")
        }
        let featuresArray = try MLMultiArray(
            shape: [1, NSNumber(value: frameCount), NSNumber(value: SignFeatures.featureCount)],
            dataType: .float32
        )
        let maskArray = try MLMultiArray(shape: [1, NSNumber(value: frameCount)], dataType: .float32)
        Self.copy(features, into: featuresArray)
        Self.copy(mask, into: maskArray)
        let inputs = try MLDictionaryFeatureProvider(dictionary: [
            Self.featuresInputName: MLFeatureValue(multiArray: featuresArray),
            Self.maskInputName: MLFeatureValue(multiArray: maskArray)
        ])
        let outputs = try model.prediction(from: inputs)
        guard let scoresArray = outputs.featureValue(for: Self.scoresOutputName)?.multiArrayValue else {
            throw SignModelError("\(name) gave no \(Self.scoresOutputName)")
        }
        return (Self.flatValues(of: scoresArray), scoresArray.shape.map { $0.intValue })
    }

    // MARK: Compiling

    /// A `.mlmodelc` is used as it is. Anything else is compiled into `<cacheFolder>/<name>.mlmodelc`, unless a
    /// compiled copy there is at least as new as the newest file inside the package.
    static func compiledModelURL(for modelURL: URL, cacheFolder: URL) throws -> URL {
        if modelURL.pathExtension == "mlmodelc" { return modelURL }
        let fileManager = FileManager.default
        let cachedURL = cacheFolder.appendingPathComponent(modelBaseName(of: modelURL) + ".mlmodelc", isDirectory: true)
        if fileManager.fileExists(atPath: cachedURL.path),
           let cachedDate = newestModificationDate(under: cachedURL),
           let sourceDate = newestModificationDate(under: modelURL),
           cachedDate >= sourceDate {
            return cachedURL
        }
        try fileManager.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
        let temporaryCompiledURL: URL
        do {
            temporaryCompiledURL = try MLModel.compileModel(at: modelURL)
        } catch {
            throw SignModelError("\(modelURL.lastPathComponent) couldn't be compiled: \(error.localizedDescription)")
        }
        if fileManager.fileExists(atPath: cachedURL.path) {
            try fileManager.removeItem(at: cachedURL)
        }
        // Core ML compiles into a temporary folder that may be on another volume; moving copies when it has to.
        try fileManager.moveItem(at: temporaryCompiledURL, to: cachedURL)
        return cachedURL
    }

    /// The newest modification date of the item and everything inside it (a package's top folder keeps its date when
    /// only the weights inside it are replaced).
    static func newestModificationDate(under itemURL: URL) -> Date? {
        let fileManager = FileManager.default
        var newestDate = (try? itemURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let enumerator = fileManager.enumerator(at: itemURL, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for case let innerURL as URL in enumerator {
                guard let innerDate = (try? innerURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { continue }
                if newestDate == nil || innerDate > newestDate! {
                    newestDate = innerDate
                }
            }
        }
        return newestDate
    }

    static func leastWordProbability(fromReadingSettingsAt fileURL: URL) -> Float? {
        guard let settingsData = try? Data(contentsOf: fileURL),
              let settingsObject = try? JSONSerialization.jsonObject(with: settingsData) as? [String: Any],
              let leastWordProbability = settingsObject["leastWordProbability"] as? NSNumber
        else { return nil }
        let value = leastWordProbability.floatValue
        return (value >= 0 && value <= 1) ? value : nil
    }

    // MARK: Multi-arrays

    /// A freshly made float32 multi-array is contiguous, so the values go straight in.
    private static func copy(_ values: [Float], into multiArray: MLMultiArray) {
        let destination = multiArray.dataPointer.bindMemory(to: Float.self, capacity: values.count)
        values.withUnsafeBufferPointer { sourceBuffer in
            guard let sourceAddress = sourceBuffer.baseAddress else { return }
            destination.update(from: sourceAddress, count: values.count)
        }
    }

    /// Every value in row-major order, whatever the array's strides and number type (an output may be float16 when
    /// a model was exported that way, so each value is read through `NSNumber` by its full index).
    static func flatValues(of multiArray: MLMultiArray) -> [Float] {
        let shape = multiArray.shape.map { $0.intValue }
        let valueCount = shape.reduce(1, *)
        guard valueCount > 0 else { return [] }
        if multiArray.dataType == .float32, isContiguous(multiArray) {
            let source = multiArray.dataPointer.bindMemory(to: Float.self, capacity: valueCount)
            return Array(UnsafeBufferPointer(start: source, count: valueCount))
        }
        var values: [Float] = []
        values.reserveCapacity(valueCount)
        var position = [Int](repeating: 0, count: shape.count)
        for _ in 0..<valueCount {
            values.append(multiArray[position.map { NSNumber(value: $0) }].floatValue)
            // Count up the last index first (row-major).
            var dimension = shape.count - 1
            while dimension >= 0 {
                position[dimension] += 1
                if position[dimension] < shape[dimension] { break }
                position[dimension] = 0
                dimension -= 1
            }
        }
        return values
    }

    private static func isContiguous(_ multiArray: MLMultiArray) -> Bool {
        let shape = multiArray.shape.map { $0.intValue }
        let strides = multiArray.strides.map { $0.intValue }
        var expectedStride = 1
        for dimension in stride(from: shape.count - 1, through: 0, by: -1) {
            if shape[dimension] > 1 && strides[dimension] != expectedStride { return false }
            expectedStride *= shape[dimension]
        }
        return true
    }
}

// MARK: - The scorer the live reader uses

/// The word and finger-spelling models for one language, as `SignStretchScoring`. Either model may be missing.
public final class SignCoreMLScorer: SignStretchScoring {
    public let language: SignLanguage
    public let wordModel: SignModelRunner?
    public let spellingModel: SignModelRunner?
    /// What's missing or failed to load, in plain words (nil when both models are ready).
    public let problems: String?

    /// Loads whatever `files` found; a model that fails to load is reported in `problems`, not thrown, so the other
    /// one still works. Compiling an `.mlpackage` can take seconds the first time: call this off the main thread.
    public init(files: SignModelFiles.Found, compiledModelCacheFolder: URL) {
        language = files.language
        var problemLines = files.missingPieces
        var loadedWordModel: SignModelRunner?
        var loadedSpellingModel: SignModelRunner?
        if let wordModelURL = files.wordModelURL {
            do {
                loadedWordModel = try SignModelRunner(modelURL: wordModelURL, compiledModelCacheFolder: compiledModelCacheFolder)
            } catch {
                problemLines.append(String(describing: error))
            }
        }
        if let spellingModelURL = files.spellingModelURL {
            do {
                loadedSpellingModel = try SignModelRunner(modelURL: spellingModelURL, compiledModelCacheFolder: compiledModelCacheFolder)
            } catch {
                problemLines.append(String(describing: error))
            }
        }
        wordModel = loadedWordModel
        spellingModel = loadedSpellingModel
        problems = problemLines.isEmpty ? nil : problemLines.joined(separator: "; ")
    }

    public var hasAnyModel: Bool { wordModel != nil || spellingModel != nil }

    public var wordModelFrameCount: Int? { wordModel?.frameCount }
    public var wordLabels: [String] { wordModel?.labels ?? [] }
    public var spellingModelFrameCount: Int? { spellingModel?.frameCount }

    /// SPEC section 4: ISL's spelling model reads one still letter from one frame; ASL's reads letters on the move.
    /// Told apart by the frames it reads, so a later moving ISL model works without a change here.
    public var spellingModelKind: SignSpellingModelKind {
        (spellingModel?.frameCount ?? 0) == 1 ? .stillLetter : .movingLetters
    }

    public var spellingCharacters: [String] { spellingModel?.labels ?? [] }
    public var leastWordProbabilityOverride: Float? { wordModel?.leastWordProbabilityOverride }

    public func wordScores(features: [Float], mask: [Float]) throws -> [Float] {
        guard let wordModel else { throw SignModelError("no word model") }
        return try wordModel.scores(features: features, mask: mask).values
    }

    public func spellingScores(features: [Float], mask: [Float]) throws -> [Float] {
        guard let spellingModel else { throw SignModelError("no finger-spelling model") }
        return try spellingModel.scores(features: features, mask: mask).values
    }
}
