import AppKit
import Carbon
import Foundation

enum KeyboardLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case english = "en"
    case russian = "ru"
    case hebrew = "he"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .english: "English"
        case .russian: "Russian"
        case .hebrew: "Hebrew"
        }
    }

    var menuGlyph: String {
        switch self {
        case .english: "A"
        case .russian: "Я"
        case .hebrew: "א"
        }
    }
}

final class InputSourceManager {
    func currentKeyboardLanguage() -> KeyboardLanguage {
        guard
            let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
            let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages)
        else {
            return .english
        }

        let languages = Unmanaged<CFArray>.fromOpaque(value).takeUnretainedValue() as? [String] ?? []

        if languages.contains(where: { $0.hasPrefix("ru") }) {
            return .russian
        }

        if languages.contains(where: { $0.hasPrefix("he") || $0.hasPrefix("iw") }) {
            return .hebrew
        }

        return .english
    }

    @discardableResult
    func selectKeyboardLanguage(_ language: KeyboardLanguage) -> Bool {
        guard let source = selectableInputSource(for: language) else {
            return false
        }

        return TISSelectInputSource(source) == noErr
    }

    private func selectableInputSource(for language: KeyboardLanguage) -> TISInputSource? {
        let properties: [String: Any] = [
            kTISPropertyInputSourceIsSelectCapable as String: true
        ]

        guard
            let sourceList = TISCreateInputSourceList(properties as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource]
        else {
            return nil
        }

        return sourceList.first { source in
            isKeyboardInputSource(source)
                && isEnabled(source)
                && keyboardLanguage(for: source) == language
        }
    }

    private func isKeyboardInputSource(_ source: TISInputSource) -> Bool {
        guard let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceCategory) else {
            return false
        }

        let category = Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
        return category == (kTISCategoryKeyboardInputSource as String)
    }

    private func isEnabled(_ source: TISInputSource) -> Bool {
        guard let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsEnabled) else {
            return false
        }

        return Unmanaged<CFBoolean>.fromOpaque(value).takeUnretainedValue() == kCFBooleanTrue
    }

    private func keyboardLanguage(for source: TISInputSource) -> KeyboardLanguage? {
        guard let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else {
            return nil
        }

        let languages = Unmanaged<CFArray>.fromOpaque(value).takeUnretainedValue() as? [String] ?? []

        if languages.contains(where: { $0.hasPrefix("ru") }) {
            return .russian
        }

        if languages.contains(where: { $0.hasPrefix("he") || $0.hasPrefix("iw") }) {
            return .hebrew
        }

        if languages.contains(where: { $0.hasPrefix("en") }) {
            return .english
        }

        return nil
    }
}
