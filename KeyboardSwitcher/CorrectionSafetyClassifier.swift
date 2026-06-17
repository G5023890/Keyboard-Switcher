import CoreML
import Foundation

enum CorrectionSafetyAction: String, Codable, Equatable, Sendable {
    case autoCorrect = "auto_correct"
    case suggestOnly = "suggest_only"
    case doNothing = "do_nothing"

    var displayName: String {
        switch self {
        case .autoCorrect: "Auto correct"
        case .suggestOnly: "Suggest only"
        case .doNothing: "Do nothing"
        }
    }
}

struct CorrectionSafetyFeatures: Codable, Equatable, Sendable {
    let wordLength: Int
    let candidateLength: Int
    let sourceLanguage: KeyboardLanguage?
    let targetLanguage: KeyboardLanguage
    let terminatorType: String
    let isShortWord: Bool
    let isTechnicalContext: Bool
    let appMode: AppBehaviorMode
    let ruleScore: Double
    let runnerUpScore: Double
    let scoreDelta: Double
    let hasDigits: Bool
    let hasMixedCase: Bool
    let hasPunctuation: Bool
    let wasLearned: Bool
    let wasSuppressed: Bool
}

struct CorrectionSafetyPrediction: Codable, Equatable, Sendable {
    let action: CorrectionSafetyAction
    let confidence: Double
    let modelIdentifier: String
    let explanation: String
}

enum CorrectionTrainingOutcome: String, Codable, Equatable, Sendable {
    case autoCorrected = "auto_corrected"
    case suggested = "suggested"
    case suggestionAccepted = "suggestion_accepted"
    case suggestionIgnored = "suggestion_ignored"
    case manualCorrected = "manual_corrected"
    case undone = "undone"
    case mlDivergence = "ml_divergence"
}

struct CorrectionTrainingSample: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let createdAt: Date
    let outcome: CorrectionTrainingOutcome
    let features: CorrectionSafetyFeatures
    let prediction: CorrectionSafetyPrediction?
    let decisionReason: String
    let textContext: String
}

struct CorrectionTrainingSampleSummary: Equatable, Sendable {
    let count: Int
    let lastOutcome: CorrectionTrainingOutcome?
    let lastTextContext: String
}

final class CorrectionTrainingSampleStore: @unchecked Sendable {
    static let shared = CorrectionTrainingSampleStore()

    private let defaults: UserDefaults
    private let samplesKey = "correctionTrainingSamples.v1"
    private let maximumSamples = 2_000
    private let lock = NSLock()
    private var samples: [CorrectionTrainingSample]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        samples = Self.loadSamples(defaults: defaults, key: samplesKey)
    }

    func record(
        outcome: CorrectionTrainingOutcome,
        features: CorrectionSafetyFeatures,
        prediction: CorrectionSafetyPrediction?,
        decisionReason: String,
        now: Date = Date()
    ) {
        let sample = CorrectionTrainingSample(
            id: UUID(),
            createdAt: now,
            outcome: outcome,
            features: features,
            prediction: prediction,
            decisionReason: decisionReason,
            textContext: Self.textContext(for: features)
        )

        lock.withLock {
            samples.append(sample)
            if samples.count > maximumSamples {
                samples.removeFirst(samples.count - maximumSamples)
            }
            save()
        }
    }

    func recordUndo(_ correction: Correction, now: Date = Date()) {
        let original = correction.original.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = correction.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty, !replacement.isEmpty else { return }

        let features = CorrectionSafetyFeatureExtractor.make(
            typedText: original,
            candidate: replacement,
            targetLanguage: correction.language,
            ruleScore: 0,
            runnerUpScore: 0,
            appMode: .normal,
            terminatorType: "undo",
            isTechnicalContext: false,
            wasSuppressed: true
        )
        record(
            outcome: .undone,
            features: features,
            prediction: nil,
            decisionReason: "Undo after \(correction.origin.rawValue)",
            now: now
        )
    }

    func allSamples() -> [CorrectionTrainingSample] {
        lock.withLock { samples.sorted { $0.createdAt > $1.createdAt } }
    }

    func summary() -> CorrectionTrainingSampleSummary {
        lock.withLock {
            CorrectionTrainingSampleSummary(
                count: samples.count,
                lastOutcome: samples.last?.outcome,
                lastTextContext: samples.last?.textContext ?? "plain_text"
            )
        }
    }

    func reset() {
        lock.withLock {
            samples.removeAll()
            save()
        }
    }

    func exportJSONLData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let lines = try lock.withLock {
            try samples.map { sample -> String in
                let data = try encoder.encode(sample)
                return String(decoding: data, as: UTF8.self)
            }
        }
        return Data(lines.joined(separator: "\n").utf8)
    }

    static func textContext(for features: CorrectionSafetyFeatures) -> String {
        if features.isTechnicalContext {
            return "technical_text"
        }
        if features.hasDigits || features.hasPunctuation {
            return "structured_token"
        }
        if features.hasMixedCase {
            return "mixed_case"
        }
        return "plain_text"
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(samples) else { return }
        defaults.set(data, forKey: samplesKey)
    }

    private static func loadSamples(defaults: UserDefaults, key: String) -> [CorrectionTrainingSample] {
        guard let data = defaults.data(forKey: key),
              let samples = try? JSONDecoder().decode([CorrectionTrainingSample].self, from: data) else {
            return []
        }
        return Array(samples.suffix(2_000))
    }
}

