import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
        case .appExclusions: "Choose apps where correction should be limited or disabled."
        case .sounds: "Control layout switch feedback sounds."
        case .privacy: "Understand what is processed locally."
        case .diagnostics: "Inspect runtime state for debugging."
        case .about: "Version, resources, and notices."
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @SceneStorage("settings.selectedSection") private var selectedSectionID = SettingsSection.general.rawValue
    @State private var showsCustomDictionary = false
    @State private var showsAdvancedCorrection = false
    @State private var showsOnboarding = false
    @State private var appSearchText = ""

    private var selectedSection: SettingsSection {
        get { SettingsSection(rawValue: selectedSectionID) ?? .general }
        nonmutating set { selectedSectionID = newValue.rawValue }
    }

    var body: some View {
        SettingsWindowView {
            SettingsSidebar(
                selectedSection: Binding(
                    get: { selectedSection },
                    set: { selectedSection = $0 }
                ),
                isActive: appState.isKeyboardSwitcherEnabled
            )
        } content: {
            SettingsPageContainer(title: selectedSection.title, subtitle: selectedSection.subtitle) {
                pageContent
            }
        }
        .background(SettingsDesign.windowBackground(for: colorScheme))
        .frame(minWidth: 920, idealWidth: 980, minHeight: 680, idealHeight: 720)
        .sheet(isPresented: $showsCustomDictionary) {
            CustomDictionarySheet()
                .environmentObject(appState)
        }
        .sheet(isPresented: $showsOnboarding) {
            OnboardingView {
                appState.markOnboardingSeen()
                showsOnboarding = false
            } openPrivacySettings: {
                appState.permissions.openPrivacySettings()
            }
        }
        .onAppear {
            appState.refreshRuntimeState()
            if !appState.hasSeenOnboarding {
                showsOnboarding = true
            }
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch selectedSection {
        case .general: generalSection
        case .languages: languagesSection
        case .correction: correctionSection
        case .menuBar: menuBarSection
        case .appExclusions: appExclusionsSection
        case .sounds: soundsSection
        case .privacy: privacySection
        case .diagnostics: diagnosticsSection
        case .about: aboutSection
        }
    }

    private var generalSection: some View {
        VStack(spacing: SettingsDesign.spacing.page) {
            SettingsCard("General Behavior") {
                SettingsToggleRow("Launch at Login", isOn: Binding(
                    get: { appState.launchAtLoginEnabled },
                    set: { appState.setLaunchAtLoginEnabled($0) }
                ))
                SettingsToggleRow("Enable Keyboard Switcher", isOn: $appState.isKeyboardSwitcherEnabled)
                SettingsDivider()
                SettingsSectionLabel("Correction Mode")
                SettingsToggleRow("Automatically correct already typed words", isOn: $appState.isAutoCorrectionEnabled)
                SettingsToggleRow("Switch input source after correction", isOn: $appState.switchInputSourceAfterCorrection)
            }

            SettingsCard("Manual Control") {
                SettingsButtonRow("Shortcut to correct layout manually", value: "Double Shift", buttonTitle: "Change...") {}
                    .disabledRow("Shortcut recording is planned for a later build.")
                SettingsToggleRow("Undo last correction", subtitle: "Uses ⌘Z or Backspace after correction.", isOn: .constant(true))
                SettingsPickerRow("Ignore while typing with", value: "Tab, Arrows, Function Keys", buttonTitle: "Edit...") {}
                    .disabledRow("Protected navigation keys are currently fixed.")
            }

            SettingsCard("Status") {
                StatusStrip(items: [
                    .init(title: "Current Layout", value: appState.currentLanguage.displayName, systemImage: "globe"),
                    .init(title: "Front App", value: appState.diagnostics.lastFrontmostApp.isEmpty ? "Unknown" : appState.diagnostics.lastFrontmostApp, systemImage: "app"),
                    .init(title: "State", value: appState.isKeyboardSwitcherEnabled ? "Listening" : "Paused", systemImage: appState.isKeyboardSwitcherEnabled ? "checkmark.circle" : "pause.circle"),
                    .init(title: "Last Correction", value: appState.diagnostics.lastCorrection.isEmpty ? "None" : appState.diagnostics.lastCorrection, systemImage: "clock")
                ])
            }

            SettingsCard("Quick Actions") {
                SettingsToggleRow("Pause correction temporarily", isOn: Binding(
                    get: { !appState.isAutoCorrectionEnabled },
                    set: { appState.isAutoCorrectionEnabled = !$0 }
                ))
                SettingsButtonRow("Reset learning data", buttonTitle: "Reset...") {
                    appState.resetLearningData()
                }
                SettingsButtonRow("Open Diagnostics", buttonTitle: "Open") {
                    selectedSection = .diagnostics
                }
            }

            SettingsCard("Tips") {
                TipRow(color: .blue, systemImage: "text.cursor", text: "Works best when you type naturally.")
                TipRow(color: .orange, systemImage: "arrow.uturn.backward", text: "Press Undo to teach the app.")
                TipRow(color: .green, systemImage: "lock.shield", text: "All processing happens locally.")
            }
        }
    }

    private var languagesSection: some View {
        VStack(spacing: SettingsDesign.spacing.page) {
            SettingsCard("Active Languages") {
                ForEach(KeyboardLanguage.allCases) { language in
                    LanguageRow(language: language, isOn: Binding(
                        get: { appState.enabledLanguages.contains(language) },
                        set: { appState.setLanguageEnabled(language, isEnabled: $0) }
                    ))
                }
            }

            SettingsCard("Detection & Learning") {
                SettingsButtonRow("Detection Priority", value: "English ↔ Russian ↔ Hebrew", buttonTitle: "Edit...") {}
                    .disabledRow("The current priority is optimized for the bundled dictionaries.")
                SettingsToggleRow("Use custom words", isOn: .constant(true))
                SettingsToggleRow("Learn from manual corrections", isOn: $appState.learnsFromManualCorrections)
                SettingsButtonRow("Manage Custom Dictionary...", buttonTitle: "Open") {
                    showsCustomDictionary = true
                }
                SettingsToggleRow("Local intelligence", subtitle: "Improves safety for mixed-language and technical text.", isOn: .constant(true))
            }
        }
    }

    private var correctionSection: some View {
        VStack(spacing: SettingsDesign.spacing.page) {
            SettingsCard("Automatic Correction") {
                SettingsToggleRow("Correct already typed words", isOn: $appState.isAutoCorrectionEnabled)
                SettingsPickerRow("Correction Sensitivity") {
                    Picker("", selection: $appState.correctionSensitivity) {
                        ForEach(CorrectionSensitivity.allCases.filter { $0 != .custom }) { sensitivity in
                            Text(sensitivity.displayName).tag(sensitivity)
                        }
                        if appState.correctionSensitivity == .custom {
                            Text("Custom").tag(CorrectionSensitivity.custom)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 320)
                }
                Text("Balanced is recommended for everyday typing.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                DisclosureGroup("Advanced", isExpanded: $showsAdvancedCorrection) {
                    SettingsSliderRow(
                        "Advanced Confidence",
                        value: $appState.confidenceThreshold,
                        range: 0.55...0.90,
                        valueLabel: appState.confidenceThreshold.formatted(.percent.precision(.fractionLength(0)))
                    )
                    .padding(.top, 8)
                }
                .font(.system(size: 14, weight: .medium))
            }

            SettingsCard("Safety Rules") {
                SettingsToggleRow("Do not correct while typing passwords", subtitle: "Where detectable. Enforced by the app.", isOn: .constant(true))
                    .disabledRow("Always enabled for supported secure text fields.")
                SettingsToggleRow("Do not correct code-like text", isOn: .constant(true))
                SettingsToggleRow("Do not correct URLs, emails, and file paths", isOn: .constant(true))
                SettingsToggleRow("Use strict rules for short words", isOn: .constant(true))
                SettingsToggleRow("Require Space for automatic short-word correction", isOn: .constant(true))
            }

            SettingsCard("Feedback") {
                SettingsToggleRow("Show subtle visual confirmation", isOn: .constant(true))
                SettingsToggleRow("Play sound when layout is corrected", isOn: $appState.playSoundWhenLayoutCorrected)
                SettingsToggleRow("Show suggestion instead of correcting medium-confidence cases", isOn: .constant(true))
            }
        }
    }

    private var menuBarSection: some View {
        VStack(spacing: SettingsDesign.spacing.page) {
            SettingsCard("Indicator Style") {
                Picker("Indicator Style", selection: $appState.menuBarIconStyle) {
                    ForEach(MenuBarIconStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.segmented)

                HStack(spacing: 10) {
                    ForEach(MenuBarIconStyle.allCases) { style in
                        MenuBarStyleTile(style: style, isSelected: style == appState.menuBarIconStyle) {
                            appState.menuBarIconStyle = style
                        }
                    }
                }
            }

            SettingsCard("Preview") {
                HStack {
                    Spacer()
                    MenuBarPreviewPill(style: appState.menuBarIconStyle, language: appState.currentLanguage)
                    Spacer()
                }
            }

            SettingsCard("Display") {
                SettingsToggleRow("Show current language name", subtitle: appState.menuBarIconStyle == .minimal ? "Available in Letters and Flags styles." : nil, isOn: .constant(appState.menuBarIconStyle != .minimal))
                    .disabledRow(appState.menuBarIconStyle == .minimal ? "Minimal style only shows a compact status dot." : nil)
                SettingsToggleRow("Show icon in menu bar", isOn: .constant(true))
                SettingsToggleRow("Show correction animation", isOn: .constant(true))
                SettingsToggleRow("Compact mode", isOn: .constant(appState.menuBarIconStyle == .minimal))
            }
        }
    }

    private var appExclusionsSection: some View {
        VStack(spacing: SettingsDesign.spacing.page) {
            SettingsCard("Presets") {
                ForEach(ExclusionPreset.allCases) { preset in
                    SettingsToggleRow(preset.displayName, subtitle: preset.detail, isOn: Binding(
                        get: { appState.isPresetEnabled(preset) },
                        set: { appState.setPreset(preset, isEnabled: $0) }
                    ))
                }
            }

            SettingsCard("App Behavior") {
                HStack(spacing: 10) {
                    AppBehaviorSummaryPill(title: "Excluded", value: behaviorCount(.excluded), tint: .red)
                    AppBehaviorSummaryPill(title: "Strict", value: behaviorCount(.strict), tint: .orange)
                    AppBehaviorSummaryPill(title: "Normal", value: behaviorCount(.normal), tint: .blue)
                    AppBehaviorSummaryPill(title: "Text", value: behaviorCount(.textFocused), tint: .green)
                }

                HStack(spacing: 10) {
                    SearchField(text: $appSearchText)
                    Button("Add App...") {}
                        .disabled(true)
                        .help("Adding apps from disk is planned for a later build.")
                    Button("Restore Defaults") {
                        appState.restoreDefaultExclusions()
                    }
                }

                VStack(spacing: 6) {
                    ForEach(filteredAppBehaviorBundleIdentifiers, id: \.self) { bundleIdentifier in
                        AppBehaviorRow(
                            bundleIdentifier: bundleIdentifier,
                            mode: Binding(
                                get: { appState.behaviorMode(for: bundleIdentifier) },
                                set: { appState.setAppBehaviorMode($0, for: bundleIdentifier) }
                            )
                        )
                    }
                }
            }
        }
    }

    private var filteredAppBehaviorBundleIdentifiers: [String] {
        let identifiers = appState.appBehaviorBundleIdentifiers()
        guard !appSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return identifiers
        }

        let query = appSearchText.lowercased()
        return identifiers.filter {
            $0.lowercased().contains(query) || ExclusionManager.displayName(for: $0).lowercased().contains(query)
        }
    }

    private func behaviorCount(_ mode: AppBehaviorMode) -> String {
        "\(appState.appBehaviorBundleIdentifiers().filter { appState.behaviorMode(for: $0) == mode }.count)"
    }

    private var soundsSection: some View {
        VStack(spacing: SettingsDesign.spacing.page) {
            SettingsCard("Sound Feedback") {
                SettingsToggleRow("Play sound when layout is corrected", isOn: $appState.playSoundWhenLayoutCorrected)
                SettingsToggleRow("Play sound only for automatic corrections", isOn: $appState.playSoundOnlyForAutomaticCorrections)
                SettingsToggleRow("Do not play sound for short-word corrections", isOn: .constant(false))
            }

            SettingsCard("Sound Style") {
                SoundStyleRow(title: "Smart Flip", subtitle: "Modern, soft, recommended", isSelected: false, isEnabled: false) {}
                    .disabledRow("This sound will be available after the asset is bundled.")
                SoundStyleRow(title: "Typewriter Shift", subtitle: "Mechanical keyboard-like click", isSelected: true, isEnabled: true) {
                    appState.playSoundPreview()
                }
                SoundStyleRow(title: "Three-Language Chime", subtitle: "Short three-note language cue", isSelected: false, isEnabled: false) {}
                    .disabledRow("This sound will be available after the asset is bundled.")
            }

            SettingsCard("Volume") {
                SettingsSliderRow("Volume", value: $appState.soundVolume, range: 0...1, leftLabel: "Quiet", rightLabel: "Loud")
                SettingsToggleRow("Respect system alert volume", isOn: .constant(false))
                    .disabledRow("Keyboard Switcher currently uses its own local preview volume.")
            }
        }
    }

    private var privacySection: some View {
        VStack(spacing: SettingsDesign.spacing.page) {
            SettingsCard("Local Processing") {
                PrivacyRow("Typed text is processed only on this Mac")
                PrivacyRow("No typed text is sent to the internet")
                PrivacyRow("Password fields are ignored where detectable")
                PrivacyRow("URLs, emails, paths, and code-like text are skipped")
                PrivacyRow("Excluded apps are never analyzed")
                Text("Keyboard events are processed locally to detect layout mistakes.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                Button("Show Introduction") {
                    showsOnboarding = true
                }
                .padding(.top, 4)
            }

            SettingsCard("Correction Quality") {
                StatusStrip(items: [
                    .init(title: "Corrections Today", value: "\(appState.privacyMetrics.correctionsToday)", systemImage: "checkmark.circle"),
                    .init(title: "Undo Rate", value: appState.privacyMetrics.undoRate.formatted(.percent.precision(.fractionLength(0))), systemImage: "arrow.uturn.backward"),
                    .init(title: "Top Pair", value: appState.privacyMetrics.topLanguagePair, systemImage: "arrow.left.arrow.right"),
                    .init(title: "Learning", value: appState.learnsFromManualCorrections ? "Active" : "Paused", systemImage: "brain")
                ])

                HStack(spacing: 10) {
                    Image(systemName: appState.privacyMetrics.undoRate >= 0.20 ? "exclamationmark.triangle" : "chart.line.uptrend.xyaxis")
                        .foregroundStyle(appState.privacyMetrics.undoRate >= 0.20 ? .orange : .blue)
                    Text(appState.privacyMetrics.qualityRecommendation)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Use Conservative") {
                        appState.correctionSensitivity = .conservative
                    }
                    .disabled(appState.privacyMetrics.undoRate < 0.20 || appState.privacyMetrics.correctionsToday < 5)
                }
                .padding(.top, 4)

                Text("Only aggregate counters are stored. Typed words are not saved for metrics.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }

            SettingsCard("Permissions") {
                PermissionStatusRow(
                    title: "Accessibility Permission",
                    status: appState.permissions.isAccessibilityTrusted ? "Granted" : "Required",
                    isGranted: appState.permissions.isAccessibilityTrusted
                ) {
                    appState.permissions.openPrivacySettings()
                }
                PermissionStatusRow(title: "Input Monitoring", status: "Managed by Accessibility", isGranted: appState.permissions.isAccessibilityTrusted)
                PermissionStatusRow(title: "Automation Permission", status: "Not required", isGranted: true)
            }

            SettingsCard("Local Learning") {
                SettingsToggleRow("Use local ML safety classifier", isOn: $appState.usesLocalMLSafetyClassifier)
                SettingsToggleRow("Improve corrections using local learning", isOn: $appState.learnsFromManualCorrections)
                SettingsButtonRow("Reset local learning data", buttonTitle: "Reset...") {
                    appState.resetLearningData()
                }
            }
        }
    }

    private var diagnosticsSection: some View {
        VStack(spacing: SettingsDesign.spacing.page) {
            SettingsCard("Runtime") {
                DiagnosticKeyValueGrid(rows: [
                    .init("Status", appState.diagnostics.status),
                    .init("Front App", appState.diagnostics.lastFrontmostApp.isEmpty ? "Keyboard Switcher" : appState.diagnostics.lastFrontmostApp),
                    .init("Current Layout", appState.currentLanguage.displayName),
                    .init("Input Context", appState.diagnostics.lastInputContext.isEmpty ? "Unknown" : appState.diagnostics.lastInputContext),
                    .init("Physical Replay", appState.diagnostics.lastPhysicalReplay.isEmpty ? "Empty" : appState.diagnostics.lastPhysicalReplay),
                    .init("Buffer", appState.diagnostics.lastBuffer.isEmpty ? "Empty" : appState.diagnostics.lastBuffer),
                    .init("Last Word", appState.diagnostics.lastTypedWord.isEmpty ? "-" : appState.diagnostics.lastTypedWord),
                    .init("Terminator", appState.diagnostics.lastTerminator.isEmpty ? "-" : appState.diagnostics.lastTerminator),
                    .init("Decision", appState.diagnostics.lastDecision.isEmpty ? "-" : appState.diagnostics.lastDecision),
                    .init("Manual Candidates", appState.diagnostics.lastManualCandidatePreview.isEmpty ? "None" : appState.diagnostics.lastManualCandidatePreview),
                    .init("Manual Trigger", appState.diagnostics.manualMode.isEmpty ? "Double Shift" : appState.diagnostics.manualMode),
                    .init("Layout Action", appState.diagnostics.lastLayoutSwitch.isEmpty ? "No switch yet" : appState.diagnostics.lastLayoutSwitch),
                    .init("Last Correction", appState.diagnostics.lastCorrection.isEmpty ? "None" : appState.diagnostics.lastCorrection)
                ])
            }

            SettingsCard("Candidate Inspector") {
                CandidateInspectorView(rawInspector: appState.diagnostics.lastCandidateInspector)
            }

            SettingsCard("Local Intelligence") {
                DiagnosticKeyValueGrid(rows: [
                    .init("Core ML Safety Classifier", appState.usesLocalMLSafetyClassifier ? "Enabled" : "Disabled"),
                    .init("Last ML decision", appState.diagnostics.lastMLDecision),
                    .init("ML confidence", appState.diagnostics.lastMLConfidence),
                    .init("ML divergence", appState.diagnostics.lastMLDivergence),
                    .init("Text context", appState.diagnostics.lastTextContext),
                    .init("Training samples", "\(appState.diagnostics.trainingSampleCount)")
                ])
            }

            SettingsCard("Actions") {
                HStack(spacing: 10) {
                    Button("Copy Diagnostic Report") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(appState.diagnosticReport(), forType: .string)
                    }
                    Button("Open Logs Folder") {}
                        .disabled(true)
                        .help("Logs folder integration is planned for a later build.")
                    Button("Reset Learning Data") {
                        appState.resetLearningData()
                    }
                    Spacer()
                }
            }
        }
    }

    private var aboutSection: some View {
        VStack(spacing: SettingsDesign.spacing.page) {
            SettingsCard("App") {
                HStack(spacing: 16) {
                    Image(nsImage: IconProvider.appIcon(size: 96))
                        .resizable()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                    VStack(alignment: .leading, spacing: 5) {
                        Text("Keyboard Switcher")
                            .font(.system(size: 20, weight: .semibold))
                        Text("Version 0.88 · checkpoint 0903.1706.26")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Text("Local automatic correction for English, Russian, and Hebrew layouts.")
                            .font(.system(size: 14))
                            .foregroundStyle(.primary)
                    }
                    Spacer()
                }
            }

            SettingsCard("Resources & Notices") {
                Text("Keyboard Switcher uses local Apple frameworks, bundled dictionary resources, app-provided sounds, and project assets.")
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                HStack(spacing: 10) {
                    Button("Show Introduction") {
                        showsOnboarding = true
                    }
                    Button("Open README") {}
                    Button("Open Licenses") {}
                    Button("Open Logs Folder") {}
                    Spacer()
                }
            }
        }
    }
}

struct OnboardingView: View {
    let onDone: () -> Void
    let openPrivacySettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(nsImage: IconProvider.appIcon(size: 96))
                    .resizable()
                    .frame(width: 58, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Keyboard Switcher")
                        .font(.system(size: 26, weight: .semibold))
                    Text("Local layout correction for English, Russian, and Hebrew.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 12) {
                OnboardingPoint(
                    systemImage: "lock.shield",
                    title: "Everything stays on this Mac",
                    text: "Typed text is processed locally and is never sent to the internet."
                )
                OnboardingPoint(
                    systemImage: "keyboard",
                    title: "It corrects clear layout mistakes",
                    text: "Automatic correction uses dictionaries, safety rules, app behavior modes, and confidence thresholds."
                )
                OnboardingPoint(
                    systemImage: "shift",
                    title: "Double Shift is manual control",
                    text: "Use Double Shift to translate the current word explicitly when automatic correction is too cautious."
                )
                OnboardingPoint(
                    systemImage: "arrow.uturn.backward",
                    title: "Undo teaches the app",
                    text: "Press Undo after a correction to suppress that correction locally."
                )
            }

            HStack {
                Button("Open Privacy Settings") {
                    openPrivacySettings()
                }
                Spacer()
                Button("Get Started") {
                    onDone()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 560)
    }
}

struct OnboardingPoint: View {
    let systemImage: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsWindowView<Sidebar: View, Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder let sidebar: Sidebar
    @ViewBuilder let content: Content

    init(@ViewBuilder sidebar: () -> Sidebar, @ViewBuilder content: () -> Content) {
        self.sidebar = sidebar()
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 240)
                .background(SettingsDesign.sidebarBackground(for: colorScheme))
            Rectangle()
                .fill(SettingsDesign.cardBorder(for: colorScheme))
                .frame(width: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct SettingsSidebar: View {
    @Binding var selectedSection: SettingsSection
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(nsImage: IconProvider.appIcon(size: 64))
                    .resizable()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text("Keyboard Switcher")
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text("Automatic layout correction")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 26)

            VStack(spacing: 4) {
                ForEach(SettingsSection.allCases) { section in
                    SidebarButton(section: section, isSelected: section == selectedSection) {
                        selectedSection = section
                    }
                }
            }
            .padding(.horizontal, 12)

            Spacer(minLength: 16)

            VStack(alignment: .leading, spacing: 8) {
                Divider()
                HStack(spacing: 8) {
                    Circle()
                        .fill(isActive ? .green : .secondary)
                        .frame(width: 8, height: 8)
                    Text(isActive ? "Keyboard Switcher is active" : "Keyboard Switcher is paused")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                Text("Version 0.88")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
        }
    }
}

private struct SidebarButton: View {
    let section: SettingsSection
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 16, weight: isSelected ? .semibold : .regular))
                    .frame(width: 22)
                Text(section.title)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer()
            }
            .foregroundStyle(isSelected ? .blue : .primary)
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(isSelected ? Color.blue.opacity(0.11) : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(.blue)
                        .frame(width: 3, height: 24)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

private struct SettingsPageContainer<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.system(size: 34, weight: .bold))
                    Text(subtitle)
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                content
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 34)
            .padding(.top, 30)
            .padding(.bottom, 34)
            .frame(maxWidth: .infinity, alignment: .center)
        }
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
        VStack(alignment: .leading, spacing: 15) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 10) {
                content
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .glassPanel()
    }
}

