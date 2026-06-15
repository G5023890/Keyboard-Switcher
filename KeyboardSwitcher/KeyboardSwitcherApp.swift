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
            Text(appState.currentLanguage.menuGlyph)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospaced()
                .accessibilityLabel("Current keyboard layout: \(appState.currentLanguage.displayName)")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environmentObject(appState)
                .frame(width: 620, height: 540)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.applicationIconImage = IconProvider.appIcon(size: 512)
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

            Divider()

            Toggle("Auto-correct typed words", isOn: $appState.isAutoCorrectionEnabled)

            Button("Undo Last Correction") {
                appState.undoLastCorrection()
            }
            .disabled(!appState.canUndoLastCorrection)

            Button("Open Settings...") {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut(",", modifiers: .command)

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