protocol CorrectionSafetyClassifying: Sendable {
    var modelIdentifier: String { get }
    func prediction(for features: CorrectionSafetyFeatures) -> CorrectionSafetyPrediction
}

struct RuleBasedCorrectionSafetyClassifier: CorrectionSafetyClassifying {
    let modelIdentifier = "RuleBasedSafetyFallback v1"

    func prediction(for features: CorrectionSafetyFeatures) -> CorrectionSafetyPrediction {
        if features.appMode == .excluded {
            return prediction(.doNothing, 1.0, "app is excluded")
        }

        if features.wasSuppressed {
            return prediction(.doNothing, 0.98, "user suppression exists")
        }

        if features.isTechnicalContext || features.hasDigits || features.hasPunctuation {
            return prediction(.doNothing, 0.92, "technical or structured token")
        }

        if features.hasMixedCase {
            return prediction(.doNothing, 0.88, "mixed casing looks intentional")
        }

        if features.wasLearned {
            return prediction(.autoCorrect, 0.94, "learned user preference")
        }

        let requiredScore: Double
        let requiredDelta: Double
        switch features.appMode {
        case .excluded:
            requiredScore = 1.0
            requiredDelta = 1.0
        case .strict:
            requiredScore = 0.82
            requiredDelta = 0.30
        case .normal:
            requiredScore = 0.74
            requiredDelta = 0.20
        case .textFocused:
            requiredScore = 0.66
            requiredDelta = 0.16
        }

        let shortWordPenalty = features.isShortWord ? 0.08 : 0
        let adjustedRequiredScore = min(0.98, requiredScore + shortWordPenalty)
        let adjustedRequiredDelta = min(0.98, requiredDelta + (features.isShortWord ? 0.06 : 0))

        if features.ruleScore >= adjustedRequiredScore && features.scoreDelta >= adjustedRequiredDelta {
            return prediction(.autoCorrect, min(0.98, features.ruleScore), "clear score and delta")
        }

        let suggestScore = max(0.46, adjustedRequiredScore - 0.18)
        let suggestDelta = max(0.08, adjustedRequiredDelta * 0.5)
        if features.ruleScore >= suggestScore && features.scoreDelta >= suggestDelta {
            return prediction(.suggestOnly, min(0.90, max(features.ruleScore, 0.55)), "borderline score or delta")
        }

        return prediction(.doNothing, 0.82, "score too low")
    }

    private func prediction(_ action: CorrectionSafetyAction, _ confidence: Double, _ explanation: String) -> CorrectionSafetyPrediction {
        CorrectionSafetyPrediction(
            action: action,
            confidence: max(0, min(confidence, 1)),
            modelIdentifier: modelIdentifier,
            explanation: explanation
        )
    }
}

final class CoreMLCorrectionSafetyClassifier: CorrectionSafetyClassifying, @unchecked Sendable {
    static let userDefaultsEnabledKey = "usesLocalMLSafetyClassifier"

    private let fallback = RuleBasedCorrectionSafetyClassifier()
    private let model: MLModel?
    private let isEnabledByDefault: Bool

    var modelIdentifier: String {
        guard isEnabled else {
            return "Local ML disabled; \(fallback.modelIdentifier)"
        }
        guard model != nil else {
            return "CoreMLCorrectionSafetyClassifier unavailable; \(fallback.modelIdentifier)"
        }
        return "CorrectionSafetyClassifier.mlmodel v0.1; \(fallback.modelIdentifier)"
    }

