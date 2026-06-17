import CoreGraphics
import XCTest
@testable import Keyboard_Switcher

private struct FixedSafetyClassifier: CorrectionSafetyClassifying {
    let action: CorrectionSafetyAction
    let modelIdentifier = "FixedSafetyClassifier"

    func prediction(for features: CorrectionSafetyFeatures) -> CorrectionSafetyPrediction {
        CorrectionSafetyPrediction(
            action: action,
            confidence: 0.99,
            modelIdentifier: modelIdentifier,
            explanation: "test override"
        )
    }
}

final class KeyboardSwitcherCoreTests: XCTestCase {
    private func isolatedDefaults(name: String = #function) -> UserDefaults {
        let suiteName = "KeyboardSwitcherTests.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func isolatedLearningStore(named name: String = #function) -> LearningStore {
        LearningStore(defaults: isolatedDefaults(name: name))
    }

    func testMenuBarIconStyles() {
        XCTAssertEqual(KeyboardLanguage.english.menuBarIcon(for: .glyphs), "A")
        XCTAssertEqual(KeyboardLanguage.russian.menuBarIcon(for: .glyphs), "Я")
        XCTAssertEqual(KeyboardLanguage.hebrew.menuBarIcon(for: .glyphs), "א")

        XCTAssertEqual(KeyboardLanguage.english.menuBarIcon(for: .flags), "🇺🇸")
        XCTAssertEqual(KeyboardLanguage.russian.menuBarIcon(for: .flags), "🇷🇺")
        XCTAssertEqual(KeyboardLanguage.hebrew.menuBarIcon(for: .flags), "🇮🇱")

        XCTAssertEqual(KeyboardLanguage.english.menuBarIcon(for: .minimal), "●")
        XCTAssertEqual(KeyboardLanguage.russian.menuBarIcon(for: .minimal), "●")
        XCTAssertEqual(KeyboardLanguage.hebrew.menuBarIcon(for: .minimal), "●")
    }

    func testCorrectionSensitivityThresholds() {
        XCTAssertEqual(CorrectionSensitivity.conservative.threshold, 0.72)
        XCTAssertEqual(CorrectionSensitivity.balanced.threshold, 0.62)
        XCTAssertEqual(CorrectionSensitivity.aggressive.threshold, 0.55)
        XCTAssertEqual(CorrectionSensitivity.closest(to: 0.62), .balanced)
        XCTAssertEqual(CorrectionSensitivity.closest(to: 0.70), .custom)
    }

    func testPhysicalReplayRespectsCapsLockForLetters() {
        let capsG = KeyStroke(keyCode: 5, isShifted: false, isCapsLocked: true)
        let shiftCapsG = KeyStroke(keyCode: 5, isShifted: true, isCapsLocked: true)

        XCTAssertEqual(LayoutEngine.character(for: capsG, language: .english), "G")
        XCTAssertEqual(LayoutEngine.character(for: shiftCapsG, language: .english), "g")
        XCTAssertEqual(LayoutEngine.character(for: capsG, language: .russian), "П")
        XCTAssertEqual(LayoutEngine.character(for: shiftCapsG, language: .russian), "п")
    }

    func testPhysicalReplayDoesNotApplyCapsLockToPunctuation() {
        let capsSlash = KeyStroke(keyCode: 44, isShifted: false, isCapsLocked: true)
        let shiftedCapsSlash = KeyStroke(keyCode: 44, isShifted: true, isCapsLocked: true)

        XCTAssertEqual(LayoutEngine.character(for: capsSlash, language: .english), "/")
        XCTAssertEqual(LayoutEngine.character(for: shiftedCapsSlash, language: .english), "?")
    }

    func testNonReplayableModifiersAreDetected() {
        XCTAssertFalse(KeyStroke(keyCode: 5, isShifted: false, modifierFlagsRawValue: CGEventFlags.maskShift.rawValue).hasNonReplayableModifiers)
        XCTAssertTrue(KeyStroke(keyCode: 5, isShifted: false, modifierFlagsRawValue: CGEventFlags.maskAlternate.rawValue).hasNonReplayableModifiers)
        XCTAssertTrue(KeyStroke(keyCode: 5, isShifted: false, modifierFlagsRawValue: CGEventFlags.maskCommand.rawValue).hasNonReplayableModifiers)
        XCTAssertTrue(KeyStroke(keyCode: 5, isShifted: false, modifierFlagsRawValue: CGEventFlags.maskControl.rawValue).hasNonReplayableModifiers)
    }

    func testPhysicalReplaySummaryIncludesMetadata() {
        let stroke = KeyStroke(
            keyCode: 5,
            isShifted: true,
            isCapsLocked: true,
            modifierFlagsRawValue: CGEventFlags.maskShift.union(.maskAlphaShift).rawValue,
            characters: "g",
            charactersIgnoringModifiers: "g",
            inputSourceID: "com.apple.keylayout.US",
            inputLanguage: .english
        )

        let summary = LayoutEngine.physicalReplaySummary(for: [stroke])

        XCTAssertTrue(summary.contains("key:5"))
        XCTAssertTrue(summary.contains("shift"))
        XCTAssertTrue(summary.contains("caps"))
        XCTAssertTrue(summary.contains("en"))
        XCTAssertTrue(summary.contains("source:com.apple.keylayout.US"))
        XCTAssertTrue(summary.contains("chars:g"))
        XCTAssertTrue(summary.contains("base:g"))
    }

    func testAppBehaviorModesResolveProfiles() {
        XCTAssertEqual(AppBehaviorMode.excluded.correctionProfile.minimumDeltaOverride, 1)
        XCTAssertEqual(AppBehaviorMode.strict.correctionProfile.minimumDeltaOverride, 0.30)
        XCTAssertNil(AppBehaviorMode.normal.correctionProfile.minimumDeltaOverride)
        XCTAssertEqual(AppBehaviorMode.textFocused.correctionProfile.minimumDeltaOverride, 0.16)
    }

    func testCorrectionProfileTighteningKeepsStricterValues() {
        let textFocused = AppBehaviorMode.textFocused.correctionProfile
        let strict = AppBehaviorMode.strict.correctionProfile

        let combined = textFocused.tightened(with: strict)

        XCTAssertEqual(combined.confidenceThresholdOffset, 0.10, accuracy: 0.001)
        XCTAssertEqual(combined.minimumDeltaOverride, 0.30)
    }

    func testFocusedInputContextClassifiesRoles() {
        XCTAssertEqual(FocusedInputContextInspector.kind(role: "AXTextField", subrole: ""), .textField)
        XCTAssertEqual(FocusedInputContextInspector.kind(role: "AXTextArea", subrole: ""), .textArea)
        XCTAssertEqual(FocusedInputContextInspector.kind(role: "AXTextField", subrole: "AXSearchField"), .searchField)
        XCTAssertEqual(FocusedInputContextInspector.kind(role: "AXTextField", subrole: "AXSecureTextField"), .secureTextField)
        XCTAssertEqual(FocusedInputContextInspector.kind(role: "AXComboBox", subrole: ""), .comboBox)
        XCTAssertEqual(FocusedInputContextInspector.kind(role: "AXButton", subrole: ""), .unknown)
    }

