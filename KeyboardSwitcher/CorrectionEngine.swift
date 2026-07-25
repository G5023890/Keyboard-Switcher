import AppKit
import Foundation

struct CorrectionDecision: Equatable {
    let replacement: String
    let language: KeyboardLanguage
    let score: Double
    let runnerUpScore: Double
}

enum TextReplacementMethod {
    case accessibility
    case synthetic
}

struct CorrectionEvaluation: Equatable {
    let typedText: String
    let candidateScores: [CandidateScore]
    let decision: CorrectionDecision?
    let suggestion: CorrectionDecision?
    let reason: String
    let confidenceThreshold: Double
    let minimumConfidenceDelta: Double
    let safetyFeatures: CorrectionSafetyFeatures?
    let safetyPrediction: CorrectionSafetyPrediction?
    let safetyFallbackPrediction: CorrectionSafetyPrediction?

    var winnerScore: Double? {
        candidateScores.first?.score ?? decision?.score
    }

    var runnerUpScore: Double? {
        candidateScores.dropFirst().first?.score ?? decision?.runnerUpScore
    }

    var confidenceDelta: Double? {
        guard let winnerScore, let runnerUpScore else { return nil }
        return max(0, winnerScore - runnerUpScore)
    }

    var diagnosticSummary: String {
        var lines = [
            "Typed: \(typedText.isEmpty ? "-" : typedText)",
            "Decision: \(reason)",
            "Threshold: \(Self.percent(confidenceThreshold))",
            "Minimum delta: \(Self.percent(minimumConfidenceDelta))"
        ]

        if let winnerScore {
            lines.append("Winner score: \(Self.percent(winnerScore))")
        }
        if let runnerUpScore {
            lines.append("Runner-up score: \(Self.percent(runnerUpScore))")
        }
        if let confidenceDelta {
            lines.append("Delta: \(Self.percent(confidenceDelta))")
        }
        if let decision {
            lines.append("Replacement: \(typedText) -> \(decision.replacement) (\(decision.language.displayName))")
        }
        if let suggestion {
            lines.append("Suggestion: \(typedText) -> \(suggestion.replacement) (\(suggestion.language.displayName))")
        }
        if let safetyPrediction {
            lines.append("Local ML: \(safetyPrediction.modelIdentifier)")
            lines.append("ML decision: \(safetyPrediction.action.displayName) \(Self.percent(safetyPrediction.confidence))")
            lines.append("ML reason: \(safetyPrediction.explanation)")
        }
        if let safetyFallbackPrediction {
            lines.append("Rule fallback: \(safetyFallbackPrediction.action.displayName) \(Self.percent(safetyFallbackPrediction.confidence))")
            if let safetyPrediction, safetyPrediction.action != safetyFallbackPrediction.action {
                lines.append("ML divergence: \(safetyPrediction.action.rawValue) vs rule \(safetyFallbackPrediction.action.rawValue)")
            }
        }

        guard !candidateScores.isEmpty else {
            lines.append("Candidates: None")
            return lines.joined(separator: "\n")
        }

        lines.append("Candidates:")
        lines.append(contentsOf: candidateScores.prefix(6).map { score in
            "  \(score.candidate.language.displayName): \(score.candidate.text) \(Self.percent(score.score))"
        })
        return lines.joined(separator: "\n")
    }

    private static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

final class CorrectionEngine: @unchecked Sendable {
    private enum ShortWordMode {
        case automatic
        case manual
    }

    var confidenceThreshold = 0.42
    var minimumConfidenceDelta = 0.20
    var enabledLanguages = Set(KeyboardLanguage.allCases)
    var detectionPriority = KeyboardLanguage.allCases
    var learnsFromManualCorrections = true

    private let classifier = TextClassifier()
    private let safetyClassifier: CorrectionSafetyClassifying
    private let fallbackSafetyClassifier = RuleBasedCorrectionSafetyClassifier()
    private let undoController: CorrectionUndoManager
    private let learningStore: LearningStore
    private let commonCandidateFixes = [
        "спосибо": "спасибо"
    ]
    private let automaticHebrewShortFunctionalWords: Set<String> = ["של"]

    init(
        undoController: CorrectionUndoManager,
        learningStore: LearningStore = .shared,
        safetyClassifier: CorrectionSafetyClassifying = CoreMLCorrectionSafetyClassifier()
    ) {
        self.undoController = undoController
        self.learningStore = learningStore
        self.safetyClassifier = safetyClassifier
    }

    func decision(for strokes: [KeyStroke], typedText: String, allowsShortFunctionalWords: Bool = true) -> CorrectionDecision? {
        evaluate(strokes: strokes, typedText: typedText, allowsShortFunctionalWords: allowsShortFunctionalWords).decision
    }

    func warmUp() {
        classifier.warmUp()
        let features = CorrectionSafetyFeatureExtractor.make(
            typedText: "ghbdtn",
            candidate: "привет",
            targetLanguage: .russian,
            ruleScore: 0.92,
            runnerUpScore: 0.08,
            appMode: .normal,
            terminatorType: "space",
            isTechnicalContext: false
        )
        _ = fallbackSafetyClassifier.prediction(for: features)
        _ = safetyClassifier.prediction(for: features)
        _ = LayoutEngine.candidates(
            for: [
                KeyStroke(keyCode: 5, isShifted: false),
                KeyStroke(keyCode: 4, isShifted: false),
                KeyStroke(keyCode: 11, isShifted: false),
                KeyStroke(keyCode: 2, isShifted: false),
                KeyStroke(keyCode: 17, isShifted: false),
                KeyStroke(keyCode: 45, isShifted: false)
            ],
            enabledLanguages: Set(KeyboardLanguage.allCases)
        )
    }

