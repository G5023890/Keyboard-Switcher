import Foundation

struct LearnedCorrection: Codable, Equatable {
    let original: String
    let replacement: String
    let language: KeyboardLanguage
    var uses: Int
    var updatedAt: Date
}

final class LearningStore: @unchecked Sendable {
    static let shared = LearningStore()

    private let defaults: UserDefaults
    private let preferencesKey = "learnedCorrections"
    private let suppressionsKey = "suppressedCorrections"
    private let lock = NSLock()
    private var preferences: [String: LearnedCorrection]
    private var suppressions: Set<String>

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

    func isSuppressed(original: String, replacement: String) -> Bool {
        lock.withLock {
            suppressions.contains(Self.pairKey(original: original, replacement: replacement))
        }
    }

    func recordPreference(original: String, replacement: String, language: KeyboardLanguage) {
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
            suppressions.remove(Self.pairKey(original: original, replacement: storedReplacement))
            save()
        }
    }

    func suppress(original: String, replacement: String) {
        let original = Self.normalized(original)
        let replacement = Self.normalized(replacement)
        guard !original.isEmpty, !replacement.isEmpty else { return }

        lock.withLock {
            preferences.removeValue(forKey: Self.key(for: original))
            suppressions.insert(Self.pairKey(original: original, replacement: replacement))
            save()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(preferences) {
            defaults.set(data, forKey: preferencesKey)
        }
        if let data = try? JSONEncoder().encode(Array(suppressions).sorted()) {
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

    private static func loadSuppressions(defaults: UserDefaults, key: String) -> Set<String> {
        guard let data = defaults.data(forKey: key),
              let suppressions = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(suppressions)
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
}
