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
    var performance = PerformanceMetricsSnapshot.empty
}

enum PerformanceCorrectionKind: String, Equatable {
    case automatic
    case manual
    case spelling

    var displayName: String {
        switch self {
        case .automatic: "Auto"
        case .manual: "Manual"
        case .spelling: "Spelling"
        }
    }
}

struct PerformanceMetricsSnapshot: Equatable {
    struct Bucket: Equatable {
        let count: Int
        let averageMilliseconds: Double
        let p50Milliseconds: Double
        let p95Milliseconds: Double
        let maxMilliseconds: Double

        static let empty = Bucket(
            count: 0,
            averageMilliseconds: 0,
            p50Milliseconds: 0,
            p95Milliseconds: 0,
            maxMilliseconds: 0
        )
    }

    let lastKind: PerformanceCorrectionKind?
    let lastTotalMilliseconds: Double
    let lastEvaluationMilliseconds: Double
    let lastReplacementMilliseconds: Double
    let lastLayoutSwitchMilliseconds: Double
    let lastSoundMilliseconds: Double
    let overall: Bucket
    let warmOverall: Bucket
    let automatic: Bucket
    let manual: Bucket
    let spelling: Bucket
    let coldStartSamples: Int

    var warning: String {
        let p95 = warmOverall.count > 0 ? warmOverall.p95Milliseconds : overall.p95Milliseconds
        return p95 > 120
            ? "Session p95 is above 120 ms"
            : "Latency looks normal"
    }

    static let empty = PerformanceMetricsSnapshot(
        lastKind: nil,
        lastTotalMilliseconds: 0,
        lastEvaluationMilliseconds: 0,
        lastReplacementMilliseconds: 0,
        lastLayoutSwitchMilliseconds: 0,
        lastSoundMilliseconds: 0,
        overall: .empty,
        warmOverall: .empty,
        automatic: .empty,
        manual: .empty,
        spelling: .empty,
        coldStartSamples: 0
    )
}

struct PerformanceTimingSample: Equatable {
    let kind: PerformanceCorrectionKind
    let totalMilliseconds: Double
    let evaluationMilliseconds: Double
    let replacementMilliseconds: Double
    let layoutSwitchMilliseconds: Double
    let soundMilliseconds: Double
    let isColdStart: Bool

    init(
        kind: PerformanceCorrectionKind,
        totalMilliseconds: Double,
        evaluationMilliseconds: Double,
        replacementMilliseconds: Double,
        layoutSwitchMilliseconds: Double,
        soundMilliseconds: Double,
        isColdStart: Bool = false
    ) {
        self.kind = kind
        self.totalMilliseconds = totalMilliseconds
        self.evaluationMilliseconds = evaluationMilliseconds
        self.replacementMilliseconds = replacementMilliseconds
        self.layoutSwitchMilliseconds = layoutSwitchMilliseconds
        self.soundMilliseconds = soundMilliseconds
        self.isColdStart = isColdStart
    }

    func markingColdStart(_ isColdStart: Bool) -> PerformanceTimingSample {
        PerformanceTimingSample(
            kind: kind,
            totalMilliseconds: totalMilliseconds,
            evaluationMilliseconds: evaluationMilliseconds,
            replacementMilliseconds: replacementMilliseconds,
            layoutSwitchMilliseconds: layoutSwitchMilliseconds,
            soundMilliseconds: soundMilliseconds,
            isColdStart: isColdStart
        )
    }
}

final class PerformanceMetricsStore {
    private var samples: [PerformanceTimingSample] = []
    private let maximumSamples: Int

    init(maximumSamples: Int = 500) {
        self.maximumSamples = maximumSamples
    }

    func record(_ sample: PerformanceTimingSample) -> PerformanceMetricsSnapshot {
        let storedSample = sample.markingColdStart(sample.isColdStart || samples.isEmpty)
        samples.append(storedSample)
        if samples.count > maximumSamples {
            samples.removeFirst(samples.count - maximumSamples)
        }
        return snapshot()
    }

