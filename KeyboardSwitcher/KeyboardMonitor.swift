import AppKit
import Foundation
import SwiftUI

struct KeyboardMonitorDiagnostics: Equatable {
    var status = "Stopped"
    var lastFrontmostApp = ""
    var lastBuffer = ""
    var lastTypedWord = ""
    var lastCandidates = ""
    var lastCandidateInspector = "No candidate evaluation yet"
    var lastTerminator = "-"
    var lastDecision = "No key events yet"
    var lastSuggestion = ""
    var lastCorrection = ""
    var lastLayoutSwitch = ""
    var lastInputContext = "Unknown"
    var lastPhysicalReplay = "Empty"
    var lastManualCandidatePreview = ""
    var manualMode = "Double Shift ready"
    var lastMLDecision = "do_nothing"
    var lastMLConfidence = "-"
    var lastMLDivergence = "None"
    var lastTextContext = "plain_text"
    var trainingSampleCount = 0
}

struct PendingCorrectionSuggestion: Equatable {
    let original: String
    let terminator: String
    let replacement: String
    let language: KeyboardLanguage
    let score: Double
    let safetyFeatures: CorrectionSafetyFeatures?
    let safetyPrediction: CorrectionSafetyPrediction?
    let safetyFallbackPrediction: CorrectionSafetyPrediction?
    let decisionReason: String

    var displayText: String {
        "\(original) -> \(replacement) (\(language.displayName), \(Int((score * 100).rounded()))%)"
    }
}

private struct ManualCandidateCycleState {
    enum Source {
        case selection
        case bufferedWord
    }

    let original: String
    var currentReplacement: String
    let candidates: [CorrectionDecision]
    var index: Int
    var updatedAt: Date
    let source: Source

    var canCycle: Bool {
        canAcceptKeyboardSelection
    }

    var canAcceptKeyboardSelection: Bool {
        candidates.count > 1 && Date().timeIntervalSince(updatedAt) <= 12.5
    }

    var options: [ManualCandidateOption] {
        candidates.enumerated().map { index, decision in
            ManualCandidateOption(
                index: index,
                replacement: decision.replacement,
                language: decision.language,
                score: decision.score,
                isSelected: index == self.index
            )
        }
    }
}

private struct ManualCandidateOption: Identifiable, Equatable {
    let index: Int
    let replacement: String
    let language: KeyboardLanguage
    let score: Double
    let isSelected: Bool

    var id: Int { index }

    var scoreText: String {
        "\(Int((score * 100).rounded()))%"
    }
}

final class KeyboardMonitor {
    private let correctionEngine: CorrectionEngine
    private let exclusionManager: ExclusionManager
    private let inputSourceManager = InputSourceManager()
    private let soundPlayer = SoundPlayer()
    private let trainingSampleStore = CorrectionTrainingSampleStore.shared
    var preferences = KeyboardMonitorPreferences()
    var automaticallyCorrectsTypedWords = true
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var strokes: [KeyStroke] = []
    private var typedText = ""
    private var isApplyingCorrection = false
    private var lastShiftKeyDownAt: Date?
    private var isShiftCurrentlyDown = false
    private var pendingManualCorrectionAfterShiftRelease = false
    private var pendingSuggestion: PendingCorrectionSuggestion?
    private var manualCycleState: ManualCandidateCycleState? {
        didSet {
            updateManualCandidatePreview()
        }
    }
    private(set) var diagnostics = KeyboardMonitorDiagnostics()

    init(correctionEngine: CorrectionEngine, exclusionManager: ExclusionManager) {
        self.correctionEngine = correctionEngine
        self.exclusionManager = exclusionManager
    }

