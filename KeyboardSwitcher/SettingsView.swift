import AppKit
import SwiftUI

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case languages
    case correction
    case menuBar
    case appExclusions
    case sounds
    case privacy
    case diagnostics
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .languages: "Languages"
        case .correction: "Correction"
        case .menuBar: "Menu Bar"
        case .appExclusions: "App Exclusions"
        case .sounds: "Sounds"
        case .privacy: "Privacy"
        case .diagnostics: "Diagnostics"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .languages: "character.bubble"
        case .correction: "wand.and.stars"
        case .menuBar: "menubar.rectangle"
        case .appExclusions: "app.badge"
        case .sounds: "speaker.wave.2"
        case .privacy: "hand.raised"
        case .diagnostics: "waveform.path.ecg"
        case .about: "info.circle"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "Configure the main behavior of Keyboard Switcher."
        case .languages: "Choose the layouts and learning behavior used for correction."
        case .correction: "Tune automatic correction quality and safety."
        case .menuBar: "Customize the menu bar indicator."
        case .appExclusions: "Choose apps where text should never be corrected."
        case .sounds: "Control layout switch feedback sounds."
        case .privacy: "Understand what is processed locally."
        case .diagnostics: "Inspect runtime state for debugging."
        case .about: "Version, resources, and notices."
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedSection: SettingsSection = .general
    @State private var showsCustomDictionary = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            content
        }
        .background(settingsBackground)
        .sheet(isPresented: $showsCustomDictionary) {
            CustomDictionarySheet()
                .environmentObject(appState)
        }
        .onAppear {
            appState.refreshRuntimeState()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(nsImage: IconProvider.appIcon(size: 64))
                    .resizable()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text("Keyboard Switcher")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Automatic layout correction for EN, RU, HE")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 28)

            VStack(spacing: 6) {
                ForEach(SettingsSection.allCases) { section in
                    SidebarButton(section: section, isSelected: section == selectedSection) {
                        selectedSection = section
                    }
                }
            }
            .padding(.horizontal, 12)

            Spacer()

            VStack(alignment: .leading, spacing: 10) {
                Divider()
                HStack(spacing: 8) {
                    Circle()
                        .fill(appState.isKeyboardSwitcherEnabled ? .green : .secondary)
                        .frame(width: 9, height: 9)
                    Text(appState.isKeyboardSwitcherEnabled ? "Keyboard Switcher is active" : "Keyboard Switcher is paused")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Text("v0.85")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
        }
        .frame(width: 190)
        .background(.thinMaterial)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(selectedSection.title)
                        .font(.system(size: 28, weight: .semibold))
                    Text(selectedSection.subtitle)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }

                switch selectedSection {
                case .general:
                    generalSection
                case .languages:
                    languagesSection
                case .correction:
                    correctionSection
                case .menuBar:
                    menuBarSection
                case .appExclusions:
                    appExclusionsSection
                case .sounds:
                    soundsSection
                case .privacy:
                    privacySection
                case .diagnostics:
                    diagnosticsSection
                case .about:
                    aboutSection
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 20) {
                SettingsCard("General Behavior") {
                    SettingsToggleRow("Launch at Login", isOn: Binding(
                        get: { appState.launchAtLoginEnabled },
                        set: { appState.setLaunchAtLoginEnabled($0) }
                    ))
                    SettingsToggleRow("Enable Keyboard Switcher", isOn: $appState.isKeyboardSwitcherEnabled)
                    Divider()
                    Text("Correction Mode")
                        .font(.system(size: 13, weight: .semibold))
                    SettingsToggleRow("Automatically correct already typed words", isOn: $appState.isAutoCorrectionEnabled)
                    SettingsToggleRow("Switch input source after correction", isOn: $appState.switchInputSourceAfterCorrection)
                }

                SettingsCard("Manual Control") {
                    Text("Shortcut to switch layout manually")
                        .font(.system(size: 13))
                    HStack {
                        Text("Double Shift")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .frame(height: 36)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        Button("Change...") {}
                            .disabled(true)
                    }
                    DisabledToggleRow("Custom shortcut recording")
                    Divider()
                    SettingsToggleRow("Undo last correction", isOn: .constant(true))
                        .disabled(true)
                        .opacity(0.55)
                    Text("⌘Z / Backspace")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            SettingsCard("Status") {
                HStack(spacing: 0) {
                    StatusMetric(systemImage: "globe", title: "Current Layout", value: appState.currentLanguage.displayName)
                    VerticalDivider()
                    StatusMetric(systemImage: "app.fill", title: "Front App", value: appState.diagnostics.lastFrontmostApp.isEmpty ? "Unknown" : appState.diagnostics.lastFrontmostApp)
                    VerticalDivider()
                    StatusMetric(systemImage: appState.isKeyboardSwitcherEnabled ? "checkmark.circle" : "pause.circle", title: "State", value: appState.diagnostics.status)
                    VerticalDivider()
                    StatusMetric(systemImage: "clock", title: "Last Correction", value: appState.diagnostics.lastCorrection.isEmpty ? "-" : appState.diagnostics.lastCorrection)
                }
            }

            HStack(alignment: .top, spacing: 20) {
                SettingsCard("Quick Actions") {
                    QuickActionRow(systemImage: "pause.circle", title: "Pause correction temporarily", detail: "Stop automatic corrections") {
                        Toggle("", isOn: Binding(
                            get: { !appState.isAutoCorrectionEnabled },
                            set: { appState.isAutoCorrectionEnabled = !$0 }
                        ))
                        .labelsHidden()
                    }
                    QuickActionRow(systemImage: "arrow.counterclockwise.square", title: "Reset learning data", detail: "Clear learned words and decisions") {
                        Button("Reset...") {
                            appState.resetLearningData()
                        }
                    }
                    QuickActionRow(systemImage: "checklist.checked", title: "Open Diagnostics", detail: "View detailed runtime information") {
                        Button("Open") {
                            selectedSection = .diagnostics
                        }
                    }
                }

                SettingsCard("Tips") {
                    TipRow(color: .blue, systemImage: "a.square", text: "Keyboard Switcher works best when you type naturally.")
                    TipRow(color: .green, systemImage: "checkmark.shield", text: "Your text is processed locally. Nothing is sent to the internet.")
                    TipRow(color: .purple, systemImage: "sparkles", text: "Add apps to Exclusions to avoid unnecessary corrections.")
                }
            }

            FooterPrivacyBar {
                selectedSection = .privacy
            }
        }
    }

    private var languagesSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsCard("Active Languages") {
                ForEach(KeyboardLanguage.allCases) { language in
                    LanguageCard(language: language, isOn: Binding(
                        get: { appState.enabledLanguages.contains(language) },
                        set: { appState.setLanguageEnabled(language, isEnabled: $0) }
                    ))
                }
            }

            SettingsCard("Detection & Learning") {
                SettingsInfoRow("Detection Priority", value: "English ↔ Russian ↔ Hebrew")
                DisabledToggleRow("Use custom words")
                SettingsToggleRow("Learn from manual corrections", isOn: $appState.learnsFromManualCorrections)
                Button("Manage Custom Dictionary...") {
                    showsCustomDictionary = true
                }
            }
        }
    }

    private var correctionSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsCard("Automatic Correction") {
                SettingsToggleRow("Correct already typed words", isOn: $appState.isAutoCorrectionEnabled)

                Picker("Correction Sensitivity", selection: $appState.correctionSensitivity) {
                    ForEach(CorrectionSensitivity.allCases.filter { $0 != .custom }) { sensitivity in
                        Text(sensitivity.displayName).tag(sensitivity)
                    }
                    if appState.correctionSensitivity == .custom {
                        Text("Custom").tag(CorrectionSensitivity.custom)
                    }
                }
                .pickerStyle(.segmented)

                Text(appState.correctionSensitivity.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                HStack {
                    Text("Advanced Confidence")
                    Slider(value: $appState.confidenceThreshold, in: 0.55...0.90, step: 0.01)
                    Text(appState.confidenceThreshold, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 46, alignment: .trailing)
                }
            }

            SettingsCard("Behavior") {
                DisabledToggleRow("Show subtle visual confirmation")
                SettingsToggleRow("Play sound when layout is corrected", isOn: $appState.playSoundWhenLayoutCorrected)
                DisabledToggleRow("Do not correct while typing passwords", detail: "Where detectable")
                SettingsToggleRow("Do not correct code-like text", isOn: .constant(true))
                    .disabled(true)
                    .opacity(0.55)
                SettingsToggleRow("Do not correct URLs and file paths", isOn: .constant(true))
                    .disabled(true)
                    .opacity(0.55)
            }
        }
    }

    private var menuBarSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsCard("Indicator Style") {
                Picker("Indicator Style", selection: $appState.menuBarIconStyle) {
                    ForEach(MenuBarIconStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.segmented)

                HStack(spacing: 12) {
                    ForEach(MenuBarIconStyle.allCases) { style in
                        VStack(spacing: 8) {
                            Text(style.displayName)
                                .font(.system(size: 12, weight: .semibold))
                            Text(style.description)
                                .font(.system(size: style == .flags ? 18 : 16, weight: .semibold, design: .rounded))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }

            SettingsCard("Preview") {
                HStack {
                    Text(appState.currentLanguage.menuBarIcon(for: appState.menuBarIconStyle))
                        .font(.system(size: appState.menuBarIconStyle == .flags ? 22 : 18, weight: .semibold))
                    Text(appState.currentLanguage.displayName)
                        .font(.system(size: 14, weight: .medium))
                }
                .padding(.vertical, 9)
                .padding(.horizontal, 14)
                .background(.regularMaterial, in: Capsule())
            }

            SettingsCard("Display") {
                DisabledToggleRow("Show current language name")
                SettingsToggleRow("Show icon in menu bar", isOn: .constant(true))
                    .disabled(true)
                    .opacity(0.55)
                DisabledToggleRow("Show correction animation")
            }
        }
    }

    private var appExclusionsSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsCard("Presets") {
                Text("Keyboard Switcher will not correct text in selected apps.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                ForEach(ExclusionPreset.allCases) { preset in
                    Toggle(isOn: Binding(
                        get: { appState.isPresetEnabled(preset) },
                        set: { appState.setPreset(preset, isEnabled: $0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.displayName)
                            Text(preset.detail)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                }
            }

            SettingsCard("Excluded Apps") {
                ForEach(Array(appState.excludedBundleIdentifiers).sorted(), id: \.self) { bundleIdentifier in
                    Toggle(isOn: Binding(
                        get: { appState.excludedBundleIdentifiers.contains(bundleIdentifier) },
                        set: { appState.setExclusion(bundleIdentifier, isEnabled: $0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ExclusionManager.displayName(for: bundleIdentifier))
                            Text(bundleIdentifier)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }

                HStack {
                    Button("Add App...") {}
                        .disabled(true)
                    Button("Remove") {}
                        .disabled(true)
                    Spacer()
                    Button("Restore Defaults") {
                        appState.restoreDefaultExclusions()
                    }
                }
            }
        }
    }

    private var soundsSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsCard("Sounds") {
                SettingsToggleRow("Play sound when layout is corrected", isOn: $appState.playSoundWhenLayoutCorrected)
                SettingsToggleRow("Play sound only for automatic corrections", isOn: $appState.playSoundOnlyForAutomaticCorrections)
            }

            SettingsCard("Sound Style") {
                SoundStyleRow(title: "Smart Flip", isEnabled: false) {}
                SoundStyleRow(title: "Typewriter Shift", isEnabled: true) {
                    appState.playSoundPreview()
                }
                SoundStyleRow(title: "Three-Language Chime", isEnabled: false) {}
            }

            SettingsCard("Volume") {
                HStack {
                    Text("Quiet")
                        .foregroundStyle(.secondary)
                    Slider(value: $appState.soundVolume, in: 0...1, step: 0.05)
                    Text("Loud")
                        .foregroundStyle(.secondary)
                }
                DisabledToggleRow("Respect system alert volume")
            }
        }
    }

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsCard("Keyboard Switcher works locally.") {
                PrivacyRow("Typed text is processed only on this Mac")
                PrivacyRow("No typed text is sent to the internet")
                PrivacyRow("Password fields are ignored where detectable")
                PrivacyRow("URLs, emails, paths, and code-like text are skipped")
                PrivacyRow("Excluded apps are never analyzed")
            }

            SettingsCard("Permissions") {
                PermissionStatusRow(
                    title: "Accessibility Permission",
                    status: appState.permissions.isAccessibilityTrusted ? "Granted" : "Required",
                    isGranted: appState.permissions.isAccessibilityTrusted
                )
                PermissionStatusRow(title: "Input Monitoring", status: "Managed by Accessibility", isGranted: appState.permissions.isAccessibilityTrusted)
                    .opacity(0.55)

                Button("Open Privacy Settings") {
                    appState.permissions.openPrivacySettings()
                }
            }
        }
    }

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsCard("Runtime") {
                DiagnosticRow("Status", appState.diagnostics.status)
                DiagnosticRow("Front App", appState.diagnostics.lastFrontmostApp.isEmpty ? "No app yet" : appState.diagnostics.lastFrontmostApp)
                DiagnosticRow("Current Layout", appState.currentLanguage.displayName)
                DiagnosticRow("Buffer", appState.diagnostics.lastBuffer.isEmpty ? "Empty" : appState.diagnostics.lastBuffer)
                DiagnosticRow("Last Word", appState.diagnostics.lastTypedWord.isEmpty ? "-" : appState.diagnostics.lastTypedWord)
                DiagnosticRow("Decision", appState.diagnostics.lastDecision)
                DiagnosticRow("Manual", appState.diagnostics.manualMode)
                DiagnosticRow("Layout", appState.diagnostics.lastLayoutSwitch.isEmpty ? "No switch yet" : appState.diagnostics.lastLayoutSwitch)
                DiagnosticRow("Candidates", appState.diagnostics.lastCandidates.isEmpty ? "None" : appState.diagnostics.lastCandidates)
                DiagnosticRow("Correction", appState.diagnostics.lastCorrection.isEmpty ? "-" : appState.diagnostics.lastCorrection)
            }

            SettingsCard("Actions") {
                HStack {
                    Button("Copy Diagnostic Report") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(appState.diagnosticReport(), forType: .string)
                    }
                    Button("Reset Learning Data") {
                        appState.resetLearningData()
                    }
                    Button("Open Logs Folder") {}
                        .disabled(true)
                }
            }
        }
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsCard("Keyboard Switcher") {
                HStack(spacing: 16) {
                    Image(nsImage: IconProvider.appIcon(size: 96))
                        .resizable()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Keyboard Switcher")
                            .font(.system(size: 20, weight: .semibold))
                        Text("Version 0.85 · checkpoint v0.85")
                            .foregroundStyle(.secondary)
                        Text("Local automatic correction for English, Russian, and Hebrew layouts.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            SettingsCard("Notices") {
                Text("Keyboard Switcher uses local Apple frameworks, a compact Russian frequency list, an English common-word list, and project-provided app/sound assets.")
                    .foregroundStyle(.secondary)
                Text("See README.md and LICENSES/THIRD-PARTY-NOTICES.md for details.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var settingsBackground: some View {
        LinearGradient(
            colors: [
                Color(nsColor: .windowBackgroundColor),
                Color(nsColor: .controlBackgroundColor).opacity(0.84)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

private struct SidebarButton: View {
    let section: SettingsSection
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 17))
                    .frame(width: 22)
                    .foregroundStyle(isSelected ? .blue : .primary)
                Text(section.title)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(isSelected ? Color.blue.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .leading) {
                if isSelected {
                    Capsule()
                        .fill(.blue)
                        .frame(width: 3, height: 28)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            VStack(alignment: .leading, spacing: 12) {
                content
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassPanel()
    }
}

private struct SettingsToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        _isOn = isOn
    }

    var body: some View {
        Toggle(title, isOn: $isOn)
            .toggleStyle(.switch)
            .frame(minHeight: 30)
    }
}

private struct DisabledToggleRow: View {
    let title: String
    var detail: String?

    init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("", isOn: .constant(false))
                .labelsHidden()
        }
        .disabled(true)
        .opacity(0.45)
    }
}

private struct SettingsInfoRow: View {
    let title: String
    let value: String

    init(_ title: String, value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 13))
    }
}