    func testExclusionManagerResolvesBehaviorModes() {
        let manager = ExclusionManager(excludedBundleIdentifiers: ["com.apple.Terminal"])
        manager.appBehaviorModes["com.apple.Terminal"] = .normal
        manager.appBehaviorModes["com.apple.TextEdit"] = .strict

        XCTAssertEqual(manager.behaviorMode(for: "com.apple.Terminal"), .excluded)
        XCTAssertEqual(manager.behaviorMode(for: "com.apple.TextEdit"), .strict)
        XCTAssertEqual(ExclusionManager.defaultBehaviorMode(for: "com.apple.TextEdit"), .textFocused)
        XCTAssertEqual(ExclusionManager.defaultBehaviorMode(for: "com.apple.dt.Xcode"), .strict)
        XCTAssertEqual(ExclusionManager.defaultBehaviorMode(for: "com.todesktop.230313mzl4w4u92"), .strict)
        XCTAssertEqual(ExclusionManager.defaultBehaviorMode(for: "com.apple.Siri"), .strict)
        XCTAssertEqual(ExclusionManager.defaultBehaviorMode(for: "com.apple.Notes"), .textFocused)
        XCTAssertEqual(ExclusionManager.defaultBehaviorMode(for: "com.unknown.App"), .normal)
    }

    func testKeyboardMonitorPreferencesGateSwitchAndSound() {
        var preferences = KeyboardMonitorPreferences()
        XCTAssertTrue(preferences.shouldSwitchInputSource())
        XCTAssertTrue(preferences.shouldPlaySound(origin: .automatic))
        XCTAssertTrue(preferences.shouldPlaySound(origin: .manual))

        preferences.switchInputSourceAfterCorrection = false
        XCTAssertFalse(preferences.shouldSwitchInputSource())

        preferences.playSoundWhenLayoutCorrected = false
        XCTAssertFalse(preferences.shouldPlaySound(origin: .automatic))

        preferences.playSoundWhenLayoutCorrected = true
        preferences.playSoundOnlyForAutomaticCorrections = true
        XCTAssertTrue(preferences.shouldPlaySound(origin: .automatic))
        XCTAssertFalse(preferences.shouldPlaySound(origin: .manual))
    }

    func testManualCorrectionCanSkipLearning() {
        let undo = CorrectionUndoManager()
        let learningStore = isolatedLearningStore()
        let engine = CorrectionEngine(undoController: undo, learningStore: learningStore)
        engine.learnsFromManualCorrections = false

        engine.recordManualCorrection(original: "ghbdtn", replacement: "привет")

        XCTAssertNil(learningStore.preference(for: "ghbdtn"))
        XCTAssertTrue(undo.canUndo)
    }

    func testManualTranslationRecordsUndoWithoutLearning() {
        let undo = CorrectionUndoManager()
        let learningStore = isolatedLearningStore()
        let engine = CorrectionEngine(undoController: undo, learningStore: learningStore)

        engine.recordManualTranslation(original: "ghbdtn", replacement: "привет")

        XCTAssertNil(learningStore.preference(for: "ghbdtn"))
        XCTAssertTrue(undo.canUndo)
    }

    func testExclusionPresetsContainExpectedBundleIdentifiers() {
        XCTAssertTrue(ExclusionPreset.developerTools.bundleIdentifiers.contains("com.apple.Terminal"))
        XCTAssertFalse(ExclusionPreset.developerTools.bundleIdentifiers.contains("com.todesktop.230313mzl4w4u92"))
        XCTAssertTrue(ExclusionPreset.passwordManagers.bundleIdentifiers.contains("com.1password.1password"))
        XCTAssertTrue(ExclusionPreset.remoteDesktop.bundleIdentifiers.contains("com.microsoft.rdc.macos"))
    }

    func testRussianCandidateForPrivet() {
        let strokes = [5, 4, 11, 2, 17, 45].map { KeyStroke(keyCode: Int64($0), isShifted: false) }
        let candidates = LayoutEngine.candidates(for: strokes, enabledLanguages: Set(KeyboardLanguage.allCases))

        XCTAssertTrue(candidates.contains(LayoutCandidate(language: .english, text: "ghbdtn")))
        XCTAssertTrue(candidates.contains(LayoutCandidate(language: .russian, text: "привет")))
    }

    func testRussianCandidateForKak() {
        let strokes = [15, 3, 15].map { KeyStroke(keyCode: Int64($0), isShifted: false) }
        let candidates = LayoutEngine.candidates(for: strokes, enabledLanguages: Set(KeyboardLanguage.allCases))
        XCTAssertTrue(candidates.contains(LayoutCandidate(language: .russian, text: "как")))
    }

    func testTechnicalTokenSeparatorKeepsPathSlashInBuffer() {
        let slash = KeyStroke(keyCode: 44, isShifted: false)
        let russianYu = KeyStroke(keyCode: 47, isShifted: false)

        XCTAssertEqual(LayoutEngine.technicalTokenSeparator(for: slash, currentLanguage: .russian), "/")
        XCTAssertNil(LayoutEngine.technicalTokenSeparator(for: russianYu, currentLanguage: .russian))
    }

    func testRussianPronounYaCorrectsAsShortWord() {
        let undo = CorrectionUndoManager()
        let engine = CorrectionEngine(undoController: undo, learningStore: isolatedLearningStore())
        engine.confidenceThreshold = 0.62

        let lower = LayoutEngine.strokes(for: "z", language: .english) ?? []
        let upper = LayoutEngine.strokes(for: "Z", language: .english) ?? []

        XCTAssertEqual(engine.decision(for: lower, typedText: "z")?.replacement, "я")
        XCTAssertEqual(engine.decision(for: lower, typedText: "z")?.language, .russian)
        XCTAssertEqual(engine.decision(for: upper, typedText: "Z")?.replacement, "Я")
        XCTAssertEqual(engine.decision(for: upper, typedText: "Z")?.language, .russian)
    }

    func testManualReplacementForRussianPronounYa() {
        let undo = CorrectionUndoManager()
        let engine = CorrectionEngine(undoController: undo, learningStore: isolatedLearningStore())

        XCTAssertEqual(engine.manualReplacement(for: "z")?.replacement, "я")
        XCTAssertEqual(engine.manualReplacement(for: "z")?.language, .russian)
        XCTAssertEqual(engine.manualReplacement(for: "Z")?.replacement, "Я")
        XCTAssertEqual(engine.manualReplacement(for: "Z")?.language, .russian)
    }

