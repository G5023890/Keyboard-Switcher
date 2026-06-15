import AppKit
import Combine
import Foundation
import ServiceManagement

@MainActor
final class AppState: ObservableObject {
    @Published var isKeyboardSwitcherEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(isKeyboardSwitcherEnabled, forKey: DefaultsKey.keyboardSwitcherEnabled)
            updateMonitorState()
        }
    }

    @Published var isAutoCorrectionEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(isAutoCorrectionEnabled, forKey: DefaultsKey.autoCorrection)
            updateMonitorPreferences()
        }
    }

    @Published var confidenceThreshold: Double = 0.62 {
        didSet {
            UserDefaults.standard.set(confidenceThreshold, forKey: DefaultsKey.confidence)
            correctionEngine.confidenceThreshold = confidenceThreshold
            let closest = CorrectionSensitivity.closest(to: confidenceThreshold)
            if closest != correctionSensitivity {
                correctionSensitivity = closest
            }
        }
    }

    @Published var correctionSensitivity: CorrectionSensitivity = .balanced {
        didSet {
            UserDefaults.standard.set(correctionSensitivity.rawValue, forKey: DefaultsKey.correctionSensitivity)
            if let threshold = correctionSensitivity.threshold, abs(confidenceThreshold - threshold) > 0.001 {
                confidenceThreshold = threshold
            }
        }
    }

    @Published var enabledLanguages: Set<KeyboardLanguage> = Set(KeyboardLanguage.allCases) {
        didSet {
            UserDefaults.standard.set(enabledLanguages.map(\.rawValue), forKey: DefaultsKey.enabledLanguages)
            correctionEngine.enabledLanguages = enabledLanguages
        }
    }

    @Published var excludedBundleIdentifiers: Set<String> = ExclusionManager.defaultExcludedBundleIdentifiers {
        didSet {
            UserDefaults.standard.set(Array(excludedBundleIdentifiers).sorted(), forKey: DefaultsKey.exclusions)
            exclusionManager.excludedBundleIdentifiers = excludedBundleIdentifiers
        }
    }

    @Published var menuBarIconStyle: MenuBarIconStyle = .glyphs {
        didSet {
            UserDefaults.standard.set(menuBarIconStyle.rawValue, forKey: DefaultsKey.menuBarIconStyle)
        }
    }

    @Published var switchInputSourceAfterCorrection: Bool = true {
        didSet {
            UserDefaults.standard.set(switchInputSourceAfterCorrection, forKey: DefaultsKey.switchInputSourceAfterCorrection)
            updateMonitorPreferences()
        }
    }

    @Published var learnsFromManualCorrections: Bool = true {
        didSet {
            UserDefaults.standard.set(learnsFromManualCorrections, forKey: DefaultsKey.learnsFromManualCorrections)
            correctionEngine.learnsFromManualCorrections = learnsFromManualCorrections
        }
    }

    @Published var playSoundWhenLayoutCorrected: Bool = true {
        didSet {
            UserDefaults.standard.set(playSoundWhenLayoutCorrected, forKey: DefaultsKey.playSoundWhenLayoutCorrected)
            updateMonitorPreferences()
        }
    }

    @Published var soundVolume: Double = 0.75 {
        didSet {
            let clamped = max(0, min(soundVolume, 1))
            if clamped != soundVolume {
                soundVolume = clamped
                return
            }
            UserDefaults.standard.set(soundVolume, forKey: DefaultsKey.soundVolume)
            updateMonitorPreferences()
        }
    }

    @Published var playSoundOnlyForAutomaticCorrections: Bool = false {
        didSet {
            UserDefaults.standard.set(playSoundOnlyForAutomaticCorrections, forKey: DefaultsKey.playSoundOnlyForAutomaticCorrections)
            updateMonitorPreferences()
        }
    }

    @Published private(set) var launchAtLoginEnabled = false
    @Published private(set) var currentLanguage: KeyboardLanguage = .english
    @Published private(set) var canUndoLastCorrection = false
    @Published private(set) var diagnostics = KeyboardMonitorDiagnostics()
    @Published var permissions = PermissionManager()

    let defaultExclusions = ExclusionManager.defaultExcludedBundleIdentifiers

    private let inputSourceManager = InputSourceManager()
    private let exclusionManager = ExclusionManager(excludedBundleIdentifiers: ExclusionManager.defaultExcludedBundleIdentifiers)
    private let undoController = CorrectionUndoManager()
    private lazy var correctionEngine = CorrectionEngine(undoController: undoController)
    private lazy var keyboardMonitor = KeyboardMonitor(correctionEngine: correctionEngine, exclusionManager: exclusionManager)
    private let soundPreviewPlayer = SoundPlayer()
    private var cancellables = Set<AnyCancellable>()
    private var inputSourceTimer: Timer?

    init() {
        let defaults = UserDefaults.standard
        let storedLanguages = defaults.stringArray(forKey: DefaultsKey.enabledLanguages) ?? KeyboardLanguage.allCases.map(\.rawValue)
        let languages = Set(storedLanguages.compactMap(KeyboardLanguage.init(rawValue:)))

        isKeyboardSwitcherEnabled = defaults.object(forKey: DefaultsKey.keyboardSwitcherEnabled) as? Bool ?? true
        isAutoCorrectionEnabled = defaults.object(forKey: DefaultsKey.autoCorrection) as? Bool ?? true
        let storedConfidence = defaults.object(forKey: DefaultsKey.confidence) as? Double ?? 0.62
        confidenceThreshold = max(storedConfidence, 0.62)
        correctionSensitivity = CorrectionSensitivity(rawValue: defaults.string(forKey: DefaultsKey.correctionSensitivity) ?? "") ?? CorrectionSensitivity.closest(to: confidenceThreshold)
        enabledLanguages = languages.isEmpty ? Set(KeyboardLanguage.allCases) : languages
        menuBarIconStyle = MenuBarIconStyle(rawValue: defaults.string(forKey: DefaultsKey.menuBarIconStyle) ?? "") ?? .glyphs
        switchInputSourceAfterCorrection = defaults.object(forKey: DefaultsKey.switchInputSourceAfterCorrection) as? Bool ?? true
        learnsFromManualCorrections = defaults.object(forKey: DefaultsKey.learnsFromManualCorrections) as? Bool ?? true
        playSoundWhenLayoutCorrected = defaults.object(forKey: DefaultsKey.playSoundWhenLayoutCorrected) as? Bool ?? true
        soundVolume = defaults.object(forKey: DefaultsKey.soundVolume) as? Double ?? 0.75
        playSoundOnlyForAutomaticCorrections = defaults.object(forKey: DefaultsKey.playSoundOnlyForAutomaticCorrections) as? Bool ?? false
        var storedExclusions = Set(defaults.stringArray(forKey: DefaultsKey.exclusions) ?? Array(ExclusionManager.defaultExcludedBundleIdentifiers))
        storedExclusions.remove("com.apple.TextEdit")
        excludedBundleIdentifiers = storedExclusions
        exclusionManager.excludedBundleIdentifiers = storedExclusions

        correctionEngine.confidenceThreshold = confidenceThreshold
        correctionEngine.enabledLanguages = enabledLanguages
        correctionEngine.learnsFromManualCorrections = learnsFromManualCorrections
        undoController.onUndo = { [weak self] correction in
            self?.correctionEngine.recordUndoneCorrection(correction)
        }
        launchAtLoginEnabled = LaunchAtLoginManager.isEnabled
        updateMonitorPreferences()
        startInputSourcePolling()
        bindUndoState()
        updateMonitorState()
    }

    func refreshRuntimeState() {
        permissions.refresh()
        currentLanguage = inputSourceManager.currentKeyboardLanguage()
        canUndoLastCorrection = undoController.canUndo
        if isKeyboardSwitcherEnabled {
            keyboardMonitor.ensureRunning()
        }
        diagnostics = keyboardMonitor.diagnostics
        launchAtLoginEnabled = LaunchAtLoginManager.isEnabled
        updateMonitorState()
    }

    func setLanguageEnabled(_ language: KeyboardLanguage, isEnabled: Bool) {
        if isEnabled {
            enabledLanguages.insert(language)
        } else if enabledLanguages.count > 1 {
            enabledLanguages.remove(language)
        }
    }

    func setExclusion(_ bundleIdentifier: String, isEnabled: Bool) {
        if isEnabled {
            excludedBundleIdentifiers.insert(bundleIdentifier)
        } else {
            excludedBundleIdentifiers.remove(bundleIdentifier)
        }
    }

    func isPresetEnabled(_ preset: ExclusionPreset) -> Bool {
        preset.bundleIdentifiers.isSubset(of: excludedBundleIdentifiers)
    }

    func setPreset(_ preset: ExclusionPreset, isEnabled: Bool) {
        if isEnabled {
            excludedBundleIdentifiers.formUnion(preset.bundleIdentifiers)
        } else {
            excludedBundleIdentifiers.subtract(preset.bundleIdentifiers)
        }
    }

    func restoreDefaultExclusions() {
        excludedBundleIdentifiers = ExclusionManager.defaultExcludedBundleIdentifiers
    }

    func undoLastCorrection() {
        undoController.undoLastCorrection()
        canUndoLastCorrection = undoController.canUndo
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        do {
            try LaunchAtLoginManager.setEnabled(enabled)
            launchAtLoginEnabled = LaunchAtLoginManager.isEnabled
        } catch {
            launchAtLoginEnabled = LaunchAtLoginManager.isEnabled
            diagnostics.lastDecision = "Launch at Login failed: \(error.localizedDescription)"
        }
    }

    func learnedCorrections() -> [LearnedCorrection] {
        LearningStore.shared.allPreferences()
    }

    func removeLearnedCorrection(_ correction: LearnedCorrection) {
        LearningStore.shared.removePreference(original: correction.original)
    }

    func resetLearningData() {
        LearningStore.shared.reset()
        diagnostics.lastDecision = "Learning data reset"
    }

    func playSoundPreview() {
        soundPreviewPlayer.playLayoutSwitch(volume: soundVolume)
    }

    func diagnosticReport() -> String {
        [
            "Keyboard Switcher Diagnostic Report",
            "Status: \(diagnostics.status)",
            "Front App: \(diagnostics.lastFrontmostApp.isEmpty ? "Unknown" : diagnostics.lastFrontmostApp)",
            "Current Layout: \(currentLanguage.displayName)",
            "Buffer: \(diagnostics.lastBuffer.isEmpty ? "Empty" : diagnostics.lastBuffer)",
            "Last Word: \(diagnostics.lastTypedWord.isEmpty ? "-" : diagnostics.lastTypedWord)",
            "Decision: \(diagnostics.lastDecision)",
            "Manual: \(diagnostics.manualMode)",
            "Layout Switch: \(diagnostics.lastLayoutSwitch.isEmpty ? "-" : diagnostics.lastLayoutSwitch)",
            "Candidates: \(diagnostics.lastCandidates.isEmpty ? "None" : diagnostics.lastCandidates)",
            "Correction: \(diagnostics.lastCorrection.isEmpty ? "-" : diagnostics.lastCorrection)"
        ].joined(separator: "\n")
    }

    private func startInputSourcePolling() {
        currentLanguage = inputSourceManager.currentKeyboardLanguage()
        inputSourceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.isKeyboardSwitcherEnabled {
                    self.keyboardMonitor.ensureRunning()
                }
                self.currentLanguage = self.inputSourceManager.currentKeyboardLanguage()
                self.canUndoLastCorrection = self.undoController.canUndo
                self.diagnostics = self.keyboardMonitor.diagnostics
                self.permissions.refresh()
            }
        }
    }

    private func bindUndoState() {
        undoController.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.canUndoLastCorrection = self?.undoController.canUndo ?? false
                }
            }
            .store(in: &cancellables)
    }

    private func updateMonitorState() {
        updateMonitorPreferences()
        if isKeyboardSwitcherEnabled {
            keyboardMonitor.start()
        } else {
            keyboardMonitor.stop()
        }
    }

    private func updateMonitorPreferences() {
        keyboardMonitor.automaticallyCorrectsTypedWords = isAutoCorrectionEnabled
        keyboardMonitor.preferences = KeyboardMonitorPreferences(
            switchInputSourceAfterCorrection: switchInputSourceAfterCorrection,
            playSoundWhenLayoutCorrected: playSoundWhenLayoutCorrected,
            soundVolume: soundVolume,
            playSoundOnlyForAutomaticCorrections: playSoundOnlyForAutomaticCorrections
        )
    }
}

private enum DefaultsKey {
    static let keyboardSwitcherEnabled = "keyboardSwitcherEnabled"
    static let autoCorrection = "autoCorrectionEnabled"
    static let confidence = "confidenceThreshold"
    static let correctionSensitivity = "correctionSensitivity"
    static let enabledLanguages = "enabledLanguages"
    static let exclusions = "excludedBundleIdentifiers"
    static let menuBarIconStyle = "menuBarIconStyle"
    static let switchInputSourceAfterCorrection = "switchInputSourceAfterCorrection"
    static let learnsFromManualCorrections = "learnsFromManualCorrections"
    static let playSoundWhenLayoutCorrected = "playSoundWhenLayoutCorrected"
    static let soundVolume = "soundVolume"
    static let playSoundOnlyForAutomaticCorrections = "playSoundOnlyForAutomaticCorrections"
}

private enum LaunchAtLoginManager {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
        }
    }
}