    func snapshot() -> PerformanceMetricsSnapshot {
        let last = samples.last
        let warmSamples = samples.filter { !$0.isColdStart }
        return PerformanceMetricsSnapshot(
            lastKind: last?.kind,
            lastTotalMilliseconds: last?.totalMilliseconds ?? 0,
            lastEvaluationMilliseconds: last?.evaluationMilliseconds ?? 0,
            lastReplacementMilliseconds: last?.replacementMilliseconds ?? 0,
            lastLayoutSwitchMilliseconds: last?.layoutSwitchMilliseconds ?? 0,
            lastSoundMilliseconds: last?.soundMilliseconds ?? 0,
            overall: bucket(for: samples),
            warmOverall: bucket(for: warmSamples),
            automatic: bucket(for: samples.filter { $0.kind == .automatic }),
            manual: bucket(for: samples.filter { $0.kind == .manual }),
            spelling: bucket(for: samples.filter { $0.kind == .spelling }),
            coldStartSamples: samples.filter(\.isColdStart).count
        )
    }

    private func bucket(for samples: [PerformanceTimingSample]) -> PerformanceMetricsSnapshot.Bucket {
        guard !samples.isEmpty else { return .empty }
        let totals = samples.map(\.totalMilliseconds).sorted()
        let average = totals.reduce(0, +) / Double(totals.count)
        return PerformanceMetricsSnapshot.Bucket(
            count: totals.count,
            averageMilliseconds: average,
            p50Milliseconds: percentile(0.50, in: totals),
            p95Milliseconds: percentile(0.95, in: totals),
            maxMilliseconds: totals.last ?? 0
        )
    }

    private func percentile(_ percentile: Double, in sortedValues: [Double]) -> Double {
        guard !sortedValues.isEmpty else { return 0 }
        let clamped = max(0, min(percentile, 1))
        let index = Int((Double(sortedValues.count - 1) * clamped).rounded(.up))
        return sortedValues[min(index, sortedValues.count - 1)]
    }
}

private struct CorrectionPerformanceTimer {
    let kind: PerformanceCorrectionKind
    private let startedAt: DispatchTime
    private var evaluationCompletedAt: DispatchTime?
    private var replacementCompletedAt: DispatchTime?
    private var layoutSwitchMilliseconds: Double = 0
    private var soundMilliseconds: Double = 0

    init(kind: PerformanceCorrectionKind, startedAt: DispatchTime = .now()) {
        self.kind = kind
        self.startedAt = startedAt
    }

    mutating func markEvaluationComplete() {
        evaluationCompletedAt = .now()
    }

    mutating func markReplacementComplete() {
        replacementCompletedAt = .now()
    }

    mutating func addPostCorrection(_ timing: PostCorrectionPerformanceTiming) {
        layoutSwitchMilliseconds += timing.layoutSwitchMilliseconds
        soundMilliseconds += timing.soundMilliseconds
    }

    func finish() -> PerformanceTimingSample {
        let finishedAt = DispatchTime.now()
        return PerformanceTimingSample(
            kind: kind,
            totalMilliseconds: Self.milliseconds(from: startedAt, to: finishedAt),
            evaluationMilliseconds: evaluationCompletedAt.map { Self.milliseconds(from: startedAt, to: $0) } ?? 0,
            replacementMilliseconds: replacementCompletedAt.map { Self.milliseconds(from: evaluationCompletedAt ?? startedAt, to: $0) } ?? 0,
            layoutSwitchMilliseconds: layoutSwitchMilliseconds,
            soundMilliseconds: soundMilliseconds
        )
    }

    private static func milliseconds(from start: DispatchTime, to end: DispatchTime) -> Double {
        Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }
}

private struct PostCorrectionPerformanceTiming {
    var layoutSwitchMilliseconds: Double = 0
    var soundMilliseconds: Double = 0
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
    private static let maximumBufferedTokenLength = 64

    private let correctionEngine: CorrectionEngine
    private let exclusionManager: ExclusionManager
    private let inputSourceManager = InputSourceManager()
    private let soundPlayer = SoundPlayer()
    private let trainingSampleStore = CorrectionTrainingSampleStore.shared
    private let performanceMetricsStore = PerformanceMetricsStore()
    var preferences = KeyboardMonitorPreferences()
    var automaticallyCorrectsTypedWords = true
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var strokes: [KeyStroke] = []
    private var typedText = ""
    private var isDiscardingOversizedToken = false
    private var isApplyingCorrection = false
    private var lastShiftKeyDownAt: Date?
    private var isShiftCurrentlyDown = false
    private var pendingManualCorrectionAfterShiftRelease = false
    private var lastFrontmostBundleIdentifier: String?
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
        let frontmostBundleIdentifier = frontmostApp?.bundleIdentifier
        if frontmostBundleIdentifier != lastFrontmostBundleIdentifier {
            resetBuffer()
            manualCycleState = nil
            lastFrontmostBundleIdentifier = frontmostBundleIdentifier
        }
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

