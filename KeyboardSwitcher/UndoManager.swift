import AppKit
import Combine
import Foundation

final class CorrectionUndoManager: ObservableObject {
    @Published private(set) var lastCorrection: Correction?
    var onUndo: ((Correction) -> Void)?
    var onRecord: ((Correction) -> Void)?

    var canUndo: Bool {
        lastCorrection != nil
    }

    func record(original: String, replacement: String, language: KeyboardLanguage, origin: CorrectionOrigin) {
        let correction = Correction(original: original, replacement: replacement, language: language, origin: origin)
        lastCorrection = correction
        onRecord?(correction)
    }

    func undoLastCorrection() {
        guard let correction = lastCorrection else { return }
        TextReplacementPerformer.replacePreviousText(characterCount: correction.replacement.count, with: correction.original)
        onUndo?(correction)
        lastCorrection = nil
    }
}

struct Correction: Equatable {
    let original: String
    let replacement: String
    let language: KeyboardLanguage
    let origin: CorrectionOrigin
}

enum CorrectionOrigin: String, Equatable {
    case automatic
    case manual
}

struct PrivacyMetricsSnapshot: Equatable {
    let correctionsToday: Int
    let undosToday: Int
    let automaticCorrectionsToday: Int
    let manualCorrectionsToday: Int
    let topLanguagePair: String

    var undoRate: Double {
        guard correctionsToday > 0 else { return 0 }
        return Double(undosToday) / Double(correctionsToday)
    }

    var qualityRecommendation: String {
        guard correctionsToday >= 5 else {
            return "Collecting local signal"
        }
        if undoRate >= 0.20 {
            return "Consider Conservative mode"
        }
        return "Correction quality looks stable"
    }

    static let empty = PrivacyMetricsSnapshot(
        correctionsToday: 0,
        undosToday: 0,
        automaticCorrectionsToday: 0,
        manualCorrectionsToday: 0,
        topLanguagePair: "None yet"
    )
}

final class PrivacyMetricsStore {
    private enum Key {
        static let day = "privacyMetrics.day"
        static let corrections = "privacyMetrics.corrections"
        static let undos = "privacyMetrics.undos"
        static let automatic = "privacyMetrics.automatic"
        static let manual = "privacyMetrics.manual"
        static let pairs = "privacyMetrics.pairs"
    }

    private let defaults: UserDefaults
    private let calendar: Calendar

    init(defaults: UserDefaults = .standard, calendar: Calendar = .current) {
        self.defaults = defaults
        self.calendar = calendar
    }

    func recordCorrection(_ correction: Correction, now: Date = Date()) {
        resetIfNeeded(now: now)
        defaults.set(defaults.integer(forKey: Key.corrections) + 1, forKey: Key.corrections)

        switch correction.origin {
        case .automatic:
            defaults.set(defaults.integer(forKey: Key.automatic) + 1, forKey: Key.automatic)
        case .manual:
            defaults.set(defaults.integer(forKey: Key.manual) + 1, forKey: Key.manual)
        }

        var pairs = languagePairs()
        let pair = languagePair(for: correction)
        pairs[pair, default: 0] += 1
        defaults.set(pairs, forKey: Key.pairs)
    }

    func recordUndo(now: Date = Date()) {
        resetIfNeeded(now: now)
        defaults.set(defaults.integer(forKey: Key.undos) + 1, forKey: Key.undos)
    }

    func snapshot(now: Date = Date()) -> PrivacyMetricsSnapshot {
        resetIfNeeded(now: now)
        let pairs = languagePairs()
        let topPair = pairs.max { lhs, rhs in
            lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
        }?.key ?? "None yet"

        return PrivacyMetricsSnapshot(
            correctionsToday: defaults.integer(forKey: Key.corrections),
            undosToday: defaults.integer(forKey: Key.undos),
            automaticCorrectionsToday: defaults.integer(forKey: Key.automatic),
            manualCorrectionsToday: defaults.integer(forKey: Key.manual),
            topLanguagePair: topPair
        )
    }

    func reset(now: Date = Date()) {
        defaults.set(dayKey(for: now), forKey: Key.day)
        defaults.set(0, forKey: Key.corrections)
        defaults.set(0, forKey: Key.undos)
        defaults.set(0, forKey: Key.automatic)
        defaults.set(0, forKey: Key.manual)
        defaults.set([String: Int](), forKey: Key.pairs)
    }

    private func resetIfNeeded(now: Date) {
        let today = dayKey(for: now)
        guard defaults.string(forKey: Key.day) == today else {
            reset(now: now)
            return
        }
    }

    private func dayKey(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
    }

    private func languagePairs() -> [String: Int] {
        defaults.dictionary(forKey: Key.pairs) as? [String: Int] ?? [:]
    }

    private func languagePair(for correction: Correction) -> String {
        let originalLanguage = LayoutEngine.detectScriptLanguage(for: correction.original) ?? .english
        return "\(originalLanguage.displayName) -> \(correction.language.displayName)"
    }
}
