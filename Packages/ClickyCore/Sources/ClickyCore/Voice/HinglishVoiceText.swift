//
//  HinglishVoiceText.swift
//  ClickyCore
//
//  What the X Space bot's voice is given for Hinglish in Roman letters. The bot writes Hindi in Roman letters (one script
//  per reply), and Sarvam's Hindi voice reads Roman Hindi like English: "main" came out "mey", and nasal sounds ("hun",
//  "nahin", "haan") came out hard (a public Space, 26 Nov). So, for the voice only, the everyday Hindi words of a sentence
//  are written in Devanagari and English words stay as they are. The reply itself is never changed.
//

import Foundation

public enum HinglishVoiceText {
    /// Common Hinglish words in Roman letters and how they're written in Devanagari. Only words that can't be mistaken for
    /// English ones ("to", "me", "is", "do", "so", "he", "hi", "us" are left out); "main" is "मैं" in a Hinglish sentence.
    static let words: [String: String] = {
        var table: [String: String] = [:]
        let entries: [(String, String)] = [
            // I, you, they
            ("mein", "में"), ("mujhe", "मुझे"), ("mujhko", "मुझको"), ("mera", "मेरा"), ("meri", "मेरी"), ("mere", "मेरे"),
            ("maine", "मैंने"), ("hum", "हम"), ("humne", "हमने"), ("hamara", "हमारा"), ("hamari", "हमारी"), ("hamare", "हमारे"), ("humein", "हमें"), ("hume", "हमें"),
            ("tum", "तुम"), ("tumhe", "तुम्हें"), ("tumhein", "तुम्हें"), ("tumhara", "तुम्हारा"), ("tumhari", "तुम्हारी"), ("tumhare", "तुम्हारे"), ("tumne", "तुमने"),
            ("aap", "आप"), ("aapka", "आपका"), ("aapki", "आपकी"), ("aapke", "आपके"), ("aapko", "आपको"), ("aapne", "आपने"), ("tu", "तू"), ("tera", "तेरा"), ("teri", "तेरी"),
            ("tere", "तेरे"), ("tujhe", "तुझे"), ("wo", "वो"), ("woh", "वो"), ("vo", "वो"), ("voh", "वो"), ("ye", "ये"), ("yeh", "ये"), ("usne", "उसने"), ("uska", "उसका"),
            ("uski", "उसकी"), ("uske", "उसके"), ("usko", "उसको"), ("unka", "उनका"), ("unki", "उनकी"), ("unke", "उनके"), ("unko", "उनको"), ("unhe", "उन्हें"),
            ("unhone", "उन्होंने"), ("iska", "इसका"), ("iski", "इसकी"), ("iske", "इसके"), ("isko", "इसको"), ("ise", "इसे"), ("inka", "इनका"), ("apna", "अपना"),
            ("apni", "अपनी"), ("apne", "अपने"), ("khud", "ख़ुद"), ("sab", "सब"), ("sabko", "सबको"), ("sabka", "सबका"), ("sabki", "सबकी"), ("sabke", "सबके"), ("sabse", "सबसे"),
            ("koi", "कोई"), ("kisi", "किसी"), ("kuch", "कुछ"), ("kuchh", "कुछ"), ("log", "लोग"), ("logon", "लोगों"), ("logo", "लोगों"),
            // be
            ("hun", "हूँ"), ("hoon", "हूँ"), ("hu", "हूँ"), ("hai", "है"), ("hain", "हैं"), ("ho", "हो"), ("tha", "था"), ("thi", "थी"), ("hoga", "होगा"),
            ("hogi", "होगी"), ("honge", "होंगे"), ("hua", "हुआ"), ("hui", "हुई"), ("hue", "हुए"), ("hona", "होना"), ("hota", "होता"), ("hoti", "होती"), ("hote", "होते"),
            // little words
            ("nahi", "नहीं"), ("nahin", "नहीं"), ("nhi", "नहीं"), ("na", "ना"), ("naa", "ना"), ("mat", "मत"), ("haan", "हाँ"), ("han", "हाँ"), ("haa", "हाँ"), ("ji", "जी"),
            ("aur", "और"), ("ya", "या"), ("par", "पर"), ("lekin", "लेकिन"), ("magar", "मगर"), ("ki", "की"), ("ka", "का"), ("ke", "के"), ("ko", "को"), ("se", "से"),
            ("ne", "ने"), ("toh", "तो"), ("bhi", "भी"), ("tak", "तक"), ("liye", "लिए"), ("wala", "वाला"), ("wali", "वाली"), ("wale", "वाले"),
            ("kyunki", "क्योंकि"), ("kyonki", "क्योंकि"), ("agar", "अगर"), ("jab", "जब"), ("tab", "तब"), ("phir", "फिर"), ("fir", "फिर"), ("bas", "बस"), ("sirf", "सिर्फ़"),
            ("bilkul", "बिल्कुल"), ("ekdum", "एकदम"), ("zaroor", "ज़रूर"), ("jarur", "ज़रूर"), ("shayad", "शायद"), ("sach", "सच"), ("sahi", "सही"), ("galat", "ग़लत"),
            ("accha", "अच्छा"), ("achha", "अच्छा"), ("acha", "अच्छा"), ("acchi", "अच्छी"), ("achhi", "अच्छी"), ("acche", "अच्छे"), ("achhe", "अच्छे"), ("theek", "ठीक"),
            ("thik", "ठीक"), ("arre", "अरे"), ("yaar", "यार"), ("yar", "यार"), ("bhai", "भाई"), ("didi", "दीदी"), ("behen", "बहन"), ("dost", "दोस्त"),
            ("waah", "वाह"), ("wah", "वाह"), ("chalo", "चलो"), 
            // questions and places
            ("kya", "क्या"), ("kyun", "क्यों"), ("kyu", "क्यों"), ("kaise", "कैसे"), ("kaisa", "कैसा"), ("kaisi", "कैसी"), ("kab", "कब"), ("kahan", "कहाँ"),
            ("kaha", "कहाँ"), ("kaun", "कौन"), ("kitna", "कितना"), ("kitni", "कितनी"), ("kitne", "कितने"), ("yahan", "यहाँ"), ("yaha", "यहाँ"), ("yahin", "यहीं"),
            ("wahan", "वहाँ"), ("waha", "वहाँ"), ("wahin", "वहीं"), ("idhar", "इधर"), ("udhar", "उधर"), ("andar", "अंदर"), ("bahar", "बाहर"), ("upar", "ऊपर"), ("neeche", "नीचे"),
            ("saath", "साथ"), ("sath", "साथ"), ("paas", "पास"), ("baad", "बाद"), ("pehle", "पहले"), ("pahle", "पहले"), ("abhi", "अभी"), ("ab", "अब"), ("aaj", "आज"),
            ("kal", "कल"), ("roz", "रोज़"), ("hamesha", "हमेशा"), ("kabhi", "कभी"), ("jaldi", "जल्दी"), ("der", "देर"), ("thoda", "थोड़ा"), ("thodi", "थोड़ी"),
            ("thode", "थोड़े"), ("bahut", "बहुत"), ("bohot", "बहुत"), ("zyada", "ज़्यादा"), ("jyada", "ज़्यादा"), ("kam", "कम"), ("aisa", "ऐसा"), ("aisi", "ऐसी"),
            ("aise", "ऐसे"), ("waisa", "वैसा"), ("waise", "वैसे"), ("jaisa", "जैसा"), ("jaise", "जैसे"), ("matlab", "मतलब"), ("baat", "बात"), ("baatein", "बातें"),
            ("sawaal", "सवाल"), ("sawal", "सवाल"), ("jawab", "जवाब"), ("naam", "नाम"), ("kaam", "काम"), ("ghar", "घर"), ("din", "दिन"), ("raat", "रात"), ("dil", "दिल"),
            ("pyaar", "प्यार"), ("pyar", "प्यार"), ("duniya", "दुनिया"), ("desh", "देश"), ("ladki", "लड़की"), ("ladkiyan", "लड़कियाँ"), ("ladkiyon", "लड़कियों"),
            ("ladka", "लड़का"), ("ladke", "लड़के"), ("aurat", "औरत"), ("auratein", "औरतें"), ("mahila", "महिला"), ("mahilayen", "महिलाएँ"), ("aadmi", "आदमी"),
            ("paisa", "पैसा"), ("paise", "पैसे"), ("samay", "समय"), ("waqt", "वक़्त"), ("mazaa", "मज़ा"), ("maza", "मज़ा"), ("mazedaar", "मज़ेदार"), ("mast", "मस्त"),
            ("pyari", "प्यारी"), ("pyara", "प्यारा"), ("chhoti", "छोटी"), ("choti", "छोटी"), ("chhota", "छोटा"), ("chota", "छोटा"), ("badi", "बड़ी"), ("bada", "बड़ा"),
            ("bade", "बड़े"), ("naya", "नया"), ("nayi", "नई"), ("purana", "पुराना"), ("asli", "असली"), ("pakka", "पक्का"), ("barabar", "बराबर"), ("haq", "हक़"),
            ("izzat", "इज़्ज़त"), ("aazadi", "आज़ादी"), ("sapna", "सपना"), ("sapne", "सपने"), ("hansi", "हँसी"), ("sunao", "सुनाओ"), ("suniye", "सुनिए"), ("dekhiye", "देखिए"),
            ("ek", "एक"), ("teen", "तीन"), ("char", "चार"), ("paanch", "पाँच"), ("das", "दस"), ("sau", "सौ"), ("hazaar", "हज़ार"),
            // doing
            ("karna", "करना"), ("karta", "करता"), ("karti", "करती"), ("karte", "करते"), ("karo", "करो"), ("kariye", "करिए"), ("karein", "करें"), ("karun", "करूँ"),
            ("karoon", "करूँ"), ("karunga", "करूँगा"), ("karungi", "करूँगी"), ("karenge", "करेंगे"), ("karega", "करेगा"), ("karegi", "करेगी"), ("kiya", "किया"),
            ("kiye", "किए"), ("ki", "की"), ("kar", "कर"), ("karke", "करके"), ("rahi", "रही"), ("raha", "रहा"), ("rahe", "रहे"), ("rahungi", "रहूँगी"), ("rahunga", "रहूँगा"),
            ("reh", "रह"), ("rehna", "रहना"), ("rehti", "रहती"), ("rehta", "रहता"), ("gaya", "गया"), ("gayi", "गई"), ("gaye", "गए"), ("gai", "गई"), ("jaana", "जाना"),
            ("jana", "जाना"), ("jaata", "जाता"), ("jata", "जाता"), ("jaati", "जाती"), ("jati", "जाती"), ("jaate", "जाते"), ("jao", "जाओ"), ("jaao", "जाओ"),
            ("jaunga", "जाऊँगा"), ("jaungi", "जाऊँगी"), ("jayega", "जाएगा"), ("jaayega", "जाएगा"), ("jayegi", "जाएगी"), ("aana", "आना"), ("aata", "आता"), ("aati", "आती"),
            ("aate", "आते"), ("aao", "आओ"), ("aaya", "आया"), ("aayi", "आई"), ("aaye", "आए"), ("aaunga", "आऊँगा"), ("aaungi", "आऊँगी"), ("aayega", "आएगा"),
            ("dena", "देना"), ("deta", "देता"), ("deti", "देती"), ("dete", "देते"), ("diya", "दिया"), ("di", "दी"), ("dijiye", "दीजिए"), ("dungi", "दूँगी"),
            ("dunga", "दूँगा"), ("lena", "लेना"), ("leta", "लेता"), ("leti", "लेती"), ("lo", "लो"), ("liya", "लिया"), ("li", "ली"), ("lungi", "लूँगी"), ("lunga", "लूँगा"),
            ("bolna", "बोलना"), ("bolta", "बोलता"), ("bolti", "बोलती"), ("bolo", "बोलो"), ("bola", "बोला"), ("boli", "बोली"), ("boliye", "बोलिए"), ("bolungi", "बोलूँगी"),
            ("sunna", "सुनना"), ("sunta", "सुनता"), ("sunti", "सुनती"), ("suno", "सुनो"), ("suna", "सुना"), ("suni", "सुनी"), ("dekhna", "देखना"), ("dekhta", "देखता"),
            ("dekhti", "देखती"), ("dekho", "देखो"), ("dekha", "देखा"), ("dekhi", "देखी"), ("sochna", "सोचना"), ("sochta", "सोचता"), ("sochti", "सोचती"), ("socho", "सोचो"),
            ("socha", "सोचा"), ("samajh", "समझ"), ("samjho", "समझो"), ("samjha", "समझा"), ("samjhi", "समझी"), ("samajhti", "समझती"), ("batao", "बताओ"), ("bata", "बता"),
            ("batana", "बताना"), ("batati", "बताती"), ("bataya", "बताया"), ("bataiye", "बताइए"), ("pata", "पता"), ("chahiye", "चाहिए"), ("chahti", "चाहती"),
            ("chahta", "चाहता"), ("chahte", "चाहते"), ("sakti", "सकती"), ("sakta", "सकता"), ("sakte", "सकते"), ("sakegi", "सकेगी"), ("lagta", "लगता"), ("lagti", "लगती"),
            ("laga", "लगा"), ("lagi", "लगी"), ("mila", "मिला"), ("mili", "मिली"), ("milte", "मिलते"), ("milenge", "मिलेंगे"), ("milna", "मिलना"), ("chal", "चल"),
            ("chalta", "चलता"), ("chalti", "चलती"), ("chala", "चला"), ("chali", "चली"), ("chaliye", "चलिए"), ("ruko", "रुको"), ("ruk", "रुक"), ("baitho", "बैठो"),
            ("khana", "खाना"), ("pani", "पानी"), ("paani", "पानी"), ("padhna", "पढ़ना"), ("padhai", "पढ़ाई"), ("likhna", "लिखना"), ("khelna", "खेलना"), ("seekhna", "सीखना"),
            ("hansna", "हँसना"), ("hanso", "हँसो"), ("bana", "बना"), ("banaya", "बनाया"), ("banayi", "बनाई"), ("banana", "बनाना"), ("banati", "बनाती"), ("thak", "थक"),
            ("kehna", "कहना"), ("kehti", "कहती"), ("kehta", "कहता"), ("kaho", "कहो"), ("kaha", "कहा"), ("kahi", "कही"), ("puchho", "पूछो"), ("poochho", "पूछो"),
            ("poocha", "पूछा"), ("puchha", "पूछा"), ("jaanti", "जानती"), ("janti", "जानती"), ("jaanta", "जानता"), ("jaante", "जानते"), ("maan", "मान"), ("maanti", "मानती"),
            ("rakh", "रख"), ("rakho", "रखो"), ("bhool", "भूल"), ("yaad", "याद"), ("shukriya", "शुक्रिया"), ("dhanyavaad", "धन्यवाद"), ("namaste", "नमस्ते"),
        ]
        for (roman, devanagari) in entries where table[roman] == nil { table[roman] = devanagari }
        return table
    }()

