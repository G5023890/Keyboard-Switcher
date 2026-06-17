import SwiftUI

enum SettingsDesign {
    enum spacing {
        static let card: CGFloat = 20
        static let page: CGFloat = 22
        static let row: CGFloat = 12
    }

    enum cornerRadius {
        static let card: CGFloat = 18
        static let row: CGFloat = 12
    }

    static func windowBackground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color(hex: 0x111214) : Color(hex: 0xF7F7F8)
    }

    static func sidebarBackground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color(hex: 0x18191B) : Color(hex: 0xECEDEF)
    }

    static func cardBackground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color(hex: 0x242528).opacity(0.92) : Color.white.opacity(0.95)
    }

    static func rowBackground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.white.opacity(0.045) : Color.black.opacity(0.035)
    }

    static func cardBorder(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
    }
}

extension View {
    func glassPanel() -> some View {
        modifier(GlassPanelModifier())
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }
}

private struct GlassPanelModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: SettingsDesign.cornerRadius.card, style: .continuous)
                    .fill(SettingsDesign.cardBackground(for: colorScheme))
            }
            .overlay {
                RoundedRectangle(cornerRadius: SettingsDesign.cornerRadius.card, style: .continuous)
                    .strokeBorder(SettingsDesign.cardBorder(for: colorScheme), lineWidth: 1)
            }
            .shadow(
                color: .black.opacity(colorScheme == .dark ? 0.14 : 0.08),
                radius: 18,
                x: 0,
                y: 8
            )
    }
}