    func evaluate(
        strokes: [KeyStroke],
        typedText: String,
        allowsShortFunctionalWords: Bool = true,
        profile: CorrectionProfile = .normal,
        appMode: AppBehaviorMode = .normal,
        terminatorType: String = "unknown",
        isStrictContext: Bool = false
    ) -> CorrectionEvaluation {
        let activeConfidenceThreshold = max(0, min(confidenceThreshold + profile.confidenceThresholdOffset, 1))
        let activeMinimumConfidenceDelta = max(0, min(profile.minimumDeltaOverride ?? minimumConfidenceDelta, 1))

        let typedSafetyReason = classifier.correctionSafetyReason(for: typedText)
        let replayableSafetyReasons = Set(["technical delimiter token", "path-like text"])
        if let typedSafetyReason,
           !replayableSafetyReasons.contains(typedSafetyReason) {
            return makeEvaluation(typedText: typedText, candidateScores: [], decision: nil, reason: "Skipped \(typedSafetyReason)", confidenceThreshold: activeConfidenceThreshold, minimumConfidenceDelta: activeMinimumConfidenceDelta)
        }

        if hasSuspiciousCasing(typedText), !isMixedLayoutWord(typedText) {
            return makeEvaluation(typedText: typedText, candidateScores: [], decision: nil, reason: "Skipped suspicious casing", confidenceThreshold: activeConfidenceThreshold, minimumConfidenceDelta: activeMinimumConfidenceDelta)
        }

        if !isStrictContext,
           allowsShortFunctionalWords,
           let decision = shortWordDecision(for: strokes, typedText: typedText, mode: .automatic) {
            return makeEvaluation(
                typedText: typedText,
                candidateScores: [],
                decision: decision,
                reason: "Short functional word",
                confidenceThreshold: activeConfidenceThreshold,
                minimumConfidenceDelta: activeMinimumConfidenceDelta
            )
        }

        if !isStrictContext, let learnedDecision = learnedDecision(for: typedText) {
            return makeEvaluation(typedText: typedText, candidateScores: [], decision: learnedDecision, reason: "Learned correction", confidenceThreshold: activeConfidenceThreshold, minimumConfidenceDelta: activeMinimumConfidenceDelta)
        }

        guard strokes.count >= 3 else {
            return makeEvaluation(typedText: typedText, candidateScores: [], decision: nil, reason: "Need at least 3 letters", confidenceThreshold: activeConfidenceThreshold, minimumConfidenceDelta: activeMinimumConfidenceDelta)
        }

        let rawCandidates = LayoutEngine.candidates(for: strokes, enabledLanguages: enabledLanguages)
            .filter { $0.text != typedText }

        let normalizedCandidates = rawCandidates
            .map { normalizedCandidate($0, typedText: typedText) }
            .filter { $0.text != typedText }

        let safeCandidates = normalizedCandidates
            .filter { candidateSafetyReason(for: $0.text) == nil }

        if let typedSafetyReason {
            let sourceLanguage = LayoutEngine.detectScriptLanguage(for: typedText)
            let hasCrossLanguageEvidence = safeCandidates.contains { candidate in
                classifier.hasStrongLexicalEvidence(candidate)
                    && candidate.language != sourceLanguage
            }
            if !hasCrossLanguageEvidence {
                return makeEvaluation(typedText: typedText, candidateScores: [], decision: nil, reason: "Skipped \(typedSafetyReason)", confidenceThreshold: activeConfidenceThreshold, minimumConfidenceDelta: activeMinimumConfidenceDelta)
            }
        }

        if rawCandidates.isEmpty {
            return makeEvaluation(typedText: typedText, candidateScores: [], decision: nil, reason: "No alternate layout candidate", confidenceThreshold: activeConfidenceThreshold, minimumConfidenceDelta: activeMinimumConfidenceDelta)
        }

        if safeCandidates.isEmpty,
           let safetyReason = normalizedCandidates.compactMap({ candidateSafetyReason(for: $0.text) }).first {
            return makeEvaluation(typedText: typedText, candidateScores: [], decision: nil, reason: "Skipped \(safetyReason)", confidenceThreshold: activeConfidenceThreshold, minimumConfidenceDelta: activeMinimumConfidenceDelta)
        }

        let scores = sortedScores(safeCandidates.map(classifier.score))
        guard let winner = scores.first else {
            return makeEvaluation(typedText: typedText, candidateScores: scores, decision: nil, reason: "No alternate layout candidate", confidenceThreshold: activeConfidenceThreshold, minimumConfidenceDelta: activeMinimumConfidenceDelta)
        }

        let runnerUp = scores.dropFirst().first?.score ?? 0
        let margin = winner.score - runnerUp
        let safety = correctionSafety(
            typedText: typedText,
            winner: winner,
            runnerUp: runnerUp,
            appMode: appMode,
            terminatorType: terminatorType
        )

        if let hebrewSafetyReason = hebrewAutomaticSafetyReason(
            for: winner.candidate,
            score: winner.score,
            margin: margin,
            confidenceThreshold: activeConfidenceThreshold,
            minimumConfidenceDelta: activeMinimumConfidenceDelta
        ) {
            return makeEvaluation(typedText: typedText, candidateScores: scores, decision: nil, reason: hebrewSafetyReason, confidenceThreshold: activeConfidenceThreshold, minimumConfidenceDelta: activeMinimumConfidenceDelta, safetyFeatures: safety.features, safetyPrediction: safety.prediction, safetyFallbackPrediction: safety.fallbackPrediction)
        }

        if isStrictContext,
           !meetsStrictAutomaticGate(
                winner: winner,
                margin: margin,
                confidenceThreshold: activeConfidenceThreshold,
                minimumConfidenceDelta: activeMinimumConfidenceDelta
           ) {
            return makeEvaluation(
                typedText: typedText,
                candidateScores: scores,
                decision: nil,
                reason: "Skipped strict confidence gate",
                confidenceThreshold: activeConfidenceThreshold,
                minimumConfidenceDelta: activeMinimumConfidenceDelta,
                safetyFeatures: safety.features,
                safetyPrediction: safety.prediction,
                safetyFallbackPrediction: safety.fallbackPrediction
            )
        }

        if let punctuationTokenDecision = punctuationTokenDecision(
            for: winner,
            runnerUp: runnerUp,
            margin: margin,
            typedText: typedText,
            minimumConfidenceDelta: activeMinimumConfidenceDelta
        ) {
            return makeEvaluation(
                typedText: typedText,
                candidateScores: scores,
                decision: punctuationTokenDecision,
                reason: "Corrected punctuation token",
                confidenceThreshold: activeConfidenceThreshold,
                minimumConfidenceDelta: activeMinimumConfidenceDelta,
                safetyFeatures: safety.features,
                safetyPrediction: safety.prediction,
                safetyFallbackPrediction: safety.fallbackPrediction
            )
        }

        if let hyphenatedWordDecision = hyphenatedWordDecision(
            for: winner,
            scores: scores,
            typedText: typedText
        ) {
            return makeEvaluation(
                typedText: typedText,
                candidateScores: scores,
                decision: hyphenatedWordDecision,
                reason: "Corrected hyphenated dictionary token",
                confidenceThreshold: activeConfidenceThreshold,
                minimumConfidenceDelta: activeMinimumConfidenceDelta,
                safetyFeatures: safety.features,
                safetyPrediction: safety.prediction,
                safetyFallbackPrediction: safety.fallbackPrediction
            )
        }

        if let spellingAssistedDecision = spellingAssistedLayoutDecision(
            for: winner,
            runnerUp: runnerUp,
            margin: margin,
            typedText: typedText,
            confidenceThreshold: activeConfidenceThreshold,
            minimumConfidenceDelta: activeMinimumConfidenceDelta
        ) {
            return makeEvaluation(
                typedText: typedText,
                candidateScores: scores,
                decision: spellingAssistedDecision,
                reason: "Corrected layout candidate spelling",
                confidenceThreshold: activeConfidenceThreshold,
                minimumConfidenceDelta: activeMinimumConfidenceDelta,
                safetyFeatures: safety.features,
                safetyPrediction: safety.prediction,
                safetyFallbackPrediction: safety.fallbackPrediction
            )
        }

        if let lexicalDecision = clearStrongLexicalDecision(
            scores: scores,
            typedText: typedText,
            confidenceThreshold: activeConfidenceThreshold,
            minimumConfidenceDelta: activeMinimumConfidenceDelta
        ) {
            return makeEvaluation(
                typedText: typedText,
                candidateScores: scores,
                decision: lexicalDecision,
                reason: "Corrected clear dictionary candidate",
                confidenceThreshold: activeConfidenceThreshold,
                minimumConfidenceDelta: activeMinimumConfidenceDelta,
                safetyFeatures: safety.features,
                safetyPrediction: safety.prediction,
                safetyFallbackPrediction: safety.fallbackPrediction
            )
        }

        guard winner.score >= activeConfidenceThreshold else {
            let suggestion = mediumConfidenceSuggestion(
                winner: winner,
                runnerUp: runnerUp,
                margin: margin,
                confidenceThreshold: activeConfidenceThreshold,
                minimumConfidenceDelta: activeMinimumConfidenceDelta,
                typedText: typedText
            )
            return makeEvaluation(typedText: typedText, candidateScores: scores, decision: nil, suggestion: suggestion, reason: "Winner below confidence threshold", confidenceThreshold: activeConfidenceThreshold, minimumConfidenceDelta: activeMinimumConfidenceDelta, safetyFeatures: safety.features, safetyPrediction: safety.prediction, safetyFallbackPrediction: safety.fallbackPrediction)
        }

        guard classifier.hasStrongLexicalEvidence(winner.candidate) else {
            return makeEvaluation(typedText: typedText, candidateScores: scores, decision: nil, reason: "Winner lacks dictionary evidence", confidenceThreshold: activeConfidenceThreshold, minimumConfidenceDelta: activeMinimumConfidenceDelta, safetyFeatures: safety.features, safetyPrediction: safety.prediction, safetyFallbackPrediction: safety.fallbackPrediction)
        }

        let replacement = casingAdjustedReplacement(
            winner.candidate.text,
            language: winner.candidate.language,
            typedText: typedText
        )

        guard !learningStore.isSuppressed(original: typedText, replacement: replacement) else {
            return makeEvaluation(typedText: typedText, candidateScores: scores, decision: nil, reason: "Skipped learned suppression", confidenceThreshold: activeConfidenceThreshold, minimumConfidenceDelta: activeMinimumConfidenceDelta, safetyFeatures: safety.features, safetyPrediction: safety.prediction, safetyFallbackPrediction: safety.fallbackPrediction)
        }

        guard margin >= activeMinimumConfidenceDelta else {
            let suggestion = mediumConfidenceSuggestion(
                winner: winner,
                runnerUp: runnerUp,
                margin: margin,
                confidenceThreshold: activeConfidenceThreshold,
                minimumConfidenceDelta: activeMinimumConfidenceDelta,
                typedText: typedText
            )
            return makeEvaluation(typedText: typedText, candidateScores: scores, decision: nil, suggestion: suggestion, reason: "Winner delta below minimum", confidenceThreshold: activeConfidenceThreshold, minimumConfidenceDelta: activeMinimumConfidenceDelta, safetyFeatures: safety.features, safetyPrediction: safety.prediction, safetyFallbackPrediction: safety.fallbackPrediction)
        }

        let decision = CorrectionDecision(
            replacement: replacement,
            language: winner.candidate.language,
            score: winner.score,
            runnerUpScore: runnerUp
        )

        return makeEvaluation(typedText: typedText, candidateScores: scores, decision: decision, reason: "Corrected", confidenceThreshold: activeConfidenceThreshold, minimumConfidenceDelta: activeMinimumConfidenceDelta, safetyFeatures: safety.features, safetyPrediction: safety.prediction, safetyFallbackPrediction: safety.fallbackPrediction)
    }