    /// Verb stems that are also English words ("sun", "pi"), in Devanagari only right before a helper verb: "sun rahi",
    /// "kar sakti", "so gayi".
    static let stems: [String: String] = [
        "sun": "सुन", "kar": "कर", "dekh": "देख", "soch": "सोच", "bol": "बोल", "likh": "लिख", "padh": "पढ़", "khel": "खेल", "chal": "चल", "ruk": "रुक",
        "so": "सो", "kha": "खा", "pi": "पी", "jaa": "जा", "ja": "जा", "aa": "आ", "de": "दे", "le": "ले", "ban": "बन", "samajh": "समझ", "mil": "मिल",
        "hans": "हँस", "ro": "रो", "gaa": "गा", "bata": "बता", "seekh": "सीख", "jeet": "जीत", "haar": "हार",
    ]
    static let helpers: Set<String> = ["rahi", "raha", "rahe", "sakti", "sakta", "sakte", "lo", "liya", "li", "chuki", "chuka", "chuke", "diya", "di",
                                       "dena", "gayi", "gaya", "gaye", "jaati", "jaata", "jao", "lena", "paayi", "payi", "paati", "pati"]

    /// A sentence counts as Hinglish when at least this share of its words are in the table, and at least two of them.
    static let leastHindiShare = 0.3

