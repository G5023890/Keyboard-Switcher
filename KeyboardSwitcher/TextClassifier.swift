import AppKit
import Foundation
import NaturalLanguage

struct CandidateScore: Equatable {
    let candidate: LayoutCandidate
    let score: Double
}

enum SafetyPreflight {
    static func blockReason(for text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lowercased = trimmed.lowercased()
        if let technicalReason = TechnicalTermLexicon.protectionReason(for: trimmed) {
            return technicalReason
        }
        if lowercased.contains("://") || lowercased.hasPrefix("www.") {
            return "URL-like text"
        }
        if lowercased.contains("@") {
            return "email-like text"
        }
        if lowercased.hasPrefix("~/") || lowercased.hasPrefix("/") || lowercased.contains("\\") {
            return "path-like text"
        }
        if lowercased.contains("/") {
            return "path-like text"
        }
        if lowercased.contains("_") || lowercased.contains("=") || lowercased.contains("{") || lowercased.contains("}") {
            return "code-like text"
        }
        if looksLikeMixedRTLToken(trimmed) {
            return "mixed RTL/LTR text"
        }
        if looksLikeCamelCase(trimmed) || looksLikeIPAddress(trimmed) || looksLikeUUID(trimmed) || looksLikeBundleIdentifier(trimmed) {
            return "code-like text"
        }
        if looksLikeDomainOrFileName(trimmed) {
            return "URL/file-like text"
        }

        return nil
    }

    private static func looksLikeCamelCase(_ text: String) -> Bool {
        guard text.rangeOfCharacter(from: .letters) != nil else { return false }
        let hasLowercase = text.rangeOfCharacter(from: .lowercaseLetters) != nil
        let hasUppercase = text.rangeOfCharacter(from: .uppercaseLetters) != nil
        return hasLowercase && hasUppercase && !text.hasPrefix(text.prefix(1).uppercased())
    }

    private static func looksLikeMixedRTLToken(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard letters.count >= 2 else { return false }

        let hasHebrew = letters.contains { (0x0590...0x05FF).contains(Int($0.value)) }
        let hasLTRScript = letters.contains { scalar in
            ("a"..."z").contains(String(scalar).lowercased()) || (0x0400...0x04FF).contains(Int(scalar.value))
        }

        return hasHebrew && hasLTRScript
    }