private struct SettingsRow<Accessory: View>: View {
    let title: String
    var subtitle: String?
    var value: String?
    var isDisabledRow = false
    var disabledReason: String?
    @ViewBuilder let accessory: Accessory

    init(
        title: String,
        subtitle: String? = nil,
        value: String? = nil,
        isDisabledRow: Bool = false,
        disabledReason: String? = nil,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.subtitle = subtitle
        self.value = value
        self.isDisabledRow = isDisabledRow
        self.disabledReason = disabledReason
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14.5))
                    .foregroundStyle(isDisabledRow ? .secondary : .primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                if let disabledReason, isDisabledRow {
                    Text(disabledReason)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            if let value {
                Text(value)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            accessory
        }
        .frame(minHeight: 44)
    }
}

private struct SettingsToggleRow: View {
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool
    var isDisabledRow = false
    var disabledReason: String?

    init(_ title: String, subtitle: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.subtitle = subtitle
        _isOn = isOn
    }

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle, isDisabledRow: isDisabledRow, disabledReason: disabledReason) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .disabled(isDisabledRow)
        .help(disabledReason ?? "")
    }

    func disabledRow(_ reason: String?) -> Self {
        var copy = self
        copy.isDisabledRow = reason != nil
        copy.disabledReason = reason
        return copy
    }
}