    func start() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
            diagnostics.status = "Listening"
            return
        }

        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.tapDisabledByTimeout.rawValue)
            | (1 << CGEventType.tapDisabledByUserInput.rawValue)
        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon else {
                return Unmanaged.passUnretained(event)
            }

            let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                monitor.reenableEventTap(reason: type == .tapDisabledByTimeout ? "timeout" : "user input")
                return Unmanaged.passUnretained(event)
            }

            if monitor.handle(proxy: proxy, type: type, event: event) {
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: refcon
        )

        guard let eventTap else {
            diagnostics.status = "Failed to create event tap"
            return
        }
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: eventTap, enable: true)
        diagnostics.status = "Listening"
    }

    func ensureRunning() {
        guard let eventTap else {
            start()
            return
        }

        if !CGEvent.tapIsEnabled(tap: eventTap) {
            reenableEventTap(reason: "health check")
        }
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        resetBuffer()
        diagnostics.status = "Stopped"
    }

    private func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Bool {
        guard !isApplyingCorrection else { return false }

        let frontmostApp = NSWorkspace.shared.frontmostApplication
        diagnostics.lastFrontmostApp = frontmostApp?.localizedName ?? frontmostApp?.bundleIdentifier ?? "Unknown app"

        guard !exclusionManager.isFrontmostAppExcluded else {
            diagnostics.status = "Excluded"
            diagnostics.lastDecision = "Skipped excluded app: \(diagnostics.lastFrontmostApp)"
            diagnostics.lastCandidateInspector = [
                "App Behavior",
                "Front App: \(diagnostics.lastFrontmostApp)",
                "Mode: Excluded",
                "Decision: skipped"
            ].joined(separator: "\n")
            resetBuffer()
            return false
        }

        diagnostics.status = "Listening"

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        if type == .flagsChanged {
            if handleFlagsChanged(keyCode: keyCode, flags: flags) {
                return true
            }
            return false
        }

        guard type == .keyDown else { return false }

        if let handled = handlePendingSuggestionKey(keyCode: keyCode) {
            return handled
        }
        clearPendingSuggestionIfNeeded()

        if let handled = handleManualCandidateKey(keyCode: keyCode) {
            return handled
        }

        if let terminator = wordTerminator(for: keyCode) {
            manualCycleState = nil
            guard automaticallyCorrectsTypedWords else {
                diagnostics.lastDecision = "Automatic correction disabled"
                resetBuffer()
                return false
            }
            let didCorrect = finalizeCurrentWord(terminator: terminator)
            resetBuffer()
            return didCorrect
        }

        if keyCode == 51 {
            manualCycleState = nil
            if !strokes.isEmpty { strokes.removeLast() }
            if !typedText.isEmpty { typedText.removeLast() }
            diagnostics.lastBuffer = typedText
            diagnostics.lastPhysicalReplay = LayoutEngine.physicalReplaySummary(for: strokes)
            diagnostics.lastDecision = "Backspace"
            return false
        }

        let currentLanguage = inputSourceManager.currentKeyboardLanguage()
        let stroke = KeyStroke(
            keyCode: keyCode,
            isShifted: flags.contains(.maskShift),
            isCapsLocked: flags.contains(.maskAlphaShift),
            modifierFlagsRawValue: flags.rawValue,
            characters: eventCharacters(for: event),
            charactersIgnoringModifiers: eventCharactersIgnoringModifiers(keyCode: keyCode, currentLanguage: currentLanguage),
            inputSourceID: inputSourceManager.currentInputSourceID(),
            inputLanguage: currentLanguage
        )
        guard !stroke.hasNonReplayableModifiers else {
            manualCycleState = nil
            diagnostics.lastDecision = "Reset on non-replayable modifier"
            resetBuffer()
            return false
        }

        if let separator = LayoutEngine.technicalTokenSeparator(for: stroke, currentLanguage: currentLanguage) {
            strokes.append(stroke)
            typedText.append(separator)
            manualCycleState = nil
            diagnostics.lastBuffer = typedText
            diagnostics.lastPhysicalReplay = LayoutEngine.physicalReplaySummary(for: strokes)
            diagnostics.lastDecision = "Buffering technical token"
            return false
        }

        guard let character = LayoutEngine.character(for: stroke, language: currentLanguage), LayoutEngine.isWordCharacter(stroke: stroke, currentLanguage: currentLanguage) else {
            diagnostics.lastDecision = "Reset on non-letter key \(keyCode)"
            resetBuffer()
            return false
        }

        strokes.append(stroke)
        typedText.append(character)
        manualCycleState = nil
        diagnostics.lastBuffer = typedText
        diagnostics.lastPhysicalReplay = LayoutEngine.physicalReplaySummary(for: strokes)
        diagnostics.lastDecision = "Buffering"
        return false
    }

    func acceptPendingSuggestion() {
        applyPendingSuggestion()
    }

    func ignorePendingSuggestion() {
        guard let pendingSuggestion else { return }
        correctionEngine.recordIgnoredSuggestion(
            original: pendingSuggestion.original,
            replacement: pendingSuggestion.replacement
        )
        diagnostics.lastDecision = "Suggestion ignored"
        diagnostics.lastCandidateInspector += "\nPreview: ignored by user"
        recordTrainingSample(
            outcome: .suggestionIgnored,
            features: pendingSuggestion.safetyFeatures,
            prediction: pendingSuggestion.safetyPrediction,
            decisionReason: pendingSuggestion.decisionReason
        )
        clearPendingSuggestion()
    }

    private func reenableEventTap(reason: String) {
        guard let eventTap else {
            start()
            return
        }

        CGEvent.tapEnable(tap: eventTap, enable: true)
        diagnostics.status = "Listening"
        diagnostics.lastDecision = "Re-enabled event tap after \(reason)"
    }

    private func finalizeCurrentWord(terminator: String) -> Bool {
        let appMode = exclusionManager.frontmostAppBehaviorMode
        let inputContext = FocusedInputContextInspector.current()
        diagnostics.lastInputContext = inputContext.diagnosticDescription

        switch inputContext.correctionPolicy {
        case .block(let reason):
            diagnostics.lastTypedWord = typedText
            diagnostics.lastTerminator = terminatorLabel(terminator)
            diagnostics.lastDecision = "Skipped \(reason)"
            diagnostics.lastCandidateInspector = [
                "Input Context",
                "Typed: \(typedText.isEmpty ? "-" : typedText)",
                "Context: \(inputContext.diagnosticDescription)",
                "Physical replay: \(LayoutEngine.physicalReplaySummary(for: strokes))",
                "Decision: blocked \(reason)"
            ].joined(separator: "\n")
            clearPendingSuggestion()
            return false
        case .allow, .strict:
            break
        }

        let inputProfile: CorrectionProfile
        let inputModeDescription: String
        switch inputContext.correctionPolicy {
        case .strict(let reason):
            inputProfile = AppBehaviorMode.strict.correctionProfile
            inputModeDescription = "Strict (\(reason))"
        case .allow:
            inputProfile = .normal
            inputModeDescription = "Allowed"
        case .block:
            inputProfile = .normal
            inputModeDescription = "Blocked"
        }

        let activeProfile = appMode.correctionProfile.tightened(with: inputProfile)
        let evaluation = correctionEngine.evaluate(
            strokes: strokes,
            typedText: typedText,
            allowsShortFunctionalWords: terminator == " ",
            profile: activeProfile,
            appMode: appMode,
            terminatorType: terminator == " " ? "space" : "punctuation"
        )
        diagnostics.lastTypedWord = typedText
        diagnostics.lastTerminator = terminatorLabel(terminator)
        diagnostics.lastCandidates = evaluation.candidateScores
            .map { "\($0.candidate.language.displayName): \($0.candidate.text) \(Int($0.score * 100))%" }
            .joined(separator: " | ")
        diagnostics.lastCandidateInspector = evaluation.diagnosticSummary
            + "\nApp mode: \(appMode.displayName)"
            + "\nInput context: \(inputContext.diagnosticDescription)"
            + "\nInput policy: \(inputModeDescription)"
            + "\nPhysical replay: \(LayoutEngine.physicalReplaySummary(for: strokes))"
        diagnostics.lastDecision = evaluation.reason
        diagnostics.lastSuggestion = evaluation.suggestion.map {
            "\(typedText) -> \($0.replacement) (\($0.language.displayName), \(Int(($0.score * 100).rounded()))%)"
        } ?? ""
        updateLocalIntelligenceDiagnostics(
            features: evaluation.safetyFeatures,
            prediction: evaluation.safetyPrediction,
            fallbackPrediction: evaluation.safetyFallbackPrediction
        )
        recordMLDivergenceIfNeeded(evaluation)

        guard let decision = evaluation.decision else {
            if let suggestion = evaluation.suggestion {
                pendingSuggestion = PendingCorrectionSuggestion(
                    original: typedText,
                    terminator: terminator,
                    replacement: suggestion.replacement,
                    language: suggestion.language,
                    score: suggestion.score,
                    safetyFeatures: evaluation.safetyFeatures,
                    safetyPrediction: evaluation.safetyPrediction,
                    safetyFallbackPrediction: evaluation.safetyFallbackPrediction,
                    decisionReason: evaluation.reason
                )
                diagnostics.lastSuggestion = pendingSuggestion?.displayText ?? ""
                diagnostics.lastDecision = "Suggestion pending"
                recordTrainingSample(
                    outcome: .suggested,
                    features: evaluation.safetyFeatures,
                    prediction: evaluation.safetyPrediction,
                    decisionReason: evaluation.reason
                )
                showAutomaticSuggestionHUD()
            } else {
                clearPendingSuggestion()
            }
            return false
        }

        let original = typedText
        let replacement = decision.replacement + terminator

        isApplyingCorrection = true
        correctionEngine.applyCorrection(
            replacingPreviousCharacterCount: original.count,
            original: original + terminator,
            with: replacement,
            language: decision.language
        )
        handlePostCorrection(language: decision.language, origin: .automatic)
        isApplyingCorrection = false
        diagnostics.lastCorrection = "\(original) -> \(replacement)"
        diagnostics.lastSuggestion = ""
        diagnostics.lastDecision = "Corrected to \(decision.language.displayName), score \(Int(decision.score * 100))%"
        recordTrainingSample(
            outcome: .autoCorrected,
            features: evaluation.safetyFeatures,
            prediction: evaluation.safetyPrediction,
            decisionReason: evaluation.reason
        )
        return true
    }

    private func handlePendingSuggestionKey(keyCode: Int64) -> Bool? {
        guard pendingSuggestion != nil else { return nil }

        switch keyCode {
        case 36, 76:
            applyPendingSuggestion()
            return true
        case 53:
            ignorePendingSuggestion()
            return true
        default:
            return nil
        }
    }

    private func applyPendingSuggestion() {
        guard let pendingSuggestion else { return }

        let originalWithTerminator = pendingSuggestion.original + pendingSuggestion.terminator
        let replacementWithTerminator = pendingSuggestion.replacement + pendingSuggestion.terminator

        isApplyingCorrection = true
        correctionEngine.applyCorrection(
            replacingPreviousCharacterCount: originalWithTerminator.count,
            original: originalWithTerminator,
            with: replacementWithTerminator,
            language: pendingSuggestion.language
        )
        correctionEngine.recordAcceptedSuggestion(
            original: pendingSuggestion.original,
            replacement: pendingSuggestion.replacement,
            language: pendingSuggestion.language
        )
        handlePostCorrection(language: pendingSuggestion.language, origin: .automatic)
        isApplyingCorrection = false

        diagnostics.lastCorrection = "\(pendingSuggestion.original) -> \(pendingSuggestion.replacement)"
        diagnostics.lastDecision = "Suggestion accepted"
        diagnostics.lastCandidateInspector += "\nPreview: accepted by user"
        recordTrainingSample(
            outcome: .suggestionAccepted,
            features: pendingSuggestion.safetyFeatures,
            prediction: pendingSuggestion.safetyPrediction,
            decisionReason: pendingSuggestion.decisionReason
        )
        clearPendingSuggestion()
    }

    private func clearPendingSuggestionIfNeeded() {
        guard pendingSuggestion != nil else { return }
        diagnostics.lastDecision = "Suggestion dismissed by typing"
        clearPendingSuggestion()
    }

    private func clearPendingSuggestion() {
        pendingSuggestion = nil
        diagnostics.lastSuggestion = ""
        Task { @MainActor in
            AutomaticSuggestionHUD.shared.hide()
        }
    }

    private func showAutomaticSuggestionHUD() {
        guard let pendingSuggestion else { return }
        Task { @MainActor in
            AutomaticSuggestionHUD.shared.show(suggestion: pendingSuggestion)
        }
    }

    private func handleFlagsChanged(keyCode: Int64, flags: CGEventFlags) -> Bool {
        guard isShiftKey(keyCode) else { return false }

        let isDown = flags.contains(.maskShift)
        guard isDown != isShiftCurrentlyDown else { return false }
        isShiftCurrentlyDown = isDown

        guard isDown else {
            guard pendingManualCorrectionAfterShiftRelease else { return false }
            pendingManualCorrectionAfterShiftRelease = false
            return performManualCorrection()
        }

        return handleShiftDown()
    }

    private func handleShiftDown() -> Bool {
        let now = Date()
        defer { lastShiftKeyDownAt = now }

        guard let previous = lastShiftKeyDownAt, now.timeIntervalSince(previous) <= 0.45 else {
            diagnostics.manualMode = "First Shift"
            return false
        }

        diagnostics.manualMode = "Double Shift"
        pendingManualCorrectionAfterShiftRelease = true
        diagnostics.lastDecision = "Double Shift: waiting for Shift release"
        return true
    }

    private func performManualCorrection() -> Bool {
        isApplyingCorrection = true
        defer { isApplyingCorrection = false }

        if !typedText.isEmpty {
            return performBufferedManualTranslation()
        }

        if cycleManualCandidateIfAvailable() {
            return true
        }

        guard let selectedWord = TextReplacementPerformer.copyWordBeforeCursor(), !selectedWord.isEmpty else {
            diagnostics.lastDecision = "Double Shift: no word before cursor"
            return true
        }

        diagnostics.lastTypedWord = selectedWord
        diagnostics.lastTerminator = "Manual"

        let candidates = correctionEngine.manualReplacements(for: selectedWord)
        guard let decision = candidates.first else {
            diagnostics.lastDecision = "Double Shift: no replacement for \(selectedWord)"
            diagnostics.lastCandidateInspector = "Manual Double Shift\nTyped: \(selectedWord)\nDecision: no replacement"
            manualCycleState = nil
            return true
        }

        TextReplacementPerformer.replaceSelection(with: decision.replacement)
        handlePostCorrection(language: decision.language, origin: .manual)
        correctionEngine.recordManualCorrection(original: selectedWord, replacement: decision.replacement)
        rememberManualCycle(original: selectedWord, replacement: decision.replacement, candidates: candidates, source: .selection)
        diagnostics.lastCorrection = "\(selectedWord) -> \(decision.replacement)"
        diagnostics.lastSuggestion = ""
        diagnostics.lastDecision = manualDecisionText(prefix: "Manual corrected", decision: decision, index: 0, count: candidates.count)
        diagnostics.lastCandidateInspector = [
            "Manual Double Shift",
            "Typed: \(selectedWord)",
            "Replacement: \(selectedWord) -> \(decision.replacement) (\(decision.language.displayName))",
            "Candidates: \(manualCandidatesSummary(candidates))",
            "Physical replay: \(LayoutEngine.physicalReplaySummary(for: strokes))",
            "Score: \(Int((decision.score * 100).rounded()))%"
        ].joined(separator: "\n")
        recordManualTrainingSample(original: selectedWord, decision: decision, reason: "Manual Double Shift")
        resetBuffer()
        return true
    }

    private func performBufferedManualTranslation() -> Bool {
        let original = typedText
        diagnostics.lastTypedWord = original
        diagnostics.lastTerminator = "Manual"

        let candidates = correctionEngine.manualReplacements(for: original)
        guard let decision = candidates.first else {
            diagnostics.lastDecision = "Double Shift: no replacement for \(original)"
            diagnostics.lastCandidateInspector = "Manual Double Shift\nTyped: \(original)\nMode: current word\nDecision: no replacement"
            manualCycleState = nil
            return true
        }

        TextReplacementPerformer.replacePreviousText(characterCount: original.count, with: decision.replacement)
        handlePostCorrection(language: decision.language, origin: .manual)
        correctionEngine.recordManualTranslation(original: original, replacement: decision.replacement)
        rememberManualCycle(original: original, replacement: decision.replacement, candidates: candidates, source: .bufferedWord)
        diagnostics.lastCorrection = "\(original) -> \(decision.replacement)"
        diagnostics.lastSuggestion = ""
        diagnostics.lastDecision = manualDecisionText(prefix: "Manual translated current word", decision: decision, index: 0, count: candidates.count)
        diagnostics.lastCandidateInspector = [
            "Manual Double Shift",
            "Typed: \(original)",
            "Mode: current word without trailing space",
            "Replacement: \(original) -> \(decision.replacement) (\(decision.language.displayName))",
            "Candidates: \(manualCandidatesSummary(candidates))",
            "Learning: skipped",
            "Physical replay: \(LayoutEngine.physicalReplaySummary(for: strokes))",
            "Score: \(Int((decision.score * 100).rounded()))%"
        ].joined(separator: "\n")
        recordManualTrainingSample(original: original, decision: decision, reason: "Manual Double Shift current word")
        resetBuffer()
        return true
    }

    private func cycleManualCandidateIfAvailable() -> Bool {
        guard var cycle = manualCycleState, cycle.canCycle else {
            manualCycleState = nil
            return false
        }

        let nextIndex = (cycle.index + 1) % cycle.candidates.count
        let decision = cycle.candidates[nextIndex]
        TextReplacementPerformer.replacePreviousText(
            characterCount: cycle.currentReplacement.count,
            expectedPreviousText: cycle.currentReplacement,
            with: decision.replacement
        )
        handlePostCorrection(language: decision.language, origin: .manual)
        switch cycle.source {
        case .selection:
            correctionEngine.recordManualCorrection(original: cycle.original, replacement: decision.replacement)
        case .bufferedWord:
            correctionEngine.recordManualTranslation(original: cycle.original, replacement: decision.replacement)
        }

        cycle.index = nextIndex
        cycle.currentReplacement = decision.replacement
        cycle.updatedAt = Date()
        manualCycleState = cycle

        diagnostics.lastTypedWord = cycle.original
        diagnostics.lastTerminator = "Manual"
        diagnostics.lastCorrection = "\(cycle.original) -> \(decision.replacement)"
        diagnostics.lastSuggestion = ""
        diagnostics.lastDecision = manualDecisionText(prefix: "Manual cycled", decision: decision, index: nextIndex, count: cycle.candidates.count)
        diagnostics.lastCandidateInspector = [
            "Manual Double Shift",
            "Typed: \(cycle.original)",
            "Mode: candidate cycling",
            "Replacement: \(cycle.original) -> \(decision.replacement) (\(decision.language.displayName))",
            "Candidates: \(manualCandidatesSummary(cycle.candidates))",
            "Selected candidate: \(nextIndex + 1) of \(cycle.candidates.count)",
            "Score: \(Int((decision.score * 100).rounded()))%"
        ].joined(separator: "\n")
        recordManualTrainingSample(original: cycle.original, decision: decision, reason: "Manual Double Shift candidate cycling")
        return true
    }

    private func handleManualCandidateKey(keyCode: Int64) -> Bool? {
        guard let cycle = manualCycleState else { return nil }
        guard cycle.canAcceptKeyboardSelection else {
            manualCycleState = nil
            return nil
        }

        if keyCode == 53 {
            cancelManualCandidateSelection(cycle)
            return true
        }

        guard let index = manualCandidateIndex(for: keyCode), cycle.candidates.indices.contains(index) else {
            return nil
        }

        applyManualCandidate(at: index, from: cycle)
        return true
    }

    private func manualCandidateIndex(for keyCode: Int64) -> Int? {
        switch keyCode {
        case 18, 83:
            return 0
        case 19, 84:
            return 1
        case 20, 85:
            return 2
        case 21, 86:
            return 3
        default:
            return nil
        }
    }

    private func applyManualCandidate(at index: Int, from cycle: ManualCandidateCycleState) {
        let decision = cycle.candidates[index]
        if decision.replacement != cycle.currentReplacement {
            TextReplacementPerformer.replacePreviousText(
                characterCount: cycle.currentReplacement.count,
                expectedPreviousText: cycle.currentReplacement,
                with: decision.replacement
            )
            handlePostCorrection(language: decision.language, origin: .manual)
        }

        switch cycle.source {
        case .selection:
            correctionEngine.recordManualCorrection(original: cycle.original, replacement: decision.replacement)
        case .bufferedWord:
            correctionEngine.recordManualTranslation(original: cycle.original, replacement: decision.replacement)
        }

        diagnostics.lastTypedWord = cycle.original
        diagnostics.lastTerminator = "Manual"
        diagnostics.lastCorrection = "\(cycle.original) -> \(decision.replacement)"
        diagnostics.lastDecision = manualDecisionText(prefix: "Manual selected", decision: decision, index: index, count: cycle.candidates.count)
        diagnostics.lastCandidateInspector = [
            "Manual Double Shift",
            "Typed: \(cycle.original)",
            "Mode: candidate keyboard selection",
            "Replacement: \(cycle.original) -> \(decision.replacement) (\(decision.language.displayName))",
            "Candidates: \(manualCandidatesSummary(cycle.candidates))",
            "Selected candidate: \(index + 1) of \(cycle.candidates.count)",
            "Score: \(Int((decision.score * 100).rounded()))%"
        ].joined(separator: "\n")
        recordManualTrainingSample(original: cycle.original, decision: decision, reason: "Manual candidate keyboard selection")
        manualCycleState = nil
    }

    private func cancelManualCandidateSelection(_ cycle: ManualCandidateCycleState) {
        TextReplacementPerformer.replacePreviousText(
            characterCount: cycle.currentReplacement.count,
            expectedPreviousText: cycle.currentReplacement,
            with: cycle.original
        )
        diagnostics.lastTypedWord = cycle.original
        diagnostics.lastTerminator = "Manual"
        diagnostics.lastCorrection = "\(cycle.currentReplacement) -> \(cycle.original)"
        diagnostics.lastDecision = "Manual candidate selection cancelled"
        diagnostics.lastCandidateInspector = [
            "Manual Double Shift",
            "Typed: \(cycle.original)",
            "Mode: candidate keyboard selection",
            "Decision: cancelled with Escape",
            "Candidates: \(manualCandidatesSummary(cycle.candidates))"
        ].joined(separator: "\n")
        manualCycleState = nil
    }

    private func updateManualCandidatePreview() {
        guard let cycle = manualCycleState, cycle.candidates.count > 1 else {
            diagnostics.lastManualCandidatePreview = ""
            Task { @MainActor in
                ManualCandidateHUD.shared.hide(after: 4.0)
            }
            return
        }

        diagnostics.lastManualCandidatePreview = cycle.options
            .map { option in
                let marker = option.isSelected ? "selected" : "option"
                return "\(option.index + 1). \(option.replacement) (\(option.language.displayName), \(option.scoreText), \(marker))"
            }
            .joined(separator: " | ")

        let original = cycle.original
        let options = cycle.options
        let selectedIndex = cycle.index
        Task { @MainActor in
            ManualCandidateHUD.shared.show(
                original: original,
                options: options,
                selectedIndex: selectedIndex
            )
        }
    }

    private func rememberManualCycle(original: String, replacement: String, candidates: [CorrectionDecision], source: ManualCandidateCycleState.Source) {
        guard candidates.count > 1 else {
            manualCycleState = nil
            return
        }

        manualCycleState = ManualCandidateCycleState(
            original: original,
            currentReplacement: replacement,
            candidates: candidates,
            index: 0,
            updatedAt: Date(),
            source: source
        )
    }

    private func manualDecisionText(prefix: String, decision: CorrectionDecision, index: Int, count: Int) -> String {
        if count > 1 {
            return "\(prefix) to \(decision.language.displayName) (\(index + 1)/\(count))"
        }
        return "\(prefix) to \(decision.language.displayName)"
    }

    private func manualCandidatesSummary(_ candidates: [CorrectionDecision]) -> String {
        guard !candidates.isEmpty else { return "None" }
        return candidates.enumerated().map { index, decision in
            "\(index + 1). \(decision.replacement) (\(decision.language.displayName), \(Int((decision.score * 100).rounded()))%)"
        }.joined(separator: " | ")
    }

    private func recordTrainingSample(
        outcome: CorrectionTrainingOutcome,
        features: CorrectionSafetyFeatures?,
        prediction: CorrectionSafetyPrediction?,
        decisionReason: String
    ) {
        guard let features else { return }
        trainingSampleStore.record(
            outcome: outcome,
            features: features,
            prediction: prediction,
            decisionReason: decisionReason
        )
        updateLocalIntelligenceDiagnostics(features: features, prediction: prediction, fallbackPrediction: nil)
    }

    private func recordMLDivergenceIfNeeded(_ evaluation: CorrectionEvaluation) {
        guard let features = evaluation.safetyFeatures,
              let prediction = evaluation.safetyPrediction,
              let fallbackPrediction = evaluation.safetyFallbackPrediction,
              prediction.action != fallbackPrediction.action else {
            return
        }

        trainingSampleStore.record(
            outcome: .mlDivergence,
            features: features,
            prediction: prediction,
            decisionReason: "ML divergence: \(prediction.action.rawValue) vs rule \(fallbackPrediction.action.rawValue)"
        )
        updateLocalIntelligenceDiagnostics(
            features: features,
            prediction: prediction,
            fallbackPrediction: fallbackPrediction
        )
    }

    private func recordManualTrainingSample(original: String, decision: CorrectionDecision, reason: String) {
        let features = CorrectionSafetyFeatureExtractor.make(
            typedText: original,
            candidate: decision.replacement,
            targetLanguage: decision.language,
            ruleScore: decision.score,
            runnerUpScore: decision.runnerUpScore,
            appMode: exclusionManager.frontmostAppBehaviorMode,
            terminatorType: "manual",
            isTechnicalContext: false
        )
        let prediction = RuleBasedCorrectionSafetyClassifier().prediction(for: features)
        recordTrainingSample(
            outcome: .manualCorrected,
            features: features,
            prediction: prediction,
            decisionReason: reason
        )
    }

    private func updateLocalIntelligenceDiagnostics(
        features: CorrectionSafetyFeatures?,
        prediction: CorrectionSafetyPrediction?,
        fallbackPrediction: CorrectionSafetyPrediction?
    ) {
        if let prediction {
            diagnostics.lastMLDecision = prediction.action.rawValue
            diagnostics.lastMLConfidence = "\(Int((prediction.confidence * 100).rounded()))%"
        }
        if let prediction, let fallbackPrediction, prediction.action != fallbackPrediction.action {
            diagnostics.lastMLDivergence = "\(prediction.action.rawValue) vs rule \(fallbackPrediction.action.rawValue)"
        } else if fallbackPrediction != nil {
            diagnostics.lastMLDivergence = "None"
        }
        if let features {
            diagnostics.lastTextContext = CorrectionTrainingSampleStore.textContext(for: features)
        }
        diagnostics.trainingSampleCount = trainingSampleStore.summary().count
    }

    private func handlePostCorrection(language: KeyboardLanguage, origin: CorrectionOrigin) {
        guard preferences.shouldSwitchInputSource() else {
            diagnostics.lastLayoutSwitch = "Switch disabled"
            return
        }
        switchInputSource(to: language, origin: origin)
    }

    private func switchInputSource(to language: KeyboardLanguage, origin: CorrectionOrigin) {
        let previousLanguage = inputSourceManager.currentKeyboardLanguage()
        let didSwitch = inputSourceManager.selectKeyboardLanguage(language)
        if didSwitch && previousLanguage != language && preferences.shouldPlaySound(origin: origin) {
            soundPlayer.playLayoutSwitch(volume: preferences.soundVolume)
        }
        diagnostics.lastLayoutSwitch = didSwitch ? "Switched to \(language.displayName)" : "Could not switch to \(language.displayName)"
    }

    private func resetBuffer() {
        strokes.removeAll(keepingCapacity: true)
        typedText.removeAll(keepingCapacity: true)
        pendingManualCorrectionAfterShiftRelease = false
        diagnostics.lastBuffer = ""
    }

    private func wordTerminator(for keyCode: Int64) -> String? {
        switch keyCode {
        case 49:
            return " "
        case 36, 48, 52:
            return "\n"
        default:
            return nil
        }
    }

    private func terminatorLabel(_ terminator: String) -> String {
        switch terminator {
        case " ":
            return "Space"
        case "\n":
            return "Enter/Tab"
        default:
            return terminator
        }
    }

    private func isShiftKey(_ keyCode: Int64) -> Bool {
        keyCode == 56 || keyCode == 60
    }

    private func eventCharacters(for event: CGEvent) -> String {
        let maxLength = 8
        var actualLength = 0
        var buffer = [UniChar](repeating: 0, count: maxLength)
        event.keyboardGetUnicodeString(
            maxStringLength: maxLength,
            actualStringLength: &actualLength,
            unicodeString: &buffer
        )
        guard actualLength > 0 else { return "" }
        return String(utf16CodeUnits: buffer, count: actualLength)
    }

    private func eventCharactersIgnoringModifiers(keyCode: Int64, currentLanguage: KeyboardLanguage) -> String {
        let unmodifiedStroke = KeyStroke(keyCode: keyCode, isShifted: false)
        return LayoutEngine.character(for: unmodifiedStroke, language: currentLanguage) ?? ""
    }
}

