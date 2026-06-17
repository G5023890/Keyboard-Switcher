import ApplicationServices
import Foundation

enum FocusedInputContextKind: String, Equatable {
    case textField
    case textArea
    case searchField
    case secureTextField
    case comboBox
    case unknown
    case unavailable

    var displayName: String {
        switch self {
        case .textField: "Text Field"
        case .textArea: "Text Area"
        case .searchField: "Search Field"
        case .secureTextField: "Secure Text Field"
        case .comboBox: "Combo Box"
        case .unknown: "Unknown Element"
        case .unavailable: "Unavailable"
        }
    }
}

struct FocusedInputContext: Equatable {
    enum CorrectionPolicy: Equatable {
        case allow
        case strict(reason: String)
        case block(reason: String)
    }

    let kind: FocusedInputContextKind
    let role: String
    let subrole: String

    var correctionPolicy: CorrectionPolicy {
        switch kind {
        case .secureTextField:
            return .block(reason: "secure text field")
        case .searchField:
            return .strict(reason: "search field")
        case .comboBox:
            return .strict(reason: "combo box")
        case .unknown:
            return .strict(reason: "unknown focused element")
        case .textField, .textArea, .unavailable:
            return .allow
        }
    }

    var diagnosticDescription: String {
        let roleText = role.isEmpty ? "none" : role
        let subroleText = subrole.isEmpty ? "none" : subrole
        return "\(kind.displayName) · role \(roleText) · subrole \(subroleText)"
    }

    static let unavailable = FocusedInputContext(kind: .unavailable, role: "", subrole: "")
}

enum FocusedInputContextInspector {
    static func current() -> FocusedInputContext {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElementRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementRef
        ) == .success, let focusedElementRef else {
            return .unavailable
        }

        let focusedElement = focusedElementRef as! AXUIElement
        let role = stringAttribute(kAXRoleAttribute, from: focusedElement)
        let subrole = stringAttribute(kAXSubroleAttribute, from: focusedElement)
        return FocusedInputContext(
            kind: kind(role: role, subrole: subrole),
            role: role,
            subrole: subrole
        )
    }

    static func kind(role: String, subrole: String) -> FocusedInputContextKind {
        let normalizedRole = role.lowercased()
        let normalizedSubrole = subrole.lowercased()

        if normalizedRole.contains("secure") || normalizedSubrole.contains("secure") {
            return .secureTextField
        }
        if normalizedSubrole.contains("search") {
            return .searchField
        }
        if normalizedRole.contains("combobox") || normalizedRole.contains("combo box") {
            return .comboBox
        }
        if normalizedRole.contains("textarea") || normalizedRole.contains("text area") {
            return .textArea
        }
        if normalizedRole.contains("textfield") || normalizedRole.contains("text field") {
            return .textField
        }
        if normalizedRole.isEmpty && normalizedSubrole.isEmpty {
            return .unavailable
        }
        return .unknown
    }

    private static func stringAttribute(_ attribute: String, from element: AXUIElement) -> String {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &valueRef
        ) == .success, let valueRef else {
            return ""
        }

        return valueRef as? String ?? ""
    }
}
