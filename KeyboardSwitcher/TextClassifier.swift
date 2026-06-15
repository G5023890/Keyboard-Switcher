import AppKit
import Foundation
import NaturalLanguage

struct CandidateScore: Equatable {
    let candidate: LayoutCandidate
    let score: Double
}

final class TextClassifier {
    private static let russianFrequencyWords = RankedWordList.load(
        resourceName: "russian-frequency-50000",
        extension: "txt",
        fallbackWords: []
    )
    private static let englishCommonWords = RankedWordList.load(
        resourceName: "english-common-5000",
        extension: "txt",
        fallbackWords: []
    )
    private static let technicalTermsByNormalizedText: [String: String] = [
        "airplay": "AirPlay",
        "appkit": "AppKit",
        "apple": "Apple",
        "applescript": "AppleScript",
        "chatgpt": "ChatGPT",
        "coredata": "CoreData",
        "coreml": "CoreML",
        "foundation": "Foundation",
        "ios": "iOS",
        "ipados": "iPadOS",
        "iphone": "iPhone",
        "macbook": "MacBook",
        "macos": "macOS",
        "openai": "OpenAI",
        "swift": "Swift",
        "swiftui": "SwiftUI",
        "testflight": "TestFlight",
        "tvos": "tvOS",
        "uikit": "UIKit",
        "watchos": "watchOS",
        "xcode": "Xcode"
    ]

    private let spellChecker = NSSpellChecker.shared

    private let frequentWords: [KeyboardLanguage: Set<String>] = [
        .english: [
            "a", "about", "after", "all", "also", "and", "are", "as", "at", "be", "because", "but",
            "can", "day", "do", "for", "from", "good", "have", "hello", "how", "i", "if", "in",
            "is", "it", "keyboard", "language", "not", "of", "on", "or", "switch", "test", "that",
            "the", "this", "to", "was", "we", "what", "with", "word", "you"
        ],
        .russian: [
            "а", "автоматически", "адрес", "без", "больше", "будет", "буду", "будем", "будут",
            "бы", "было", "быстро", "в", "вам", "вас", "ваш", "верно", "весь", "вместе", "во",
            "вопрос", "время", "все", "всегда", "всего", "вчера", "вы", "где", "главное", "год",
            "да", "давай", "даже", "дальше", "два", "дела", "делать", "день", "для", "до",
            "добрый", "должно", "дома", "его", "если", "есть", "еще", "жду", "же", "журнал", "завтра",
            "здесь", "знаю", "и", "из", "или", "именно", "их", "к", "как", "какой", "когда",
            "клавиатура", "кнопка", "код", "который", "куда", "лучше", "меню", "место", "мне",
            "может", "можно", "мой", "мы", "на", "надо", "назад", "нам", "написать", "например",
            "настроить", "не", "него", "нее", "нет", "нужно", "но", "новый", "обратно", "окно",
            "он", "она", "они", "оно", "очень", "передача", "переключить", "плохо", "по",
            "пока", "получилось", "почему", "правильно", "привет", "программа", "работает",
            "раз", "раскладка", "режим", "рядом", "с", "сработало", "сейчас", "сегодня", "слово", "слова",
            "сделать", "спасибо", "сразу", "так", "также", "там", "тебе", "текст", "теперь",
            "тест", "то", "тоже", "только", "тут", "у", "уже", "хорошо", "хочу", "что",
            "чтобы", "эхо", "это", "этот", "юлия", "я"
        ],
        .hebrew: [
            "אני", "את", "אתה", "בוקר", "בית", "גם", "הוא", "היא", "היום", "זה", "טוב", "כן",
            "לא", "לה", "מה", "מבחן", "מקלדת", "עברית", "עם", "שלום", "של", "תודה"
        ]
    ]

    private let ngrams: [KeyboardLanguage: Set<String>] = [
        .english: ["th", "he", "in", "er", "an", "re", "on", "at", "en", "nd", "ou", "ing", "ion"],
        .russian: ["пр", "ри", "ив", "ве", "ет", "ка", "ак", "де", "ел", "ла", "сп", "па", "ас", "си", "иб", "бо", "чт", "то", "эт", "ст", "ени", "ост"],
        .hebrew: ["של", "לו", "ום", "מה", "תו", "דה", "בר", "ים", "ני", "את"]
    ]

    func score(_ candidate: LayoutCandidate) -> CandidateScore {
        let normalized = candidate.text.lowercased()
        guard !normalized.isEmpty else {
            return CandidateScore(candidate: candidate, score: 0)
        }

        var score = scriptScore(normalized, language: candidate.language)
        score += dictionaryScore(normalized, language: candidate.language)
        score += ngramScore(normalized, language: candidate.language)
        score += naturalLanguageScore(normalized, language: candidate.language)
        score += spellCheckerScore(candidate.text, language: candidate.language)

        if looksUnsafeForCorrection(normalized) {
            score -= 1
        }

        return CandidateScore(candidate: candidate, score: max(0, min(score, 1)))
    }

    func hasStrongLexicalEvidence(_ candidate: LayoutCandidate) -> Bool {
        let normalized = candidate.text.lowercased()
        guard normalized.count >= 3 else { return false }

        if candidate.language == .english, Self.technicalTermsByNormalizedText[normalized] != nil {
            return true
        }

        if candidate.language == .english, Self.englishCommonWords.contains(normalized) {
            return true
        }

        if candidate.language == .russian, Self.russianFrequencyWords.contains(normalized) {
            return true
        }

        if isCorrectlySpelled(candidate.text, language: candidate.language) {
            return true
        }

        if frequentWords[candidate.language]?.contains(normalized) == true {
            return true
        }

        let words = frequentWords[candidate.language] ?? []
        return normalized.count >= 5 && words.contains { word in
            word.count >= 5 && (word.hasPrefix(normalized) || normalized.hasPrefix(word))
        }
    }

