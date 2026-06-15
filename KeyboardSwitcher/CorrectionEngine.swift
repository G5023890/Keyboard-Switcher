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
    let reason: String
}

final class CorrectionEngine {
    var confidenceThreshold = 0.42
    var enabledLanguages = Set(KeyboardLanguage.allCases)
    var learnsFromManualCorrections = true

    private let classifier = TextClassifier()
    private let undoController: CorrectionUndoManager
    private let learningStore: LearningStore
    private let commonCandidateFixes = [
        "спосибо": "спасибо"
    ]

    init(undoController: CorrectionUndoManager, learningStore: LearningStore = .shared) {
        self.undoController = undoController
        self.learningStore = learningStore
    }

    func decision(for strokes: [KeyStroke], typedText: String) -> CorrectionDecision? {
        evaluate(strokes: strokes, typedText: typedText).decision
    }

    func evaluate(strokes: [KeyStroke], typedText: String) -> CorrectionEvaluation {
        guard strokes.count >= 3 else {
            return CorrectionEvaluation(typedText: typedText, candidateScores: [], decision: nil, reason: "Need at least 3 letters")
        }

        guard !classifier.looksUnsafeForCorrection(typedText) else {
            return CorrectionEvaluation(typedText: typedText, candidateScores: [], decision: nil, reason: "Skipped unsafe text")
        }

        if let learned = learningStore.preference(for: typedText),
           enabledLanguages.contains(learned.language),
           learned.replacement != typedText,
           !learningStore.isSuppressed(original: typedText, replacement: learned.replacement) {
            let replacement = classifier.preferredSpelling(for: learned.replacement, language: learned.language)
            let decision = CorrectionDecision(
                replacement: replacement,
                language: learned.language,
                score: min(0.98, 0.78 + Double(min(learned.uses, 10)) * 0.02),
                runnerUpScore: 0
            )
            return CorrectionEvaluation(typedText: typedText, candidateScores: [], decision: decision, reason: "Learned correction")
        }

        let candidates = LayoutEngine.candidates(for: strokes, enabledLanguages: enabledLanguages)
            .map(normalizedCandidate)
            .filter { $0.text != typedText }

        let scores = candidates.map(classifier.score).sorted { $0.score > $1.score }
        guard let winner = scores.first else {
            return CorrectionEvaluation(typedText: typedText, candidateScores: scores, decision: nil, reason: "No alternate layout candidate")
        }

        let runnerUp = scores.dropFirst().first?.score ?? 0
        let margin = winner.score - runnerUp

        guard winner.score >= confidenceThreshold else {
            return CorrectionEvaluation(typedText: typedText, candidateScores: scores, decision: nil, reason: "Winner below confidence threshold")
        }

        guard classifier.hasStrongLexicalEvidence(winner.candidate) else {
            return CorrectionEvaluation(typedText: typedText, candidateScores: scores, decision: nil, reason: "Winner lacks dictionary evidence")
        }

        guard !learningStore.isSuppressed(original: typedText, replacement: winner.candidate.text) else {
            return CorrectionEvaluation(typedText: typedText, candidateScores: scores, decision: nil, reason: "Skipped learned suppression")
        }

        guard margin >= 0.20 else {
            return CorrectionEvaluation(typedText: typedText, candidateScores: scores, decision: nil, reason: "Winner margin too small")
        }

        let decision = CorrectionDecision(
            replacement: winner.candidate.text,
            language: winner.candidate.language,
            score: winner.score,
            runnerUpScore: runnerUp
        )

        return CorrectionEvaluation(typedText: typedText, candidateScores: scores, decision: decision, reason: "Corrected")
    }

    func applyCorrection(replacingPreviousCharacterCount originalLength: Int, original: String, with replacement: String, language: KeyboardLanguage) {
        TextReplacementPerformer.replacePreviousText(characterCount: originalLength, with: replacement)
        undoController.record(original: original, replacement: replacement, language: language, origin: .automatic)
    }

    func manualReplacement(for word: String) -> CorrectionDecision? {
        guard word.count >= 2 else { return nil }
        let isMixedLayoutWord = isMixedLayoutWord(word)
        let resolvedStrokes = isMixedLayoutWord ? LayoutEngine.mixedLayoutStrokes(for: word) : LayoutEngine.strokes(for: word)
        guard let strokes = resolvedStrokes else { return nil }

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
        if let best = scored.first(where: { classifier.hasStrongLexicalEvidence($0.candidate) }), best.score >= 0.28 {
            return CorrectionDecision(
                replacement: best.candidate.text,
                language: best.candidate.language,
                score: best.score,
                runnerUpScore: scored.dropFirst().first?.score ?? 0
            )
        }

        if currentLanguage == nil {
            return nil
        }

        if let currentLanguage {
            let cycle = manualLanguageCycle(from: currentLanguage)
            for language in cycle {
                if let candidate = candidates.first(where: { $0.language == language }) {
                    return CorrectionDecision(replacement: candidate.text, language: language, score: 0, runnerUpScore: 0)
                }
            }
        }

        return nil
    }

    func recordManualCorrection(original: String, replacement: String) {
        guard let language = LayoutEngine.detectScriptLanguage(for: replacement) else { return }
        if learnsFromManualCorrections {
            learningStore.recordPreference(original: original, replacement: replacement, language: language)
        }
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

    private func normalizedCandidate(_ candidate: LayoutCandidate) -> LayoutCandidate {
        let fixedText = commonCandidateFixes[candidate.text.lowercased()] ?? candidate.text
        let preferredText = classifier.preferredSpelling(for: fixedText, language: candidate.language)
        return LayoutCandidate(language: candidate.language, text: preferredText)
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
    static func replacePreviousText(characterCount: Int, with replacement: String) {
        guard characterCount > 0, !replacement.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        let preservedString = pasteboard.string(forType: .string)
        let previousChangeCount = pasteboard.changeCount

        for _ in 0..<characterCount {
            postKey(keyCode: 51)
        }

        pasteboard.clearContents()
        pasteboard.setString(replacement, forType: .string)
        postKey(keyCode: 9, flags: .maskCommand)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let pasteboard = NSPasteboard.general
            guard pasteboard.changeCount != previousChangeCount else { return }
            pasteboard.clearContents()
            if let preservedString {
                pasteboard.setString(preservedString, forType: .string)
            }
        }
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

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            restorePasteboardString(preservedString)
        }
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
