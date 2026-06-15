import AppKit

enum IconProvider {
    static func appIcon(size: CGFloat = 512) -> NSImage {
        if let image = NSImage(named: "KeyboardSwitcherIcon_1024_whitebg") {
            image.size = NSSize(width: size, height: size)
            return image
        }

        if let image = NSImage(named: "AppIcon") {
            image.size = NSSize(width: size, height: size)
            return image
        }

        return GeneratedIconFactory.makeAppIcon(size: size)
    }
}
