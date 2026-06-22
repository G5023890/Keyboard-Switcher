import AppKit
import Foundation

struct CandidateScore: Equatable {
    let candidate: LayoutCandidate
    let score: Double
}

struct SpellingCorrection: Equatable {
    let original: String
    let replacement: String
    let language: KeyboardLanguage
}

enum SafetyPreflight {
    static func blockReason(for text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lowercased = trimmed.lowercased()
        if let technicalReason = TechnicalTermLexicon.protectionReason(for: trimmed),
           !(technicalReason == "technical delimiter token" && looksLikeLayoutPunctuationToken(trimmed)) {
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

    private static func looksLikeLayoutPunctuationToken(_ text: String) -> Bool {
        guard text.rangeOfCharacter(from: .letters) != nil else { return false }
        if text.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\_@=")) != nil {
            return false
        }

        let strongLayoutPunctuation = CharacterSet(charactersIn: ",;:'\"`‘’“”[]{}<>%^*")
        if text.rangeOfCharacter(from: strongLayoutPunctuation) != nil {
            return true
        }

        return text.hasPrefix(".") || text.hasSuffix(".")
    }
}

final class TextClassifier {
    private static let russianAutoWords = RankedWordList.load(
        resourceName: "ru_auto_core_100k",
        extension: "tsv",
        fallbackWords: []
    )
    private static let englishAutoWords = RankedWordList.load(
        resourceName: "en_auto_core_50k",
        extension: "tsv",
        fallbackWords: []
    )
    private static let russianManualWords = RankedWordList.load(
        resourceName: "ru_manual_extended_300k",
        extension: "tsv",
        fallbackWords: []
    )
    private static let englishManualWords = RankedWordList.load(
        resourceName: "en_manual_extended_200k",
        extension: "tsv",
        fallbackWords: []
    )
    private static let russianShortAutoWords = RankedWordList.loadShortWordWhitelist(
        resourceName: "short_words_auto_whitelist",
        extension: "tsv",
        languageCode: "ru"
    )
    private static let englishShortAutoWords = RankedWordList.loadShortWordWhitelist(
        resourceName: "short_words_auto_whitelist",
        extension: "tsv",
        languageCode: "en"
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

    private let hebrewBuiltInWords: Set<String> = [
        "אני", "את", "אתה", "בוקר", "בית", "גם", "הוא", "היא", "היום", "זה", "טוב", "כן",
        "לא", "לה", "מה", "מבחן", "מקלדת", "עברית", "עם", "שלום", "של", "תודה"
    ]
    private let russianSupplementalTokenWords: Set<String> = [
        "двоеточиями",
        "запятыми",
        "пробела"
    ]

    private let ngrams: [KeyboardLanguage: Set<String>] = [
        .english: ["th", "he", "in", "er", "an", "re", "on", "at", "en", "nd", "ou", "ing", "ion"],
        .russian: ["пр", "ри", "ив", "ве", "ет", "ка", "ак", "де", "ел", "ла", "сп", "па", "ас", "си", "иб", "бо", "чт", "то", "эт", "ст", "ени", "ост"],
        .hebrew: ["של", "לו", "ום", "מה", "תו", "דה", "בר", "ים", "ני", "את"]
    ]

    func score(_ candidate: LayoutCandidate) -> CandidateScore {
        let normalized = candidate.text.lowercased()
        let lexical = lexicalToken(normalized)
        guard !lexical.isEmpty else {
            return CandidateScore(candidate: candidate, score: 0)
        }

        var score = scriptScore(normalized, language: candidate.language)
        score += dictionaryScore(lexical, language: candidate.language)
        score += ngramScore(lexical, language: candidate.language)

        if let safetyReason = correctionSafetyReason(for: normalized),
           safetyReason != "known technical term" {
            score -= 1
        }

        return CandidateScore(candidate: candidate, score: max(0, min(score, 1)))
    }

    func hasStrongLexicalEvidence(_ candidate: LayoutCandidate) -> Bool {
        let normalized = lexicalToken(candidate.text.lowercased())
        guard normalized.count >= 3 else { return false }

        if isCoreShortWord(normalized, language: candidate.language) {
            return true
        }

        if candidate.language == .english, Self.preferredTechnicalSpelling(for: normalized) != nil {
            return true
        }

        if candidate.language == .english, Self.englishAutoWords.contains(normalized) {
            return true
        }

        if candidate.language == .russian, Self.russianAutoWords.contains(normalized) {
            return true
        }

        if candidate.language == .russian, russianSupplementalTokenWords.contains(normalized) {
            return true
        }

        return candidate.language == .hebrew && hebrewBuiltInWords.contains(normalized)
    }

    func hasManualLexicalEvidence(_ candidate: LayoutCandidate) -> Bool {
        let normalized = lexicalToken(candidate.text.lowercased())
        guard normalized.count >= 2 else { return false }

        if hasStrongLexicalEvidence(candidate) {
            return true
        }

        if isManualDictionaryWord(normalized, language: candidate.language) {
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

    func isSpellCheckerValid(_ text: String, language: KeyboardLanguage) -> Bool {
        isCorrectlySpelled(text, language: language)
    }

    func spellingCorrection(for text: String, language: KeyboardLanguage) -> SpellingCorrection? {
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = word.lowercased()

        guard word.count >= 4,
              language != .hebrew,
              !hasSuspiciousMixedCase(word),
              correctionSafetyReason(for: word) == nil,
              TechnicalTermLexicon.protectionReason(for: word) == nil,
              !isCoreShortWord(normalized, language: language),
              !isAutoDictionaryWord(normalized, language: language) else {
            return nil
        }

        if let replacement = systemSpellingReplacement(for: word, language: language) {
            return SpellingCorrection(
                original: word,
                replacement: preserveSimpleCasing(from: word, replacement: replacement),
                language: language
            )
        }

        if let replacement = dictionarySpellingReplacement(for: word, language: language) {
            return SpellingCorrection(
                original: word,
                replacement: preserveSimpleCasing(from: word, replacement: replacement),
                language: language
            )
        }

        return nil
    }

    func isCoreShortWord(_ text: String, language: KeyboardLanguage) -> Bool {
        let normalized = text.lowercased()
        switch language {
        case .english:
            return Self.englishShortAutoWords.contains(normalized)
        case .russian:
            return Self.russianShortAutoWords.contains(normalized)
        case .hebrew:
            return false
        }
    }

    private func isAutoDictionaryWord(_ text: String, language: KeyboardLanguage) -> Bool {
        switch language {
        case .english:
            return Self.englishAutoWords.contains(text)
        case .russian:
            return Self.russianAutoWords.contains(text)
        case .hebrew:
            return false
        }
    }

    private func isManualDictionaryWord(_ text: String, language: KeyboardLanguage) -> Bool {
        switch language {
        case .english:
            return Self.englishManualWords.contains(text)
        case .russian:
            return Self.russianManualWords.contains(text)
        case .hebrew:
            return false
        }
    }

    func isExtendedShortWord(_ text: String, language: KeyboardLanguage) -> Bool {
        let normalized = text.lowercased()
        guard (1...4).contains(normalized.count) else { return false }
        switch language {
        case .english:
            return Self.englishManualWords.contains(normalized) && !Self.englishShortAutoWords.contains(normalized)
        case .russian:
            return Self.russianManualWords.contains(normalized) && !Self.russianShortAutoWords.contains(normalized)
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

        if language == .english, let score = Self.englishAutoWords.score(for: text) {
            return score
        }

        if language == .russian, let score = Self.russianAutoWords.score(for: text) {
            return score
        }

        if language == .russian, russianSupplementalTokenWords.contains(text) {
            return 0.54
        }

        if language == .hebrew, hebrewBuiltInWords.contains(text) {
            return 0.46
        }

        return 0
    }

    private func lexicalToken(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(CharacterSet.symbols))
    }

    private func shortWordDictionaryScore(_ text: String, language: KeyboardLanguage) -> Double? {
        guard (1...4).contains(text.count) else { return nil }

        switch language {
        case .english:
            if let score = Self.englishShortAutoWords.score(for: text) {
                return max(0.46, min(score + 0.08, 0.62))
            }
        case .russian:
            if let score = Self.russianShortAutoWords.score(for: text) {
                return max(0.46, min(score + 0.08, 0.62))
            }
        case .hebrew:
            return nil
        }

        return nil
    }

    private func systemSpellingReplacement(for word: String, language: KeyboardLanguage) -> String? {
        guard let spellLanguage = spellCheckerLanguage(for: language),
              !isCorrectlySpelled(word, language: language) else {
            return nil
        }

        let nsWord = word as NSString
        let range = NSRange(location: 0, length: nsWord.length)
        var guesses = spellChecker.guesses(
            forWordRange: range,
            in: word,
            language: spellLanguage,
            inSpellDocumentWithTag: 0
        ) ?? []
        if let correction = spellChecker.correction(
            forWordRange: range,
            in: word,
            language: spellLanguage,
            inSpellDocumentWithTag: 0
        ) {
            guesses.insert(correction, at: 0)
        }

        let safeGuesses = guesses
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { isSafeSpellingGuess($0, original: word, language: language) }

        guard let replacement = safeGuesses.first else { return nil }
        let uniqueLowercased = Set(safeGuesses.prefix(3).map { $0.lowercased() })
        guard uniqueLowercased.count == 1 || editDistance(word.lowercased(), replacement.lowercased()) <= 1 else {
            return nil
        }

        return replacement
    }

    private func dictionarySpellingReplacement(for word: String, language: KeyboardLanguage) -> String? {
        let normalized = word.lowercased().replacingOccurrences(of: "ё", with: "е")
        guard normalized.count >= 5,
              normalized.count <= 24,
              normalized.rangeOfCharacter(from: CharacterSet.letters.inverted) == nil else {
            return nil
        }

        let maxDistance = maxAllowedSpellingDistance(for: normalized)
        let replacement: String?
        switch language {
        case .english:
            replacement = Self.englishAutoWords.closestWord(to: normalized, maxDistance: maxDistance)
        case .russian:
            replacement = Self.russianAutoWords.closestWord(to: normalized, maxDistance: maxDistance)
        case .hebrew:
            replacement = nil
        }

        guard let replacement,
              replacement != normalized,
              scriptScore(replacement, language: language) >= 0.33 else {
            return nil
        }

        return replacement
    }

    private func ngramScore(_ text: String, language: KeyboardLanguage) -> Double {
        let grams = ngrams[language] ?? []
        guard text.count >= 3, !grams.isEmpty else { return 0 }
        let matches = grams.filter { text.contains($0) }.count
        return min(Double(matches) * 0.04, 0.16)
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

    private func isSafeSpellingGuess(_ guess: String, original: String, language: KeyboardLanguage) -> Bool {
        let normalizedGuess = guess.lowercased()
        let normalizedOriginal = original.lowercased()
        guard !guess.isEmpty,
              normalizedGuess != normalizedOriginal,
              guess.rangeOfCharacter(from: CharacterSet.letters.inverted) == nil,
              guess.count >= 4,
              editDistance(normalizedOriginal, normalizedGuess) <= maxAllowedSpellingDistance(for: original),
              scriptScore(normalizedGuess, language: language) >= 0.33,
              isCorrectlySpelled(guess, language: language) else {
            return false
        }

        if language == .english, Self.preferredTechnicalSpelling(for: normalizedGuess) != nil {
            return false
        }

        return true
    }

    private func hasSuspiciousMixedCase(_ text: String) -> Bool {
        let letters = text.filter { $0.isLetter }
        guard letters.count >= 3 else { return false }
        let hasLowercase = letters.contains { $0.isLowercase }
        let hasUppercase = letters.contains { $0.isUppercase }
        guard hasLowercase && hasUppercase else { return false }
        return text.first?.isUppercase != true
    }

    private func maxAllowedSpellingDistance(for word: String) -> Int {
        word.count <= 5 ? 1 : 2
    }

    private func preserveSimpleCasing(from original: String, replacement: String) -> String {
        if original == original.uppercased() {
            return replacement.uppercased()
        }
        if original.first?.isUppercase == true,
           original.dropFirst() == original.dropFirst().lowercased() {
            return replacement.prefix(1).uppercased() + replacement.dropFirst()
        }
        return replacement
    }

    private func editDistance(_ left: String, _ right: String) -> Int {
        let a = Array(left)
        let b = Array(right)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var previous = Array(0...b.count)
        var current = Array(repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + cost
                )
            }
            swap(&previous, &current)
        }

        return previous[b.count]
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
        if let records = loadNeverCorrectTSVRecords(), !records.isEmpty {
            return records
        }

        return []
    }

    private static func loadNeverCorrectTSVRecords() -> [TechnicalTermRecord]? {
        guard let contents = resourceContents(named: "technical_never_correct", extension: "tsv") else {
            return nil
        }

        let records = contents
            .split(whereSeparator: \.isNewline)
            .dropFirst()
            .map { String($0).components(separatedBy: "\t") }
            .filter { $0.count >= 6 }
            .compactMap { columns -> TechnicalTermRecord? in
                let term = columns[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let normalized = columns[1].trimmingCharacters(in: .whitespacesAndNewlines)
                let category = columns[2].trimmingCharacters(in: .whitespacesAndNewlines)
                let matchType = columns[3].trimmingCharacters(in: .whitespacesAndNewlines)
                let reason = columns[5].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !term.isEmpty, matchType != "regex", !term.hasPrefix("<REGEX:") else { return nil }
                return TechnicalTermRecord(
                    term: term,
                    normalized: normalized.isEmpty ? term.lowercased() : normalized.lowercased(),
                    category: category.isEmpty ? "Technical" : category,
                    reason: reason.isEmpty ? "known technical term" : reason
                )
            }

        return records
    }

    private static func loadRules() -> [TechnicalProtectionRule] {
        if let rules = loadNeverCorrectTSVRules(), !rules.isEmpty {
            return rules
        }

        return []
    }

    private static func loadNeverCorrectTSVRules() -> [TechnicalProtectionRule]? {
        guard let contents = resourceContents(named: "technical_never_correct", extension: "tsv") else {
            return nil
        }

        let rules = contents
            .split(whereSeparator: \.isNewline)
            .dropFirst()
            .map { String($0).components(separatedBy: "\t") }
            .filter { $0.count >= 6 }
            .compactMap { columns -> TechnicalProtectionRule? in
                let term = columns[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let pattern = columns[1].trimmingCharacters(in: .whitespacesAndNewlines)
                let matchType = columns[3].trimmingCharacters(in: .whitespacesAndNewlines)
                let reason = columns[5].trimmingCharacters(in: .whitespacesAndNewlines)
                guard matchType == "regex", !pattern.isEmpty else { return nil }
                return TechnicalProtectionRule(
                    id: term.replacingOccurrences(of: "<REGEX:", with: "").replacingOccurrences(of: ">", with: ""),
                    name: reason.isEmpty ? term : reason,
                    pattern: pattern,
                    priority: 90,
                    notes: reason
                )
            }

        return rules.sorted { $0.priority > $1.priority }
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

        let projectResourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("KeyboardSwitcher")
            .appendingPathComponent("Resources")
            .appendingPathComponent("\(resourceName).\(fileExtension)")
        if let contents = try? String(contentsOf: projectResourceURL, encoding: .utf8) {
            return contents
        }

        return nil
    }

}

private struct RankedWordList {
    let ranks: [String: Int]
    let explicitScores: [String: Double]

    var count: Int {
        ranks.count
    }

    func contains(_ word: String) -> Bool {
        ranks[Self.normalize(word)] != nil
    }

    func score(for word: String) -> Double? {
        let normalizedWord = Self.normalize(word)
        if let explicitScore = explicitScores[normalizedWord] {
            return 0.34 + max(0, min(explicitScore, 1)) * 0.24
        }

        guard let rank = ranks[normalizedWord], count > 1 else { return nil }

        let normalizedRank = log(Double(rank + 1)) / log(Double(count + 1))
        let frequencyWeight = max(0, 1 - normalizedRank)
        return 0.34 + frequencyWeight * 0.20
    }

    func closestWord(to word: String, maxDistance: Int) -> String? {
        let normalizedWord = Self.normalize(word)
        guard normalizedWord.count >= 5,
              maxDistance > 0,
              let firstScalar = normalizedWord.unicodeScalars.first else {
            return nil
        }

        var best: (word: String, distance: Int, rank: Int)?
        for (candidate, rank) in ranks {
            guard candidate.unicodeScalars.first == firstScalar,
                  abs(candidate.count - normalizedWord.count) <= maxDistance else {
                continue
            }

            let distance = Self.editDistance(normalizedWord, candidate, maxDistance: maxDistance)
            guard distance > 0, distance <= maxDistance else { continue }

            if let current = best {
                if distance < current.distance || (distance == current.distance && rank < current.rank) {
                    best = (candidate, distance, rank)
                }
            } else {
                best = (candidate, distance, rank)
            }
        }

        return best?.word
    }

    static func load(
        resourceName: String,
        extension fileExtension: String,
        fallbackWords: [String]
    ) -> RankedWordList {
        if let contents = resourceContents(named: resourceName, extension: fileExtension) {
            return parse(contents: contents, fileExtension: fileExtension)
        }

        return RankedWordList(
            ranks: ranks(from: fallbackWords.map { normalize($0) }),
            explicitScores: [:]
        )
    }

    static func loadShortWordWhitelist(
        resourceName: String,
        extension fileExtension: String,
        languageCode: String
    ) -> RankedWordList {
        if let contents = resourceContents(named: resourceName, extension: fileExtension) {
            let entries = contents
                .split(whereSeparator: \.isNewline)
                .dropFirst()
                .compactMap { line -> (word: String, rank: Int, score: Double)? in
                    let columns = String(line).components(separatedBy: "\t")
                    guard columns.count >= 6, columns[0] == languageCode else { return nil }
                    let word = normalize(columns[1])
                    guard !word.isEmpty else { return nil }
                    return (
                        word: word,
                        rank: Int(columns[3]) ?? Int.max,
                        score: Double(columns[4]) ?? 0
                    )
                }
                .sorted { $0.rank < $1.rank }

            if !entries.isEmpty {
                return RankedWordList(
                    ranks: ranks(from: entries.map(\.word)),
                    explicitScores: scores(from: entries.map { ($0.word, $0.score) })
                )
            }
        }

        return RankedWordList(ranks: [:], explicitScores: [:])
    }

    private static func parse(contents: String, fileExtension: String) -> RankedWordList {
        if fileExtension == "tsv" {
            let entries = parseFrequencyTSV(contents)
            if !entries.isEmpty {
                return RankedWordList(
                    ranks: ranks(from: entries.map(\.word)),
                    explicitScores: scores(from: entries.map { ($0.word, $0.score) })
                )
            }
        }

        let words = contents
            .split(whereSeparator: \.isNewline)
            .map { normalize(String($0)) }
            .filter { !$0.isEmpty }
        return RankedWordList(ranks: ranks(from: words), explicitScores: [:])
    }

    private static func parseFrequencyTSV(_ contents: String) -> [(word: String, score: Double)] {
        contents
            .split(whereSeparator: \.isNewline)
            .dropFirst()
            .compactMap { line -> (word: String, score: Double)? in
                let columns = String(line).components(separatedBy: "\t")
                guard columns.count >= 5 else { return nil }
                let word = normalize(columns[0])
                guard !word.isEmpty else { return nil }
                return (word, Double(columns[4]) ?? 0)
            }
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

        let projectResourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("KeyboardSwitcher")
            .appendingPathComponent("Resources")
            .appendingPathComponent("\(resourceName).\(fileExtension)")
        if let contents = try? String(contentsOf: projectResourceURL, encoding: .utf8) {
            return contents
        }

        return nil
    }

    private static func normalize(_ word: String) -> String {
        word
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}")))
            .lowercased()
            .replacingOccurrences(of: "ё", with: "е")
    }

    private static func ranks(from words: [String]) -> [String: Int] {
        var ranks: [String: Int] = [:]
        for (index, word) in words.enumerated() where ranks[word] == nil {
            ranks[word] = index + 1
        }
        return ranks
    }

    private static func scores(from entries: [(String, Double)]) -> [String: Double] {
        var scores: [String: Double] = [:]
        for entry in entries where scores[entry.0] == nil {
            scores[entry.0] = entry.1
        }
        return scores
    }

    private static func editDistance(_ left: String, _ right: String, maxDistance: Int) -> Int {
        let a = Array(left)
        let b = Array(right)
        if abs(a.count - b.count) > maxDistance {
            return maxDistance + 1
        }
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var previous = Array(0...b.count)
        var current = Array(repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            var rowMinimum = current[0]
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + cost
                )
                rowMinimum = min(rowMinimum, current[j])
            }
            if rowMinimum > maxDistance {
                return maxDistance + 1
            }
            swap(&previous, &current)
        }

        return previous[b.count]
    }
}
