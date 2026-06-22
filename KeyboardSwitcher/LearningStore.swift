import Foundation

struct LearnedCorrection: Codable, Equatable {
    let original: String
    let replacement: String
    let language: KeyboardLanguage
    var uses: Int
    var updatedAt: Date
}

struct SuppressedCorrection: Codable, Equatable {
    let original: String
    let replacement: String
    var undoCount: Int
    var updatedAt: Date
    var expiresAt: Date?

    var isPersistent: Bool {
        expiresAt == nil
    }

    func isActive(at date: Date) -> Bool {
        guard let expiresAt else { return true }
        return expiresAt > date
    }
}

struct LearningBackup: Codable, Equatable {
    let version: Int
    let exportedAt: Date
    let learnedCorrections: [LearnedCorrection]
    let suppressedCorrections: [SuppressedCorrection]
}

struct LearningImportResult: Equatable {
    let importedLearnedCorrections: Int
    let importedSuppressions: Int
}

struct LearnedCorrectionValidation: Equatable {
    enum Severity: Equatable {
        case valid
        case blocked
    }

    let severity: Severity
    let reasons: [String]

    static let valid = LearnedCorrectionValidation(severity: .valid, reasons: [])

    var canStore: Bool {
        severity == .valid
    }

    var isSuspicious: Bool {
        severity != .valid
    }

    var message: String {
        reasons.joined(separator: " ")
    }
}

enum LearnedCorrectionValidator {
    private static let allowedReplacementPunctuation = CharacterSet(charactersIn: "'’")

    static func validate(
        original: String,
        replacement: String,
        language: KeyboardLanguage
    ) -> LearnedCorrectionValidation {
        let original = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        var reasons: [String] = []

        if original.isEmpty {
            reasons.append("Typed form is empty.")
        }
        if replacement.isEmpty {
            reasons.append("Replacement is empty.")
        }
        if normalized(original) == normalized(replacement), !original.isEmpty {
            reasons.append("Typed form and replacement are the same.")
        }
        if original.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            reasons.append("Typed form must be one word.")
        }
        if replacement.rangeOfCharacter(from: .newlines) != nil {
            reasons.append("Replacement must not contain line breaks.")
        }

        if !replacement.isEmpty, containsUnsafeReplacementScalar(replacement) {
            reasons.append("Replacement contains punctuation or separators.")
        }

        if !replacement.isEmpty {
            let detectedLanguage = LayoutEngine.detectScriptLanguage(for: replacement)
            if detectedLanguage != language {
                reasons.append("Replacement does not match \(language.displayName).")
            }
        }

        if !original.isEmpty, !replacement.isEmpty, !isReplayConsistent(original: original, replacement: replacement, language: language) {
            reasons.append("Typed form does not replay cleanly to the replacement.")
        }

        if reasons.isEmpty, !hasLexicalEvidence(replacement: replacement, language: language) {
            reasons.append("Replacement is not recognized by the bundled dictionaries.")
        }

        guard reasons.isEmpty else {
            return LearnedCorrectionValidation(severity: .blocked, reasons: reasons)
        }
        return .valid
    }

    static func validate(_ correction: LearnedCorrection) -> LearnedCorrectionValidation {
        validate(original: correction.original, replacement: correction.replacement, language: correction.language)
    }

    private static func containsUnsafeReplacementScalar(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            if CharacterSet.letters.contains(scalar) { return false }
            if CharacterSet.whitespaces.contains(scalar) { return false }
            if allowedReplacementPunctuation.contains(scalar) { return false }
            return true
        }
    }

    private static func isReplayConsistent(
        original: String,
        replacement: String,
        language: KeyboardLanguage
    ) -> Bool {
        guard let strokes = LayoutEngine.mixedLayoutStrokes(for: original) else { return false }
        let expected = normalizedForReplay(replacement)
        return LayoutEngine
            .candidates(for: strokes, enabledLanguages: [language])
            .contains { normalizedForReplay($0.text) == expected }
    }

    private static func hasLexicalEvidence(replacement: String, language: KeyboardLanguage) -> Bool {
        if language == .hebrew {
            return true
        }

        let words = replacement
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)

        guard !words.isEmpty else { return false }
        let classifier = TextClassifier()

        return words.allSatisfy { word in
            let candidate = LayoutCandidate(language: language, text: word)
            return classifier.isCoreShortWord(word, language: language)
                || classifier.hasManualLexicalEvidence(candidate)
                || classifier.hasStrongLexicalEvidence(candidate)
        }
    }

    private static func normalized(_ text: String) -> String {
        normalizedForReplay(text)
    }

    private static func normalizedForReplay(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "ё", with: "е")
    }
}

final class LearningStore: @unchecked Sendable {
    static let shared = LearningStore()

