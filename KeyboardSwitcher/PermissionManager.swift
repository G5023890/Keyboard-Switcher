import AppKit
import ApplicationServices
import Foundation

@MainActor
final class PermissionManager: ObservableObject {
    @Published private(set) var isAccessibilityTrusted = AXIsProcessTrusted()

    func refresh() {
        isAccessibilityTrusted = AXIsProcessTrusted()
    }

    func requestAccessibilityPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        isAccessibilityTrusted = AXIsProcessTrustedWithOptions(options)
    }

    func openPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        if let url {
            NSWorkspace.shared.open(url)
        }
    }
}