@MainActor
private final class ManualCandidateHUD {
    static let shared = ManualCandidateHUD()

    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?

    func show(original: String, options: [ManualCandidateOption], selectedIndex: Int) {
        hideWorkItem?.cancel()
        let content = ManualCandidateHUDView(
            original: original,
            options: options,
            selectedIndex: selectedIndex
        )
        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = NSRect(x: 0, y: 0, width: 320, height: Self.height(for: options.count))

        let panel = self.panel ?? self.makePanel()
        panel.contentView = hostingView
        panel.setContentSize(hostingView.frame.size)
        self.position(panel: panel, size: hostingView.frame.size)
        panel.orderFrontRegardless()
        self.panel = panel
        hide(after: 12.0)
    }

    func hide(after delay: TimeInterval = 0) {
        hideWorkItem?.cancel()

        guard delay > 0 else {
            self.panel?.orderOut(nil)
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.panel?.orderOut(nil)
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 160),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return panel
    }

    private func position(panel: NSPanel, size: CGSize) {
        let mouseLocation = NSEvent.mouseLocation
        let screenFrame = NSScreen.screens
            .first(where: { $0.frame.contains(mouseLocation) })?
            .visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let x = min(max(mouseLocation.x + 14, screenFrame.minX + 12), screenFrame.maxX - size.width - 12)
        let y = min(max(mouseLocation.y - size.height - 14, screenFrame.minY + 12), screenFrame.maxY - size.height - 12)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private static func height(for optionCount: Int) -> CGFloat {
        CGFloat(76 + min(optionCount, 4) * 34)
    }
}

private struct ManualCandidateHUDView: View {
    let original: String
    let options: [ManualCandidateOption]
    let selectedIndex: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Manual candidates")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("Shift×2/1-4 select · Esc cancel")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Text(original)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            VStack(spacing: 5) {
                ForEach(options.prefix(4)) { option in
                    HStack(spacing: 8) {
                        Text("\(option.index + 1)")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(option.isSelected ? .white : .secondary)
                            .frame(width: 18, height: 18)
                            .background(option.isSelected ? Color.accentColor : Color.secondary.opacity(0.14))
                            .clipShape(Circle())

                        Text(option.replacement)
                            .font(.system(size: 13, weight: option.isSelected ? .semibold : .regular))
                            .lineLimit(1)

                        Spacer(minLength: 8)

                        Text(option.language.displayName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)

                        Text(option.scoreText)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(option.isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
        .padding(12)
        .frame(width: 320)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }
}

@MainActor
private final class AutomaticSuggestionHUD {
    static let shared = AutomaticSuggestionHUD()

    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?

    func show(suggestion: PendingCorrectionSuggestion) {
        hideWorkItem?.cancel()
        let content = AutomaticSuggestionHUDView(suggestion: suggestion)
        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = NSRect(x: 0, y: 0, width: 340, height: 128)

        let panel = self.panel ?? self.makePanel()
        panel.contentView = hostingView
        panel.setContentSize(hostingView.frame.size)
        self.position(panel: panel, size: hostingView.frame.size)
        panel.orderFrontRegardless()
        self.panel = panel
        hide(after: 10.0)
    }

    func hide(after delay: TimeInterval = 0) {
        hideWorkItem?.cancel()

        guard delay > 0 else {
            panel?.orderOut(nil)
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.panel?.orderOut(nil)
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 128),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return panel
    }

    private func position(panel: NSPanel, size: CGSize) {
        let mouseLocation = NSEvent.mouseLocation
        let screenFrame = NSScreen.screens
            .first(where: { $0.frame.contains(mouseLocation) })?
            .visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let x = min(max(mouseLocation.x + 14, screenFrame.minX + 12), screenFrame.maxX - size.width - 12)
        let y = min(max(mouseLocation.y - size.height - 14, screenFrame.minY + 12), screenFrame.maxY - size.height - 12)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

private struct AutomaticSuggestionHUDView: View {
    let suggestion: PendingCorrectionSuggestion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Correction Preview", systemImage: "wand.and.stars")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("Enter accept · Esc ignore")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Text(suggestion.original)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .lineLimit(1)

                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text(suggestion.replacement)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
            }

            HStack(spacing: 8) {
                Text(suggestion.language.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                Text("\(Int((suggestion.score * 100).rounded()))% confidence")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)

                Spacer()
            }
        }
        .padding(12)
        .frame(width: 340)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }
}
