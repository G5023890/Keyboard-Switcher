import AppKit
import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published var isAutoCorrectionEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isAutoCorrectionEnabled, forKey: DefaultsKey.autoCorrection)
            updateMonitorState()
        }
    }

    @Published var confidenceThreshold: Double {
        didSet {
            UserDefaults.standard.set(confidenceThreshold, forKey: DefaultsKey.confidence)
            correctionEngine.confidenceThreshold = confidenceThreshold
        }
    }

    @Published var enabledLanguages: Set<KeyboardLanguage> {
        didSet {
            UserDefaults.standard.set(enabledLanguages.map(\.rawValue), forKey: DefaultsKey.enabledLanguages)
            correctionEngine.enabledLanguages = enabledLanguages
        }
    }

    @Published var excludedBundleIdentifiers: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(excludedBundleIdentifiers).sorted(), forKey: DefaultsKey.exclusions)
            exclusionManager.excludedBundleIdentifiers = excludedBundleIdentifiers
        }
    }

    @Published private(set) var currentLanguage: KeyboardLanguage = .english
    @Published private(set) var canUndoLastCorrection = false
    @Published private(set) var diagnostics = KeyboardMonitorDiagnostics()
    @Published var permissions = PermissionManager()

    let defaultExclusions = ExclusionManager.defaultExcludedBundleIdentifiers

    private let inputSourceManager = InputSourceManager()
    private let exclusionManager: ExclusionManager
    private let undoController = CorrectionUndoManager()
    private lazy var correctionEngine = CorrectionEngine(undoController: undoController)
    private lazy var keyboardMonitor = KeyboardMonitor(correctionEngine: correctionEngine, exclusionManager: exclusionManager)
    private var cancellables = Set<AnyCancellable>()
    private var inputSourceTimer: Timer?

    init() {
        let defaults = UserDefaults.standard
        let storedLanguages = defaults.stringArray(forKey: DefaultsKey.enabledLanguages) ?? KeyboardLanguage.allCases.map(\.rawValue)
        let languages = Set(storedLanguages.compactMap(KeyboardLanguage.init(rawValue:)))

        isAutoCorrectionEnabled = defaults.object(forKey: DefaultsKey.autoCorrection) as? Bool ?? true
        let storedConfidence = defaults.object(forKey: DefaultsKey.confidence) as? Double ?? 0.62
        confidenceThreshold = max(storedConfidence, 0.62)
        enabledLanguages = languages.isEmpty ? Set(KeyboardLanguage.allCases) : languages
        var storedExclusions = Set(defaults.stringArray(forKey: DefaultsKey.exclusions) ?? Array(ExclusionManager.defaultExcludedBundleIdentifiers))
        storedExclusions.remove("com.apple.TextEdit")
        excludedBundleIdentifiers = storedExclusions
        exclusionManager = ExclusionManager(excludedBundleIdentifiers: storedExclusions)

        correctionEngine.confidenceThreshold = confidenceThreshold
        correctionEngine.enabledLanguages = enabledLanguages
        undoController.onUndo = { [weak self] correction in
            self?.correctionEngine.recordUndoneCorrection(correction)
        }
        startInputSourcePolling()
        bindUndoState()
        updateMonitorState()
    }

    func refreshRuntimeState() {
        permissions.refresh()
        currentLanguage = inputSourceManager.currentKeyboardLanguage()
        canUndoLastCorrection = undoController.canUndo
        diagnostics = keyboardMonitor.diagnostics
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

    func undoLastCorrection() {
        undoController.undoLastCorrection()
        canUndoLastCorrection = undoController.canUndo
    }

    private func startInputSourcePolling() {
        currentLanguage = inputSourceManager.currentKeyboardLanguage()
        inputSourceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
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
        if isAutoCorrectionEnabled {
            keyboardMonitor.start()
        } else {
            keyboardMonitor.stop()
        }
    }
}

private enum DefaultsKey {
    static let autoCorrection = "autoCorrectionEnabled"
    static let confidence = "confidenceThreshold"
    static let enabledLanguages = "enabledLanguages"
    static let exclusions = "excludedBundleIdentifiers"
}