    private func clearStrongLexicalDecision(
        scores: [CandidateScore],
        typedText: String,
        confidenceThreshold: Double,
        minimumConfidenceDelta: Double
    ) -> CorrectionDecision? {
        guard let winner = scores.first else { return nil }
        let runnerUp = scores.dropFirst().first?.score ?? 0
        let margin = winner.score - runnerUp
        let supported = scores.filter { classifier.hasStrongLexicalEvidence($0.candidate) }
        guard confidenceThreshold <= 0.72,
              supported.count == 1,
              supported.first?.candidate == winner.candidate,
              winner.score < confidenceThreshold,
              winner.score >= 0.42,
              margin >= max(0.08, minimumConfidenceDelta * 0.4),
              winner.candidate.text.count >= 5 else {
            return nil
        }

        let replacement = casingAdjustedReplacement(
            winner.candidate.text,
            language: winner.candidate.language,
            typedText: typedText
        )
        guard !learningStore.isSuppressed(original: typedText, replacement: replacement) else {
            return nil
        }

        return CorrectionDecision(
            replacement: replacement,
            language: winner.candidate.language,
            score: max(winner.score, confidenceThreshold),
            runnerUpScore: runnerUp
        )
    }

    // Strict contexts must not use an exception path that is more permissive
    // than the normal confidence and separation requirements.
    private func meetsStrictAutomaticGate(
        winner: CandidateScore,
        margin: Double,
        confidenceThreshold: Double,
        minimumConfidenceDelta: Double
    ) -> Bool {
        winner.score >= confidenceThreshold
            && margin >= minimumConfidenceDelta
            && classifier.hasStrongLexicalEvidence(winner.candidate)
    }