    func testEnglishPronounICorrectsAsShortWord() {
        let undo = CorrectionUndoManager()
        let engine = CorrectionEngine(undoController: undo, learningStore: isolatedLearningStore())
        engine.confidenceThreshold = 0.62

        let lower = LayoutEngine.strokes(for: "ш", language: .russian) ?? []
        let upper = LayoutEngine.strokes(for: "Ш", language: .russian) ?? []

        XCTAssertEqual(engine.decision(for: lower, typedText: "ш")?.replacement, "I")
        XCTAssertEqual(engine.decision(for: lower, typedText: "ш")?.language, .english)
        XCTAssertEqual(engine.decision(for: upper, typedText: "Ш")?.replacement, "I")
        XCTAssertEqual(engine.decision(for: upper, typedText: "Ш")?.language, .english)
    }

    func testManualReplacementForEnglishPronounI() {
        let undo = CorrectionUndoManager()
        let engine = CorrectionEngine(undoController: undo, learningStore: isolatedLearningStore())

        XCTAssertEqual(engine.manualReplacement(for: "ш")?.replacement, "I")
        XCTAssertEqual(engine.manualReplacement(for: "ш")?.language, .english)
        XCTAssertEqual(engine.manualReplacement(for: "Ш")?.replacement, "I")
        XCTAssertEqual(engine.manualReplacement(for: "Ш")?.language, .english)
    }

    func testShortRussianConjunctionICorrectsAsFunctionalWord() {
        let undo = CorrectionUndoManager()
        let engine = CorrectionEngine(undoController: undo, learningStore: isolatedLearningStore())
        engine.confidenceThreshold = 0.62

        let strokes = LayoutEngine.strokes(for: "b", language: .english) ?? []

        XCTAssertEqual(engine.decision(for: strokes, typedText: "b")?.replacement, "и")
        XCTAssertEqual(engine.decision(for: strokes, typedText: "b")?.language, .russian)
        XCTAssertEqual(engine.manualReplacement(for: "b")?.replacement, "и")
    }

    func testShortFunctionalWordsRequireExplicitAllowanceForAutomaticCorrection() {
        let undo = CorrectionUndoManager()
        let engine = CorrectionEngine(undoController: undo, learningStore: isolatedLearningStore())
        engine.confidenceThreshold = 0.62

        let strokes = LayoutEngine.strokes(for: "b", language: .english) ?? []

        XCTAssertEqual(engine.decision(for: strokes, typedText: "b", allowsShortFunctionalWords: true)?.replacement, "и")
        XCTAssertNil(engine.decision(for: strokes, typedText: "b", allowsShortFunctionalWords: false))
    }

    func testShortEnglishPrepositionsCorrectAsFunctionalWords() {
        let undo = CorrectionUndoManager()
        let engine = CorrectionEngine(undoController: undo, learningStore: isolatedLearningStore())
        engine.confidenceThreshold = 0.62

        let article = LayoutEngine.strokes(for: "ф", language: .russian) ?? []
        let preposition = LayoutEngine.strokes(for: "шт", language: .russian) ?? []

        XCTAssertEqual(engine.decision(for: article, typedText: "ф")?.replacement, "a")
        XCTAssertEqual(engine.decision(for: article, typedText: "ф")?.language, .english)
        XCTAssertEqual(engine.decision(for: preposition, typedText: "шт")?.replacement, "in")
        XCTAssertEqual(engine.decision(for: preposition, typedText: "шт")?.language, .english)
    }

    func testShortHebrewFunctionalWordsAreStrictInAutomaticMode() {
        let undo = CorrectionUndoManager()
        let engine = CorrectionEngine(undoController: undo, learningStore: isolatedLearningStore())
        engine.confidenceThreshold = 0.62

        let conjunction = LayoutEngine.strokes(for: "u", language: .english) ?? []
        let possessive = LayoutEngine.strokes(for: "ak", language: .english) ?? []

        XCTAssertNil(engine.decision(for: conjunction, typedText: "u"))
        XCTAssertEqual(engine.manualReplacement(for: "u")?.replacement, "ו")
        XCTAssertEqual(engine.manualReplacement(for: "u")?.language, .hebrew)
        XCTAssertEqual(engine.decision(for: possessive, typedText: "ak")?.replacement, "של")
        XCTAssertEqual(engine.decision(for: possessive, typedText: "ak")?.language, .hebrew)
    }

    func testHebrewFinalLettersAreNormalizedForCandidates() {
        let undo = CorrectionUndoManager()
        let engine = CorrectionEngine(undoController: undo, learningStore: isolatedLearningStore())
        engine.confidenceThreshold = 0.62

        let strokes = LayoutEngine.strokes(for: "akun", language: .english) ?? []
        let evaluation = engine.evaluate(strokes: strokes, typedText: "akun")

        XCTAssertEqual(evaluation.decision?.replacement, "שלום")
        XCTAssertEqual(evaluation.decision?.language, .hebrew)
        XCTAssertTrue(evaluation.diagnosticSummary.contains("שלום"))
    }

    func testHebrewShortCandidatesStayConservativeInAutomaticMode() {
        let undo = CorrectionUndoManager()
        let engine = CorrectionEngine(undoController: undo, learningStore: isolatedLearningStore())
        engine.confidenceThreshold = 0.35

        let strokes = LayoutEngine.strokes(for: "if", language: .english) ?? []
        let evaluation = engine.evaluate(strokes: strokes, typedText: "if", allowsShortFunctionalWords: true)

        XCTAssertNil(evaluation.decision)
        XCTAssertNil(evaluation.suggestion)
        XCTAssertNotEqual(evaluation.reason, "Short functional word")
    }

    func testCorrectionDecisionForPrivet() {
        let undo = CorrectionUndoManager()
        let engine = CorrectionEngine(undoController: undo, learningStore: isolatedLearningStore())
        engine.confidenceThreshold = 0.35
        let strokes = [5, 4, 11, 2, 17, 45].map { KeyStroke(keyCode: Int64($0), isShifted: false) }

        let decision = engine.decision(for: strokes, typedText: "ghbdtn")
        XCTAssertEqual(decision?.replacement, "привет")
        XCTAssertEqual(decision?.language, .russian)
    }

    func testEvaluationExplainsPrivet() {
        let undo = CorrectionUndoManager()
        let engine = CorrectionEngine(undoController: undo, learningStore: isolatedLearningStore())
        engine.confidenceThreshold = 0.35
        let strokes = [5, 4, 11, 2, 17, 45].map { KeyStroke(keyCode: Int64($0), isShifted: false) }

        let evaluation = engine.evaluate(strokes: strokes, typedText: "ghbdtn")
        XCTAssertEqual(evaluation.reason, "Corrected")
        XCTAssertEqual(evaluation.decision?.replacement, "привет")
        XCTAssertFalse(evaluation.candidateScores.isEmpty)
    }