    private let defaults: UserDefaults
    private let preferencesKey = "learnedCorrections"
    private let suppressionsKey = "suppressedCorrections"
    private let lock = NSLock()
    private var preferences: [String: LearnedCorrection]
    private var suppressions: [String: SuppressedCorrection]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preferences = Self.loadPreferences(defaults: defaults, key: preferencesKey)
        suppressions = Self.loadSuppressions(defaults: defaults, key: suppressionsKey)
    }

    func preference(for original: String) -> LearnedCorrection? {
        lock.withLock {
            preferences[Self.normalized(original)]
        }
    }

    func allPreferences() -> [LearnedCorrection] {
        lock.withLock {
            preferences.values.sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    func isSuppressed(original: String, replacement: String, now: Date = Date()) -> Bool {
        lock.withLock {
            let key = Self.pairKey(original: original, replacement: replacement)
            guard let suppression = suppressions[key] else { return false }
            if suppression.isActive(at: now) {
                return true
            }
            suppressions.removeValue(forKey: key)
            save()
            return false
        }
    }

    func recordPreference(original: String, replacement: String, language: KeyboardLanguage) {
        guard LearnedCorrectionValidator
            .validate(original: original, replacement: replacement, language: language)
            .canStore else { return }

        let original = Self.normalized(original)
        let normalizedReplacement = Self.normalized(replacement)
        let storedReplacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty, !storedReplacement.isEmpty, original != normalizedReplacement else { return }

        lock.withLock {
            let key = Self.key(for: original)
            var correction = preferences[key] ?? LearnedCorrection(
                original: original,
                replacement: storedReplacement,
                language: language,
                uses: 0,
                updatedAt: Date()
            )
            correction = LearnedCorrection(
                original: original,
                replacement: storedReplacement,
                language: language,
                uses: correction.uses + 1,
                updatedAt: Date()
            )
            preferences[key] = correction
            suppressions.removeValue(forKey: Self.pairKey(original: original, replacement: storedReplacement))
            save()
        }
    }

    func setPreference(original: String, replacement: String, language: KeyboardLanguage) {
        guard LearnedCorrectionValidator
            .validate(original: original, replacement: replacement, language: language)
            .canStore else { return }

        let original = Self.normalized(original)
        let normalizedReplacement = Self.normalized(replacement)
        let storedReplacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty, !storedReplacement.isEmpty, original != normalizedReplacement else { return }

        lock.withLock {
            preferences[Self.key(for: original)] = LearnedCorrection(
                original: original,
                replacement: storedReplacement,
                language: language,
                uses: preferences[Self.key(for: original)]?.uses ?? 0,
                updatedAt: Date()
            )
            suppressions.removeValue(forKey: Self.pairKey(original: original, replacement: storedReplacement))
            save()
        }
    }

    func suppress(original: String, replacement: String, now: Date = Date()) {
        let original = Self.normalized(original)
        let replacement = Self.normalized(replacement)
        guard !original.isEmpty, !replacement.isEmpty else { return }

        lock.withLock {
            let key = Self.pairKey(original: original, replacement: replacement)
            let undoCount = (suppressions[key]?.undoCount ?? 0) + 1
            let expiresAt = undoCount >= 3 ? nil : now.addingTimeInterval(24 * 60 * 60)
            preferences.removeValue(forKey: Self.key(for: original))
            suppressions[key] = SuppressedCorrection(
                original: original,
                replacement: replacement,
                undoCount: undoCount,
                updatedAt: now,
                expiresAt: expiresAt
            )
            save()
        }
    }

    func suppressPersistently(original: String, replacement: String, now: Date = Date()) {
        let original = Self.normalized(original)
        let replacement = Self.normalized(replacement)
        guard !original.isEmpty, !replacement.isEmpty else { return }

        lock.withLock {
            let key = Self.pairKey(original: original, replacement: replacement)
            preferences.removeValue(forKey: Self.key(for: original))
            suppressions[key] = SuppressedCorrection(
                original: original,
                replacement: replacement,
                undoCount: max(suppressions[key]?.undoCount ?? 0, 3),
                updatedAt: now,
                expiresAt: nil
            )
            save()
        }
    }

    func allSuppressions(now: Date = Date()) -> [SuppressedCorrection] {
        lock.withLock {
            purgeExpiredSuppressions(now: now)
            return suppressions.values.sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    func removePreference(original: String) {
        let original = Self.normalized(original)
        guard !original.isEmpty else { return }

        lock.withLock {
            preferences.removeValue(forKey: Self.key(for: original))
            save()
        }
    }

    func removeSuppression(original: String, replacement: String) {
        let original = Self.normalized(original)
        let replacement = Self.normalized(replacement)
        guard !original.isEmpty, !replacement.isEmpty else { return }

        lock.withLock {
            suppressions.removeValue(forKey: Self.pairKey(original: original, replacement: replacement))
            save()
        }
    }

    func reset() {
        lock.withLock {
            preferences.removeAll()
            suppressions.removeAll()
            save()
        }
    }

    func exportBackupData(now: Date = Date()) throws -> Data {
        let backup = lock.withLock {
            LearningBackup(
                version: 1,
                exportedAt: now,
                learnedCorrections: preferences.values.sorted { $0.updatedAt > $1.updatedAt },
                suppressedCorrections: suppressions.values.sorted { $0.updatedAt > $1.updatedAt }
            )
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(backup)
    }

    @discardableResult
    func importBackupData(_ data: Data) throws -> LearningImportResult {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(LearningBackup.self, from: data)

        return lock.withLock {
            var importedPreferences = 0
            var importedSuppressions = 0

            for correction in backup.learnedCorrections {
                let original = Self.normalized(correction.original)
                let replacement = correction.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !original.isEmpty,
                      !replacement.isEmpty,
                      original != Self.normalized(replacement),
                      LearnedCorrectionValidator
                          .validate(original: original, replacement: replacement, language: correction.language)
                          .canStore else {
                    continue
                }

                let key = Self.key(for: original)
                if shouldReplace(existingDate: preferences[key]?.updatedAt, importedDate: correction.updatedAt) {
                    preferences[key] = LearnedCorrection(
                        original: original,
                        replacement: replacement,
                        language: correction.language,
                        uses: max(0, correction.uses),
                        updatedAt: correction.updatedAt
                    )
                    suppressions.removeValue(forKey: Self.pairKey(original: original, replacement: replacement))
                    importedPreferences += 1
                }
            }

            for suppression in backup.suppressedCorrections {
                let original = Self.normalized(suppression.original)
                let replacement = Self.normalized(suppression.replacement)
                guard !original.isEmpty, !replacement.isEmpty else {
                    continue
                }

                let key = Self.pairKey(original: original, replacement: replacement)
                if shouldReplace(existingDate: suppressions[key]?.updatedAt, importedDate: suppression.updatedAt) {
                    preferences.removeValue(forKey: Self.key(for: original))
                    suppressions[key] = SuppressedCorrection(
                        original: original,
                        replacement: replacement,
                        undoCount: max(1, suppression.undoCount),
                        updatedAt: suppression.updatedAt,
                        expiresAt: suppression.expiresAt
                    )
                    importedSuppressions += 1
                }
            }

            save()
            return LearningImportResult(
                importedLearnedCorrections: importedPreferences,
                importedSuppressions: importedSuppressions
            )
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(preferences) {
            defaults.set(data, forKey: preferencesKey)
        }
        if let data = try? JSONEncoder().encode(suppressions) {
            defaults.set(data, forKey: suppressionsKey)
        }
    }

    private static func loadPreferences(defaults: UserDefaults, key: String) -> [String: LearnedCorrection] {
        guard let data = defaults.data(forKey: key),
              let preferences = try? JSONDecoder().decode([String: LearnedCorrection].self, from: data) else {
            return [:]
        }
        return preferences
    }

    private func purgeExpiredSuppressions(now: Date = Date()) {
        let expiredKeys = suppressions
            .filter { !$0.value.isActive(at: now) }
            .map(\.key)
        guard !expiredKeys.isEmpty else { return }

        for key in expiredKeys {
            suppressions.removeValue(forKey: key)
        }
        save()
    }

    private static func loadSuppressions(defaults: UserDefaults, key: String) -> [String: SuppressedCorrection] {
        guard let data = defaults.data(forKey: key) else {
            return [:]
        }

        if let suppressions = try? JSONDecoder().decode([String: SuppressedCorrection].self, from: data) {
            return suppressions
        }

        if let legacySuppressions = try? JSONDecoder().decode([String].self, from: data) {
            let now = Date()
            return Dictionary(uniqueKeysWithValues: legacySuppressions.map { key in
                let parts = key.split(separator: "\u{1F}", maxSplits: 1).map(String.init)
                let original = parts.first ?? key
                let replacement = parts.dropFirst().first ?? ""
                return (
                    key,
                    SuppressedCorrection(
                        original: original,
                        replacement: replacement,
                        undoCount: 3,
                        updatedAt: now,
                        expiresAt: nil
                    )
                )
            })
        }

        return [:]
    }

    private static func key(for original: String) -> String {
        normalized(original)
    }

    private static func pairKey(original: String, replacement: String) -> String {
        "\(normalized(original))\u{1F}\(normalized(replacement))"
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func shouldReplace(existingDate: Date?, importedDate: Date) -> Bool {
        guard let existingDate else { return true }
        return importedDate >= existingDate
    }
}