    private func makeEvaluation(
        typedText: String,
        candidateScores: [CandidateScore],
        decision: CorrectionDecision?,
        suggestion: CorrectionDecision? = nil,
        reason: String,
        confidenceThreshold: Double? = nil,
        minimumConfidenceDelta: Double? = nil,
        safetyFeatures: CorrectionSafetyFeatures? = nil,
        safetyPrediction: CorrectionSafetyPrediction? = nil,
        safetyFallbackPrediction: CorrectionSafetyPrediction? = nil
    ) -> CorrectionEvaluation {
        CorrectionEvaluation(
            typedText: typedText,
            candidateScores: candidateScores,
            decision: decision,
            suggestion: suggestion,
            reason: reason,
            confidenceThreshold: confidenceThreshold ?? self.confidenceThreshold,
            minimumConfidenceDelta: minimumConfidenceDelta ?? self.minimumConfidenceDelta,
            safetyFeatures: safetyFeatures,
            safetyPrediction: safetyPrediction,
            safetyFallbackPrediction: safetyFallbackPrediction
        )
    }

    private func mediumConfidenceSuggestion(
        winner: CandidateScore,
        runnerUp: Double,
        margin: Double,
        confidenceThreshold: Double,
        minimumConfidenceDelta: Double,
        typedText: String
    ) -> CorrectionDecision? {
        let previewThreshold = max(0.28, confidenceThreshold - 0.12)
        let previewDelta = max(0.08, minimumConfidenceDelta * 0.5)
        guard winner.score >= previewThreshold,
              margin >= previewDelta,
              winner.candidate.text != typedText,
              hebrewAutomaticSafetyReason(
                for: winner.candidate,
                score: winner.score,
                margin: margin,
                confidenceThreshold: confidenceThreshold,
                minimumConfidenceDelta: minimumConfidenceDelta
              ) == nil,
              classifier.hasStrongLexicalEvidence(winner.candidate),
              !learningStore.isSuppressed(original: typedText, replacement: winner.candidate.text) else {
            return nil
        }

        let replacement = casingAdjustedReplacement(
            winner.candidate.text,
            language: winner.candidate.language,
            typedText: typedText
        )

        return CorrectionDecision(
            replacement: replacement,
            language: winner.candidate.language,
            score: winner.score,
            runnerUpScore: runnerUp
        )
    }

    private func spellingAssistedLayoutDecision(
        for winner: CandidateScore,
        runnerUp: Double,
        margin: Double,
        typedText: String,
        confidenceThreshold: Double,
        minimumConfidenceDelta: Double
    ) -> CorrectionDecision? {
        let candidate = winner.candidate
        let candidateText = candidate.text
        let minimumScore = max(0.34, confidenceThreshold - 0.28)
        let minimumMargin = max(0.08, minimumConfidenceDelta * 0.45)

        guard candidate.language != .hebrew,
              candidateText != typedText,
              winner.score >= minimumScore,
              margin >= minimumMargin,
              !classifier.hasManualLexicalEvidence(candidate),
              candidateText.count >= 6,
              let spellingCorrection = classifier.spellingCorrection(for: candidateText, language: candidate.language) else {
            return nil
        }

        let replacement = casingAdjustedReplacement(
            spellingCorrection.replacement,
            language: candidate.language,
            typedText: typedText
        )

        guard replacement != typedText,
              !learningStore.isSuppressed(original: typedText, replacement: replacement),
              hebrewAutomaticSafetyReason(
                for: LayoutCandidate(language: candidate.language, text: replacement),
                score: winner.score,
                margin: margin,
                confidenceThreshold: confidenceThreshold,
                minimumConfidenceDelta: minimumConfidenceDelta
              ) == nil else {
            return nil
        }

        return CorrectionDecision(
            replacement: replacement,
            language: candidate.language,
            score: max(winner.score, confidenceThreshold),
            runnerUpScore: runnerUp
        )
    }

    private func punctuationTokenDecision(
        for winner: CandidateScore,
        runnerUp: Double,
        margin: Double,
        typedText: String,
        minimumConfidenceDelta: Double
    ) -> CorrectionDecision? {
        let requiredMargin = hasFinalSentencePunctuation(typedText)
            ? 0.03
            : max(0.08, minimumConfidenceDelta * 0.4)

        guard isMixedLayoutWord(typedText),
              winner.score >= 0.34,
              margin >= requiredMargin,
              classifier.hasStrongLexicalEvidence(winner.candidate) else {
            return nil
        }

        let replacement = casingAdjustedReplacement(
            winner.candidate.text,
            language: winner.candidate.language,
            typedText: typedText
        )
        guard !learningStore.isSuppressed(original: typedText, replacement: replacement) else {
            return nil
        }

        return CorrectionDecision(
            replacement: replacement,
            language: winner.candidate.language,
            score: max(winner.score, 0.72),
            runnerUpScore: runnerUp
        )
    }

    private func hyphenatedWordDecision(
        for winner: CandidateScore,
        scores: [CandidateScore],
        typedText: String
    ) -> CorrectionDecision? {
        guard typedText.contains("-"),
              winner.candidate.text.contains("-"),
              winner.score >= 0.34,
              classifier.hasStrongLexicalEvidence(winner.candidate),
              scores.filter({ classifier.hasStrongLexicalEvidence($0.candidate) }).count == 1 else {
            return nil
        }

        let replacement = casingAdjustedReplacement(
            winner.candidate.text,
            language: winner.candidate.language,
            typedText: typedText
        )
        guard !learningStore.isSuppressed(original: typedText, replacement: replacement) else {
            return nil
        }

        return CorrectionDecision(
            replacement: replacement,
            language: winner.candidate.language,
            score: max(winner.score, 0.72),
            runnerUpScore: scores.dropFirst().first?.score ?? 0
        )
    }

    private func hasFinalSentencePunctuation(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return "?!".contains(last)
    }

    @discardableResult
    func applyCorrection(
        replacingPreviousCharacterCount originalLength: Int,
        original: String,
        with replacement: String,
        language: KeyboardLanguage,
        terminator: String = "",
        allowSyntheticFallback: Bool = false
    ) -> TextReplacementMethod? {
        let previousText = String(original.prefix(originalLength))
        let replacementMethod = TextReplacementPerformer.replacePreviousTextMethod(
            characterCount: originalLength,
            expectedPreviousText: previousText,
            with: replacement,
            // AX replacement leaves the real terminator in the event stream.
            // Synthetic replay has no reliable AX caret, so it must remain an
            // atomic word-plus-terminator operation.
            syntheticReplacement: replacement + terminator,
            allowSyntheticFallback: allowSyntheticFallback
        )
        guard let replacementMethod else { return nil }
        undoController.record(
            original: original + terminator,
            replacement: replacement + terminator,
            language: language,
            origin: .automatic
        )
        return replacementMethod
    }