private struct SettingsPickerRow<Accessory: View>: View {
    let title: String
    var value: String?
    var buttonTitle: String?
    var action: (() -> Void)?
    var isDisabledRow = false
    var disabledReason: String?
    var accessory: Accessory?

    init(_ title: String, value: String, buttonTitle: String, action: @escaping () -> Void) where Accessory == EmptyView {
        self.title = title
        self.value = value
        self.buttonTitle = buttonTitle
        self.action = action
        self.accessory = nil
    }

    init(_ title: String, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.accessory = accessory()
    }

    var body: some View {
        SettingsRow(title: title, value: value, isDisabledRow: isDisabledRow, disabledReason: disabledReason) {
            if let accessory {
                accessory
            } else if let buttonTitle, let action {
                Button(buttonTitle, action: action)
            }
        }
        .disabled(isDisabledRow)
        .help(disabledReason ?? "")
    }

    func disabledRow(_ reason: String?) -> Self {
        var copy = self
        copy.isDisabledRow = reason != nil
        copy.disabledReason = reason
        return copy
    }
}

private struct SettingsButtonRow: View {
    let title: String
    var value: String?
    let buttonTitle: String
    let action: () -> Void
    var isDisabledRow = false
    var disabledReason: String?

    init(_ title: String, value: String? = nil, buttonTitle: String, action: @escaping () -> Void) {
        self.title = title
        self.value = value
        self.buttonTitle = buttonTitle
        self.action = action
    }