private struct LanguageCard: View {
    let language: KeyboardLanguage
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(language.flagGlyph)
                .font(.system(size: 24))
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text(language.displayName)
                    .font(.system(size: 14, weight: .semibold))
                Text(layoutDescription)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var layoutDescription: String {
        switch language {
        case .english: "A · QWERTY layout"
        case .russian: "Я · ЙЦУКЕН layout"
        case .hebrew: "א · Hebrew layout"
        }
    }
}

private struct StatusMetric: View {
    let systemImage: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct VerticalDivider: View {
    var body: some View {
        Rectangle()
            .fill(.separator)
            .frame(width: 1, height: 42)
            .padding(.horizontal, 12)
    }
}

private struct QuickActionRow<Accessory: View>: View {
    let systemImage: String
    let title: String
    let detail: String
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 19))
                .foregroundStyle(.blue)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            accessory
        }
    }
}

private struct TipRow: View {
    let color: Color
    let systemImage: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .frame(width: 30, height: 30)
                .background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }
}

private struct FooterPrivacyBar: View {
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.shield")
                .foregroundStyle(.secondary)
            Text("All features work locally on your Mac. Your privacy is important.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Open Privacy Settings...", action: action)
        }
        .padding(14)
        .glassPanel()
    }
}

private struct SoundStyleRow: View {
    let title: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(isEnabled ? .primary : .secondary)
            Spacer()
            Button("Play", action: action)
                .disabled(!isEnabled)
        }
        .opacity(isEnabled ? 1 : 0.45)
    }
}