    func testConfidenceDeltaCanBlockCloseWinner() {
        let undo = CorrectionUndoManager()
        let engine = CorrectionEngine(undoController: undo, learningStore: isolatedLearningStore())
        engine.confidenceThreshold = 0.35
        engine.minimumConfidenceDelta = 0.99
        let strokes = LayoutEngine.strokes(for: "ghbdtn", language: .english) ?? []

        let evaluation = engine.evaluate(strokes: strokes, typedText: "ghbdtn")

        XCTAssertNil(evaluation.decision)
        XCTAssertEqual(evaluation.reason, "Winner delta below minimum")
        XCTAssertLessThan(evaluation.confidenceDelta ?? 0, engine.minimumConfidenceDelta)
    }

    func testCandidateInspectorExplainsScoresAndDelta() {
        let undo = CorrectionUndoManager()
        let engine = CorrectionEngine(undoController: undo, learningStore: isolatedLearningStore())
        engine.confidenceThreshold = 0.35
        let strokes = LayoutEngine.strokes(for: "ghbdtn", language: .english) ?? []

        let inspector = engine.evaluate(strokes: strokes, typedText: "ghbdtn").diagnosticSummary

        XCTAssertTrue(inspector.contains("Typed: ghbdtn"))
        XCTAssertTrue(inspector.contains("Replacement: ghbdtn -> привет"))
        XCTAssertTrue(inspector.contains("Threshold:"))
        XCTAssertTrue(inspector.contains("Delta:"))
        XCTAssertTrue(inspector.contains("Russian: привет"))
    }

    func testCorrectionProfileAdjustsEvaluationThresholds() {
        let undo = CorrectionUndoManager()
        let engine = CorrectionEngine(undoController: undo, learningStore: isolatedLearningStore())
        engine.confidenceThreshold = 0.62
        let strokes = LayoutEngine.strokes(for: "ghbdtn", language: .english) ?? []

        let strict = engine.evaluate(strokes: strokes, typedText: "ghbdtn", profile: AppBehaviorMode.strict.correctionProfile)
        let textFocused = engine.evaluate(strokes: strokes, typedText: "ghbdtn", profile: AppBehaviorMode.textFocused.correctionProfile)

        XCTAssertEqual(strict.confidenceThreshold, 0.72, accuracy: 0.001)
        XCTAssertEqual(strict.minimumConfidenceDelta, 0.30, accuracy: 0.001)
        XCTAssertEqual(textFocused.confidenceThreshold, 0.58, accuracy: 0.001)
        XCTAssertEqual(textFocused.minimumConfidenceDelta, 0.16, accuracy: 0.001)
    }

    func testMediumConfidenceSuggestionDoesNotAutoCorrect() {
        let undo = CorrectionUndoManager()
        let engine = CorrectionEngine(undoController: undo, learningStore: isolatedLearningStore())
        engine.confidenceThreshold = 0.62
        engine.minimumConfidenceDelta = 0.90
        let strokes = LayoutEngine.strokes(for: "ghbdtn", language: .english) ?? []

        let evaluation = engine.evaluate(strokes: strokes, typedText: "ghbdtn")

        XCTAssertNil(evaluation.decision)
        XCTAssertEqual(evaluation.reason, "Winner delta below minimum")
        XCTAssertEqual(evaluation.suggestion?.replacement, "привет")
        XCTAssertEqual(evaluation.suggestion?.language, .russian)
    }

    func testAcceptedSuggestionRecordsLearningPreference() {
        let undo = CorrectionUndoManager()
        let learningStore = isolatedLearningStore()
        let engine = CorrectionEngine(undoController: undo, learningStore: learningStore)

        engine.recordAcceptedSuggestion(original: "ghbdtn", replacement: "привет", language: .russian)

        XCTAssertEqual(learningStore.preference(for: "ghbdtn")?.replacement, "привет")
        XCTAssertEqual(learningStore.preference(for: "ghbdtn")?.language, .russian)
    }

    func testIgnoredSuggestionRecordsSuppression() {
        let undo = CorrectionUndoManager()
        let learningStore = isolatedLearningStore()
        let engine = CorrectionEngine(undoController: undo, learningStore: learningStore)

        engine.recordIgnoredSuggestion(original: "ghbdtn", replacement: "привет")

        XCTAssertTrue(learningStore.isSuppressed(original: "ghbdtn", replacement: "привет"))
    }

    func testUnsafeTextIsNotCorrected() {
        let undo = CorrectionUndoManager()
        let engine = CorrectionEngine(undoController: undo)
        let strokes = [13, 13, 13].map { KeyStroke(keyCode: Int64($0), isShifted: false) }

        XCTAssertNil(engine.decision(for: strokes, typedText: "www"))
    }

    func testSafetyPreflightBlocksURLLikeTextWithReason() {
        let undo = CorrectionUndoManager()
        let engine = CorrectionEngine(undoController: undo, learningStore: isolatedLearningStore())
        let strokes = LayoutEngine.strokes(for: "example", language: .english) ?? []

        let evaluation = engine.evaluate(strokes: strokes, typedText: "example.com")

        XCTAssertNil(evaluation.decision)
        XCTAssertTrue(["Skipped URL/file-like text", "Skipped technical delimiter token"].contains(evaluation.reason))
    }

    func testSafetyPreflightBlocksUnsafeLayoutCandidate() {
        let undo = CorrectionUndoManager()
        let engine = CorrectionEngine(undoController: undo, learningStore: isolatedLearningStore())
        engine.confidenceThreshold = 0.35
        let strokes = LayoutEngine.strokes(for: "example.com", language: .english) ?? []
        let typedRussianLayoutText = LayoutEngine.candidates(for: strokes, enabledLanguages: [.russian]).first?.text ?? ""

        let evaluation = engine.evaluate(strokes: strokes, typedText: typedRussianLayoutText)

        XCTAssertFalse(typedRussianLayoutText.isEmpty)
        XCTAssertNil(evaluation.decision)
        XCTAssertTrue(["Skipped URL/file-like text", "Skipped technical delimiter token"].contains(evaluation.reason))
    }

    func testSafetyPreflightBlocksBundleIdentifierCandidate() {
        let undo = CorrectionUndoManager()
        let engine = CorrectionEngine(undoController: undo, learningStore: isolatedLearningStore())
        engine.confidenceThreshold = 0.35
        let strokes = LayoutEngine.strokes(for: "com.apple.Terminal", language: .english) ?? []
        let typedRussianLayoutText = LayoutEngine.candidates(for: strokes, enabledLanguages: [.russian]).first?.text ?? ""

        let evaluation = engine.evaluate(strokes: strokes, typedText: typedRussianLayoutText)

        XCTAssertFalse(typedRussianLayoutText.isEmpty)
        XCTAssertNil(evaluation.decision)
        XCTAssertEqual(evaluation.reason, "Skipped code-like text")
    }