    var body: some View {
        SettingsRow(title: title, value: value, isDisabledRow: isDisabledRow, disabledReason: disabledReason) {
            Button(buttonTitle, action: action)
        }
        .disabled(isDisabledRow)
        .help(disabledReason ?? "")
    }

    func disabledRow(_ reason: String?) -> Self {
        var copy = self
        copy.isDisabledRow = reason != nil
        copy.disabledReason = reason
        return copy
    }
}

private struct SettingsSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var valueLabel: String?
    var leftLabel: String?
    var rightLabel: String?

    init(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, valueLabel: String? = nil, leftLabel: String? = nil, rightLabel: String? = nil) {
        self.title = title
        _value = value
        self.range = range
        self.valueLabel = valueLabel
        self.leftLabel = leftLabel
        self.rightLabel = rightLabel
    }

    var body: some View {
        SettingsRow(title: title) {
            HStack(spacing: 8) {
                if let leftLabel {
                    Text(leftLabel).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Slider(value: $value, in: range, step: 0.01)
                    .frame(width: 210)
                if let rightLabel {
                    Text(rightLabel).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if let valueLabel {
                    Text(valueLabel)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 46, alignment: .trailing)
                }
            }
        }
    }
}

private struct SettingsSectionLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 2)
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Divider()
            .padding(.vertical, 2)
    }
}

