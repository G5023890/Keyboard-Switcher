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

    @Published var appBehaviorModes: [String: AppBehaviorMode] = [:] {
        didSet {
            UserDefaults.standard.set(
                appBehaviorModes.mapValues(\.rawValue),
                forKey: DefaultsKey.appBehaviorModes
            )
            exclusionManager.appBehaviorModes = appBehaviorModes
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

    @Published var usesLocalMLSafetyClassifier: Bool = true {
        didSet {
            UserDefaults.standard.set(usesLocalMLSafetyClassifier, forKey: DefaultsKey.usesLocalMLSafetyClassifier)
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

    @Published var hasSeenOnboarding: Bool = false {
        didSet {
            UserDefaults.standard.set(hasSeenOnboarding, forKey: DefaultsKey.hasSeenOnboarding)
        }
    }

    @Published private(set) var launchAtLoginEnabled = false
    @Published private(set) var currentLanguage: KeyboardLanguage = .english
    @Published private(set) var canUndoLastCorrection = false
    @Published private(set) var diagnostics = KeyboardMonitorDiagnostics()
    @Published private(set) var learningDataRevision = 0
    @Published private(set) var privacyMetrics = PrivacyMetricsSnapshot.empty
    @Published var permissions = PermissionManager()

    let defaultExclusions = ExclusionManager.defaultExcludedBundleIdentifiers

    private let inputSourceManager = InputSourceManager()
    private let exclusionManager = ExclusionManager(excludedBundleIdentifiers: ExclusionManager.defaultExcludedBundleIdentifiers)
    private let undoController = CorrectionUndoManager()
    private let privacyMetricsStore = PrivacyMetricsStore()
    private let trainingSampleStore = CorrectionTrainingSampleStore.shared
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
        usesLocalMLSafetyClassifier = defaults.object(forKey: DefaultsKey.usesLocalMLSafetyClassifier) as? Bool ?? true
        playSoundWhenLayoutCorrected = defaults.object(forKey: DefaultsKey.playSoundWhenLayoutCorrected) as? Bool ?? true
        soundVolume = defaults.object(forKey: DefaultsKey.soundVolume) as? Double ?? 0.75
        playSoundOnlyForAutomaticCorrections = defaults.object(forKey: DefaultsKey.playSoundOnlyForAutomaticCorrections) as? Bool ?? false
        hasSeenOnboarding = defaults.object(forKey: DefaultsKey.hasSeenOnboarding) as? Bool ?? false
        var storedExclusions = Set(defaults.stringArray(forKey: DefaultsKey.exclusions) ?? Array(ExclusionManager.defaultExcludedBundleIdentifiers))
        let behaviorDefaultsVersion = defaults.integer(forKey: DefaultsKey.behaviorDefaultsVersion)
        if behaviorDefaultsVersion < 1 {
            storedExclusions.subtract(ExclusionManager.defaultStrictBundleIdentifiers)
            defaults.set(1, forKey: DefaultsKey.behaviorDefaultsVersion)
        }
        storedExclusions.remove("com.apple.TextEdit")
        excludedBundleIdentifiers = storedExclusions
        exclusionManager.excludedBundleIdentifiers = storedExclusions
        let storedModes = defaults.dictionary(forKey: DefaultsKey.appBehaviorModes) as? [String: String] ?? [:]
        appBehaviorModes = storedModes.compactMapValues(AppBehaviorMode.init(rawValue:))
        exclusionManager.appBehaviorModes = appBehaviorModes

        correctionEngine.confidenceThreshold = confidenceThreshold
        correctionEngine.enabledLanguages = enabledLanguages
        correctionEngine.learnsFromManualCorrections = learnsFromManualCorrections
        undoController.onRecord = { [weak self] correction in
            self?.privacyMetricsStore.recordCorrection(correction)
            self?.privacyMetrics = self?.privacyMetricsStore.snapshot() ?? .empty
        }
        undoController.onUndo = { [weak self] correction in
            self?.correctionEngine.recordUndoneCorrection(correction)
            self?.privacyMetricsStore.recordUndo()
            self?.trainingSampleStore.recordUndo(correction)
            self?.privacyMetrics = self?.privacyMetricsStore.snapshot() ?? .empty
        }
        privacyMetrics = privacyMetricsStore.snapshot()
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
        privacyMetrics = privacyMetricsStore.snapshot()
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
            setAppBehaviorMode(.excluded, for: bundleIdentifier)
        } else {
            setAppBehaviorMode(.normal, for: bundleIdentifier)
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
        appBehaviorModes.removeAll()
        UserDefaults.standard.set(1, forKey: DefaultsKey.behaviorDefaultsVersion)
    }

    func behaviorMode(for bundleIdentifier: String) -> AppBehaviorMode {
        if excludedBundleIdentifiers.contains(bundleIdentifier) {
            return .excluded
        }
        return appBehaviorModes[bundleIdentifier] ?? ExclusionManager.defaultBehaviorMode(for: bundleIdentifier)
    }

    func setAppBehaviorMode(_ mode: AppBehaviorMode, for bundleIdentifier: String) {
        if mode == .excluded {
            excludedBundleIdentifiers.insert(bundleIdentifier)
            appBehaviorModes.removeValue(forKey: bundleIdentifier)
        } else {
            excludedBundleIdentifiers.remove(bundleIdentifier)
            if mode == ExclusionManager.defaultBehaviorMode(for: bundleIdentifier) {
                appBehaviorModes.removeValue(forKey: bundleIdentifier)
            } else {
                appBehaviorModes[bundleIdentifier] = mode
            }
        }
    }

    func appBehaviorBundleIdentifiers() -> [String] {
        Array(
            ExclusionManager.defaultBehaviorBundleIdentifiers
                .union(excludedBundleIdentifiers)
                .union(appBehaviorModes.keys)
        ).sorted {
            ExclusionManager.displayName(for: $0) < ExclusionManager.displayName(for: $1)
        }
    }

    func undoLastCorrection() {
        undoController.undoLastCorrection()
        canUndoLastCorrection = undoController.canUndo
    }

    func acceptPendingSuggestion() {
        keyboardMonitor.acceptPendingSuggestion()
        diagnostics = keyboardMonitor.diagnostics
        canUndoLastCorrection = undoController.canUndo
    }

    func ignorePendingSuggestion() {
        keyboardMonitor.ignorePendingSuggestion()
        diagnostics = keyboardMonitor.diagnostics
        learningDataRevision += 1
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

    func suppressedCorrections() -> [SuppressedCorrection] {
        LearningStore.shared.allSuppressions()
    }

    func addLearnedCorrection(original: String, replacement: String, language: KeyboardLanguage) {
        LearningStore.shared.setPreference(original: original, replacement: replacement, language: language)
        learningDataRevision += 1
    }

    func addSuppressedCorrection(original: String, replacement: String) {
        LearningStore.shared.suppressPersistently(original: original, replacement: replacement)
        learningDataRevision += 1
    }

    func removeLearnedCorrection(_ correction: LearnedCorrection) {
        LearningStore.shared.removePreference(original: correction.original)
        learningDataRevision += 1
    }

    func removeSuppressedCorrection(_ correction: SuppressedCorrection) {
        LearningStore.shared.removeSuppression(original: correction.original, replacement: correction.replacement)
        learningDataRevision += 1
    }

    func resetLearningData() {
        LearningStore.shared.reset()
        diagnostics.lastDecision = "Learning data reset"
        learningDataRevision += 1
    }

    func exportLearningData(to url: URL) throws {
        let data = try LearningStore.shared.exportBackupData()
        try data.write(to: url, options: .atomic)
        diagnostics.lastDecision = "Learning data exported"
    }

    @discardableResult
    func importLearningData(from url: URL) throws -> LearningImportResult {
        let data = try Data(contentsOf: url)
        let result = try LearningStore.shared.importBackupData(data)
        diagnostics.lastDecision = "Learning data imported: \(result.importedLearnedCorrections) learned, \(result.importedSuppressions) suppressed"
        learningDataRevision += 1
        return result
    }

    func markOnboardingSeen() {
        hasSeenOnboarding = true
    }

    func playSoundPreview() {
        soundPreviewPlayer.playLayoutSwitch(volume: soundVolume)
    }

    func diagnosticReport() -> String {
        let trainingSummary = trainingSampleStore.summary()
        return [
            "Keyboard Switcher Diagnostic Report",
            "Status: \(diagnostics.status)",
            "Front App: \(diagnostics.lastFrontmostApp.isEmpty ? "Unknown" : diagnostics.lastFrontmostApp)",
            "Current Layout: \(currentLanguage.displayName)",
            "Input Context: \(diagnostics.lastInputContext)",
            "Physical Replay: \(diagnostics.lastPhysicalReplay)",
            "Buffer: \(diagnostics.lastBuffer.isEmpty ? "Empty" : diagnostics.lastBuffer)",
            "Last Word: \(diagnostics.lastTypedWord.isEmpty ? "-" : diagnostics.lastTypedWord)",
            "Terminator: \(diagnostics.lastTerminator)",
            "Decision: \(diagnostics.lastDecision)",
            "Suggestion: \(diagnostics.lastSuggestion.isEmpty ? "-" : diagnostics.lastSuggestion)",
            "Manual Candidates: \(diagnostics.lastManualCandidatePreview.isEmpty ? "-" : diagnostics.lastManualCandidatePreview)",
            "Manual: \(diagnostics.manualMode)",
            "Layout Switch: \(diagnostics.lastLayoutSwitch.isEmpty ? "-" : diagnostics.lastLayoutSwitch)",
            "Candidates: \(diagnostics.lastCandidates.isEmpty ? "None" : diagnostics.lastCandidates)",
            "Candidate Inspector:",
            diagnostics.lastCandidateInspector,
            "Correction: \(diagnostics.lastCorrection.isEmpty ? "-" : diagnostics.lastCorrection)",
            "Privacy Metrics:",
            "Corrections Today: \(privacyMetrics.correctionsToday)",
            "Undo Rate: \(privacyMetrics.undoRate.formatted(.percent.precision(.fractionLength(0))))",
            "Top Language Pair: \(privacyMetrics.topLanguagePair)",
            "Local Intelligence:",
            "Last ML Decision: \(diagnostics.lastMLDecision)",
            "ML Confidence: \(diagnostics.lastMLConfidence)",
            "ML Divergence: \(diagnostics.lastMLDivergence)",
            "Training Samples: \(trainingSummary.count)",
            "Last Training Outcome: \(trainingSummary.lastOutcome?.rawValue ?? "-")",
            "Last Text Context: \(trainingSummary.lastTextContext)"
        ].joined(separator: "\n")
    }

    func exportTrainingSamples(to url: URL) throws {
        let data = try trainingSampleStore.exportJSONLData()
        try data.write(to: url, options: .atomic)
        diagnostics.lastDecision = "Training samples exported"
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
                self.privacyMetrics = self.privacyMetricsStore.snapshot()
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
    static let appBehaviorModes = "appBehaviorModes"
    static let behaviorDefaultsVersion = "behaviorDefaultsVersion"
    static let menuBarIconStyle = "menuBarIconStyle"
    static let switchInputSourceAfterCorrection = "switchInputSourceAfterCorrection"
    static let learnsFromManualCorrections = "learnsFromManualCorrections"
    static let usesLocalMLSafetyClassifier = CoreMLCorrectionSafetyClassifier.userDefaultsEnabledKey
    static let playSoundWhenLayoutCorrected = "playSoundWhenLayoutCorrected"
    static let soundVolume = "soundVolume"
    static let playSoundOnlyForAutomaticCorrections = "playSoundOnlyForAutomaticCorrections"
    static let hasSeenOnboarding = "hasSeenOnboarding"
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
