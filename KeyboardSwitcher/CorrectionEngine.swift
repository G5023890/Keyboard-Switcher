import AppKit
import Foundation

struct CorrectionDecision: Equatable {
    let replacement: String
    let language: KeyboardLanguage
    let score: Double
    let runnerUpScore: Double
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

final class CorrectionEngine {
    private enum ShortWordMode {
        case automatic
        case manual
    }

    var confidenceThreshold = 0.42
    var minimumConfidenceDelta = 0.20
    var enabledLanguages = Set(KeyboardLanguage.allCases)
    var learnsFromManualCorrections = true

    private let classifier = TextClassifier()
    private let safetyClassifier: CorrectionSafetyClassifying
    private let fallbackSafetyClassifier = RuleBasedCorrectionSafetyClassifier()
    private let undoController: CorrectionUndoManager
    private let learningStore: LearningStore
    private let commonCandidateFixes = [
        "спосибо": "спасибо"
    ]
    private let shortFunctionalWords: [KeyboardLanguage: Set<String>] = [
        .english: ["a", "as", "at", "by", "i", "if", "in", "is", "it", "of", "on", "or", "to", "we"],
        .russian: ["а", "в", "и", "к", "о", "с", "у", "я"],
        .hebrew: ["ב", "ו", "זה", "לא", "ל", "מה", "על", "עם", "של"]
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

    func evaluate(
        strokes: [KeyStroke],
        typedText: String,
        allowsShortFunctionalWords: Bool = true,
        profile: CorrectionProfile = .normal,
        appMode: AppBehaviorMode = .normal,
        terminatorType: String = "unknown"
    ) -> CorrectionEvaluation {
        let activeConfidenceThreshold = max(0, min(confidenceThreshold + profile.confidenceThresholdOffset, 1))
        let activeMinimumConfidenceDelta = max(0, min(profile.minimumDeltaOverride ?? minimumConfidenceDelta, 1))

        if allowsShortFunctionalWords, let decision = shortWordDecision(for: strokes, typedText: typedText, mode: .automatic) {
            return makeEvaluation(
                typedText: typedText,
                candidateScores: [],
                decision: decision,
                reason: "Short functional word",
                confidenceThreshold: activeConfidenceThreshold,
                minimumConfidenceDelta: activeMinimumConfidenceDelta
            )
        }

        guard strokes.count >= 3 else {
            return makeEvaluation(typedText: typedText, candidateScores: [], decision: nil, reason: "Need at least 3 letters", confidenceThreshold: activeConfidenceThreshold, minimumConfidenceDelta: activeMinimumConfidenceDelta)
        }

        if let safetyReason = classifier.correctionSafetyReason(for: typedText) {
            return makeEvaluation(typedText: typedText, candidateScores: [], decision: nil, reason: "Skipped \(safetyReason)", confidenceThreshold: activeConfidenceThreshold, minimumConfidenceDelta: activeMinimumConfidenceDelta)
        }

        if hasSuspiciousCasing(typedText) {
            return makeEvaluation(typedText: typedText, candidateScores: [], decision: nil, reason: "Skipped suspicious casing", confidenceThreshold: activeConfidenceThreshold, minimumConfidenceDelta: activeMinimumConfidenceDelta)
        }

        let rawCandidates = LayoutEngine.candidates(for: strokes, enabledLanguages: enabledLanguages)
            .filter { $0.text != typedText }

        if let unsafeCandidate = rawCandidates.first(where: { candidateSafetyReason(for: $0.text) != nil }),
           let safetyReason = candidateSafetyReason(for: unsafeCandidate.text) {
            return makeEvaluation(typedText: typedText, candidateScores: [], decision: nil, reason: "Skipped \(safetyReason)", confidenceThreshold: activeConfidenceThreshold, minimumConfidenceDelta: activeMinimumConfidenceDelta)
        }

        if let learned = learningStore.preference(for: typedText),
           enabledLanguages.contains(learned.language),
           learned.replacement != typedText,
           !learningStore.isSuppressed(original: typedText, replacement: learned.replacement) {
            let replacement = casingAdjustedReplacement(
                classifier.preferredSpelling(for: learned.replacement, language: learned.language),
                language: learned.language,
                typedText: typedText
            )
            let decision = CorrectionDecision(
                replacement: replacement,
                language: learned.language,
                score: min(0.98, 0.78 + Double(min(learned.uses, 10)) * 0.02),
                runnerUpScore: 0
            )
            return makeEvaluation(typedText: typedText, candidateScores: [], decision: decision, reason: "Learned correction", confidenceThreshold: activeConfidenceThreshold, minimumConfidenceDelta: activeMinimumConfidenceDelta)
        }

        let candidates = rawCandidates
            .map(normalizedCandidate)

        let scores = candidates.map(classifier.score).sorted { $0.score > $1.score }
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

    func applyCorrection(replacingPreviousCharacterCount originalLength: Int, original: String, with replacement: String, language: KeyboardLanguage) {
        let previousText = String(original.prefix(originalLength))
        TextReplacementPerformer.replacePreviousText(characterCount: originalLength, expectedPreviousText: previousText, with: replacement)
        undoController.record(original: original, replacement: replacement, language: language, origin: .automatic)
    }

    func manualReplacement(for word: String) -> CorrectionDecision? {
        manualReplacements(for: word).first
    }

    func manualReplacements(for word: String) -> [CorrectionDecision] {
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
            .map(normalizedCandidate)
            .filter { candidate in
                if candidate.text == word { return false }
                if let currentLanguage {
                    return candidate.language != currentLanguage
                }
                return true
            }

        let scored = candidates.map(classifier.score).sorted { $0.score > $1.score }
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
        switch language {
        case .english:
            return [.russian, .hebrew]
        case .russian:
            return [.english, .hebrew]
        case .hebrew:
            return [.english, .russian]
        }
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

    private func normalizedCandidate(_ candidate: LayoutCandidate) -> LayoutCandidate {
        let fixedText = commonCandidateFixes[candidate.text.lowercased()] ?? candidate.text
        let normalizedText = candidate.language == .hebrew ? normalizedHebrewFinalLetters(fixedText) : fixedText
        let preferredText = classifier.preferredSpelling(for: normalizedText, language: candidate.language)
        return LayoutCandidate(language: candidate.language, text: preferredText)
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
        let normalizedTypedText = typedText.lowercased()
        let currentLanguage = LayoutEngine.detectScriptLanguage(for: typedText)
        let candidates = LayoutEngine.candidates(for: strokes, enabledLanguages: enabledLanguages)
            .filter { candidate in
                candidate.text != typedText
                    && candidate.language != currentLanguage
                    && shortFunctionalWords[candidate.language]?.contains(candidate.text.lowercased()) == true
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

        let layoutLetterPunctuation = CharacterSet(charactersIn: ",.;'[]")
        let hasAmbiguousPunctuationKey = text.rangeOfCharacter(from: layoutLetterPunctuation) != nil
        let hasLetters = text.rangeOfCharacter(from: .letters) != nil
        return hasAmbiguousPunctuationKey && hasLetters
    }
}

enum TextReplacementPerformer {
    private static let pasteboardRestoreLock = NSLock()
    private static let shortSyntheticKeyPause: useconds_t = 12_000
    nonisolated(unsafe) private static var pasteboardRestoreToken = UUID()

    static func replacePreviousText(characterCount: Int, expectedPreviousText: String? = nil, with replacement: String) {
        guard characterCount > 0, !replacement.isEmpty else { return }

        if replaceFocusedTextPreviousCharacters(characterCount: characterCount, expectedPreviousText: expectedPreviousText, with: replacement) {
            return
        }

        for _ in 0..<characterCount {
            postKey(keyCode: 51)
            usleep(shortSyntheticKeyPause)
        }
        usleep(shortSyntheticKeyPause * 2)
        pasteText(replacement)
    }

    static func replaceSelection(with replacement: String) {
        guard !replacement.isEmpty else { return }
        pasteText(replacement)
    }

    static func copyWordBeforeCursor() -> String? {
        let pasteboard = NSPasteboard.general
        let preservedString = pasteboard.string(forType: .string)
        let previousChangeCount = pasteboard.changeCount

        pasteboard.clearContents()
        postKey(keyCode: 123, flags: [.maskAlternate, .maskShift])
        postKey(keyCode: 8, flags: .maskCommand)

        let copied = waitForPasteboardString(changeCount: previousChangeCount)
        restorePasteboardString(preservedString)
        return copied?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func pasteText(_ text: String) {
        let pasteboard = NSPasteboard.general
        let preservedString = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        postKey(keyCode: 9, flags: .maskCommand)
        schedulePasteboardRestore(expectedTemporaryString: text, preservedString: preservedString)
    }

    private static func replaceFocusedTextPreviousCharacters(characterCount: Int, expectedPreviousText: String?, with replacement: String) -> Bool {
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
        ) == .success, let value = valueRef as? String else {
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
        guard AXValueGetValue(axRange, .cfRange, &selectedRange),
              selectedRange.length == 0,
              selectedRange.location >= characterCount else {
            return false
        }

        let nsValue = value as NSString
        guard selectedRange.location <= nsValue.length else {
            return false
        }

        let replacementRange = NSRange(
            location: selectedRange.location - characterCount,
            length: characterCount
        )
        if let expectedPreviousText,
           nsValue.substring(with: replacementRange) != expectedPreviousText {
            return false
        }

        let updatedValue = nsValue.replacingCharacters(in: replacementRange, with: replacement)
        guard AXUIElementSetAttributeValue(
            focusedElement,
            kAXValueAttribute as CFString,
            updatedValue as CFString
        ) == .success else {
            return false
        }

        var updatedRange = CFRange(
            location: replacementRange.location + (replacement as NSString).length,
            length: 0
        )
        guard let updatedAXRange = AXValueCreate(.cfRange, &updatedRange) else {
            return true
        }
        _ = AXUIElementSetAttributeValue(
            focusedElement,
            kAXSelectedTextRangeAttribute as CFString,
            updatedAXRange
        )
        return true
    }

    private static func waitForPasteboardString(changeCount: Int) -> String? {
        let pasteboard = NSPasteboard.general
        let timeout = Date().addingTimeInterval(0.25)

        while Date() < timeout {
            if pasteboard.changeCount != changeCount, let string = pasteboard.string(forType: .string), !string.isEmpty {
                return string
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }

        return pasteboard.string(forType: .string)
    }

    private static func restorePasteboardString(_ string: String?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let string {
            pasteboard.setString(string, forType: .string)
        }
    }

    private static func schedulePasteboardRestore(expectedTemporaryString: String, preservedString: String?) {
        let token = UUID()
        setPasteboardRestoreToken(token)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard currentPasteboardRestoreToken() == token else { return }

            let pasteboard = NSPasteboard.general
            guard pasteboard.string(forType: .string) == expectedTemporaryString else {
                return
            }

            restorePasteboardString(preservedString)
        }
    }

    private static func setPasteboardRestoreToken(_ token: UUID) {
        pasteboardRestoreLock.lock()
        pasteboardRestoreToken = token
        pasteboardRestoreLock.unlock()
    }

    private static func currentPasteboardRestoreToken() -> UUID {
        pasteboardRestoreLock.lock()
        let token = pasteboardRestoreToken
        pasteboardRestoreLock.unlock()
        return token
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
}