    private var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.userDefaultsEnabledKey) as? Bool ?? isEnabledByDefault
    }

    init(isEnabledByDefault: Bool = true, bundle: Bundle = .main) {
        self.isEnabledByDefault = isEnabledByDefault
        self.model = Self.loadModel(bundle: bundle)
    }

    func prediction(for features: CorrectionSafetyFeatures) -> CorrectionSafetyPrediction {
        let fallbackPrediction = fallback.prediction(for: features)
        guard isEnabled, let model else {
            return CorrectionSafetyPrediction(
                action: fallbackPrediction.action,
                confidence: fallbackPrediction.confidence,
                modelIdentifier: modelIdentifier,
                explanation: fallbackPrediction.explanation
            )
        }

        do {
            let output = try model.prediction(from: featureProvider(for: features, fallbackPrediction: fallbackPrediction))
            guard
                let actionValue = output.featureValue(for: "targetAction")?.stringValue,
                let action = CorrectionSafetyAction(rawValue: actionValue)
            else {
                return fallbackPrediction
            }

            let probabilities = output.featureValue(for: "targetActionProbability")?.dictionaryValue as? [String: Double]
            let confidence = probabilities?[action.rawValue] ?? fallbackPrediction.confidence
            return CorrectionSafetyPrediction(
                action: action,
                confidence: max(0, min(confidence, 1)),
                modelIdentifier: modelIdentifier,
                explanation: "Core ML inference; fallback was \(fallbackPrediction.action.rawValue)"
            )
        } catch {
            return CorrectionSafetyPrediction(
                action: fallbackPrediction.action,
                confidence: fallbackPrediction.confidence,
                modelIdentifier: "Core ML error; \(fallback.modelIdentifier)",
                explanation: fallbackPrediction.explanation
            )
        }
    }

    private func featureProvider(
        for features: CorrectionSafetyFeatures,
        fallbackPrediction: CorrectionSafetyPrediction
    ) throws -> MLFeatureProvider {
        try MLDictionaryFeatureProvider(dictionary: [
            "wordLength": MLFeatureValue(int64: Int64(features.wordLength)),
            "candidateLength": MLFeatureValue(int64: Int64(features.candidateLength)),
            "sourceLanguage": MLFeatureValue(string: features.sourceLanguage?.rawValue ?? "unknown"),
            "targetLanguage": MLFeatureValue(string: features.targetLanguage.rawValue),
            "terminatorType": MLFeatureValue(string: features.terminatorType),
            "isShortWord": MLFeatureValue(int64: features.isShortWord ? 1 : 0),
            "isTechnicalContext": MLFeatureValue(int64: features.isTechnicalContext ? 1 : 0),
            "appMode": MLFeatureValue(string: features.appMode.rawValue),
            "ruleScore": MLFeatureValue(double: features.ruleScore),
            "runnerUpScore": MLFeatureValue(double: features.runnerUpScore),
            "scoreDelta": MLFeatureValue(double: features.scoreDelta),
            "hasDigits": MLFeatureValue(int64: features.hasDigits ? 1 : 0),
            "hasMixedCase": MLFeatureValue(int64: features.hasMixedCase ? 1 : 0),
            "hasPunctuation": MLFeatureValue(int64: features.hasPunctuation ? 1 : 0),
            "wasLearned": MLFeatureValue(int64: features.wasLearned ? 1 : 0),
            "wasSuppressed": MLFeatureValue(int64: features.wasSuppressed ? 1 : 0),
            "predictionConfidence": MLFeatureValue(double: fallbackPrediction.confidence),
            "textContext": MLFeatureValue(string: CorrectionTrainingSampleStore.textContext(for: features))
        ])
    }

    private static func loadModel(bundle: Bundle) -> MLModel? {
        do {
            if let compiledURL = bundle.url(forResource: "CorrectionSafetyClassifier", withExtension: "mlmodelc") {
                return try MLModel(contentsOf: compiledURL)
            }

            if let sourceURL = bundle.url(forResource: "CorrectionSafetyClassifier", withExtension: "mlmodel") {
                let compiledURL = try MLModel.compileModel(at: sourceURL)
                return try MLModel(contentsOf: compiledURL)
            }
        } catch {
            return nil
        }

        return nil
    }
}

enum CorrectionSafetyFeatureExtractor {
    static func make(
        typedText: String,
        candidate: String,
        targetLanguage: KeyboardLanguage,
        ruleScore: Double,
        runnerUpScore: Double,
        appMode: AppBehaviorMode,
        terminatorType: String = "unknown",
        isTechnicalContext: Bool,
        wasLearned: Bool = false,
        wasSuppressed: Bool = false
    ) -> CorrectionSafetyFeatures {
        CorrectionSafetyFeatures(
            wordLength: typedText.count,
            candidateLength: candidate.count,
            sourceLanguage: LayoutEngine.detectScriptLanguage(for: typedText),
            targetLanguage: targetLanguage,
            terminatorType: terminatorType,
            isShortWord: typedText.count <= 2 || candidate.count <= 2,
            isTechnicalContext: isTechnicalContext,
            appMode: appMode,
            ruleScore: ruleScore,
            runnerUpScore: runnerUpScore,
            scoreDelta: max(0, ruleScore - runnerUpScore),
            hasDigits: containsDigits(typedText) || containsDigits(candidate),
            hasMixedCase: hasMixedCase(typedText) || hasMixedCase(candidate),
            hasPunctuation: containsPunctuation(typedText) || containsPunctuation(candidate),
            wasLearned: wasLearned,
            wasSuppressed: wasSuppressed
        )
    }

    private static func containsDigits(_ text: String) -> Bool {
        text.rangeOfCharacter(from: .decimalDigits) != nil
    }

    private static func hasMixedCase(_ text: String) -> Bool {
        text.rangeOfCharacter(from: .uppercaseLetters) != nil
            && text.rangeOfCharacter(from: .lowercaseLetters) != nil
    }

    private static func containsPunctuation(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            CharacterSet.punctuationCharacters.contains(scalar)
                || CharacterSet.symbols.contains(scalar)
        }
    }
}