    private static func looksLikeIPAddress(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let value = Int(part), value >= 0, value <= 255 else { return false }
            return String(part) == "\(value)"
        }
    }

    private static func looksLikeUUID(_ text: String) -> Bool {
        let parts = text.split(separator: "-")
        guard parts.map(\.count) == [8, 4, 4, 4, 12] else { return false }
        let hex = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        return text.unicodeScalars.allSatisfy { scalar in
            scalar == "-" || hex.contains(scalar)
        }
    }

    private static func looksLikeBundleIdentifier(_ text: String) -> Bool {
        let parts = text.split(separator: ".")
        guard parts.count >= 3 else { return false }
        return parts.allSatisfy { part in
            part.rangeOfCharacter(from: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-").inverted) == nil
        }
    }

    private static func looksLikeDomainOrFileName(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        let commonSuffixes = [
            ".app", ".com", ".dev", ".html", ".io", ".json", ".net", ".org", ".plist", ".ru", ".swift", ".txt", ".xml"
        ]

        guard commonSuffixes.contains(where: lowercased.hasSuffix) else { return false }
        return lowercased.range(of: #"[a-z0-9][a-z0-9-]*\.[a-z0-9][a-z0-9.-]*$"#, options: .regularExpression) != nil
    }
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
    private static let russianShortCoreWords = RankedWordList.load(
        resourceName: "short-ru-core-1-4",
        extension: "txt",
        fallbackWords: []
    )
    private static let russianShortExtendedWords = RankedWordList.load(
        resourceName: "short-ru-extended-1-4",
        extension: "txt",
        fallbackWords: []
    )
    private static let englishShortCoreWords = RankedWordList.load(
        resourceName: "short-en-core-1-4",
        extension: "txt",
        fallbackWords: []
    )
    private static let englishShortExtendedWords = RankedWordList.load(
        resourceName: "short-en-extended-1-4",
        extension: "txt",
        fallbackWords: []
    )
    private static let builtInTechnicalTermsByNormalizedText: [String: String] = [
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

        if let safetyReason = correctionSafetyReason(for: normalized),
           safetyReason != "known technical term" {
            score -= 1
        }

        return CandidateScore(candidate: candidate, score: max(0, min(score, 1)))
    }

    func hasStrongLexicalEvidence(_ candidate: LayoutCandidate) -> Bool {
        let normalized = candidate.text.lowercased()
        guard normalized.count >= 3 else { return false }

        if isCoreShortWord(normalized, language: candidate.language) {
            return true
        }

        if candidate.language == .english, Self.preferredTechnicalSpelling(for: normalized) != nil {
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

    func hasManualLexicalEvidence(_ candidate: LayoutCandidate) -> Bool {
        let normalized = candidate.text.lowercased()
        guard normalized.count >= 2 else { return false }

        if hasStrongLexicalEvidence(candidate) {
            return true
        }

        return isExtendedShortWord(normalized, language: candidate.language)
    }

    func looksUnsafeForCorrection(_ text: String) -> Bool {
        SafetyPreflight.blockReason(for: text) != nil
    }

    func correctionSafetyReason(for text: String) -> String? {
        SafetyPreflight.blockReason(for: text)
    }

    func preferredSpelling(for text: String, language: KeyboardLanguage) -> String {
        let normalized = text.lowercased()
        if language == .english, let preferred = Self.preferredTechnicalSpelling(for: normalized) {
            return preferred
        }
        return text
    }

    func hasPreferredSpelling(for text: String, language: KeyboardLanguage) -> Bool {
        language == .english && Self.preferredTechnicalSpelling(for: text.lowercased()) != nil
    }

    func isCoreShortWord(_ text: String, language: KeyboardLanguage) -> Bool {
        let normalized = text.lowercased()
        switch language {
        case .english:
            return Self.englishShortCoreWords.contains(normalized)
        case .russian:
            return Self.russianShortCoreWords.contains(normalized)
        case .hebrew:
            return false
        }
    }

    func isExtendedShortWord(_ text: String, language: KeyboardLanguage) -> Bool {
        let normalized = text.lowercased()
        switch language {
        case .english:
            return Self.englishShortExtendedWords.contains(normalized)
        case .russian:
            return Self.russianShortExtendedWords.contains(normalized)
        case .hebrew:
            return false
        }
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
        if language == .english, Self.preferredTechnicalSpelling(for: text) != nil {
            return 0.56
        }

        if let shortScore = shortWordDictionaryScore(text, language: language) {
            return shortScore
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

    private func shortWordDictionaryScore(_ text: String, language: KeyboardLanguage) -> Double? {
        guard (1...4).contains(text.count) else { return nil }

        switch language {
        case .english:
            if let score = Self.englishShortCoreWords.score(for: text) {
                return max(0.46, min(score + 0.08, 0.62))
            }
            if let score = Self.englishShortExtendedWords.score(for: text) {
                return max(0.20, min(score * 0.55, 0.34))
            }
        case .russian:
            if let score = Self.russianShortCoreWords.score(for: text) {
                return max(0.46, min(score + 0.08, 0.62))
            }
            if let score = Self.russianShortExtendedWords.score(for: text) {
                return max(0.20, min(score * 0.55, 0.34))
            }
        case .hebrew:
            return nil
        }

        return nil
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

    private static func preferredTechnicalSpelling(for normalized: String) -> String? {
        TechnicalTermLexicon.preferredSpelling(for: normalized)
            ?? builtInTechnicalTermsByNormalizedText[normalized]
    }
}

struct TechnicalTermRecord: Equatable, Hashable, Identifiable {
    let term: String
    let normalized: String
    let category: String
    let reason: String

    var id: String { normalized }
}

struct TechnicalProtectionRule: Equatable, Hashable, Identifiable {
    let id: String
    let name: String
    let pattern: String
    let priority: Int
    let notes: String
}

enum TechnicalTermLexicon {
    static let records: [TechnicalTermRecord] = loadTermRecords()
    static let rules: [TechnicalProtectionRule] = loadRules()
    static let terms: [String] = records.map(\.term)

    private static let preferredByNormalized: [String: String] = {
        var values: [String: String] = [:]
        for record in records where values[record.normalized] == nil {
            values[record.normalized] = record.term
        }
        return values
    }()

    static func preferredSpelling(for normalized: String) -> String? {
        preferredByNormalized[normalized.lowercased()]
    }

    static func contains(_ text: String) -> Bool {
        preferredSpelling(for: text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) != nil
    }

    static func protectionReason(for text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if contains(trimmed) {
            return "known technical term"
        }
        if looksLikeURLOrIdentityToken(trimmed) {
            return "URL/email/handle-like technical text"
        }
        if looksLikeCommandLineFlag(trimmed) {
            return "command-line flag"
        }
        if looksLikeSemanticVersion(trimmed) {
            return "version-like technical text"
        }
        if looksLikeTechnicalDelimiterToken(trimmed) {
            return "technical delimiter token"
        }
        if looksLikeAllCapsAcronym(trimmed) {
            return "technical acronym"
        }
        if looksLikeMixedCaseIdentifier(trimmed) {
            return "technical mixed-case token"
        }
        if looksLikeLetterDigitToken(trimmed) {
            return "technical alphanumeric token"
        }

        return nil
    }

    private static func looksLikeMixedCaseIdentifier(_ text: String) -> Bool {
        guard text.range(of: #"^[A-Za-z][A-Za-z0-9]*$"#, options: .regularExpression) != nil else {
            return false
        }
        let characters = Array(text)
        guard characters.contains(where: { $0.isLowercase }) else { return false }
        return characters.dropFirst().contains { $0.isUppercase }
    }

    private static func looksLikeAllCapsAcronym(_ text: String) -> Bool {
        guard (2...5).contains(text.count) else { return false }
        return text.range(of: #"^[A-ZА-ЯЁ]{2,}[0-9]*$"#, options: .regularExpression) != nil
    }

    private static func looksLikeTechnicalDelimiterToken(_ text: String) -> Bool {
        guard text.range(of: #"[./_:-]"#, options: .regularExpression) != nil else { return false }
        if text.range(of: #"^\.[A-Za-z0-9]{1,12}$"#, options: .regularExpression) != nil {
            return true
        }
        if text.range(of: #"^[A-Za-z][A-Za-z0-9-]*(\.[A-Za-z0-9-]+){2,}$"#, options: .regularExpression) != nil {
            return true
        }
        return text.range(of: #"[A-Za-z0-9][A-Za-z0-9._:/-]*[A-Za-z0-9]"#, options: .regularExpression) != nil
    }

    private static func looksLikeSemanticVersion(_ text: String) -> Bool {
        text.range(of: #"^v?\d+(\.\d+){1,3}([\-+][A-Za-z0-9.]+)?$"#, options: .regularExpression) != nil
    }

    private static func looksLikeLetterDigitToken(_ text: String) -> Bool {
        text.range(of: #"^(?=.*[A-Za-zА-Яа-яЁё])(?=.*\d)[A-Za-zА-Яа-яЁё0-9._-]+$"#, options: .regularExpression) != nil
    }

    private static func looksLikeCommandLineFlag(_ text: String) -> Bool {
        text.range(of: #"^-{1,2}[A-Za-z0-9][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil
    }

    private static func looksLikeURLOrIdentityToken(_ text: String) -> Bool {
        text.range(of: #"^(https?://\S+|\S+@\S+\.\S+|@[A-Za-z0-9_]+|#[A-Za-z0-9_]+)$"#, options: .regularExpression) != nil
    }

    private static func loadTermRecords() -> [TechnicalTermRecord] {
        guard let contents = resourceContents(named: "technical-terms-ui", extension: "csv") else {
            return loadTermsFromText()
        }

        let records = contents
            .split(whereSeparator: \.isNewline)
            .dropFirst()
            .map { parseCSVLine(String($0)) }
            .filter { $0.count >= 7 }
            .map { columns in
                TechnicalTermRecord(
                    term: columns[0],
                    normalized: columns[1].lowercased(),
                    category: columns[2],
                    reason: columns[6]
                )
            }

        return records.isEmpty ? loadTermsFromText() : records
    }

    private static func loadTermsFromText() -> [TechnicalTermRecord] {
        guard let contents = resourceContents(named: "technical-terms-ui", extension: "txt") else { return [] }
        return contents
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map {
                TechnicalTermRecord(
                    term: $0,
                    normalized: $0.lowercased(),
                    category: "Technical",
                    reason: "known technical term"
                )
            }
    }

    private static func loadRules() -> [TechnicalProtectionRule] {
        guard let contents = resourceContents(named: "technical-terms-ui-rules", extension: "csv") else {
            return []
        }

        return contents
            .split(whereSeparator: \.isNewline)
            .dropFirst()
            .map { parseCSVLine(String($0)) }
            .compactMap { columns in
                guard columns.count >= 6 else { return nil }
                return TechnicalProtectionRule(
                    id: columns[0],
                    name: columns[1],
                    pattern: columns[2],
                    priority: Int(columns[4]) ?? 0,
                    notes: columns[5]
                )
            }
            .sorted { $0.priority > $1.priority }
    }

    private static func resourceContents(named resourceName: String, extension fileExtension: String) -> String? {
        let bundles = [
            Bundle.main,
            Bundle(for: TextClassifier.self)
        ]

        for bundle in bundles {
            guard let url = bundle.url(forResource: resourceName, withExtension: fileExtension),
                  let contents = try? String(contentsOf: url, encoding: .utf8) else {
                continue
            }
            return contents
        }

        return nil
    }

    private static func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var isQuoted = false
        let characters = Array(line)
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                if isQuoted, index + 1 < characters.count, characters[index + 1] == "\"" {
                    current.append("\"")
                    index += 1
                } else {
                    isQuoted.toggle()
                }
            } else if character == ",", !isQuoted {
                fields.append(cleanCSVField(current))
                current = ""
            } else {
                current.append(character)
            }
            index += 1
        }

        fields.append(cleanCSVField(current))
        return fields
    }

    private static func cleanCSVField(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}")))
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