    func testSafetyPreflightBlocksEmailPathAndCodeLikeText() {
        XCTAssertTrue(["email-like text", "URL/email/handle-like technical text"].contains(SafetyPreflight.blockReason(for: "user@example.com")))
        XCTAssertTrue(["path-like text", "technical delimiter token"].contains(SafetyPreflight.blockReason(for: "/Users/grigory/file.txt")))
        XCTAssertTrue(["code-like text", "technical delimiter token"].contains(SafetyPreflight.blockReason(for: "api_response")))
        XCTAssertTrue(["code-like text", "technical mixed-case token"].contains(SafetyPreflight.blockReason(for: "camelCase")))
        XCTAssertEqual(SafetyPreflight.blockReason(for: "abcשלום"), "mixed RTL/LTR text")
        XCTAssertEqual(SafetyPreflight.blockReason(for: "приветשלום"), "mixed RTL/LTR text")
        XCTAssertNil(SafetyPreflight.blockReason(for: "cgjcb,j"))
        XCTAssertNil(SafetyPreflight.blockReason(for: ".лия"))
        XCTAssertNil(SafetyPreflight.blockReason(for: "שלום"))
    }

    func testManualReplacementForEnglishTypedRussianWord() {
        let undo = CorrectionUndoManager()
        let engine = CorrectionEngine(undoController: undo)

        let decision = engine.manualReplacement(for: "ghbdtn")
        XCTAssertEqual(decision?.replacement, "привет")
        XCTAssertEqual(decision?.language, .russian)
    }

    func testManualReplacementsExposeCandidateCycle() {
        let undo = CorrectionUndoManager()
        let engine = CorrectionEngine(undoController: undo, learningStore: isolatedLearningStore())

        let decisions = engine.manualReplacements(for: "asdf")

        XCTAssertGreaterThanOrEqual(decisions.count, 2)
        XCTAssertEqual(decisions.first?.language, .russian)
        XCTAssertTrue(decisions.contains { $0.language == .hebrew })
        XCTAssertEqual(engine.manualReplacement(for: "asdf"), decisions.first)
    }

    func testManualReplacementForRussianTypedEnglishWord() {
        let undo = CorrectionUndoManager()
        let engine = CorrectionEngine(undoController: undo)

        let decision = engine.manualReplacement(for: "руддщ")
        XCTAssertEqual(decision?.replacement, "hello")
        XCTAssertEqual(decision?.language, .english)
    }

    func testRussianCandidateForSpasiboWithCommaKey() {
        let strokes = LayoutEngine.strokes(for: "cgfcb,j", language: .english) ?? []
        let candidates = LayoutEngine.candidates(for: strokes, enabledLanguages: Set(KeyboardLanguage.allCases))
        XCTAssertTrue(candidates.contains(LayoutCandidate(language: .russian, text: "спасибо")))
    }

    func testCommonSpasiboTypoIsCorrected() {
        let undo = CorrectionUndoManager()
        let engine = CorrectionEngine(undoController: undo)
        engine.confidenceThreshold = 0.35

        let strokes = LayoutEngine.strokes(for: "cgjcb,j", language: .english) ?? []
        XCTAssertEqual(engine.decision(for: strokes, typedText: "cgjcb,j")?.replacement, "спасибо")
    }

    func testRussianCandidateForPeredacha() {
        let undo = CorrectionUndoManager()
        let engine = CorrectionEngine(undoController: undo)
        engine.confidenceThreshold = 0.62

        let strokes = LayoutEngine.strokes(for: "gthtlfxf", language: .english) ?? []
        XCTAssertEqual(engine.decision(for: strokes, typedText: "gthtlfxf")?.replacement, "передача")
    }

    func testRussianFrequencyResourceSupportsCommonWordsOutsideBuiltInList() {
        let undo = CorrectionUndoManager()
        let engine = CorrectionEngine(undoController: undo)
        engine.confidenceThreshold = 0.62

        let strokes = LayoutEngine.strokes(for: "vfibyf", language: .english) ?? []
        XCTAssertEqual(engine.decision(for: strokes, typedText: "vfibyf")?.replacement, "машина")
    }

    func testEnglishCommonResourceSupportsWordsOutsideBuiltInList() {
        let undo = CorrectionUndoManager()
        let engine = CorrectionEngine(undoController: undo)
        engine.confidenceThreshold = 0.62

        let strokes = LayoutEngine.strokes(for: "тфегкфд", language: .russian) ?? []
        XCTAssertEqual(engine.decision(for: strokes, typedText: "тфегкфд")?.replacement, "natural")
    }

    func testManualCorrectionLearnsFutureReplacement() {
        let undo = CorrectionUndoManager()
        let learningStore = isolatedLearningStore()
        let engine = CorrectionEngine(undoController: undo, learningStore: learningStore)
        engine.confidenceThreshold = 0.99

        engine.recordManualCorrection(original: "zzzz", replacement: "привет")
        let strokes = LayoutEngine.strokes(for: "zzzz", language: .english) ?? []

        let evaluation = engine.evaluate(strokes: strokes, typedText: "zzzz")
        XCTAssertEqual(evaluation.reason, "Learned correction")
        XCTAssertEqual(evaluation.decision?.replacement, "привет")
        XCTAssertEqual(evaluation.decision?.language, .russian)
    }

    func testManualCorrectionLearningPreservesReplacementCasing() {
        let undo = CorrectionUndoManager()
        let learningStore = isolatedLearningStore()
        let engine = CorrectionEngine(undoController: undo, learningStore: learningStore)
        engine.confidenceThreshold = 0.99

        engine.recordManualCorrection(original: "ьфсщы", replacement: "macOS")
        let strokes = LayoutEngine.strokes(for: "ьфсщы", language: .russian) ?? []

        let evaluation = engine.evaluate(strokes: strokes, typedText: "ьфсщы")
        XCTAssertEqual(evaluation.reason, "Learned correction")
        XCTAssertEqual(evaluation.decision?.replacement, "macOS")
        XCTAssertEqual(evaluation.decision?.language, .english)
    }

    func testTechnicalTermsUsePreferredCasing() {
        let undo = CorrectionUndoManager()
        let engine = CorrectionEngine(undoController: undo, learningStore: isolatedLearningStore())
        engine.confidenceThreshold = 0.62

        let macos = LayoutEngine.strokes(for: "ьфсщы", language: .russian) ?? []
        let ios = LayoutEngine.strokes(for: "шщы", language: .russian) ?? []
        let coreML = LayoutEngine.strokes(for: "сщкуьд", language: .russian) ?? []

        XCTAssertEqual(engine.decision(for: macos, typedText: "ьфсщы")?.replacement, "macOS")
        XCTAssertEqual(engine.decision(for: ios, typedText: "шщы")?.replacement, "iOS")
        XCTAssertEqual(engine.decision(for: coreML, typedText: "сщкуьд")?.replacement, "CoreML")
    }

