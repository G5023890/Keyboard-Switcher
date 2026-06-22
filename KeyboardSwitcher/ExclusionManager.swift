import AppKit
import Foundation

final class ExclusionManager {
    static let defaultExcludedBundleIdentifiers: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.agilebits.onepassword7",
        "com.1password.1password",
        "com.bitwarden.desktop",
        "org.keepassxc.keepassxc",
        "com.apple.ScreenSharing",
        "com.microsoft.rdc.macos",
        "com.philandro.anydesk",
        "com.apple.finder"
    ]

    static let defaultStrictBundleIdentifiers: Set<String> = [
        "com.apple.dt.Xcode",
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92",
        "com.github.atom",
        "com.sublimetext.4",
        "com.apple.Siri",
        "com.apple.Spotlight",
        "com.apple.systempreferences",
        "com.apple.systemsettings"
    ]

    static let defaultTextFocusedBundleIdentifiers: Set<String> = [
        "com.apple.TextEdit",
        "com.apple.Notes",
        "com.apple.mail",
        "com.apple.MobileSMS",
        "ru.keepcoder.Telegram",
        "org.telegram.desktop",
        "com.tdesktop.Telegram",
        "com.tinyspeck.slackmacgap",
        "net.whatsapp.WhatsApp",
        "com.hnc.Discord"
    ]

    static let defaultNormalBundleIdentifiers: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "org.mozilla.firefox"
    ]

    static let defaultBehaviorBundleIdentifiers: Set<String> = defaultExcludedBundleIdentifiers
        .union(defaultStrictBundleIdentifiers)
        .union(defaultTextFocusedBundleIdentifiers)
        .union(defaultNormalBundleIdentifiers)

    var excludedBundleIdentifiers: Set<String>
    var appBehaviorModes: [String: AppBehaviorMode] = [:]

    init(excludedBundleIdentifiers: Set<String>) {
        self.excludedBundleIdentifiers = excludedBundleIdentifiers
    }

    var isFrontmostAppExcluded: Bool {
        guard let bundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return false
        }

        return behaviorMode(for: bundleIdentifier) == .excluded
    }

    var frontmostAppBehaviorMode: AppBehaviorMode {
        guard let bundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return .normal
        }

        return behaviorMode(for: bundleIdentifier)
    }

    func behaviorMode(for bundleIdentifier: String) -> AppBehaviorMode {
        if excludedBundleIdentifiers.contains(bundleIdentifier) {
            return .excluded
        }
        return appBehaviorModes[bundleIdentifier] ?? defaultBehaviorMode(for: bundleIdentifier)
    }

    static func defaultBehaviorMode(for bundleIdentifier: String) -> AppBehaviorMode {
        if defaultExcludedBundleIdentifiers.contains(bundleIdentifier) {
            return .excluded
        }

        if defaultStrictBundleIdentifiers.contains(bundleIdentifier) {
            return .strict
        }

        if defaultTextFocusedBundleIdentifiers.contains(bundleIdentifier) {
            return .textFocused
        }

        if defaultNormalBundleIdentifiers.contains(bundleIdentifier) {
            return .normal
        }

        return .normal
    }

    func defaultBehaviorMode(for bundleIdentifier: String) -> AppBehaviorMode {
        Self.defaultBehaviorMode(for: bundleIdentifier)
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
        case "com.apple.Notes": "Notes"
        case "com.apple.mail": "Mail"
        case "com.apple.MobileSMS": "Messages"
        case "ru.keepcoder.Telegram", "org.telegram.desktop", "com.tdesktop.Telegram": "Telegram"
        case "com.tinyspeck.slackmacgap": "Slack"
        case "net.whatsapp.WhatsApp": "WhatsApp"
        case "com.hnc.Discord": "Discord"
        case "com.apple.Safari": "Safari"
        case "com.google.Chrome": "Google Chrome"
        case "com.microsoft.edgemac": "Microsoft Edge"
        case "com.brave.Browser": "Brave"
        case "org.mozilla.firefox": "Firefox"
        case "com.apple.Siri": "Siri"
        case "com.apple.Spotlight": "Spotlight"
        case "com.apple.finder": "Finder"
        case "com.apple.systempreferences", "com.apple.systemsettings": "System Settings"
        case "com.agilebits.onepassword7", "com.1password.1password": "1Password"
        case "com.bitwarden.desktop": "Bitwarden"
        case "org.keepassxc.keepassxc": "KeePassXC"
        case "com.apple.ScreenSharing": "Screen Sharing"
        case "com.microsoft.rdc.macos": "Microsoft Remote Desktop"
        case "com.philandro.anydesk": "AnyDesk"
        default: bundleIdentifier
        }
    }
}
