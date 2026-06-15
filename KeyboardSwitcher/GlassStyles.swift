import SwiftUI

extension View {
    func glassPanel() -> some View {
        modifier(GlassPanelModifier())
    }
}

private struct GlassPanelModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.08), radius: 18, y: 8)
    }
}
