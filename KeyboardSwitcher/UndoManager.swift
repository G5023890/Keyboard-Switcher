import AppKit
import Combine
import Foundation

final class CorrectionUndoManager: ObservableObject {
    @Published private(set) var lastCorrection: Correction?
    var onUndo: ((Correction) -> Void)?

    var canUndo: Bool {
        lastCorrection != nil
    }

    func record(original: String, replacement: String, language: KeyboardLanguage, origin: CorrectionOrigin) {
        lastCorrection = Correction(original: original, replacement: replacement, language: language, origin: origin)
    }

    func undoLastCorrection() {
        guard let correction = lastCorrection else { return }
        TextReplacementPerformer.replacePreviousText(characterCount: correction.replacement.count, with: correction.original)
        onUndo?(correction)
        lastCorrection = nil
    }
}

struct Correction: Equatable {
    let original: String
    let replacement: String
    let language: KeyboardLanguage
    let origin: CorrectionOrigin
}

enum CorrectionOrigin: String, Equatable {
    case automatic
    case manual
}
