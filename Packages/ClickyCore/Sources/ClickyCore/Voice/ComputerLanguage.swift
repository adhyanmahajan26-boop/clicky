//
//  ComputerLanguage.swift
//  ClickyCore
//
//  Calls start from the computer's own language rather than assuming Indian English. "Auto" on a Mac set to Hindi or to
//  an Indian region keeps the Hindi / English / Hinglish mixing calls were built for; anywhere else it listens in the
//  computer's language and answers in whatever language the owner just used. Hindi and Hinglish stay as explicit choices.
//

import Foundation

public enum ComputerLanguage {
    /// A recognizer locale ("en-US", "hi-IN", "fr-FR") from the computer's first preferred language, which macOS gives as
    /// "en-US", "en_GB", "hi-IN" or a bare "fr". A bare language gets its most common region; nothing usable gives "en-US".
    public static func recognizerLocale(preferredLanguage: String?) -> String {
        let parts = (preferredLanguage ?? "").replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
        guard let language = parts.first?.lowercased(), language.count >= 2, language.allSatisfy(\.isLetter) else { return "en-US" }
        // The region is the last part made of two letters ("zh-Hans-CN" → CN), if there is one.
        if let region = parts.dropFirst().last(where: { $0.count == 2 && $0.allSatisfy(\.isLetter) }) {
            return "\(language)-\(region.uppercased())"
        }
        let usualRegion: [String: String] = ["en": "US", "hi": "IN", "fr": "FR", "de": "DE", "es": "ES", "it": "IT", "pt": "BR", "ja": "JP",
                                             "ko": "KR", "zh": "CN", "nl": "NL", "sv": "SE", "ru": "RU", "ar": "SA", "tr": "TR", "pl": "PL"]
        return "\(language)-\(usualRegion[language] ?? language.uppercased())"
    }

    /// True for a Mac set to Hindi or to an Indian region: there "auto" means the Hindi / English / Hinglish mix.
    public static func isIndian(preferredLanguage: String?) -> Bool {
        let locale = recognizerLocale(preferredLanguage: preferredLanguage)
        return locale.hasPrefix("hi-") || locale.hasSuffix("-IN")
    }

    /// The English recognizer to use when English is picked: the computer's own English ("en-GB", "en-IN"), else US English.
    public static func englishLocale(preferredLanguage: String?) -> String {
        let locale = recognizerLocale(preferredLanguage: preferredLanguage)
        return locale.hasPrefix("en-") ? locale : "en-US"
    }

    /// The call language to save once on a Mac that finished setup before "auto" followed the computer: Hinglish, which is
    /// exactly what "auto" did then. Nil when a choice is saved, or for a new install, which starts on the computer's language.
    public static func migratedCallLanguage(savedValueExists: Bool, setupCompleted: Bool) -> String? {
        guard !savedValueExists, setupCompleted else { return nil }
        return "hinglish"
    }
}
