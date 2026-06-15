import Foundation

enum CorrectionSensitivity: String, CaseIterable, Identifiable, Hashable {
    case conservative
    case balanced
    case aggressive
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .conservative: "Conservative"
        case .balanced: "Balanced"
        case .aggressive: "Aggressive"
        case .custom: "Custom"
        }
    }

    var detail: String {
        switch self {
        case .conservative: "Fewer corrections, fewer mistakes"
        case .balanced: "Recommended"
        case .aggressive: "More corrections, may be wrong"
        case .custom: "Manual threshold"
        }
    }

    var threshold: Double? {
        switch self {
        case .conservative: 0.72
        case .balanced: 0.62
        case .aggressive: 0.55
        case .custom: nil
        }
    }

    static func closest(to threshold: Double) -> CorrectionSensitivity {
        let presets: [CorrectionSensitivity] = [.conservative, .balanced, .aggressive]
        if let match = presets.first(where: { abs(($0.threshold ?? 0) - threshold) < 0.005 }) {
            return match
        }
        return .custom
    }
}

enum CorrectionOriginFilter: String, CaseIterable, Identifiable, Hashable {
    case all
    case automaticOnly

    var id: String { rawValue }
}

struct KeyboardMonitorPreferences: Equatable {
    var switchInputSourceAfterCorrection = true
    var playSoundWhenLayoutCorrected = true
    var soundVolume = 0.75
    var playSoundOnlyForAutomaticCorrections = false

    func shouldSwitchInputSource() -> Bool {
        switchInputSourceAfterCorrection
    }

    func shouldPlaySound(origin: CorrectionOrigin) -> Bool {
        guard playSoundWhenLayoutCorrected else { return false }
        guard !playSoundOnlyForAutomaticCorrections || origin == .automatic else { return false }
        return true
    }
}

enum ExclusionPreset: String, CaseIterable, Identifiable, Hashable {
    case passwordManagers
    case developerTools
    case remoteDesktop

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .passwordManagers: "Password Managers"
        case .developerTools: "Developer Tools"
        case .remoteDesktop: "Remote Desktop & Screen Sharing"
        }
    }

    var detail: String {
        switch self {
        case .passwordManagers: "1Password, Bitwarden, KeePassXC"
        case .developerTools: "Terminal, iTerm, Xcode, Cursor, VS Code, Sublime Text"
        case .remoteDesktop: "Screen Sharing, Microsoft Remote Desktop, AnyDesk"
        }
    }

    var bundleIdentifiers: Set<String> {
        switch self {
        case .passwordManagers:
            return [
                "com.agilebits.onepassword7",
                "com.1password.1password",
                "com.bitwarden.desktop",
                "org.keepassxc.keepassxc"
            ]
        case .developerTools:
            return [
                "com.apple.Terminal",
                "com.googlecode.iterm2",
                "com.apple.dt.Xcode",
                "com.microsoft.VSCode",
                "com.todesktop.230313mzl4w4u92",
                "com.github.atom",
                "com.sublimetext.4"
            ]
        case .remoteDesktop:
            return [
                "com.apple.ScreenSharing",
                "com.microsoft.rdc.macos",
                "com.philandro.anydesk"
            ]
        }
    }
}
