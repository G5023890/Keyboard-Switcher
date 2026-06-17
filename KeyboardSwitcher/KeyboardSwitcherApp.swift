import AppKit
import SwiftUI

@main
struct KeyboardSwitcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(appState)
        } label: {
            Text(appState.currentLanguage.menuBarIcon(for: appState.menuBarIconStyle))
                .font(.system(size: appState.menuBarIconStyle == .flags ? 15 : 13, weight: .semibold, design: .rounded))
                .accessibilityLabel("Current keyboard layout: \(appState.currentLanguage.displayName)")
                .onAppear {
                    appDelegate.showOnboardingIfNeeded(appState: appState)
                }
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environmentObject(appState)
                .frame(minWidth: 1080, idealWidth: 1160, minHeight: 720, idealHeight: 760)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var onboardingWindowController: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.applicationIconImage = IconProvider.appIcon(size: 512)
    }

    func showOnboardingIfNeeded(appState: AppState) {
        guard !appState.hasSeenOnboarding else { return }
        showOnboarding(appState: appState, force: false)
    }

    func showOnboarding(appState: AppState, force: Bool) {
        guard force || !appState.hasSeenOnboarding else { return }

        if let window = onboardingWindowController?.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = OnboardingView {
            appState.markOnboardingSeen()
            self.closeOnboarding()
        } openPrivacySettings: {
            appState.permissions.openPrivacySettings()
        }
        let hostingView = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Keyboard Switcher"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.center()

        let controller = NSWindowController(window: window)
        onboardingWindowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeOnboarding() {
        onboardingWindowController?.close()
        onboardingWindowController = nil
    }
}

private struct MenuBarContent: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Keyboard Switcher", systemImage: "keyboard")
                .font(.headline)

            Text("Current layout: \(appState.currentLanguage.displayName)")
                .foregroundStyle(.secondary)

            if !appState.diagnostics.lastSuggestion.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Suggestion: \(appState.diagnostics.lastSuggestion)")
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    HStack {
                        Button("Accept") {
                            appState.acceptPendingSuggestion()
                        }
                        .keyboardShortcut(.return, modifiers: [])
                        Button("Ignore") {
                            appState.ignorePendingSuggestion()
                        }
                        .keyboardShortcut(.escape, modifiers: [])
                    }
                }
            }

            if !appState.diagnostics.lastManualCandidatePreview.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Manual candidates")
                        .font(.subheadline.weight(.semibold))
                    Text(appState.diagnostics.lastManualCandidatePreview)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                    Text("Press Double Shift again to choose the next candidate.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            Toggle("Enable Keyboard Switcher", isOn: $appState.isKeyboardSwitcherEnabled)

            Toggle("Auto-correct typed words", isOn: $appState.isAutoCorrectionEnabled)
                .disabled(!appState.isKeyboardSwitcherEnabled)

            Button("Undo Last Correction") {
                appState.undoLastCorrection()
            }
            .disabled(!appState.canUndoLastCorrection)

            Button("Open Settings...") {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut(",", modifiers: .command)

            Button("Show Introduction") {
                if let delegate = NSApp.delegate as? AppDelegate {
                    delegate.showOnboarding(appState: appState, force: true)
                }
            }

            Divider()

            if !appState.permissions.isAccessibilityTrusted {
                Button("Grant Accessibility Permission") {
                    appState.permissions.requestAccessibilityPermission()
                }
            }

            Button("Quit Keyboard Switcher") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.vertical, 6)
        .onAppear {
            appState.refreshRuntimeState()
        }
    }
}