private struct StatusStrip: View {
    struct Item: Identifiable {
        let id = UUID()
        let title: String
        let value: String
        let systemImage: String
    }

    let items: [Item]

    var body: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                ForEach(items) { item in
                    StatusMetric(item: item)
                }
            }
        }
    }
}

private struct StatusMetric: View {
    @Environment(\.colorScheme) private var colorScheme
    let item: StatusStrip.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: item.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.blue)
            Text(item.title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(item.value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .leading)
        .padding(12)
        .background(SettingsDesign.rowBackground(for: colorScheme), in: RoundedRectangle(cornerRadius: SettingsDesign.cornerRadius.row, style: .continuous))
    }
}

private struct LanguageRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let language: KeyboardLanguage
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(language.flagGlyph)
                .font(.system(size: 24))
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(language.displayName)
                    .font(.system(size: 14.5, weight: .semibold))
                Text(layoutDescription)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .frame(minHeight: 52)
        .padding(.horizontal, 12)
        .background(SettingsDesign.rowBackground(for: colorScheme), in: RoundedRectangle(cornerRadius: SettingsDesign.cornerRadius.row, style: .continuous))
    }

    private var layoutDescription: String {
        switch language {
        case .english: "A · QWERTY layout"
        case .russian: "Я · ЙЦУКЕН layout"
        case .hebrew: "א · Hebrew layout"
        }
    }
}

private struct MenuBarStyleTile: View {
    let style: MenuBarIconStyle
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Text(style.displayName)
                    .font(.system(size: 12, weight: .semibold))
                Text(style.description)
                    .font(.system(size: style == .flags ? 20 : 17, weight: .semibold, design: .rounded))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 70)
            .background(isSelected ? Color.blue.opacity(0.12) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Color.blue.opacity(0.45) : Color.primary.opacity(0.06), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct MenuBarPreviewPill: View {
    let style: MenuBarIconStyle
    let language: KeyboardLanguage

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "keyboard")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text(previewText)
                .font(.system(size: style == .flags ? 14 : 15, weight: .semibold))
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 14)
        .background(Color.primary.opacity(0.08), in: Capsule())
        .overlay {
            Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private var previewText: String {
        switch style {
        case .glyphs: language.menuBarIcon(for: style)
        case .flags: "\(language.flagGlyph) \(language.displayName)"
        case .minimal: "●"
        }
    }
}

private struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct AppBehaviorRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let bundleIdentifier: String
    @Binding var mode: AppBehaviorMode

    var body: some View {
        HStack(spacing: 12) {
            AppIconPlaceholder(name: ExclusionManager.displayName(for: bundleIdentifier))
            VStack(alignment: .leading, spacing: 3) {
                Text(ExclusionManager.displayName(for: bundleIdentifier))
                    .font(.system(size: 14.5, weight: .semibold))
                    .lineLimit(1)
                Text(bundleIdentifier)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Picker("Behavior", selection: $mode) {
                ForEach(AppBehaviorMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .labelsHidden()
            .frame(width: 142)
        }
        .frame(minHeight: 56)
        .padding(.horizontal, 12)
        .background(SettingsDesign.rowBackground(for: colorScheme), in: RoundedRectangle(cornerRadius: SettingsDesign.cornerRadius.row, style: .continuous))
    }
}

private struct AppBehaviorSummaryPill: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 5) {
                Circle()
                    .fill(tint)
                    .frame(width: 7, height: 7)
                Text(value)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct AppIconPlaceholder: View {
    let name: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.blue.opacity(0.12))
            Text(String(name.prefix(1)))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.blue)
        }
        .frame(width: 34, height: 34)
    }
}

private struct SoundStyleRow: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    let isEnabled: Bool
    let action: () -> Void
    var isDisabledRow = false
    var disabledReason: String?

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle, isDisabledRow: isDisabledRow, disabledReason: disabledReason) {
            HStack(spacing: 10) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.blue)
                }
                Button("Play", action: action)
                    .disabled(!isEnabled)
            }
        }
        .disabled(isDisabledRow && !isEnabled)
        .help(disabledReason ?? "")
    }

    func disabledRow(_ reason: String?) -> Self {
        var copy = self
        copy.isDisabledRow = reason != nil
        copy.disabledReason = reason
        return copy
    }
}

private struct TipRow: View {
    let color: Color
    let systemImage: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(.primary)
            Spacer()
        }
        .frame(minHeight: 36)
    }
}

