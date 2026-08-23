import AppKit
import ApplicationServices
import Foundation

@MainActor
final class PermissionManager: ObservableObject {
    @Published private(set) var isAccessibilityTrusted = AXIsProcessTrusted()
    @Published private(set) var isInputMonitoringTrusted = CGPreflightListenEventAccess()

    func refresh() {
        isAccessibilityTrusted = AXIsProcessTrusted()
        isInputMonitoringTrusted = CGPreflightListenEventAccess()
    }

    func requestAccessibilityPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        isAccessibilityTrusted = AXIsProcessTrustedWithOptions(options)
    }

    func requestInputMonitoringPermission() {
        isInputMonitoringTrusted = CGRequestListenEventAccess()
    }

    func openPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        if let url {
            NSWorkspace.shared.open(url)
        }
    }
}
