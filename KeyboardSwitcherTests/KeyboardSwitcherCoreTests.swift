import XCTest
@testable import Keyboard_Switcher

final class KeyboardSwitcherCoreTests: XCTestCase {
    private func isolatedLearningStore(named name: String = #function) -> LearningStore {
        let suiteName = "KeyboardSwitcherTests.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return LearningStore(defaults: defaults)
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

    func testExclusionPresetsContainExpectedBundleIdentifiers() {
        XCTAssertTrue(ExclusionPreset.developerTools.bundleIdentifiers.contains("com.apple.Terminal"))
        XCTAssertTrue(ExclusionPreset.developerTools.bundleIdentifiers.contains("com.todesktop.230313mzl4w4u92"))
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

    func testShortHebrewFunctionalWordsCorrectFromEnglishLayout() {
        let undo = CorrectionUndoManager()
        let engine = CorrectionEngine(undoController: undo, learningStore: isolatedLearningStore())
        engine.confidenceThreshold = 0.62

        let conjunction = LayoutEngine.strokes(for: "u", language: .english) ?? []
        let possessive = LayoutEngine.strokes(for: "ak", language: .english) ?? []

        XCTAssertEqual(engine.decision(for: conjunction, typedText: "u")?.replacement, "ו")
        XCTAssertEqual(engine.decision(for: conjunction, typedText: "u")?.language, .hebrew)
        XCTAssertEqual(engine.decision(for: possessive, typedText: "ak")?.replacement, "של")
        XCTAssertEqual(engine.decision(for: possessive, typedText: "ak")?.language, .hebrew)
    }

    func testCorrectionDecisionForPrivet() {
        let undo = CorrectionUndoManager()
        let engine = CorrectionEngine(undoController: undo)
        engine.confidenceThreshold = 0.35
        let strokes = [5, 4, 11, 2, 17, 45].map { KeyStroke(keyCode: Int64($0), isShifted: false) }

        let decision = engine.decision(for: strokes, typedText: "ghbdtn")
        XCTAssertEqual(decision?.replacement, "привет")
        XCTAssertEqual(decision?.language, .russian)
    }

    func testEvaluationExplainsPrivet() {
        let undo = CorrectionUndoManager()
        let engine = CorrectionEngine(undoController: undo)
        engine.confidenceThreshold = 0.35
        let strokes = [5, 4, 11, 2, 17, 45].map { KeyStroke(keyCode: Int64($0), isShifted: false) }

        let evaluation = engine.evaluate(strokes: strokes, typedText: "ghbdtn")
        XCTAssertEqual(evaluation.reason, "Corrected")
        XCTAssertEqual(evaluation.decision?.replacement, "привет")
        XCTAssertFalse(evaluation.candidateScores.isEmpty)
    }

    func testUnsafeTextIsNotCorrected() {
        let undo = CorrectionUndoManager()
        let engine = CorrectionEngine(undoController: undo)
        let strokes = [13, 13, 13].map { KeyStroke(keyCode: Int64($0), isShifted: false) }

        XCTAssertNil(engine.decision(for: strokes, typedText: "www"))
    }

    func testManualReplacementForEnglishTypedRussianWord() {
        let undo = CorrectionUndoManager()
        let engine = CorrectionEngine(undoController: undo)

        let decision = engine.manualReplacement(for: "ghbdtn")
        XCTAssertEqual(decision?.replacement, "привет")
        XCTAssertEqual(decision?.language, .russian)
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
}