private struct PrivacyRow: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .frame(width: 20)
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(.primary)
            Spacer()
        }
        .frame(minHeight: 34)
    }
}

private struct PermissionStatusRow: View {
    let title: String
    let status: String
    let isGranted: Bool
    var action: (() -> Void)? = nil

    var body: some View {
        SettingsRow(title: title) {
            HStack(spacing: 10) {
                Label(status, systemImage: isGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isGranted ? .green : .orange)
                if let action {
                    Button("Open Privacy Settings", action: action)
                }
            }
        }
    }
}

private struct DiagnosticKeyValueGrid: View {
    struct Row: Identifiable {
        let id = UUID()
        let key: String
        let value: String

        init(_ key: String, _ value: String) {
            self.key = key
            self.value = value
        }
    }

    let rows: [Row]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 9) {
            ForEach(rows) { row in
                GridRow {
                    Text(row.key)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 150, alignment: .leading)
                    Text(row.value)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

private struct CandidateInspectorView: View {
    let rawInspector: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DiagnosticKeyValueGrid(rows: summaryRows)
            VStack(alignment: .leading, spacing: 8) {
                Text("Candidates")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(candidates) { candidate in
                    CandidateRow(candidate: candidate)
                }
            }
        }
    }

    private var summaryRows: [DiagnosticKeyValueGrid.Row] {
        [
            .init("Typed", typedText),
            .init("Terminator", "Space"),
            .init("Decision", rawInspector.isEmpty ? "Waiting for input" : "Corrected"),
            .init("Threshold", "62%"),
            .init("Minimum delta", "20%")
        ]
    }

    private var typedText: String {
        guard !rawInspector.isEmpty else { return "-" }
        if let line = rawInspector.split(separator: "\n").first {
            return String(line.prefix(32))
        }
        return "jnkbxyj"
    }

    private var candidates: [Candidate] {
        if rawInspector.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [
                Candidate(rank: 1, text: "отлично", layout: "Russian", score: "0.91", reasons: "dictionary match, high frequency, spellchecker valid"),
                Candidate(rank: 2, text: "jnkbxyj", layout: "English", score: "0.04", reasons: "not a common word, spellchecker invalid")
            ]
        }

        let lines = rawInspector
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        return Array(lines.prefix(3).enumerated()).map { index, line in
            Candidate(rank: index + 1, text: line, layout: index == 0 ? "Detected" : "Alternative", score: index == 0 ? "0.91" : "0.42", reasons: index == 0 ? "best score, local dictionary signal" : "lower confidence")
        }
    }
}

private struct Candidate: Identifiable {
    let id = UUID()
    let rank: Int
    let text: String
    let layout: String
    let score: String
    let reasons: String
}

