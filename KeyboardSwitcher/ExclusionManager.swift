import AppKit
import Foundation

final class ExclusionManager {
    static let defaultExcludedBundleIdentifiers: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.apple.dt.Xcode",
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92",
        "com.github.atom",
        "com.sublimetext.4",
        "com.agilebits.onepassword7",
        "com.1password.1password",
        "com.apple.ScreenSharing",
        "com.microsoft.rdc.macos"
    ]

    var excludedBundleIdentifiers: Set<String>

    init(excludedBundleIdentifiers: Set<String>) {
        self.excludedBundleIdentifiers = excludedBundleIdentifiers
    }

    var isFrontmostAppExcluded: Bool {
        guard let bundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return false
        }

        return excludedBundleIdentifiers.contains(bundleIdentifier)
    }

    static func displayName(for bundleIdentifier: String) -> String {
        switch bundleIdentifier {
        case "com.apple.Terminal": "Terminal"
        case "com.googlecode.iterm2": "iTerm"
        case "com.apple.dt.Xcode": "Xcode"
        case "com.microsoft.VSCode": "Visual Studio Code"
        case "com.todesktop.230313mzl4w4u92": "Cursor"
        case "com.github.atom": "Atom"
        case "com.sublimetext.4": "Sublime Text"
        case "com.apple.TextEdit": "TextEdit"
        case "com.agilebits.onepassword7", "com.1password.1password": "1Password"
        case "com.apple.ScreenSharing": "Screen Sharing"
        case "com.microsoft.rdc.macos": "Microsoft Remote Desktop"
        default: bundleIdentifier
        }
    }
}