    func testTechnicalTermsResourceProtectsKnownTermsAndRules() {
        XCTAssertTrue(TechnicalTermLexicon.contains("SwiftUI"))
        XCTAssertTrue(TechnicalTermLexicon.contains("URLSession"))
        XCTAssertGreaterThanOrEqual(TechnicalTermLexicon.records.count, 700)
        XCTAssertGreaterThanOrEqual(TechnicalTermLexicon.rules.count, 10)

        XCTAssertEqual(SafetyPreflight.blockReason(for: "SwiftUI"), "known technical term")
        XCTAssertEqual(SafetyPreflight.blockReason(for: "URLSession"), "known technical term")
        XCTAssertTrue(["known technical term", "technical delimiter token"].contains(SafetyPreflight.blockReason(for: "HTTP/3")))
        XCTAssertTrue(["known technical term", "technical delimiter token"].contains(SafetyPreflight.blockReason(for: "com.apple.Safari")))
        XCTAssertEqual(SafetyPreflight.blockReason(for: "myVariable"), "technical mixed-case token")
        XCTAssertEqual(SafetyPreflight.blockReason(for: "--force"), "command-line flag")
    }

    func testTechnicalTermCandidatesCanStillCorrectWrongLayoutInput() {
        let undo = CorrectionUndoManager()
        let engine = CorrectionEngine(undoController: undo, learningStore: isolatedLearningStore())
        engine.confidenceThreshold = 0.62

        let macos = LayoutEngine.strokes(for: "ьфсщы", language: .russian) ?? []

        XCTAssertEqual(engine.decision(for: macos, typedText: "ьфсщы")?.replacement, "macOS")
    }

    func testReplacementCasingFollowsTypedWordShape() {
        let undo = CorrectionUndoManager()
        let engine = CorrectionEngine(undoController: undo, learningStore: isolatedLearningStore())
        engine.confidenceThreshold = 0.62

        let uppercase = LayoutEngine.strokes(for: "GHBDTN", language: .english) ?? []
        let titleCase = LayoutEngine.strokes(for: "Ghbdtn", language: .english) ?? []

        XCTAssertEqual(engine.decision(for: uppercase, typedText: "GHBDTN")?.replacement, "ПРИВЕТ")
        XCTAssertEqual(engine.decision(for: titleCase, typedText: "Ghbdtn")?.replacement, "Привет")
    }

    func testSuspiciousMixedCasingIsNotAutomaticallyCorrected() {
        let undo = CorrectionUndoManager()
        let engine = CorrectionEngine(undoController: undo, learningStore: isolatedLearningStore())
        engine.confidenceThreshold = 0.62
        let strokes = LayoutEngine.strokes(for: "gHBDTN", language: .english) ?? []

        let evaluation = engine.evaluate(strokes: strokes, typedText: "gHBDTN")

        XCTAssertNil(evaluation.decision)
        XCTAssertTrue(["Skipped code-like text", "Skipped suspicious casing", "Skipped technical mixed-case token"].contains(evaluation.reason))
    }

    func testUndoSuppressesFutureAutomaticReplacement() {
        let undo = CorrectionUndoManager()
        let learningStore = isolatedLearningStore()
        let engine = CorrectionEngine(undoController: undo, learningStore: learningStore)
        engine.confidenceThreshold = 0.62

        engine.recordUndoneCorrection(Correction(
            original: "ghbdtn ",
            replacement: "привет ",
            language: .russian,
            origin: .automatic
        ))

        let strokes = LayoutEngine.strokes(for: "ghbdtn", language: .english) ?? []
        let evaluation = engine.evaluate(strokes: strokes, typedText: "ghbdtn")
        XCTAssertEqual(evaluation.reason, "Skipped learned suppression")
        XCTAssertNil(evaluation.decision)
    }

    func testUndoSuppressionExpiresAfterOneDayUntilRepeated() {
        let learningStore = isolatedLearningStore()
        let now = Date(timeIntervalSince1970: 1000)

        learningStore.suppress(original: "ghbdtn ", replacement: "привет ", now: now)

        XCTAssertTrue(learningStore.isSuppressed(original: "ghbdtn", replacement: "привет", now: now.addingTimeInterval(60)))
        XCTAssertFalse(learningStore.isSuppressed(original: "ghbdtn", replacement: "привет", now: now.addingTimeInterval(25 * 60 * 60)))
        XCTAssertTrue(learningStore.allSuppressions(now: now.addingTimeInterval(25 * 60 * 60)).isEmpty)
    }

    func testRepeatedUndoMakesSuppressionPersistent() {
        let learningStore = isolatedLearningStore()
        let now = Date(timeIntervalSince1970: 2000)

        learningStore.suppress(original: "ghbdtn", replacement: "привет", now: now)
        learningStore.suppress(original: "ghbdtn", replacement: "привет", now: now.addingTimeInterval(10))
        learningStore.suppress(original: "ghbdtn", replacement: "привет", now: now.addingTimeInterval(20))

        let suppressions = learningStore.allSuppressions(now: now.addingTimeInterval(30))
        XCTAssertEqual(suppressions.first?.undoCount, 3)
        XCTAssertTrue(suppressions.first?.isPersistent == true)
        XCTAssertTrue(learningStore.isSuppressed(original: "ghbdtn", replacement: "привет", now: now.addingTimeInterval(30 * 24 * 60 * 60)))
    }

    func testSuppressionCanBeRemoved() {
        let learningStore = isolatedLearningStore()

        learningStore.suppress(original: "ghbdtn", replacement: "привет")
        XCTAssertTrue(learningStore.isSuppressed(original: "ghbdtn", replacement: "привет"))

        learningStore.removeSuppression(original: "ghbdtn", replacement: "привет")
        XCTAssertFalse(learningStore.isSuppressed(original: "ghbdtn", replacement: "привет"))
        XCTAssertTrue(learningStore.allSuppressions().isEmpty)
    }

    func testExplicitPreferenceCanBeManaged() {
        let learningStore = isolatedLearningStore()

        learningStore.setPreference(original: "ghbdtn", replacement: "привет", language: .russian)

        let preference = learningStore.preference(for: "ghbdtn")
        XCTAssertEqual(preference?.replacement, "привет")
        XCTAssertEqual(preference?.language, .russian)
        XCTAssertEqual(preference?.uses, 0)

        learningStore.removePreference(original: "ghbdtn")
        XCTAssertNil(learningStore.preference(for: "ghbdtn"))
    }

    func testExplicitSuppressionIsPersistent() {
        let learningStore = isolatedLearningStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        learningStore.suppressPersistently(original: "api", replacement: "фзш", now: now)

        XCTAssertTrue(learningStore.isSuppressed(original: "api", replacement: "фзш", now: now.addingTimeInterval(30 * 24 * 60 * 60)))
        XCTAssertTrue(learningStore.allSuppressions(now: now).first?.isPersistent == true)
    }

    func testLearningBackupRoundTripsPreferencesAndSuppressions() throws {
        let source = isolatedLearningStore(named: "learning-backup-source")
        let destination = isolatedLearningStore(named: "learning-backup-destination")
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        source.setPreference(original: "ghbdtn", replacement: "привет", language: .russian)
        source.suppressPersistently(original: "api", replacement: "фзш", now: now)

        let data = try source.exportBackupData(now: now)
        let result = try destination.importBackupData(data)

        XCTAssertEqual(result.importedLearnedCorrections, 1)
        XCTAssertEqual(result.importedSuppressions, 1)
        XCTAssertEqual(destination.preference(for: "ghbdtn")?.replacement, "привет")
        XCTAssertTrue(destination.isSuppressed(original: "api", replacement: "фзш", now: now.addingTimeInterval(60)))
    }