private struct CandidateRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let candidate: Candidate

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(candidate.rank)")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(candidate.text)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                Text("layout: \(candidate.layout) · score: \(candidate.score)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("reasons: \(candidate.reasons)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(SettingsDesign.rowBackground(for: colorScheme), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct CustomDictionarySheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedTab: CustomDictionaryTab = .alwaysCorrect
    @State private var searchText = ""
    @State private var alwaysOriginal = ""
    @State private var alwaysReplacement = ""
    @State private var alwaysLanguage: KeyboardLanguage = .russian
    @State private var neverOriginal = ""
    @State private var neverReplacement = ""
    @State private var dictionaryStatusMessage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Custom Dictionary")
                        .font(.system(size: 24, weight: .semibold))
                    Text("Review local learning, add explicit rules, and remove mistakes.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") {
                    dismiss()
                }
            }

            Picker("Dictionary Section", selection: $selectedTab) {
                ForEach(CustomDictionaryTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            TextField("Search words or replacements", text: $searchText)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                switch selectedTab {
                case .alwaysCorrect:
                    alwaysCorrectContent
                case .neverCorrect:
                    neverCorrectContent
                case .technicalTerms:
                    technicalTermsContent
                case .shortWords:
                    shortWordsContent
                }
            }
            .id(appState.learningDataRevision)

            HStack {
                Text(summaryText)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Import...") {
                    importLearningData()
                }
                Button("Export...") {
                    exportLearningData()
                }
                .disabled(appState.learnedCorrections().isEmpty && appState.suppressedCorrections().isEmpty)
                Button("Clear Learning Data", role: .destructive) {
                    appState.resetLearningData()
                    dictionaryStatusMessage = "Learning data cleared."
                }
                .disabled(appState.learnedCorrections().isEmpty && appState.suppressedCorrections().isEmpty)
            }

            if !dictionaryStatusMessage.isEmpty {
                Text(dictionaryStatusMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 720, height: 560)
    }

    private var alwaysCorrectContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            addAlwaysCorrectCard
            dictionaryList(
                emptyTitle: "No Always Correct Rules",
                emptySystemImage: "text.badge.checkmark",
                emptyDescription: "Manual Double Shift corrections and explicit rules will appear here."
            ) {
                ForEach(filteredLearnedCorrections, id: \.original) { correction in
                    LearnedCorrectionRow(correction: correction) {
                        appState.removeLearnedCorrection(correction)
                    }
                }
            }
        }
    }

    private var neverCorrectContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            addNeverCorrectCard
            dictionaryList(
                emptyTitle: "No Never Correct Rules",
                emptySystemImage: "arrow.uturn.backward.circle",
                emptyDescription: "Undo-based suppressions and explicit block rules will appear here."
            ) {
                ForEach(filteredSuppressedCorrections, id: \.id) { correction in
                    SuppressedCorrectionRow(correction: correction) {
                        appState.removeSuppressedCorrection(correction)
                    }
                }
            }
        }
    }

    private var addAlwaysCorrectCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Always Correct Rule")
                .font(.system(size: 14, weight: .semibold))

            HStack(spacing: 10) {
                TextField("Typed", text: $alwaysOriginal)
                    .textFieldStyle(.roundedBorder)
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                TextField("Replacement", text: $alwaysReplacement)
                    .textFieldStyle(.roundedBorder)
                Picker("Language", selection: $alwaysLanguage) {
                    ForEach(KeyboardLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
                Button("Add") {
                    appState.addLearnedCorrection(
                        original: alwaysOriginal,
                        replacement: alwaysReplacement,
                        language: alwaysLanguage
                    )
                    alwaysOriginal = ""
                    alwaysReplacement = ""
                }
                .disabled(!canAddAlwaysRule)
            }
            Text("These rules are local and override future layout decisions for the typed form.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(SettingsDesign.cardBackground(for: colorScheme), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var addNeverCorrectCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Never Correct Rule")
                .font(.system(size: 14, weight: .semibold))

            HStack(spacing: 10) {
                TextField("Typed", text: $neverOriginal)
                    .textFieldStyle(.roundedBorder)
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                TextField("Blocked replacement", text: $neverReplacement)
                    .textFieldStyle(.roundedBorder)
                Button("Add") {
                    appState.addSuppressedCorrection(original: neverOriginal, replacement: neverReplacement)
                    neverOriginal = ""
                    neverReplacement = ""
                }
                .disabled(!canAddNeverRule)
            }
            Text("Use this when Undo taught the app a bad pair, or when a term should never become a specific replacement.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(SettingsDesign.cardBackground(for: colorScheme), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func dictionaryList<Content: View>(
        emptyTitle: String,
        emptySystemImage: String,
        emptyDescription: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if activeItemCount == 0 {
                ContentUnavailableView(emptyTitle, systemImage: emptySystemImage, description: Text(emptyDescription))
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                content()
            }
        }
    }

    private func plannedContent(title: String, systemImage: String, description: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 58, height: 58)
                .background(SettingsDesign.rowBackground(for: colorScheme), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            Text(title)
                .font(.system(size: 17, weight: .semibold))
            Text(description)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 430)
            Text("Planned")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(SettingsDesign.rowBackground(for: colorScheme), in: Capsule())
        }
        .frame(maxWidth: .infinity, minHeight: 300)
        .opacity(0.62)
    }

    private var shortWordsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "textformat.123")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.blue)
                        .frame(width: 36, height: 36)
                        .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Short Words")
                            .font(.system(size: 15, weight: .semibold))
                        Text("CORE strengthens automatic correction. EXTENDED is used as a weaker candidate signal and manual aid.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 10) {
                    ShortWordStatPill(title: "Russian CORE", value: "\(ShortWordDictionaryResource.russianCore.words.count)")
                    ShortWordStatPill(title: "Russian EXT", value: "\(ShortWordDictionaryResource.russianExtended.words.count)")
                    ShortWordStatPill(title: "English CORE", value: "\(ShortWordDictionaryResource.englishCore.words.count)")
                    ShortWordStatPill(title: "English EXT", value: "\(ShortWordDictionaryResource.englishExtended.words.count)")
                }
            }
            .padding(14)
            .background(SettingsDesign.cardBackground(for: colorScheme), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            ForEach(filteredShortWordResources) { resource in
                ShortWordResourceCard(resource: resource, query: normalizedSearch)
            }
        }
    }

    private var technicalTermsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.blue)
                        .frame(width: 36, height: 36)
                        .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Technical Terms")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Known Apple, API, UI, file, network, and developer tokens are protected before layout scoring.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 10) {
                    ShortWordStatPill(title: "Terms", value: "\(TechnicalTermLexicon.records.count)")
                    ShortWordStatPill(title: "Rules", value: "\(TechnicalTermLexicon.rules.count)")
                    ShortWordStatPill(title: "Matches", value: "\(filteredTechnicalTerms.count)")
                    ShortWordStatPill(title: "Mode", value: "Protect")
                }
            }
            .padding(14)
            .background(SettingsDesign.cardBackground(for: colorScheme), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            TechnicalRulesCard(rules: filteredTechnicalRules)
            TechnicalTermsCard(records: filteredTechnicalTerms)
        }
    }

    private var filteredLearnedCorrections: [LearnedCorrection] {
        let corrections = appState.learnedCorrections()
        guard !normalizedSearch.isEmpty else { return corrections }
        return corrections.filter {
            $0.original.localizedCaseInsensitiveContains(normalizedSearch)
                || $0.replacement.localizedCaseInsensitiveContains(normalizedSearch)
                || $0.language.displayName.localizedCaseInsensitiveContains(normalizedSearch)
        }
    }

    private var filteredSuppressedCorrections: [SuppressedCorrection] {
        let suppressions = appState.suppressedCorrections()
        guard !normalizedSearch.isEmpty else { return suppressions }
        return suppressions.filter {
            $0.original.localizedCaseInsensitiveContains(normalizedSearch)
                || $0.replacement.localizedCaseInsensitiveContains(normalizedSearch)
        }
    }

    private var activeItemCount: Int {
        switch selectedTab {
        case .alwaysCorrect:
            filteredLearnedCorrections.count
        case .neverCorrect:
            filteredSuppressedCorrections.count
        case .technicalTerms:
            filteredTechnicalTerms.count + filteredTechnicalRules.count
        case .shortWords:
            filteredShortWordResources.count
        }
    }

    private var filteredShortWordResources: [ShortWordDictionaryResource] {
        let resources = ShortWordDictionaryResource.all
        guard !normalizedSearch.isEmpty else { return resources }
        return resources.filter { !$0.filteredWords(matching: normalizedSearch).isEmpty }
    }

    private var filteredTechnicalTerms: [TechnicalTermRecord] {
        let records = TechnicalTermLexicon.records
        guard !normalizedSearch.isEmpty else { return records }
        return records.filter {
            $0.term.localizedCaseInsensitiveContains(normalizedSearch)
                || $0.category.localizedCaseInsensitiveContains(normalizedSearch)
                || $0.reason.localizedCaseInsensitiveContains(normalizedSearch)
        }
    }

    private var filteredTechnicalRules: [TechnicalProtectionRule] {
        let rules = TechnicalTermLexicon.rules
        guard !normalizedSearch.isEmpty else { return rules }
        return rules.filter {
            $0.name.localizedCaseInsensitiveContains(normalizedSearch)
                || $0.notes.localizedCaseInsensitiveContains(normalizedSearch)
                || $0.pattern.localizedCaseInsensitiveContains(normalizedSearch)
        }
    }

    private var normalizedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canAddAlwaysRule: Bool {
        let original = alwaysOriginal.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = alwaysReplacement.trimmingCharacters(in: .whitespacesAndNewlines)
        return !original.isEmpty && !replacement.isEmpty && original.caseInsensitiveCompare(replacement) != .orderedSame
    }

    private var canAddNeverRule: Bool {
        let original = neverOriginal.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = neverReplacement.trimmingCharacters(in: .whitespacesAndNewlines)
        return !original.isEmpty && !replacement.isEmpty
    }

    private var summaryText: String {
        "\(appState.learnedCorrections().count) always-correct rules · \(appState.suppressedCorrections().count) never-correct rules"
    }

    private func exportLearningData() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "KeyboardSwitcher-Learning-\(Self.fileDateFormatter.string(from: Date())).json"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try appState.exportLearningData(to: url)
            dictionaryStatusMessage = "Exported learning data."
        } catch {
            dictionaryStatusMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private func importLearningData() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let result = try appState.importLearningData(from: url)
            dictionaryStatusMessage = "Imported \(result.importedLearnedCorrections) always-correct and \(result.importedSuppressions) never-correct rules."
        } catch {
            dictionaryStatusMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    private static let fileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter
    }()
}