    /// The sentence for the voice: its Hindi words in Devanagari, English words, names and numbers as written. A sentence
    /// in English, or already in Devanagari, comes back as it was.
    public static func spoken(_ sentence: String) -> String {
        withMainInRoman(spokenInDevanagari(sentence))
    }

    /// How a Roman Hinglish sentence goes to the voice. `mixed`: its known Hindi words in Devanagari, the rest as written.
    /// `whole`: all its Hindi words in Devanagari when every word is either a known Hindi word or an English one, else the
    /// whole sentence in Roman letters, so a sentence is never half and half. `roman`: as written.
    public enum Script: String, Sendable, CaseIterable { case mixed, whole, roman }

    public static func spoken(_ sentence: String, script: Script, isEnglishWord: (String) -> Bool = EnglishWords.contains) -> String {
        switch script {
        case .mixed: return spoken(sentence)
        case .roman: return sentence
        case .whole:
            // "AI" in a Devanagari sentence came back as "hai" (read back through Sarvam's ears, 27 Nov): such a sentence
            // stays in Roman letters, where it's read right.
            if sentence.range(of: #"\bA\.?I\b"#, options: .regularExpression) != nil { return withMainInRoman(sentence) }
            let romanWords = sentence.split(whereSeparator: { !($0.isASCII && $0.isLetter) }).map { $0.lowercased() }
            let unknown = romanWords.filter { words[$0] == nil && stems[$0] == nil && !isEnglishWord($0) }
            return unknown.isEmpty ? spoken(sentence) : sentence
        }
    }

    static func spokenInDevanagari(_ sentence: String) -> String {
        var pieces: [(range: Range<String.Index>, lower: String)] = []
        var start: String.Index?
        var index = sentence.startIndex
        while index < sentence.endIndex {
            let character = sentence[index]
            if character.isASCII && character.isLetter {
                if start == nil { start = index }
            } else if let wordStart = start {
                pieces.append((wordStart..<index, sentence[wordStart..<index].lowercased()))
                start = nil
            }
            index = sentence.index(after: index)
        }
        if let wordStart = start { pieces.append((wordStart..<sentence.endIndex, sentence[wordStart...].lowercased())) }
        guard !pieces.isEmpty else { return sentence }
        let hindi = pieces.filter { words[$0.lower] != nil }.count
        guard hindi >= 2, Double(hindi) / Double(pieces.count) >= leastHindiShare else { return sentence }
        var result = ""
        var cursor = sentence.startIndex
        for piece in pieces {
            result += sentence[cursor..<piece.range.lowerBound]
            let original = String(sentence[piece.range])
            // A capitalised word after the first is a name ("Ambar", "Token Tirri"), unless it's one of the little words.
            let isName = piece.range.lowerBound != pieces[0].range.lowerBound && original.first?.isUppercase == true && original.count > 3
                && !littleWords.contains(piece.lower)
            let next = pieces.firstIndex(where: { $0.range == piece.range }).flatMap { $0 + 1 < pieces.count ? pieces[$0 + 1].lower : nil }
            if !isName, let devanagari = words[piece.lower], devanagari != piece.lower {
                result += devanagari
            } else if !isName, let next, helpers.contains(next), let stem = stems[piece.lower] {
                result += stem
            } else {
                result += original
            }
            cursor = piece.range.upperBound
        }
        result += sentence[cursor...]
        return result
    }

    /// "मैं" as the voice says it best: Sarvam's male voice made it "mey" in a live Space (27 Nov), and Roman "main" was
    /// clearer, so the voice gets "main" for it, written either way.
    static func withMainInRoman(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?<![\p{L}\p{M}])(मैं|मै)(?![\p{L}\p{M}])"#, with: "main", options: .regularExpression)
    }

