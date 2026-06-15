import Foundation

struct KeyStroke: Equatable, Sendable {
    let keyCode: Int64
    let isShifted: Bool
}

struct LayoutCandidate: Equatable {
    let language: KeyboardLanguage
    let text: String
}

enum LayoutEngine {
    static func candidates(for strokes: [KeyStroke], enabledLanguages: Set<KeyboardLanguage>) -> [LayoutCandidate] {
        KeyboardLanguage.allCases
            .filter { enabledLanguages.contains($0) }
            .compactMap { language in
                let text = strokes.compactMap { character(for: $0, language: language) }.joined()
                guard text.count == strokes.count else { return nil }
                return LayoutCandidate(language: language, text: text)
            }
    }

    static func character(for stroke: KeyStroke, language: KeyboardLanguage) -> String? {
        switch language {
        case .english:
            english[stroke.keyCode]?[stroke.isShifted ? 1 : 0]
        case .russian:
            russian[stroke.keyCode]?[stroke.isShifted ? 1 : 0]
        case .hebrew:
            hebrew[stroke.keyCode]?[stroke.isShifted ? 1 : 0]
        }
    }

    static func isWordCharacter(stroke: KeyStroke, currentLanguage: KeyboardLanguage) -> Bool {
        KeyboardLanguage.allCases.contains { language in
            guard let character = character(for: stroke, language: language) else { return false }
            return character.rangeOfCharacter(from: .letters) != nil
        } || character(for: stroke, language: currentLanguage) == "'"
    }

    static func strokes(for text: String) -> [KeyStroke]? {
        guard let language = detectScriptLanguage(for: text) else { return nil }
        return strokes(for: text, language: language)
    }

    static func mixedLayoutStrokes(for text: String) -> [KeyStroke]? {
        var strokes: [KeyStroke] = []
        for character in text {
            let value = String(character)
            guard let stroke = strokeForAnyLayout(character: value) else { return nil }
            strokes.append(stroke)
        }
        return strokes
    }

    static func strokes(for text: String, language: KeyboardLanguage) -> [KeyStroke]? {
        var strokes: [KeyStroke] = []
        for character in text {
            if let stroke = stroke(for: String(character), language: language) {
                strokes.append(stroke)
            } else {
                return nil
            }
        }
        return strokes
    }

    static func detectScriptLanguage(for text: String) -> KeyboardLanguage? {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return nil }

        let russianCount = letters.filter { (0x0400...0x04FF).contains(Int($0.value)) }.count
        let hebrewCount = letters.filter { (0x0590...0x05FF).contains(Int($0.value)) }.count
        let englishCount = letters.filter { ("a"..."z").contains(String($0).lowercased()) }.count

        let counts: [(KeyboardLanguage, Int)] = [
            (.english, englishCount),
            (.russian, russianCount),
            (.hebrew, hebrewCount)
        ]

        return counts.max { $0.1 < $1.1 }?.1 ?? 0 > 0 ? counts.max { $0.1 < $1.1 }?.0 : nil
    }

    private static func stroke(for character: String, language: KeyboardLanguage) -> KeyStroke? {
        let table: [Int64: [String]]
        switch language {
        case .english:
            table = english
        case .russian:
            table = russian
        case .hebrew:
            table = hebrew
        }

        for (keyCode, variants) in table {
            if variants.first == character {
                return KeyStroke(keyCode: keyCode, isShifted: false)
            }
            if variants.dropFirst().first == character {
                return KeyStroke(keyCode: keyCode, isShifted: true)
            }
        }

        return nil
    }

    private static func strokeForAnyLayout(character: String) -> KeyStroke? {
        if ",.;'[]".contains(character), let stroke = stroke(for: character, language: .english) {
            return stroke
        }

        if character.rangeOfCharacter(from: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")) != nil {
            return stroke(for: character, language: .english)
        }

        if character.unicodeScalars.contains(where: { (0x0400...0x04FF).contains(Int($0.value)) }) {
            return stroke(for: character, language: .russian)
        }

        if character.unicodeScalars.contains(where: { (0x0590...0x05FF).contains(Int($0.value)) }) {
            return stroke(for: character, language: .hebrew)
        }

        return KeyboardLanguage.allCases.compactMap { stroke(for: character, language: $0) }.first
    }

    private static let english: [Int64: [String]] = [
        0: ["a", "A"], 1: ["s", "S"], 2: ["d", "D"], 3: ["f", "F"], 4: ["h", "H"],
        5: ["g", "G"], 6: ["z", "Z"], 7: ["x", "X"], 8: ["c", "C"], 9: ["v", "V"],
        11: ["b", "B"], 12: ["q", "Q"], 13: ["w", "W"], 14: ["e", "E"], 15: ["r", "R"],
        16: ["y", "Y"], 17: ["t", "T"], 31: ["o", "O"], 32: ["u", "U"], 34: ["i", "I"],
        35: ["p", "P"], 37: ["l", "L"], 38: ["j", "J"], 40: ["k", "K"], 45: ["n", "N"],
        33: ["[", "{"], 30: ["]", "}"], 41: [";", ":"], 39: ["'", "\""], 42: ["\\", "|"],
        43: [",", "<"], 47: [".", ">"], 44: ["/", "?"], 50: ["`", "~"], 46: ["m", "M"]
    ]

    private static let russian: [Int64: [String]] = [
        0: ["ф", "Ф"], 1: ["ы", "Ы"], 2: ["в", "В"], 3: ["а", "А"], 4: ["р", "Р"],
        5: ["п", "П"], 6: ["я", "Я"], 7: ["ч", "Ч"], 8: ["с", "С"], 9: ["м", "М"],
        11: ["и", "И"], 12: ["й", "Й"], 13: ["ц", "Ц"], 14: ["у", "У"], 15: ["к", "К"],
        16: ["н", "Н"], 17: ["е", "Е"], 31: ["щ", "Щ"], 32: ["г", "Г"], 34: ["ш", "Ш"],
        35: ["з", "З"], 37: ["д", "Д"], 38: ["о", "О"], 40: ["л", "Л"], 45: ["т", "Т"],
        33: ["х", "Х"], 30: ["ъ", "Ъ"], 41: ["ж", "Ж"], 39: ["э", "Э"], 42: ["ё", "Ё"],
        43: ["б", "Б"], 47: ["ю", "Ю"], 44: [".", ","], 50: ["ё", "Ё"], 46: ["ь", "Ь"]
    ]

    private static let hebrew: [Int64: [String]] = [
        0: ["ש", "ש"], 1: ["ד", "ד"], 2: ["ג", "ג"], 3: ["כ", "כ"], 4: ["י", "י"],
        5: ["ע", "ע"], 6: ["ז", "ז"], 7: ["ס", "ס"], 8: ["ב", "ב"], 9: ["ה", "ה"],
        11: ["נ", "נ"], 12: ["/", "/"], 13: ["'", "'"], 14: ["ק", "ק"], 15: ["ר", "ר"],
        16: ["ט", "ט"], 17: ["א", "א"], 31: ["ם", "ם"], 32: ["ו", "ו"], 34: ["ן", "ן"],
        35: ["פ", "פ"], 37: ["ך", "ך"], 38: ["ח", "ח"], 40: ["ל", "ל"], 45: ["מ", "מ"],
        46: ["צ", "צ"]
    ]
}