    func spellingCorrection(for word: String, language: KeyboardLanguage, appMode: AppBehaviorMode, terminatorType: String) -> CorrectionDecision? {
        guard let spellingLanguage = LayoutEngine.detectScriptLanguage(for: word) else {
            return nil
        }
        guard terminatorType == "space",
              appMode == .normal || appMode == .textFocused,
              enabledLanguages.contains(spellingLanguage),
              let correction = classifier.spellingCorrection(for: word, language: spellingLanguage),
              !learningStore.isSuppressed(original: correction.original, replacement: correction.replacement) else {
            return nil
        }

        return CorrectionDecision(
            replacement: correction.replacement,
            language: correction.language,
            score: 0.70,
            runnerUpScore: 0
        )
    }

    func inferredSpellingLanguage(for word: String, currentLanguage: KeyboardLanguage) -> KeyboardLanguage {
        LayoutEngine.detectScriptLanguage(for: word) ?? currentLanguage
    }

    func manualReplacement(for word: String) -> CorrectionDecision? {
        manualReplacements(for: word).first
    }

    func manualReplacements(for word: String) -> [CorrectionDecision] {
        if let learnedDecision = learnedDecision(for: word) {
            return [learnedDecision]
        }

        guard !isAllUppercaseWord(word) else { return [] }

        if let strokes = LayoutEngine.strokes(for: word),
           let decision = shortWordDecision(for: strokes, typedText: word, mode: .manual) {
            return [decision]
        }

        guard word.count >= 2 else { return [] }
        let isMixedLayoutWord = isMixedLayoutWord(word)
        let resolvedStrokes = isMixedLayoutWord ? LayoutEngine.mixedLayoutStrokes(for: word) : LayoutEngine.strokes(for: word)
        guard let strokes = resolvedStrokes else { return [] }

        let currentLanguage = isMixedLayoutWord ? nil : LayoutEngine.detectScriptLanguage(for: word) ?? .english
        let candidates = LayoutEngine.candidates(for: strokes, enabledLanguages: enabledLanguages)
            .map { normalizedCandidate($0, typedText: word) }
            .filter { candidate in
                if candidate.text == word { return false }
                if let currentLanguage {
                    return candidate.language != currentLanguage
                }
                return true
            }

        let scored = sortedScores(candidates.map(classifier.score))
        let lexicalDecisions = scored
            .filter { classifier.hasManualLexicalEvidence($0.candidate) && $0.score >= 0.28 }
            .map { score in
                CorrectionDecision(
                    replacement: casingAdjustedReplacement(score.candidate.text, language: score.candidate.language, typedText: word),
                    language: score.candidate.language,
                    score: score.score,
                    runnerUpScore: scored.first { $0.candidate.language != score.candidate.language }?.score ?? 0
                )
            }
        if !lexicalDecisions.isEmpty {
            return uniqueDecisions(lexicalDecisions)
        }

        if currentLanguage == nil {
            return []
        }

        if let currentLanguage {
            let cycle = manualLanguageCycle(from: currentLanguage)
            var fallbackDecisions: [CorrectionDecision] = []
            for language in cycle {
                if let candidate = candidates.first(where: { $0.language == language }) {
                    fallbackDecisions.append(
                        CorrectionDecision(
                            replacement: casingAdjustedReplacement(candidate.text, language: language, typedText: word),
                            language: language,
                            score: 0,
                            runnerUpScore: 0
                        )
                    )
                }
            }
            return uniqueDecisions(fallbackDecisions)
        }

        return []
    }

    func recordManualCorrection(original: String, replacement: String) {
        guard let language = LayoutEngine.detectScriptLanguage(for: replacement) else { return }
        if learnsFromManualCorrections {
            learningStore.recordPreference(original: original, replacement: replacement, language: language)
        }
        undoController.record(original: original, replacement: replacement, language: language, origin: .manual)
    }

    func recordAcceptedSuggestion(original: String, replacement: String, language: KeyboardLanguage) {
        learningStore.recordPreference(original: original, replacement: replacement, language: language)
    }

    func recordIgnoredSuggestion(original: String, replacement: String) {
        learningStore.suppress(original: original, replacement: replacement)
    }

    func recordManualTranslation(original: String, replacement: String) {
        guard let language = LayoutEngine.detectScriptLanguage(for: replacement) else { return }
        undoController.record(original: original, replacement: replacement, language: language, origin: .manual)
    }

    func recordUndoneCorrection(_ correction: Correction) {
        learningStore.suppress(original: correction.original, replacement: correction.replacement)
    }

    private func manualLanguageCycle(from language: KeyboardLanguage) -> [KeyboardLanguage] {
        normalizedDetectionPriority()
            .filter { $0 != language && enabledLanguages.contains($0) }
    }

    private func learnedDecision(for typedText: String) -> CorrectionDecision? {
        guard let learned = learningStore.preference(for: typedText),
              enabledLanguages.contains(learned.language),
              learned.replacement != typedText,
              !learningStore.isSuppressed(original: typedText, replacement: learned.replacement) else {
            return nil
        }

        let replacement = casingAdjustedReplacement(
            classifier.preferredSpelling(for: learned.replacement, language: learned.language),
            language: learned.language,
            typedText: typedText
        )

        return CorrectionDecision(
            replacement: replacement,
            language: learned.language,
            score: min(0.98, 0.78 + Double(min(learned.uses, 10)) * 0.02),
            runnerUpScore: 0
        )
    }

    private func sortedScores(_ scores: [CandidateScore]) -> [CandidateScore] {
        scores.sorted { left, right in
            let delta = abs(left.score - right.score)
            if delta > 0.001 {
                return left.score > right.score
            }
            return priorityIndex(for: left.candidate.language) < priorityIndex(for: right.candidate.language)
        }
    }

    private func priorityIndex(for language: KeyboardLanguage) -> Int {
        normalizedDetectionPriority().firstIndex(of: language) ?? Int.max
    }

    private func normalizedDetectionPriority() -> [KeyboardLanguage] {
        var seen = Set<KeyboardLanguage>()
        var ordered: [KeyboardLanguage] = []
        for language in detectionPriority where !seen.contains(language) {
            ordered.append(language)
            seen.insert(language)
        }
        for language in KeyboardLanguage.allCases where !seen.contains(language) {
            ordered.append(language)
        }
        return ordered
    }