    static let littleWords: Set<String> = ["main", "haan", "nahi", "nahin", "aur", "kya", "kaise", "theek", "accha", "achha", "chalo", "arre", "bahut", "abhi", "sach"]
}

/// Morse code said out loud in a Space ("dash dot dash dot", "डैश डॉट"): the dots and dashes in the words, in the groups
/// the speaker paused between, and the letters they make. People read it out to test the bot, and it decoded it wrong by
/// itself (a public Space, 26 Nov: "COFOI" for dashes and dots with no pauses heard).
public enum SpokenMorse {
    static let dot: Set<String> = ["dot", "dots", "dit", "डॉट", "डोट", "डॉट्स", "डिट", "ड़ॉट"]
    static let dash: Set<String> = ["dash", "dashes", "dah", "डैश", "डेश", "डाश"]
    static let table: [String: String] = [
        ".-": "A", "-...": "B", "-.-.": "C", "-..": "D", ".": "E", "..-.": "F", "--.": "G", "....": "H", "..": "I", ".---": "J", "-.-": "K",
        ".-..": "L", "--": "M", "-.": "N", "---": "O", ".--.": "P", "--.-": "Q", ".-.": "R", "...": "S", "-": "T", "..-": "U", "...-": "V",
        ".--": "W", "-..-": "X", "-.--": "Y", "--..": "Z", "-----": "0", ".----": "1", "..---": "2", "...--": "3", "....-": "4", ".....": "5",
        "-....": "6", "--...": "7", "---..": "8", "----.": "9",
    ]