        if let handled = handleManualCandidateKey(keyCode: keyCode) {
            return handled
        }

        if let terminator = wordTerminator(for: keyCode) {
            manualCycleState = nil
            if isDiscardingOversizedToken {
                diagnostics.lastDecision = "Skipped oversized token"
                resetBuffer()
                return false
            }
            guard !typedText.isEmpty else {
                diagnostics.lastDecision = "Space passed through: no buffered word"
                resetBuffer()
                return false
            }
            guard automaticallyCorrectsTypedWords else {
                diagnostics.lastDecision = "Automatic correction disabled"
                resetBuffer()
                return false
            }
            // Detach the completed token before touching the focused control.
            // AX replacement and input-source switching can synchronously pump
            // input events; a following key must never be appended to this word.
            let completedStrokes = strokes
            let completedTypedText = typedText
            resetBuffer()
            return finalizeWord(
                strokes: completedStrokes,
                typedText: completedTypedText,
                terminator: terminator
            )
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

        if keyCode == 117 {
            manualCycleState = nil
            diagnostics.lastDecision = "Forward delete: reset buffer"
            resetBuffer()
            return false
        }

        if isNavigationKey(keyCode) {
            manualCycleState = nil
            if !typedText.isEmpty || isDiscardingOversizedToken {
                diagnostics.lastDecision = "Navigation inside word: reset buffer"
                resetBuffer()
            }
            return false
        }

        if isDiscardingOversizedToken {
            diagnostics.lastDecision = "Ignoring oversized token until Space"
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
            guard keepBufferingCurrentToken() else { return false }
            manualCycleState = nil
            diagnostics.lastBuffer = typedText
            diagnostics.lastPhysicalReplay = LayoutEngine.physicalReplaySummary(for: strokes)
            diagnostics.lastDecision = "Buffering technical token"
            return false
        }

        guard let character = LayoutEngine.character(for: stroke, language: currentLanguage), LayoutEngine.isTokenCharacter(stroke: stroke, currentLanguage: currentLanguage) else {
            diagnostics.lastDecision = "Reset on non-letter key \(keyCode)"
            resetBuffer()
            return false
        }

        strokes.append(stroke)
        typedText.append(character)
        guard keepBufferingCurrentToken() else { return false }
        manualCycleState = nil
        diagnostics.lastBuffer = typedText
        diagnostics.lastPhysicalReplay = LayoutEngine.physicalReplaySummary(for: strokes)
        diagnostics.lastDecision = "Buffering"
        return false
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

    private func finalizeWord(strokes activeStrokes: [KeyStroke], typedText activeTypedText: String, terminator: String) -> Bool {
        var timing = CorrectionPerformanceTimer(kind: .automatic)
        let appMode = exclusionManager.frontmostAppBehaviorMode
        let frontmostBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let inputContext = FocusedInputContextInspector.current()
        diagnostics.lastInputContext = inputContext.diagnosticDescription

        switch inputContext.correctionPolicy {
        case .block(let reason):
            diagnostics.lastTypedWord = activeTypedText
            diagnostics.lastTerminator = terminatorLabel(terminator)
            diagnostics.lastDecision = "Skipped \(reason)"
            diagnostics.lastCandidateInspector = [
                "Input Context",
                "Typed: \(activeTypedText.isEmpty ? "-" : activeTypedText)",
                "Context: \(inputContext.diagnosticDescription)",
                "Physical replay: \(LayoutEngine.physicalReplaySummary(for: activeStrokes))",
                "Decision: blocked \(reason)"
            ].joined(separator: "\n")
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
        let isStrictContext: Bool
        switch inputContext.correctionPolicy {
        case .strict:
            isStrictContext = true
        case .allow, .block:
            isStrictContext = appMode == .strict
        }
        let evaluation = correctionEngine.evaluate(
            strokes: activeStrokes,
            typedText: activeTypedText,
            allowsShortFunctionalWords: terminator == " ",
            profile: activeProfile,
            appMode: appMode,
            terminatorType: terminator == " " ? "space" : "punctuation",
            isStrictContext: isStrictContext
        )
        timing.markEvaluationComplete()
        diagnostics.lastTypedWord = activeTypedText
        diagnostics.lastTerminator = terminatorLabel(terminator)
        diagnostics.lastCandidates = evaluation.candidateScores
            .map { "\($0.candidate.language.displayName): \($0.candidate.text) \(Int($0.score * 100))%" }
            .joined(separator: " | ")
        diagnostics.lastCandidateInspector = evaluation.diagnosticSummary
            + "\nApp mode: \(appMode.displayName)"
            + "\nInput context: \(inputContext.diagnosticDescription)"
            + "\nInput policy: \(inputModeDescription)"
            + "\nPhysical replay: \(LayoutEngine.physicalReplaySummary(for: activeStrokes))"
        diagnostics.lastDecision = evaluation.reason
        diagnostics.lastSuggestion = evaluation.suggestion.map {
            "\(activeTypedText) -> \($0.replacement) (\($0.language.displayName), \(Int(($0.score * 100).rounded()))%)"
        } ?? ""
        updateLocalIntelligenceDiagnostics(
            features: evaluation.safetyFeatures,
            prediction: evaluation.safetyPrediction,
            fallbackPrediction: evaluation.safetyFallbackPrediction
        )
        recordMLDivergenceIfNeeded(evaluation)

        guard let decision = evaluation.decision else {
            if let suggestion = evaluation.suggestion {
                diagnostics.lastSuggestion = "\(activeTypedText) -> \(suggestion.replacement) (\(suggestion.language.displayName), \(Int((suggestion.score * 100).rounded()))%)"
                diagnostics.lastDecision = "Possible typo signaled"
                if preferences.shouldPlayPossibleTypoSound() {
                    soundPlayer.playPossibleTypo(volume: preferences.soundVolume * 0.55)
                }
                recordTrainingSample(
                    outcome: .suggested,
                    features: evaluation.safetyFeatures,
                    prediction: evaluation.safetyPrediction,
                    decisionReason: evaluation.reason
                )
            } else {
                let spellingStartedAt = DispatchTime.now()
                if preferences.shouldCorrectSpellingMistakes(),
                   terminator == " ",
                   case .allow = inputContext.correctionPolicy,
                   let spellingDecision = correctionEngine.spellingCorrection(
                    for: activeTypedText,
                    language: inputSourceManager.currentKeyboardLanguage(),
                    appMode: appMode,
                    terminatorType: "space"
                   ) {
                    var spellingTiming = CorrectionPerformanceTimer(kind: .spelling, startedAt: spellingStartedAt)
                    spellingTiming.markEvaluationComplete()
                    let shouldSuppressTerminator = applySpellingCorrection(
                        spellingDecision,
                        original: activeTypedText,
                        terminator: terminator,
                        inputContext: inputContext,
                        appMode: appMode,
                        timing: &spellingTiming
                    )
                    diagnostics.lastCandidateInspector += "\nSpellchecker: corrected \(activeTypedText) -> \(spellingDecision.replacement)"
                    return shouldSuppressTerminator
                }
            }
            return false
        }

        let original = activeTypedText
        let replacement = decision.replacement

        isApplyingCorrection = true
        let replacementMethod = correctionEngine.applyCorrection(
            replacingPreviousCharacterCount: original.count,
            original: original,
            with: replacement,
            language: decision.language,
            terminator: terminator,
            allowSyntheticFallback: Self.allowsSyntheticReplacementFallback(
                bundleIdentifier: frontmostBundleIdentifier,
                inputContext: inputContext
            )
        )
        guard let replacementMethod else {
            isApplyingCorrection = false
            diagnostics.lastDecision = "Skipped replacement: focused text unavailable"
            return false
        }
        timing.markReplacementComplete()
        timing.addPostCorrection(handlePostCorrection(language: decision.language, origin: .automatic))
        isApplyingCorrection = false
        diagnostics.lastCorrection = "\(original) -> \(replacement)"
        diagnostics.lastSuggestion = ""
        diagnostics.lastDecision = "Corrected to \(decision.language.displayName), score \(Int(decision.score * 100))%"
        recordPerformanceTiming(timing.finish())
        recordTrainingSample(
            outcome: .autoCorrected,
            features: evaluation.safetyFeatures,
            prediction: evaluation.safetyPrediction,
            decisionReason: evaluation.reason
        )
        switch replacementMethod {
        case .accessibility:
            // Keep the physical Space in the original event stream. Replacing
            // only the word avoids merged words in AX-backed controls.
            return false
        case .synthetic:
            // Synthetic fallback inserted the terminator atomically because
            // browser-backed editors may not expose a stable AX caret.
            return true
        }
    }

    private func applySpellingCorrection(
        _ decision: CorrectionDecision,
        original: String,
        terminator: String,
        inputContext: FocusedInputContext,
        appMode: AppBehaviorMode,
        timing: inout CorrectionPerformanceTimer
    ) -> Bool {
        let replacement = decision.replacement
        isApplyingCorrection = true
        let replacementMethod = correctionEngine.applyCorrection(
            replacingPreviousCharacterCount: original.count,
            original: original,
            with: replacement,
            language: decision.language,
            terminator: terminator,
            allowSyntheticFallback: Self.allowsSyntheticReplacementFallback(
                bundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                inputContext: inputContext
            )
        )
        guard let replacementMethod else {
            isApplyingCorrection = false
            diagnostics.lastDecision = "Skipped spelling replacement: focused text unavailable"
            return false
        }
        timing.markReplacementComplete()
        timing.addPostCorrection(handlePostCorrection(language: decision.language, origin: .automatic))
        isApplyingCorrection = false
        diagnostics.lastCorrection = "\(original) -> \(decision.replacement)"
        diagnostics.lastSuggestion = ""
        diagnostics.lastDecision = "Spelling corrected with macOS spellchecker"
        recordPerformanceTiming(timing.finish())
        switch replacementMethod {
        case .accessibility:
            return false
        case .synthetic:
            return true
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
        var timing = CorrectionPerformanceTimer(kind: .manual)
        isApplyingCorrection = true
        defer { isApplyingCorrection = false }

        if cycleManualCandidateIfAvailable() {
            return true
        }

        guard let selectedWord = TextReplacementPerformer.copySpaceTokenBeforeCursor(), !selectedWord.isEmpty else {
            if !typedText.isEmpty {
                return performBufferedManualTranslation()
            }
            diagnostics.lastDecision = "Double Shift: active text field unavailable"
            return false
        }

        diagnostics.lastTypedWord = selectedWord
        diagnostics.lastTerminator = "Manual"

        let candidates = correctionEngine.manualReplacements(for: selectedWord)
        timing.markEvaluationComplete()
        guard let decision = candidates.first else {
            diagnostics.lastDecision = "Double Shift: no replacement for \(selectedWord)"
            diagnostics.lastCandidateInspector = "Manual Double Shift\nTyped: \(selectedWord)\nDecision: no replacement"
            manualCycleState = nil
            TextReplacementPerformer.collapseSelectionToEnd()
            return true
        }

        guard TextReplacementPerformer.replaceSelection(expectedText: selectedWord, with: decision.replacement) else {
            diagnostics.lastDecision = "Double Shift: focused text changed"
            TextReplacementPerformer.collapseSelectionToEnd()
            return true
        }
        timing.markReplacementComplete()
        timing.addPostCorrection(handlePostCorrection(language: decision.language, origin: .manual))
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
        recordPerformanceTiming(timing.finish())
        resetBuffer()
        return true
    }

    private func performBufferedManualTranslation() -> Bool {
        var timing = CorrectionPerformanceTimer(kind: .manual)
        let original = typedText
        diagnostics.lastTypedWord = original
        diagnostics.lastTerminator = "Manual"

        let candidates = correctionEngine.manualReplacements(for: original)
        timing.markEvaluationComplete()
        guard let decision = candidates.first else {
            diagnostics.lastDecision = "Double Shift: no replacement for \(original)"
            diagnostics.lastCandidateInspector = "Manual Double Shift\nTyped: \(original)\nMode: current word\nDecision: no replacement"
            manualCycleState = nil
            return true
        }

        guard TextReplacementPerformer.replacePreviousText(
            characterCount: original.count,
            expectedPreviousText: original,
            with: decision.replacement
        ) else {
            diagnostics.lastDecision = "Double Shift: focused text changed"
            return true
        }
        timing.markReplacementComplete()
        timing.addPostCorrection(handlePostCorrection(language: decision.language, origin: .manual))
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
        recordPerformanceTiming(timing.finish())
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
        var timing = CorrectionPerformanceTimer(kind: .manual)
        timing.markEvaluationComplete()
        TextReplacementPerformer.replacePreviousText(
            characterCount: cycle.currentReplacement.count,
            expectedPreviousText: cycle.currentReplacement,
            with: decision.replacement
        )
        timing.markReplacementComplete()
        timing.addPostCorrection(handlePostCorrection(language: decision.language, origin: .manual))
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
        recordPerformanceTiming(timing.finish())
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
        var timing = CorrectionPerformanceTimer(kind: .manual)
        timing.markEvaluationComplete()
        if decision.replacement != cycle.currentReplacement {
            TextReplacementPerformer.replacePreviousText(
                characterCount: cycle.currentReplacement.count,
                expectedPreviousText: cycle.currentReplacement,
                with: decision.replacement
            )
            timing.markReplacementComplete()
            timing.addPostCorrection(handlePostCorrection(language: decision.language, origin: .manual))
        } else {
            timing.markReplacementComplete()
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
        recordPerformanceTiming(timing.finish())
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
            return
        }

        diagnostics.lastManualCandidatePreview = cycle.options
            .map { option in
                let marker = option.isSelected ? "selected" : "option"
                return "\(option.index + 1). \(option.replacement) (\(option.language.displayName), \(option.scoreText), \(marker))"
            }
            .joined(separator: " | ")
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

    private func handlePostCorrection(language: KeyboardLanguage, origin: CorrectionOrigin) -> PostCorrectionPerformanceTiming {
        guard preferences.shouldSwitchInputSource() else {
            diagnostics.lastLayoutSwitch = "Switch disabled"
            return PostCorrectionPerformanceTiming()
        }
        return switchInputSource(to: language, origin: origin)
    }

    private func switchInputSource(to language: KeyboardLanguage, origin: CorrectionOrigin) -> PostCorrectionPerformanceTiming {
        var timing = PostCorrectionPerformanceTiming()
        let previousLanguage = inputSourceManager.currentKeyboardLanguage()
        let layoutStart = DispatchTime.now()
        let didSwitch = inputSourceManager.selectKeyboardLanguage(language)
        timing.layoutSwitchMilliseconds = Self.milliseconds(from: layoutStart, to: .now())
        if didSwitch && previousLanguage != language && preferences.shouldPlaySound(origin: origin) {
            let soundStart = DispatchTime.now()
            soundPlayer.playLayoutSwitch(volume: preferences.soundVolume)
            timing.soundMilliseconds = Self.milliseconds(from: soundStart, to: .now())
        }
        diagnostics.lastLayoutSwitch = didSwitch ? "Switched to \(language.displayName)" : "Could not switch to \(language.displayName)"
        return timing
    }

    private func recordPerformanceTiming(_ sample: PerformanceTimingSample) {
        diagnostics.performance = performanceMetricsStore.record(sample)
    }

    private static func milliseconds(from start: DispatchTime, to end: DispatchTime) -> Double {
        Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }

    static func allowsSyntheticReplacementFallback(bundleIdentifier: String?, inputContext: FocusedInputContext) -> Bool {
        if bundleIdentifier == "com.apple.MobileSMS" {
            return false
        }

        switch inputContext.kind {
        case .textField, .textArea:
            return true
        case .unavailable:
            return bundleIdentifier == "com.openai.codex"
        case .unknown:
            // Codex uses a browser-backed editor that can expose an AX element
            // without a writable text value. Its fallback is deliberately
            // limited to this trusted bundle identifier.
            return bundleIdentifier == "com.openai.codex"
        case .secureTextField, .searchField, .comboBox:
            return false
        }
    }

    private func resetBuffer() {
        strokes.removeAll(keepingCapacity: true)
        typedText.removeAll(keepingCapacity: true)
        isDiscardingOversizedToken = false
        pendingManualCorrectionAfterShiftRelease = false
        diagnostics.lastBuffer = ""
    }

    private func keepBufferingCurrentToken() -> Bool {
        guard strokes.count <= Self.maximumBufferedTokenLength else {
            strokes.removeAll(keepingCapacity: true)
            typedText.removeAll(keepingCapacity: true)
            isDiscardingOversizedToken = true
            manualCycleState = nil
            diagnostics.lastBuffer = ""
            diagnostics.lastPhysicalReplay = "Skipped oversized token"
            diagnostics.lastDecision = "Ignoring token longer than \(Self.maximumBufferedTokenLength) keys"
            return false
        }
        return true
    }

    private func wordTerminator(for keyCode: Int64) -> String? {
        switch keyCode {
        case 49:
            return " "
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

    private func isNavigationKey(_ keyCode: Int64) -> Bool {
        switch keyCode {
        case 115, 116, 119, 121, 123, 124, 125, 126:
            return true
        default:
            return false
        }
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