    private func uniqueDecisions(_ decisions: [CorrectionDecision]) -> [CorrectionDecision] {
        var seen = Set<String>()
        return decisions.filter { decision in
            let key = "\(decision.language.rawValue)\u{1F}\(decision.replacement)"
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    private func normalizedCandidate(_ candidate: LayoutCandidate, typedText: String) -> LayoutCandidate {
        var edgeAdjustedText = edgePunctuationAdjustedCandidateText(
            candidate.text,
            typedText: typedText,
            preservesBracketPunctuation: !classifier.hasStrongLexicalEvidence(candidate)
        )
        if isMixedLayoutWord(typedText), hasSuspiciousCasing(edgeAdjustedText) {
            edgeAdjustedText = edgeAdjustedText.lowercased()
        }
        let fixedText = commonCandidateFixes[edgeAdjustedText.lowercased()] ?? edgeAdjustedText
        let normalizedText = candidate.language == .hebrew ? normalizedHebrewFinalLetters(fixedText) : fixedText
        let preferredText = classifier.preferredSpelling(for: normalizedText, language: candidate.language)
        return LayoutCandidate(language: candidate.language, text: preferredText)
    }

    private func edgePunctuationAdjustedCandidateText(
        _ candidateText: String,
        typedText: String,
        preservesBracketPunctuation: Bool
    ) -> String {
        var candidateCharacters = Array(candidateText)
        let typedCharacters = Array(typedText)
        guard !candidateCharacters.isEmpty, !typedCharacters.isEmpty else {
            return candidateText
        }

        if preservesBracketPunctuation,
           let firstTyped = typedCharacters.first,
           "[({<".contains(firstTyped),
           isLatinLayoutBody(String(typedCharacters.dropFirst())) {
            candidateCharacters[0] = firstTyped
        }

        if let lastTyped = typedCharacters.last,
           "?!".contains(lastTyped) || (preservesBracketPunctuation && "])}>".contains(lastTyped) && isLatinLayoutBody(String(typedCharacters.dropLast()))) {
            candidateCharacters[candidateCharacters.count - 1] = lastTyped
        }

        return String(candidateCharacters)
    }

    private func isLatinLayoutBody(_ text: String) -> Bool {
        let scalars = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !scalars.isEmpty else { return false }
        let hasLatin = scalars.contains { ("a"..."z").contains(String($0).lowercased()) }
        let hasCyrillic = scalars.contains { (0x0400...0x04FF).contains(Int($0.value)) }
        let hasHebrew = scalars.contains { (0x0590...0x05FF).contains(Int($0.value)) }
        return hasLatin && !hasCyrillic && !hasHebrew
    }

    private func candidateSafetyReason(for text: String) -> String? {
        let reason = classifier.correctionSafetyReason(for: text)
        return reason == "known technical term" ? nil : reason
    }

    private func correctionSafety(
        typedText: String,
        winner: CandidateScore,
        runnerUp: Double,
        appMode: AppBehaviorMode,
        terminatorType: String
    ) -> (features: CorrectionSafetyFeatures, prediction: CorrectionSafetyPrediction, fallbackPrediction: CorrectionSafetyPrediction) {
        let technicalReason = classifier.correctionSafetyReason(for: typedText)
            ?? candidateSafetyReason(for: winner.candidate.text)
        let features = CorrectionSafetyFeatureExtractor.make(
            typedText: typedText,
            candidate: winner.candidate.text,
            targetLanguage: winner.candidate.language,
            ruleScore: winner.score,
            runnerUpScore: runnerUp,
            appMode: appMode,
            terminatorType: terminatorType,
            isTechnicalContext: technicalReason != nil
        )
        return (features, safetyClassifier.prediction(for: features), fallbackSafetyClassifier.prediction(for: features))
    }

    private func normalizedHebrewFinalLetters(_ text: String) -> String {
        guard text.count >= 2, let last = text.last else { return text }
        let replacements: [Character: Character] = [
            "כ": "ך",
            "מ": "ם",
            "נ": "ן",
            "פ": "ף",
            "צ": "ץ"
        ]
        guard let final = replacements[last] else { return text }
        return String(text.dropLast()) + String(final)
    }

    private func hebrewAutomaticSafetyReason(
        for candidate: LayoutCandidate,
        score: Double,
        margin: Double,
        confidenceThreshold: Double,
        minimumConfidenceDelta: Double
    ) -> String? {
        guard candidate.language == .hebrew else { return nil }

        let letterCount = candidate.text.unicodeScalars
            .filter { (0x0590...0x05FF).contains(Int($0.value)) }
            .count
        guard letterCount <= 3 else { return nil }

        let normalized = candidate.text.lowercased()
        if letterCount <= 2 && !automaticHebrewShortFunctionalWords.contains(normalized) {
            return "Skipped Hebrew short-word safety"
        }

        if score < max(confidenceThreshold, 0.82) || margin < max(minimumConfidenceDelta, 0.30) {
            return "Skipped Hebrew short-word low confidence"
        }

        return nil
    }

    private func casingAdjustedReplacement(_ replacement: String, language: KeyboardLanguage, typedText: String) -> String {
        guard language != .hebrew,
              !classifier.hasPreferredSpelling(for: replacement, language: language) else {
            return replacement
        }

        if isAllUppercaseWord(typedText) {
            return replacement.uppercased()
        }

        if isTitleCaseWord(typedText) {
            return replacement.prefix(1).uppercased() + replacement.dropFirst().lowercased()
        }

        if isMixedLayoutWord(typedText), hasSuspiciousCasing(replacement) {
            return replacement.lowercased()
        }

        return replacement
    }

    private func hasSuspiciousCasing(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard letters.count >= 3 else { return false }
        guard text.rangeOfCharacter(from: .uppercaseLetters) != nil,
              text.rangeOfCharacter(from: .lowercaseLetters) != nil else {
            return false
        }

        return !isTitleCaseWord(text)
    }

    private func isAllUppercaseWord(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard letters.count >= 2 else { return false }
        return letters.allSatisfy { CharacterSet.uppercaseLetters.contains($0) }
    }

    private func isTitleCaseWord(_ text: String) -> Bool {
        let characters = Array(text)
        guard characters.count >= 2,
              let first = characters.first,
              String(first).rangeOfCharacter(from: .uppercaseLetters) != nil else {
            return false
        }

        let rest = String(characters.dropFirst())
        return rest.rangeOfCharacter(from: .uppercaseLetters) == nil
            && rest.rangeOfCharacter(from: .lowercaseLetters) != nil
    }

    private func shortWordDecision(for strokes: [KeyStroke], typedText: String, mode: ShortWordMode) -> CorrectionDecision? {
        guard (1...2).contains(strokes.count),
              !classifier.looksUnsafeForCorrection(typedText) else {
            return nil
        }

        if let decision = shortRussianPronounDecision(for: strokes, typedText: typedText) {
            return decision
        }

        if let decision = shortEnglishPronounDecision(for: strokes, typedText: typedText) {
            return decision
        }

        if let decision = shortFunctionalWordDecision(for: strokes, typedText: typedText, mode: mode) {
            return decision
        }

        return nil
    }

    private func shortRussianPronounDecision(for strokes: [KeyStroke], typedText: String) -> CorrectionDecision? {
        guard enabledLanguages.contains(.russian),
              ["z", "Z"].contains(typedText) else {
            return nil
        }

        let replacement = typedText == "Z" ? "Я" : "я"
        guard !learningStore.isSuppressed(original: typedText, replacement: replacement),
              LayoutEngine.candidates(for: strokes, enabledLanguages: enabledLanguages)
                .contains(LayoutCandidate(language: .russian, text: replacement)) else {
            return nil
        }

        return CorrectionDecision(
            replacement: replacement,
            language: .russian,
            score: 0.95,
            runnerUpScore: 0
        )
    }

    private func shortEnglishPronounDecision(for strokes: [KeyStroke], typedText: String) -> CorrectionDecision? {
        guard enabledLanguages.contains(.english),
              ["ш", "Ш"].contains(typedText) else {
            return nil
        }

        let replacement = "I"
        guard !learningStore.isSuppressed(original: typedText, replacement: replacement),
              LayoutEngine.candidates(for: strokes, enabledLanguages: enabledLanguages)
                .contains(LayoutCandidate(language: .english, text: typedText == "Ш" ? "I" : "i")) else {
            return nil
        }

        return CorrectionDecision(
            replacement: replacement,
            language: .english,
            score: 0.95,
            runnerUpScore: 0
        )
    }

    private func shortFunctionalWordDecision(for strokes: [KeyStroke], typedText: String, mode: ShortWordMode) -> CorrectionDecision? {
        guard !isAllUppercaseWord(typedText) else { return nil }

        let normalizedTypedText = typedText.lowercased()
        let currentLanguage = LayoutEngine.detectScriptLanguage(for: typedText)
        let candidates = LayoutEngine.candidates(for: strokes, enabledLanguages: enabledLanguages)
            .filter { candidate in
                candidate.text != typedText
                    && candidate.language != currentLanguage
                    && classifier.isSafeShortFunctionalWord(candidate.text, language: candidate.language)
                    && isAllowedShortFunctionalCandidate(candidate, mode: mode)
            }

        guard candidates.count == 1, let candidate = candidates.first else {
            return nil
        }

        let replacement = preferredShortFunctionalSpelling(for: candidate.text, language: candidate.language)
        guard replacement.lowercased() != normalizedTypedText,
              !learningStore.isSuppressed(original: typedText, replacement: replacement) else {
            return nil
        }

        return CorrectionDecision(
            replacement: replacement,
            language: candidate.language,
            score: 0.90,
            runnerUpScore: 0
        )
    }

    private func isAllowedShortFunctionalCandidate(_ candidate: LayoutCandidate, mode: ShortWordMode) -> Bool {
        guard candidate.language == .hebrew else { return true }
        guard mode == .automatic else { return true }

        return automaticHebrewShortFunctionalWords.contains(candidate.text.lowercased())
    }

    private func preferredShortFunctionalSpelling(for text: String, language: KeyboardLanguage) -> String {
        if language == .english, text.lowercased() == "i" {
            return "I"
        }
        return text
    }

    private func containsMultipleScripts(_ text: String) -> Bool {
        let scripts = Set(text.unicodeScalars.compactMap { scalar -> KeyboardLanguage? in
            if (0x0400...0x04FF).contains(Int(scalar.value)) {
                return .russian
            }
            if (0x0590...0x05FF).contains(Int(scalar.value)) {
                return .hebrew
            }
            if ("a"..."z").contains(String(scalar).lowercased()) {
                return .english
            }
            return nil
        })
        return scripts.count > 1
    }

    private func isMixedLayoutWord(_ text: String) -> Bool {
        if containsMultipleScripts(text) {
            return true
        }

        let layoutLetterPunctuation = CharacterSet(charactersIn: ".,;:'\"`‘’“”!?()[]{}<>%^*-")
        let hasAmbiguousPunctuationKey = text.rangeOfCharacter(from: layoutLetterPunctuation) != nil
        let hasLetters = text.rangeOfCharacter(from: .letters) != nil
        return hasAmbiguousPunctuationKey && hasLetters
    }
}

enum TextReplacementPerformer {
    private enum FocusedTextReplacementResult {
        case replaced
        case unavailable
        case expectedTextMismatch
    }

    private static let maximumSyntheticReplacementLength = 16
    private static let shortSyntheticKeyPause: useconds_t = 8_000
    private static let syntheticDeletionSettlePause: useconds_t = 16_000
    private static let syntheticInsertionSettlePause: useconds_t = 35_000

    @discardableResult
    static func replacePreviousText(
        characterCount: Int,
        expectedPreviousText: String? = nil,
        with replacement: String,
        allowSyntheticFallback: Bool = false
    ) -> Bool {
        replacePreviousTextMethod(
            characterCount: characterCount,
            expectedPreviousText: expectedPreviousText,
            with: replacement,
            syntheticReplacement: replacement,
            allowSyntheticFallback: allowSyntheticFallback
        ) != nil
    }

    static func replacePreviousTextMethod(
        characterCount: Int,
        expectedPreviousText: String? = nil,
        with replacement: String,
        syntheticReplacement: String,
        allowSyntheticFallback: Bool = false
    ) -> TextReplacementMethod? {
        guard characterCount > 0, !replacement.isEmpty else { return nil }

        switch replaceFocusedTextPreviousCharacters(characterCount: characterCount, expectedPreviousText: expectedPreviousText, with: replacement) {
        case .replaced:
            return .accessibility
        case .expectedTextMismatch:
            return nil
        case .unavailable:
            break
        }

        guard allowSyntheticFallback,
              characterCount <= maximumSyntheticReplacementLength else {
            return nil
        }

        for _ in 0..<characterCount {
            postKey(keyCode: 51)
            usleep(shortSyntheticKeyPause)
        }
        usleep(syntheticDeletionSettlePause)
        guard postUnicodeText(syntheticReplacement) else { return nil }
        usleep(syntheticInsertionSettlePause)
        return .synthetic
    }

    @discardableResult
    static func replaceSelection(expectedText: String, with replacement: String) -> Bool {
        guard !expectedText.isEmpty, !replacement.isEmpty else { return false }

        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElementRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementRef
        ) == .success, let focusedElementRef else {
            return false
        }

        let focusedElement = focusedElementRef as! AXUIElement
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focusedElement,
            kAXValueAttribute as CFString,
            &valueRef
        ) == .success,
            let value = valueRef as? String else {
            return false
        }

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRef
        ) == .success, let rangeRef else {
            return false
        }