    public struct Reading: Equatable, Sendable {
        /// The groups as heard, "-.-." each.
        public let groups: [String]
        /// Each group's letter, "?" for a group that's no letter (two letters run together with no pause heard).
        public let letters: [String]
    }

    /// The Morse in the words, or nil when there's less than three dots and dashes in them. A pause is a full stop, comma,
    /// "।", "space", "gap", "stop" or "slash" between them.
    public static func reading(_ words: String) -> Reading? {
        var groups: [String] = []
        var current = ""
        var symbols = 0
        let separators = CharacterSet(charactersIn: ".,;:।!?|/")
        var token = ""
        func endToken() {
            let lower = token.lowercased()
            if dot.contains(lower) { current += "."; symbols += 1 } else if dash.contains(lower) { current += "-"; symbols += 1 } else if ["space", "gap", "stop", "slash", "pause"].contains(lower), !current.isEmpty {
                groups.append(current); current = ""
            }
            token = ""
        }
        for scalar in words.unicodeScalars {
            if CharacterSet.letters.contains(scalar) || CharacterSet.nonBaseCharacters.contains(scalar) {
                token.unicodeScalars.append(scalar)
            } else {
                if !token.isEmpty { endToken() }
                if separators.contains(scalar), !current.isEmpty { groups.append(current); current = "" }
            }
        }
        if !token.isEmpty { endToken() }
        if !current.isEmpty { groups.append(current) }
        guard symbols >= 3 else { return nil }
        return Reading(groups: groups, letters: groups.map { table[$0] ?? "?" })
    }

    /// The line for the brain, or nil.
    public static func note(_ words: String) -> String? {
        guard let reading = reading(words) else { return nil }
        let decoded = zip(reading.groups, reading.letters).map { "\($0) = \($1)" }.joined(separator: ", ")
        var note = "(Morse code read out in those words, as heard: \(decoded). Spell out the letters you got."
        if reading.letters.contains("?") { note += " A \"?\" is dots and dashes with no pause heard between letters: ask for a short pause after each letter." }
        return note + ")"
    }
}

/// English words, from the Mac's own word list, for telling an English word from Hindi in Roman letters.
public enum EnglishWords {
    static let list: Set<String> = {
        guard let text = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else { return [] }
        var set = Set<String>()
        for line in text.split(separator: "\n") where line.count >= 2 { set.insert(line.lowercased()) }
        // Short everyday words the list leaves out or that read as English anyway.
        for word in ["i", "a", "ok", "okay", "yeah", "lol", "bro", "hey", "hi", "hello", "bye", "sorry", "thanks", "please", "ai", "bot"] { set.insert(word) }
        return set
    }()
    public static func contains(_ word: String) -> Bool { list.contains(word.lowercased()) }
}
