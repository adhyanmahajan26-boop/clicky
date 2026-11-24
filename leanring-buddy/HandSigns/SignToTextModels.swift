//
//  SignToTextModels.swift
//  leanring-buddy
//
//  Sign to text's models in the app: where they are looked for, and the one queue they run on.
//
//  Models are looked for first in `SignModels` inside the app's own data folder for this profile
//  (`~/Library/Application Support/Theo/SignModels`; a test profile has its own home, so its own folder), so a newly
//  trained model can be dropped in without a new build, then in the app bundle's resources. A model there is an
//  `.mlpackage` (compiled once into the caches folder) or an `.mlmodelc`, with its `.labels.json` beside it
//  (ClickyCore `SignModelFiles`, Tools/signs/SPEC.md section 4).
//
//  `SignScoringWorker` owns the loaded models and runs every reading on one serial queue, off the main thread, so
//  the camera's frames never wait for a model and readings come back in the order they were asked for.
//

import ClickyCore
import Foundation

enum SignModelFolders {
    /// `~/Library/Application Support/Theo/SignModels` (the test profile's own home in a test profile).
    static var dataFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Theo/SignModels", isDirectory: true)
    }

    /// Where an `.mlpackage` is compiled to, once per model version. Caches, since it can always be made again.
    static var compiledModelCacheFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vello/SignModels", isDirectory: true)
    }

    /// The data folder first, then the bundle (a `SignModels` folder in its resources, then the resources themselves,
    /// which is where Xcode puts a model added to the target).
    static var searchFolders: [URL] {
        var folders = [dataFolder]
        if let resourcesURL = Bundle.main.resourceURL {
            folders.append(resourcesURL.appendingPathComponent("SignModels", isDirectory: true))
            folders.append(resourcesURL)
        }
        return folders
    }
}

/// What loading the models for one language found, for the panel, Settings and the debug state.
nonisolated struct SignModelLoadResult {
    let language: SignLanguage
    let found: SignModelFiles.Found
    /// "SignWordsASL, 2,000 words, 96 frames"; nil when there is no word model.
    let wordModelSummary: String?
    let spellingModelSummary: String?
    /// "SignSentencesISL, 261 words, 384 frames"; nil when there is no sentence model (runs of signs are then read
    /// one stretch, one word, as before).
    let sentenceModelSummary: String?
    /// What's missing or failed, in plain words; nil when both models are ready.
    let problems: String?
    let hasAnyModel: Bool
}

/// Not on the main actor: everything it holds is only touched on `scoringQueue`, and results go back to the main
/// thread through the completions.
nonisolated final class SignScoringWorker: @unchecked Sendable {
    private let scoringQueue = DispatchQueue(label: "vello.handsigns.signs.scoring", qos: .userInitiated)
    /// Only read and written on `scoringQueue`.
    private var scorer: SignCoreMLScorer?

    /// Loads the language's models (compiling an `.mlpackage` the first time can take a few seconds) and calls
    /// `completion` on the main thread. Readings asked for after this wait for it, since they share the queue.
    func loadModels(language: SignLanguage, searchFolders: [URL], compiledModelCacheFolder: URL, completion: @escaping (SignModelLoadResult) -> Void) {
        scoringQueue.async { [weak self] in
            guard let self else { return }
            let found = SignModelFiles.find(in: searchFolders, language: language)
            let loadedScorer = found.hasAnyModel ? SignCoreMLScorer(files: found, compiledModelCacheFolder: compiledModelCacheFolder) : nil
            self.scorer = (loadedScorer?.hasAnyModel ?? false) ? loadedScorer : nil
            let result = SignModelLoadResult(
                language: language,
                found: found,
                wordModelSummary: loadedScorer?.wordModel.map { "\($0.name), \($0.labels.count) words, \($0.frameCount) frames" },
                spellingModelSummary: loadedScorer?.spellingModel.map { "\($0.name), \($0.labels.count) letters, \($0.frameCount) frames" },
                sentenceModelSummary: loadedScorer?.sentenceModel.map { "\($0.name), \($0.labels.count) words, \($0.frameCount) frames" },
                problems: loadedScorer?.problems ?? found.missingDescription,
                hasAnyModel: loadedScorer?.hasAnyModel ?? false
            )
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Reads one stretch with whatever models are loaded and calls `completion` on the main thread.
    func read(_ job: SignStretchJob, settings: SignReadingSettings, completion: @escaping (SignStretchOutcome) -> Void) {
        scoringQueue.async { [weak self] in
            guard let self else { return }
            let outcome = SignLiveReader.read(job, scoring: self.scorer, settings: settings)
            DispatchQueue.main.async { completion(outcome) }
        }
    }
}
