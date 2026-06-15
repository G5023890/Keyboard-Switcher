import Foundation

enum MenuBarIconStyle: String, CaseIterable, Identifiable, Hashable {
    case glyphs
    case flags
    case minimal

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .glyphs: "Letters"
        case .flags: "Flags"
        case .minimal: "Minimal"
        }
    }

    var description: String {
        switch self {
        case .glyphs: "A, Я, א"
        case .flags: "🇺🇸, 🇷🇺, 🇮🇱"
        case .minimal: "●"
        }
    }
}

extension KeyboardLanguage {
    var flagGlyph: String {
        switch self {
        case .english: "🇺🇸"
        case .russian: "🇷🇺"
        case .hebrew: "🇮🇱"
        }
    }

    func menuBarIcon(for style: MenuBarIconStyle) -> String {
        switch style {
        case .glyphs:
            menuGlyph
        case .flags:
            flagGlyph
        case .minimal:
            "●"
        }
    }
}
