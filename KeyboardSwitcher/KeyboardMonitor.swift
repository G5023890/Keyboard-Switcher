import AppKit
import Foundation

struct KeyboardMonitorDiagnostics: Equatable {
    var status = "Stopped"
    var lastFrontmostApp = ""
    var lastBuffer = ""
    var lastTypedWord = ""
    var lastCandidates = ""
    var lastDecision = "No key events yet"
    var lastCorrection = ""
    var lastLayoutSwitch = ""
    var manualMode = "Double Shift ready"
}

final class KeyboardMonitor {
    private let correctionEngine: CorrectionEngine
    private let exclusionManager: ExclusionManager
    private let inputSourceManager = InputSourceManager()
    private let soundPlayer = SoundPlayer()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var strokes: [KeyStroke] = []
    private var typedText = ""
    private var isApplyingCorrection = false
    private var lastShiftKeyDownAt: Date?
    private var isShiftCurrentlyDown = false
    private(set) var diagnostics = KeyboardMonitorDiagnostics()

    init(correctionEngine: CorrectionEngine, exclusionManager: ExclusionManager) {
        self.correctionEngine = correctionEngine
        self.exclusionManager = exclusionManager
    }

    func start() {
        guard eventTap == nil else { return }

        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon else {
                return Unmanaged.passUnretained(event)
            }

            let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(refcon).takeUnretainedValue()
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

        if let terminator = wordTerminator(for: keyCode) {
            let didCorrect = finalizeCurrentWord(terminator: terminator)
            resetBuffer()
            return didCorrect
        }

        if keyCode == 51 {
            if !strokes.isEmpty { strokes.removeLast() }
            if !typedText.isEmpty { typedText.removeLast() }
            diagnostics.lastBuffer = typedText
            diagnostics.lastDecision = "Backspace"
            return false
        }

        let stroke = KeyStroke(keyCode: keyCode, isShifted: flags.contains(.maskShift))
        let currentLanguage = inputSourceManager.currentKeyboardLanguage()
        guard let character = LayoutEngine.character(for: stroke, language: currentLanguage), LayoutEngine.isWordCharacter(stroke: stroke, currentLanguage: currentLanguage) else {
            diagnostics.lastDecision = "Reset on non-letter key \(keyCode)"
            resetBuffer()
            return false
        }

        strokes.append(stroke)
        typedText.append(character)
        diagnostics.lastBuffer = typedText
        diagnostics.lastDecision = "Buffering"
        return false
    }

    private func finalizeCurrentWord(terminator: String) -> Bool {
        let evaluation = correctionEngine.evaluate(strokes: strokes, typedText: typedText)
        diagnostics.lastTypedWord = typedText
        diagnostics.lastCandidates = evaluation.candidateScores
            .map { "\($0.candidate.language.displayName): \($0.candidate.text) \(Int($0.score * 100))%" }
            .joined(separator: " | ")
        diagnostics.lastDecision = evaluation.reason

        guard let decision = evaluation.decision else {
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
        switchInputSource(to: decision.language)
        isApplyingCorrection = false
        diagnostics.lastCorrection = "\(original) -> \(replacement)"
        diagnostics.lastDecision = "Corrected to \(decision.language.displayName), score \(Int(decision.score * 100))%"
        return true
    }

    private func handleFlagsChanged(keyCode: Int64, flags: CGEventFlags) -> Bool {
        guard isShiftKey(keyCode) else { return false }

        let isDown = flags.contains(.maskShift)
        guard isDown != isShiftCurrentlyDown else { return false }
        isShiftCurrentlyDown = isDown

        guard isDown else { return false }
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
        return performManualCorrection()
    }

    private func performManualCorrection() -> Bool {
        isApplyingCorrection = true
        defer { isApplyingCorrection = false }

        guard let selectedWord = TextReplacementPerformer.copyWordBeforeCursor(), !selectedWord.isEmpty else {
            diagnostics.lastDecision = "Double Shift: no word before cursor"
            return true
        }

        diagnostics.lastTypedWord = selectedWord

        guard let decision = correctionEngine.manualReplacement(for: selectedWord) else {
            diagnostics.lastDecision = "Double Shift: no replacement for \(selectedWord)"
            return true
        }

        TextReplacementPerformer.replaceSelection(with: decision.replacement)
        switchInputSource(to: decision.language)
        correctionEngine.recordManualCorrection(original: selectedWord, replacement: decision.replacement)
        diagnostics.lastCorrection = "\(selectedWord) -> \(decision.replacement)"
        diagnostics.lastDecision = "Manual corrected to \(decision.language.displayName)"
        resetBuffer()
        return true
    }

    private func switchInputSource(to language: KeyboardLanguage) {
        let previousLanguage = inputSourceManager.currentKeyboardLanguage()
        let didSwitch = inputSourceManager.selectKeyboardLanguage(language)
        if didSwitch && previousLanguage != language {
            soundPlayer.playLayoutSwitch()
        }
        diagnostics.lastLayoutSwitch = didSwitch ? "Switched to \(language.displayName)" : "Could not switch to \(language.displayName)"
    }

    private func resetBuffer() {
        strokes.removeAll(keepingCapacity: true)
        typedText.removeAll(keepingCapacity: true)
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

    private func isShiftKey(_ keyCode: Int64) -> Bool {
        keyCode == 56 || keyCode == 60
    }
}