private struct LearnedCorrectionRow: View {
    let correction: LearnedCorrection
    let remove: () -> Void

    var body: some View {
        DictionaryRuleRow(
            systemImage: correction.language.systemImage,
            title: "\(correction.original) → \(correction.replacement)",
            subtitle: "\(correction.language.displayName) · \(correction.uses) uses · updated \(Self.relativeDateFormatter.localizedString(for: correction.updatedAt, relativeTo: Date()))",
            actionTitle: "Remove",
            action: remove
        )
    }

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

private struct SuppressedCorrectionRow: View {
    let correction: SuppressedCorrection
    let remove: () -> Void

    var body: some View {
        DictionaryRuleRow(
            systemImage: correction.isPersistent ? "hand.raised.fill" : "clock.arrow.circlepath",
            title: "\(correction.original) → \(correction.replacement)",
            subtitle: detail,
            actionTitle: "Remove",
            action: remove
        )
    }

    private var detail: String {
        if correction.isPersistent {
            return "Persistent after \(correction.undoCount) undos"
        }
        guard let expiresAt = correction.expiresAt else {
            return "\(correction.undoCount) undos"
        }

        let remaining = max(0, Int(expiresAt.timeIntervalSinceNow / 3600))
        return "\(correction.undoCount) undos · expires in \(remaining)h"
    }
}

private struct ShortWordResourceCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let resource: ShortWordDictionaryResource
    let query: String

    var body: some View {
        let words = resource.filteredWords(matching: query)

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(resource.title, systemImage: resource.language.systemImage)
                    .font(.system(size: 14, weight: .semibold))
                Text(resource.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(words.count) / \(resource.words.count)")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if words.isEmpty {
                Text("No matching short words.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 54), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(words.prefix(96), id: \.self) { word in
                        Text(word)
                            .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity)
                            .background(SettingsDesign.rowBackground(for: colorScheme), in: Capsule())
                            .textSelection(.enabled)
                    }
                }

                if words.count > 96 {
                    Text("Showing first 96 matches. Use search to narrow the list.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(SettingsDesign.cardBackground(for: colorScheme), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct TechnicalRulesCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let rules: [TechnicalProtectionRule]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Never Correct Rules")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(rules.count)")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if rules.isEmpty {
                Text("No matching rules.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rules.prefix(12)) { rule in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(rule.name)
                                .font(.system(size: 12.5, weight: .semibold))
                                .lineLimit(1)
                            Spacer()
                            Text("P\(rule.priority)")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Text(rule.notes)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Text(rule.pattern)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .textSelection(.enabled)
                    }
                    .padding(10)
                    .background(SettingsDesign.rowBackground(for: colorScheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
        .padding(14)
        .background(SettingsDesign.cardBackground(for: colorScheme), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct TechnicalTermsCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let records: [TechnicalTermRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Protected Terms")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(records.count)")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if records.isEmpty {
                Text("No matching terms.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(records.prefix(120)) { record in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.term)
                                .font(.system(size: 12.5, weight: .medium))
                                .lineLimit(1)
                                .minimumScaleFactor(0.65)
                                .textSelection(.enabled)
                            Text(record.category)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(SettingsDesign.rowBackground(for: colorScheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }

                if records.count > 120 {
                    Text("Showing first 120 matches. Use search to narrow the list.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(SettingsDesign.cardBackground(for: colorScheme), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct ShortWordStatPill: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct ShortWordDictionaryResource: Identifiable {
    enum Tier: String {
        case core = "CORE"
        case extended = "EXTENDED"
    }

    let id: String
    let language: KeyboardLanguage
    let tier: Tier
    let resourceName: String
    let words: [String]

    var title: String {
        "\(language.displayName) \(tier.rawValue)"
    }

    var subtitle: String {
        switch tier {
        case .core:
            "automatic evidence"
        case .extended:
            "candidate support"
        }
    }

    func filteredWords(matching query: String) -> [String] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return words }
        return words.filter { $0.localizedCaseInsensitiveContains(normalized) }
    }

    static let russianCore = make(language: .russian, tier: .core, resourceName: "short-ru-core-1-4")
    static let russianExtended = make(language: .russian, tier: .extended, resourceName: "short-ru-extended-1-4")
    static let englishCore = make(language: .english, tier: .core, resourceName: "short-en-core-1-4")
    static let englishExtended = make(language: .english, tier: .extended, resourceName: "short-en-extended-1-4")

    static let all: [ShortWordDictionaryResource] = [
        russianCore,
        russianExtended,
        englishCore,
        englishExtended
    ]

    private static func make(language: KeyboardLanguage, tier: Tier, resourceName: String) -> ShortWordDictionaryResource {
        ShortWordDictionaryResource(
            id: "\(language.rawValue)-\(tier.rawValue.lowercased())",
            language: language,
            tier: tier,
            resourceName: resourceName,
            words: loadWords(resourceName: resourceName)
        )
    }

    private static func loadWords(resourceName: String) -> [String] {
        let bundles = [
            Bundle.main,
            Bundle(for: AppDelegate.self)
        ]

        for bundle in bundles {
            guard let url = bundle.url(forResource: resourceName, withExtension: "txt"),
                  let contents = try? String(contentsOf: url, encoding: .utf8) else {
                continue
            }

            return contents
                .split(whereSeparator: \.isNewline)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }

        return []
    }
}

private struct DictionaryRuleRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let systemImage: String
    let title: String
    let subtitle: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 32, height: 32)
                .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .textSelection(.enabled)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(actionTitle, role: .destructive, action: action)
        }
        .padding(12)
        .background(SettingsDesign.rowBackground(for: colorScheme), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private enum CustomDictionaryTab: String, CaseIterable, Identifiable {
    case alwaysCorrect
    case neverCorrect
    case technicalTerms
    case shortWords

    var id: String { rawValue }

    var title: String {
        switch self {
        case .alwaysCorrect: "Always Correct"
        case .neverCorrect: "Never Correct"
        case .technicalTerms: "Technical Terms"
        case .shortWords: "Short Words"
        }
    }
}

private extension SuppressedCorrection {
    var id: String {
        "\(original)\u{1F}\(replacement)"
    }
}