    func testLearningBackupMergeKeepsNewerExistingPreference() throws {
        let source = isolatedLearningStore(named: "learning-backup-older-source")
        let destination = isolatedLearningStore(named: "learning-backup-newer-destination")
        let oldDate = Date(timeIntervalSince1970: 1_800_000_000)

        source.setPreference(original: "ghbdtn", replacement: "привет", language: .russian)
        let data = try source.exportBackupData(now: oldDate)
        destination.setPreference(original: "ghbdtn", replacement: "здравствуйте", language: .russian)

        _ = try destination.importBackupData(data)

        XCTAssertEqual(destination.preference(for: "ghbdtn")?.replacement, "здравствуйте")
    }

    func testPrivacyMetricsStoreKeepsOnlyAggregateCorrectionData() {
        let defaults = isolatedDefaults(name: "privacy-metrics")
        let calendar = Calendar(identifier: .gregorian)
        let store = PrivacyMetricsStore(defaults: defaults, calendar: calendar)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        store.recordCorrection(Correction(original: "ghbdtn ", replacement: "привет ", language: .russian, origin: .automatic), now: now)
        store.recordCorrection(Correction(original: "руддщ ", replacement: "hello ", language: .english, origin: .manual), now: now)
        store.recordUndo(now: now)

        let snapshot = store.snapshot(now: now)

        XCTAssertEqual(snapshot.correctionsToday, 2)
        XCTAssertEqual(snapshot.undosToday, 1)
        XCTAssertEqual(snapshot.automaticCorrectionsToday, 1)
        XCTAssertEqual(snapshot.manualCorrectionsToday, 1)
        XCTAssertEqual(snapshot.undoRate, 0.5, accuracy: 0.001)
        XCTAssertTrue(["English -> Russian", "Russian -> English"].contains(snapshot.topLanguagePair))
    }

    func testPrivacyMetricsStoreResetsForNewDay() {
        let defaults = isolatedDefaults(name: "privacy-metrics-reset")
        let calendar = Calendar(identifier: .gregorian)
        let store = PrivacyMetricsStore(defaults: defaults, calendar: calendar)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        store.recordCorrection(Correction(original: "ghbdtn ", replacement: "привет ", language: .russian, origin: .automatic), now: now)
        let tomorrow = now.addingTimeInterval(26 * 60 * 60)

        XCTAssertEqual(store.snapshot(now: tomorrow).correctionsToday, 0)
        XCTAssertEqual(store.snapshot(now: tomorrow).topLanguagePair, "None yet")
    }

    func testMixedWordWithCommaKeyCorrectsToRussianWord() {
        let undo = CorrectionUndoManager()
        let engine = CorrectionEngine(undoController: undo)
        engine.confidenceThreshold = 0.62

        let strokes = LayoutEngine.mixedLayoutStrokes(for: "chf,отало") ?? []
        XCTAssertEqual(engine.decision(for: strokes, typedText: "chf,отало")?.replacement, "сработало")
        XCTAssertEqual(engine.manualReplacement(for: "chf,отало")?.replacement, "сработало")
    }

    func testMixedWordsWithRussianLetterPunctuationKeys() {
        let undo = CorrectionUndoManager()
        let engine = CorrectionEngine(undoController: undo)
        engine.confidenceThreshold = 0.62

        XCTAssertEqual(engine.manualReplacement(for: ";урнал")?.replacement, "журнал")
        XCTAssertEqual(engine.manualReplacement(for: ".лия")?.replacement, "юлия")
        XCTAssertEqual(engine.manualReplacement(for: "'то")?.replacement, "это")
        XCTAssertEqual(engine.manualReplacement(for: "[орошо")?.replacement, "хорошо")
    }

    func testRandomConvertedRussianLettersAreNotEnoughForCorrection() {
        let undo = CorrectionUndoManager()
        let engine = CorrectionEngine(undoController: undo)
        engine.confidenceThreshold = 0.62

        let strokes = LayoutEngine.strokes(for: "asdfgh", language: .english) ?? []
        XCTAssertNil(engine.decision(for: strokes, typedText: "asdfgh"))
    }

    func testRussianCandidatesForChtoEto() {
        let chto = LayoutEngine.strokes(for: "xnj", language: .english) ?? []
        let eto = LayoutEngine.strokes(for: "'nj", language: .english) ?? []

        XCTAssertTrue(LayoutEngine.candidates(for: chto, enabledLanguages: Set(KeyboardLanguage.allCases)).contains(LayoutCandidate(language: .russian, text: "что")))
        XCTAssertTrue(LayoutEngine.candidates(for: eto, enabledLanguages: Set(KeyboardLanguage.allCases)).contains(LayoutCandidate(language: .russian, text: "это")))
    }

    func testAutomaticCorrectionsForPhraseWords() {
        let undo = CorrectionUndoManager()
        let engine = CorrectionEngine(undoController: undo)
        engine.confidenceThreshold = 0.35

        let kak = LayoutEngine.strokes(for: "rfr", language: .english) ?? []
        let dela = LayoutEngine.strokes(for: "ltkf", language: .english) ?? []

        XCTAssertEqual(engine.decision(for: kak, typedText: "rfr")?.replacement, "как")
        XCTAssertEqual(engine.decision(for: dela, typedText: "ltkf")?.replacement, "дела")
    }

    func testShortWordCoreResourcesLoadForRussianAndEnglish() {
        let classifier = TextClassifier()

        XCTAssertTrue(classifier.isCoreShortWord("это", language: .russian))
        XCTAssertTrue(classifier.isCoreShortWord("как", language: .russian))
        XCTAssertTrue(classifier.isCoreShortWord("the", language: .english))
        XCTAssertTrue(classifier.isCoreShortWord("you", language: .english))
    }

    func testShortWordExtendedResourcesStaySeparateFromCore() {
        let classifier = TextClassifier()

        XCTAssertFalse(classifier.isCoreShortWord("авп", language: .russian))
        XCTAssertTrue(classifier.isExtendedShortWord("авп", language: .russian))
        XCTAssertFalse(classifier.isCoreShortWord("aaah", language: .english))
        XCTAssertTrue(classifier.isExtendedShortWord("aaah", language: .english))
    }

    func testShortWordCoreProvidesStrongEvidenceAndExtendedSupportsManualLayer() {
        let classifier = TextClassifier()

        XCTAssertTrue(classifier.hasStrongLexicalEvidence(LayoutCandidate(language: .russian, text: "это")))
        XCTAssertTrue(classifier.hasStrongLexicalEvidence(LayoutCandidate(language: .english, text: "you")))
        XCTAssertTrue(classifier.hasManualLexicalEvidence(LayoutCandidate(language: .english, text: "aaah")))
    }