        let axRange = rangeRef as! AXValue
        var selectedRange = CFRange()
        guard AXValueGetValue(axRange, .cfRange, &selectedRange), selectedRange.length > 0 else {
            return false
        }

        let nsValue = value as NSString
        let range = NSRange(location: selectedRange.location, length: selectedRange.length)
        guard NSMaxRange(range) <= nsValue.length,
              nsValue.substring(with: range) == expectedText else {
            return false
        }

        let updatedValue = nsValue.replacingCharacters(in: range, with: replacement)
        if AXUIElementSetAttributeValue(
            focusedElement,
            kAXValueAttribute as CFString,
            updatedValue as CFString
        ) == .success {
            setCaret(on: focusedElement, location: range.location + (replacement as NSString).length)
            return true
        }

        guard AXUIElementSetAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            replacement as CFString
        ) == .success else {
            return false
        }
        setCaret(on: focusedElement, location: range.location + (replacement as NSString).length)
        return true
    }

    static func copySpaceTokenBeforeCursor() -> String? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElementRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementRef
        ) == .success, let focusedElementRef else {
            return nil
        }

        let focusedElement = focusedElementRef as! AXUIElement
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focusedElement,
            kAXValueAttribute as CFString,
            &valueRef
        ) == .success, let value = valueRef as? String else {
            return nil
        }

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRef
        ) == .success, let rangeRef else {
            return nil
        }

        let axRange = rangeRef as! AXValue
        var selectedRange = CFRange()
        guard AXValueGetValue(axRange, .cfRange, &selectedRange),
              selectedRange.length == 0,
              selectedRange.location > 0 else {
            return nil
        }

        let nsValue = value as NSString
        guard selectedRange.location <= nsValue.length else { return nil }

        var tokenEnd = selectedRange.location
        while tokenEnd > 0 {
            let previous = nsValue.substring(with: NSRange(location: tokenEnd - 1, length: 1))
            if previous.rangeOfCharacter(from: .whitespacesAndNewlines) == nil { break }
            tokenEnd -= 1
        }
        guard tokenEnd > 0 else { return nil }

        var tokenStart = tokenEnd
        while tokenStart > 0 {
            let previous = nsValue.substring(with: NSRange(location: tokenStart - 1, length: 1))
            if previous.rangeOfCharacter(from: .whitespacesAndNewlines) != nil { break }
            tokenStart -= 1
        }

        let tokenRange = NSRange(location: tokenStart, length: tokenEnd - tokenStart)
        guard tokenRange.length > 0 else { return nil }

        var axTokenRange = CFRange(location: tokenRange.location, length: tokenRange.length)
        guard let tokenAXRange = AXValueCreate(.cfRange, &axTokenRange),
              AXUIElementSetAttributeValue(
                focusedElement,
                kAXSelectedTextRangeAttribute as CFString,
                tokenAXRange
              ) == .success else {
            return nil
        }

        return nsValue.substring(with: tokenRange)
    }

    static func collapseSelectionToEnd() {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElementRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementRef
        ) == .success, let focusedElementRef else {
            return
        }

        let focusedElement = focusedElementRef as! AXUIElement
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRef
        ) == .success, let rangeRef else {
            return
        }

        let axRange = rangeRef as! AXValue
        var selectedRange = CFRange()
        guard AXValueGetValue(axRange, .cfRange, &selectedRange),
              selectedRange.length > 0 else {
            return
        }

        var collapsedRange = CFRange(location: selectedRange.location + selectedRange.length, length: 0)
        guard let collapsedAXRange = AXValueCreate(.cfRange, &collapsedRange) else { return }
        _ = AXUIElementSetAttributeValue(
            focusedElement,
            kAXSelectedTextRangeAttribute as CFString,
            collapsedAXRange
        )
    }

    private static func replaceFocusedTextPreviousCharacters(characterCount: Int, expectedPreviousText: String?, with replacement: String) -> FocusedTextReplacementResult {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElementRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementRef
        ) == .success, let focusedElementRef else {
            return .unavailable
        }

        let focusedElement = focusedElementRef as! AXUIElement
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focusedElement,
            kAXValueAttribute as CFString,
            &valueRef
        ) == .success, let value = valueRef as? String else {
            return .unavailable
        }

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRef
        ) == .success, let rangeRef else {
            return .unavailable
        }
        let axRange = rangeRef as! AXValue

        var selectedRange = CFRange()
        guard AXValueGetValue(axRange, .cfRange, &selectedRange),
              selectedRange.length == 0,
              selectedRange.location >= characterCount else {
            return .unavailable
        }

        let nsValue = value as NSString
        guard selectedRange.location <= nsValue.length else {
            return .unavailable
        }

        let replacementRange = NSRange(
            location: selectedRange.location - characterCount,
            length: characterCount
        )
        if let expectedPreviousText,
           nsValue.substring(with: replacementRange) != expectedPreviousText {
            return .expectedTextMismatch
        }

        let updatedValue = nsValue.replacingCharacters(in: replacementRange, with: replacement)
        if AXUIElementSetAttributeValue(
            focusedElement,
            kAXValueAttribute as CFString,
            updatedValue as CFString
        ) == .success {
            setCaret(
                on: focusedElement,
                location: replacementRange.location + (replacement as NSString).length
            )
            return .replaced
        }

        var selectedReplacementRange = CFRange(
            location: replacementRange.location,
            length: replacementRange.length
        )
        guard let selectedReplacementAXRange = AXValueCreate(.cfRange, &selectedReplacementRange),
              AXUIElementSetAttributeValue(
                focusedElement,
                kAXSelectedTextRangeAttribute as CFString,
                selectedReplacementAXRange
              ) == .success else {
            return .unavailable
        }

        if AXUIElementSetAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            replacement as CFString
        ) == .success {
            setCaret(
                on: focusedElement,
                location: replacementRange.location + (replacement as NSString).length
            )
            return .replaced
        }

        setCaret(on: focusedElement, location: selectedRange.location)
        return .unavailable
    }

    private static func setCaret(on element: AXUIElement, location: Int) {
        var range = CFRange(location: location, length: 0)
        guard let axRange = AXValueCreate(.cfRange, &range) else { return }
        _ = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            axRange
        )
    }

    private static func postKey(keyCode: CGKeyCode, flags: CGEventFlags = []) {
        guard
            let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
            let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        else {
            return
        }

        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private static func postUnicodeText(_ text: String) -> Bool {
        let unicode = Array(text.utf16)
        guard !unicode.isEmpty,
              let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
            return false
        }

        down.keyboardSetUnicodeString(stringLength: unicode.count, unicodeString: unicode)
        up.keyboardSetUnicodeString(stringLength: 0, unicodeString: [])
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