    func looksUnsafeForCorrection(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        return lowercased.contains("://")
            || lowercased.contains("@")
            || lowercased.contains("/")
            || lowercased.contains("\\")
            || lowercased.contains("~")
            || lowercased.contains("_")
            || lowercased.contains("=")
            || lowercased.contains("{")
            || lowercased.contains("}")
            || lowercased.hasPrefix("www.")
            || lowercased.hasSuffix(".com")
            || lowercased.hasSuffix(".ru")
            || lowercased.hasSuffix(".dev")
    }

    func preferredSpelling(for text: String, language: KeyboardLanguage) -> String {
        let normalized = text.lowercased()
        if language == .english, let preferred = Self.technicalTermsByNormalizedText[normalized] {
            return preferred
        }
        return text
    }

    private func scriptScore(_ text: String, language: KeyboardLanguage) -> Double {
        let scalars = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !scalars.isEmpty else { return 0 }

        let matching = scalars.filter { scalar in
            switch language {
            case .english:
                return ("a"..."z").contains(String(scalar).lowercased())
            case .russian:
                return (0x0400...0x04FF).contains(Int(scalar.value))
            case .hebrew:
                return (0x0590...0x05FF).contains(Int(scalar.value))
            }
        }

        return Double(matching.count) / Double(scalars.count) * 0.34
    }

    private func dictionaryScore(_ text: String, language: KeyboardLanguage) -> Double {
        if language == .english, Self.technicalTermsByNormalizedText[text] != nil {
            return 0.56
        }

        if language == .english, let score = Self.englishCommonWords.score(for: text) {
            return score
        }

        if language == .russian, let score = Self.russianFrequencyWords.score(for: text) {
            return score
        }

        if frequentWords[language]?.contains(text) == true {
            return 0.46
        }

        if text.count <= 2 {
            return 0
        }

        let words = frequentWords[language] ?? []
        if words.contains(where: { word in word.hasPrefix(text) || text.hasPrefix(word) }) {
            return 0.12
        }

        return 0
    }

    private func spellCheckerScore(_ text: String, language: KeyboardLanguage) -> Double {
        isCorrectlySpelled(text, language: language) ? 0.12 : 0
    }

    private func ngramScore(_ text: String, language: KeyboardLanguage) -> Double {
        let grams = ngrams[language] ?? []
        guard text.count >= 3, !grams.isEmpty else { return 0 }
        let matches = grams.filter { text.contains($0) }.count
        return min(Double(matches) * 0.04, 0.16)
    }

    private func naturalLanguageScore(_ text: String, language: KeyboardLanguage) -> Double {
        guard text.count >= 4 else { return 0 }

        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.english, .russian, .hebrew]
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
        return (hypotheses[nlLanguage(for: language)] ?? 0) * 0.14
    }

    private func isCorrectlySpelled(_ text: String, language: KeyboardLanguage) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= 4, let spellLanguage = spellCheckerLanguage(for: language) else { return false }

        let nsRange = NSRange(location: 0, length: (normalized as NSString).length)
        let misspelledRange = spellChecker.checkSpelling(
            of: normalized,
            startingAt: 0,
            language: spellLanguage,
            wrap: false,
            inSpellDocumentWithTag: 0,
            wordCount: nil
        )
        return misspelledRange.location == NSNotFound || misspelledRange.location >= nsRange.length
    }

    private func spellCheckerLanguage(for language: KeyboardLanguage) -> String? {
        let available = spellChecker.availableLanguages
        let prefixes: [String]
        switch language {
        case .english:
            prefixes = ["en"]
        case .russian:
            prefixes = ["ru"]
        case .hebrew:
            prefixes = ["he", "iw"]
        }

        return available.first { candidate in
            prefixes.contains { candidate.lowercased().hasPrefix($0) }
        }
    }

    private func nlLanguage(for language: KeyboardLanguage) -> NLLanguage {
        switch language {
        case .english: .english
        case .russian: .russian
        case .hebrew: .hebrew
        }
    }
}

private struct RankedWordList {
    let ranks: [String: Int]

    var count: Int {
        ranks.count
    }

    func contains(_ word: String) -> Bool {
        ranks[word] != nil
    }

    func score(for word: String) -> Double? {
        guard let rank = ranks[word], count > 1 else { return nil }

        let normalizedRank = log(Double(rank + 1)) / log(Double(count + 1))
        let frequencyWeight = max(0, 1 - normalizedRank)
        return 0.34 + frequencyWeight * 0.20
    }

    static func load(resourceName: String, extension fileExtension: String, fallbackWords: [String]) -> RankedWordList {
        let bundles = [
            Bundle.main,
            Bundle(for: TextClassifier.self)
        ]

        for bundle in bundles {
            guard let url = bundle.url(forResource: resourceName, withExtension: fileExtension),
                  let contents = try? String(contentsOf: url, encoding: .utf8) else {
                continue
            }

            let words = contents
                .split(whereSeparator: \.isNewline)
                .map { String($0).lowercased() }
                .filter { !$0.isEmpty }

                return RankedWordList(ranks: ranks(from: words))
            }

            return RankedWordList(ranks: ranks(from: fallbackWords.map { $0.lowercased() }))
        }

        private static func ranks(from words: [String]) -> [String: Int] {
            var ranks: [String: Int] = [:]
            for (index, word) in words.enumerated() where ranks[word] == nil {
                ranks[word] = index + 1
            }
            return ranks
        }
    }
