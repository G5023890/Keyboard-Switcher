import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color(nsColor: .controlBackgroundColor).opacity(0.88)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    correctionSection
                    diagnosticsSection
                    languageSection
                    permissionsSection
                    exclusionsSection
                    privacySection
                }
                .padding(26)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: IconProvider.appIcon(size: 72))
                .resizable()
                .frame(width: 54, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text("Keyboard Switcher")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                Text("Local automatic correction for English, Russian, and Hebrew layouts.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    private var correctionSection: some View {
        SettingsPanel("Correction", systemImage: "wand.and.stars") {
            Toggle("Automatically correct already typed words", isOn: $appState.isAutoCorrectionEnabled)
                .toggleStyle(.switch)

            HStack {
                Text("Confidence")
                Slider(value: $appState.confidenceThreshold, in: 0.55...0.90, step: 0.01)
                Text(appState.confidenceThreshold, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 46, alignment: .trailing)
            }
        }
    }

    private var diagnosticsSection: some View {
        SettingsPanel("Diagnostics", systemImage: "waveform.path.ecg") {
            DiagnosticRow("Status", appState.diagnostics.status)
            DiagnosticRow("Front App", appState.diagnostics.lastFrontmostApp.isEmpty ? "No app yet" : appState.diagnostics.lastFrontmostApp)
            DiagnosticRow("Buffer", appState.diagnostics.lastBuffer.isEmpty ? "Empty" : appState.diagnostics.lastBuffer)
            DiagnosticRow("Last Word", appState.diagnostics.lastTypedWord.isEmpty ? "None" : appState.diagnostics.lastTypedWord)
            DiagnosticRow("Decision", appState.diagnostics.lastDecision)
            DiagnosticRow("Manual", appState.diagnostics.manualMode)
            DiagnosticRow("Layout", appState.diagnostics.lastLayoutSwitch.isEmpty ? "No switch yet" : appState.diagnostics.lastLayoutSwitch)
            DiagnosticRow("Candidates", appState.diagnostics.lastCandidates.isEmpty ? "None" : appState.diagnostics.lastCandidates)
            DiagnosticRow("Correction", appState.diagnostics.lastCorrection.isEmpty ? "None" : appState.diagnostics.lastCorrection)
        }
    }

    private var languageSection: some View {
        SettingsPanel("Languages", systemImage: "character.cursor.ibeam") {
            ForEach(KeyboardLanguage.allCases) { language in
                Toggle(isOn: Binding(
                    get: { appState.enabledLanguages.contains(language) },
                    set: { appState.setLanguageEnabled(language, isEnabled: $0) }
                )) {
                    HStack(spacing: 10) {
                        Text(language.menuGlyph)
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .monospaced()
                            .frame(width: 28)
                        Text(language.displayName)
                    }
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    private var permissionsSection: some View {
        SettingsPanel("Permissions", systemImage: "lock.shield") {
            HStack {
                Label(
                    appState.permissions.isAccessibilityTrusted ? "Accessibility permission granted" : "Accessibility permission needed",
                    systemImage: appState.permissions.isAccessibilityTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(appState.permissions.isAccessibilityTrusted ? .green : .orange)

                Spacer()

                Button("Open Privacy Settings") {
                    appState.permissions.openPrivacySettings()
                }
            }

            Button("Request Accessibility Permission") {
                appState.permissions.requestAccessibilityPermission()
            }
            .disabled(appState.permissions.isAccessibilityTrusted)
        }
    }

    private var exclusionsSection: some View {
        SettingsPanel("App Exclusions", systemImage: "app.badge.checkmark") {
            ForEach(Array(appState.defaultExclusions).sorted(), id: \.self) { bundleIdentifier in
                Toggle(isOn: Binding(
                    get: { appState.excludedBundleIdentifiers.contains(bundleIdentifier) },
                    set: { appState.setExclusion(bundleIdentifier, isEnabled: $0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ExclusionManager.displayName(for: bundleIdentifier))
                        Text(bundleIdentifier)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    private var privacySection: some View {
        SettingsPanel("Privacy", systemImage: "network.slash") {
            Label("Recognition is local only. No typed text is sent to the internet.", systemImage: "checkmark.seal")
            Label("Correction is skipped for excluded apps, URLs, emails, paths, and code-like text.", systemImage: "eye.slash")
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
                .frame(width: 82, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12, design: .monospaced))
    }
}

private struct SettingsPanel<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    init(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)

            VStack(alignment: .leading, spacing: 10) {
                content
            }
        }
        .padding(16)
        .glassPanel()
    }
}