private struct PrivacyRow: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Label(title, systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green, .green)
            .font(.system(size: 13))
    }
}

private struct PermissionStatusRow: View {
    let title: String
    let status: String
    let isGranted: Bool

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Label(status, systemImage: isGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(isGranted ? .green : .orange)
        }
    }
}

private struct DiagnosticRow: View {
    let title: String
    let value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 104, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12, design: .monospaced))
    }
}

private struct CustomDictionarySheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Custom Dictionary")
                        .font(.system(size: 22, weight: .semibold))
                    Text("Learned corrections from Double Shift.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") {
                    dismiss()
                }
            }

            let corrections = appState.learnedCorrections()
            if corrections.isEmpty {
                ContentUnavailableView("No Learned Corrections", systemImage: "text.badge.checkmark", description: Text("Manual Double Shift corrections will appear here."))
            } else {
                List {
                    ForEach(corrections, id: \.original) { correction in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(correction.original) → \(correction.replacement)")
                                    .font(.system(size: 13, weight: .medium))
                                Text("\(correction.language.displayName) · \(correction.uses) uses")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Remove") {
                                appState.removeLearnedCorrection(correction)
                            }
                        }
                    }
                }
            }

            HStack {
                Button("Clear All") {
                    appState.resetLearningData()
                }
                .disabled(corrections.isEmpty)
                Spacer()
            }
        }
        .padding(24)
        .frame(width: 520, height: 420)
    }
}