    func testCorrectionSafetyFallbackClassifiesClearCorrection() {
        let classifier = RuleBasedCorrectionSafetyClassifier()
        let features = CorrectionSafetyFeatures(
            wordLength: 6,
            candidateLength: 6,
            sourceLanguage: .english,
            targetLanguage: .russian,
            terminatorType: "space",
            isShortWord: false,
            isTechnicalContext: false,
            appMode: .normal,
            ruleScore: 0.92,
            runnerUpScore: 0.08,
            scoreDelta: 0.84,
            hasDigits: false,
            hasMixedCase: false,
            hasPunctuation: false,
            wasLearned: false,
            wasSuppressed: false
        )

        let prediction = classifier.prediction(for: features)

        XCTAssertEqual(prediction.action, .autoCorrect)
        XCTAssertGreaterThanOrEqual(prediction.confidence, 0.90)
    }

    func testCorrectionSafetyFallbackSuggestsStrictBorderlineCorrection() {
        let classifier = RuleBasedCorrectionSafetyClassifier()
        let features = CorrectionSafetyFeatures(
            wordLength: 6,
            candidateLength: 6,
            sourceLanguage: .english,
            targetLanguage: .russian,
            terminatorType: "space",
            isShortWord: false,
            isTechnicalContext: false,
            appMode: .strict,
            ruleScore: 0.70,
            runnerUpScore: 0.52,
            scoreDelta: 0.18,
            hasDigits: false,
            hasMixedCase: false,
            hasPunctuation: false,
            wasLearned: false,
            wasSuppressed: false
        )

        let prediction = classifier.prediction(for: features)

        XCTAssertEqual(prediction.action, .suggestOnly)
    }

    func testCoreMLSafetyClassifierCanBeDisabledToUseFallback() {
        let defaults = UserDefaults.standard
        let key = CoreMLCorrectionSafetyClassifier.userDefaultsEnabledKey
        let previous = defaults.object(forKey: key)
        defaults.set(false, forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        let classifier = CoreMLCorrectionSafetyClassifier()
        let features = CorrectionSafetyFeatures(
            wordLength: 6,
            candidateLength: 6,
            sourceLanguage: .english,
            targetLanguage: .russian,
            terminatorType: "space",
            isShortWord: false,
            isTechnicalContext: false,
            appMode: .normal,
            ruleScore: 0.92,
            runnerUpScore: 0.08,
            scoreDelta: 0.84,
            hasDigits: false,
            hasMixedCase: false,
            hasPunctuation: false,
            wasLearned: false,
            wasSuppressed: false
        )

        let prediction = classifier.prediction(for: features)

        XCTAssertEqual(prediction.action, .autoCorrect)
        XCTAssertTrue(prediction.modelIdentifier.contains("Local ML disabled"))
    }

    func testCorrectionEvaluationIncludesLocalMLPredictionWithoutChangingDecision() {
        let undo = CorrectionUndoManager()
        let engine = CorrectionEngine(undoController: undo, learningStore: isolatedLearningStore())
        engine.confidenceThreshold = 0.62
        let strokes = LayoutEngine.strokes(for: "ghbdtn", language: .english) ?? []

        let evaluation = engine.evaluate(strokes: strokes, typedText: "ghbdtn", appMode: .normal)

        XCTAssertEqual(evaluation.decision?.replacement, "привет")
        XCTAssertEqual(evaluation.reason, "Corrected")
        XCTAssertEqual(evaluation.safetyFeatures?.targetLanguage, .russian)
        XCTAssertEqual(evaluation.safetyFeatures?.terminatorType, "unknown")
        XCTAssertEqual(evaluation.safetyPrediction?.action, .autoCorrect)
        XCTAssertTrue(evaluation.diagnosticSummary.contains("Local ML:"))
    }

    func testSafetyRerankerLogsDivergenceWithoutChangingDecision() {
        let undo = CorrectionUndoManager()
        let engine = CorrectionEngine(
            undoController: undo,
            learningStore: isolatedLearningStore(),
            safetyClassifier: FixedSafetyClassifier(action: .doNothing)
        )
        engine.confidenceThreshold = 0.62
        let strokes = LayoutEngine.strokes(for: "ghbdtn", language: .english) ?? []

        let evaluation = engine.evaluate(strokes: strokes, typedText: "ghbdtn", appMode: .normal)

        XCTAssertEqual(evaluation.decision?.replacement, "привет")
        XCTAssertEqual(evaluation.reason, "Corrected")
        XCTAssertEqual(evaluation.safetyPrediction?.action, .doNothing)
        XCTAssertEqual(evaluation.safetyFallbackPrediction?.action, .autoCorrect)
        XCTAssertTrue(evaluation.diagnosticSummary.contains("ML divergence"))
    }

    func testCorrectionEvaluationStoresTerminatorInSafetyFeatures() {
        let undo = CorrectionUndoManager()
        let engine = CorrectionEngine(undoController: undo, learningStore: isolatedLearningStore())
        engine.confidenceThreshold = 0.62
        let strokes = LayoutEngine.strokes(for: "ghbdtn", language: .english) ?? []

        let evaluation = engine.evaluate(strokes: strokes, typedText: "ghbdtn", appMode: .normal, terminatorType: "space")

        XCTAssertEqual(evaluation.safetyFeatures?.terminatorType, "space")
    }

    func testCorrectionTrainingSampleStoreRecordsAndExportsJSONL() throws {
        let store = CorrectionTrainingSampleStore(defaults: isolatedDefaults(name: "training-samples"))
        let features = CorrectionSafetyFeatures(
            wordLength: 6,
            candidateLength: 6,
            sourceLanguage: .english,
            targetLanguage: .russian,
            terminatorType: "space",
            isShortWord: false,
            isTechnicalContext: false,
            appMode: .normal,
            ruleScore: 0.92,
            runnerUpScore: 0.08,
            scoreDelta: 0.84,
            hasDigits: false,
            hasMixedCase: false,
            hasPunctuation: false,
            wasLearned: false,
            wasSuppressed: false
        )
        let prediction = RuleBasedCorrectionSafetyClassifier().prediction(for: features)

        store.record(outcome: .autoCorrected, features: features, prediction: prediction, decisionReason: "Corrected")

        XCTAssertEqual(store.summary().count, 1)
        XCTAssertEqual(store.summary().lastOutcome, .autoCorrected)
        XCTAssertEqual(store.summary().lastTextContext, "plain_text")

        let jsonl = String(decoding: try store.exportJSONLData(), as: UTF8.self)
        XCTAssertTrue(jsonl.contains("\"outcome\":\"auto_corrected\""))
        XCTAssertTrue(jsonl.contains("\"targetLanguage\":\"ru\""))
        XCTAssertFalse(jsonl.contains("ghbdtn"))
        XCTAssertFalse(jsonl.contains("привет"))
    }
}
