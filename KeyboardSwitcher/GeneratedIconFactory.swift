import AppKit
import Foundation

enum GeneratedIconFactory {
    static func makeAppIcon(size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()

        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        let cornerRadius = size * 0.22
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.06, dy: size * 0.06), xRadius: cornerRadius, yRadius: cornerRadius)

        NSGradient(colors: [
            NSColor.systemTeal.withAlphaComponent(0.95),
            NSColor.systemBlue.withAlphaComponent(0.92),
            NSColor.systemIndigo.withAlphaComponent(0.9)
        ])?.draw(in: path, angle: 315)

        NSColor.white.withAlphaComponent(0.32).setStroke()
        path.lineWidth = size * 0.012
        path.stroke()

        let keyboardRect = rect.insetBy(dx: size * 0.17, dy: size * 0.28)
        let keyboardPath = NSBezierPath(roundedRect: keyboardRect, xRadius: size * 0.045, yRadius: size * 0.045)
        NSColor.white.withAlphaComponent(0.72).setFill()
        keyboardPath.fill()

        let keys = ["A", "Я", "א"]
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size * 0.15, weight: .bold),
            .foregroundColor: NSColor.black.withAlphaComponent(0.72)
        ]

        for (index, key) in keys.enumerated() {
            let keySize = size * 0.18
            let x = keyboardRect.minX + size * 0.09 + CGFloat(index) * size * 0.2
            let y = keyboardRect.midY - keySize * 0.5
            let keyRect = NSRect(x: x, y: y, width: keySize, height: keySize)
            NSColor.white.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: keyRect, xRadius: size * 0.025, yRadius: size * 0.025).fill()
            let attributed = NSAttributedString(string: key, attributes: attributes)
            attributed.draw(in: keyRect.insetBy(dx: 0, dy: keySize * 0.12))
        }

        image.unlockFocus()
        return image
    }
}
