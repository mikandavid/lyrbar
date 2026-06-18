import AppKit

enum AppAccentColor {
    static let current: NSColor = {
        guard let screen = NSScreen.main,
              let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return .controlAccentColor
        }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        let stepX = max(1, bitmap.pixelsWide / 24)
        let stepY = max(1, bitmap.pixelsHigh / 24)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var count: CGFloat = 0

        for y in stride(from: 0, to: bitmap.pixelsHigh, by: stepY) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: stepX) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                var hue: CGFloat = 0
                var saturation: CGFloat = 0
                var brightness: CGFloat = 0
                var alpha: CGFloat = 0
                color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
                guard saturation > 0.18, brightness > 0.18, brightness < 0.9 else { continue }
                red += color.redComponent
                green += color.greenComponent
                blue += color.blueComponent
                count += 1
            }
        }

        guard count > 0 else { return .controlAccentColor }
        let average = NSColor(srgbRed: red / count, green: green / count, blue: blue / count, alpha: 1)
        guard let color = average.usingColorSpace(.sRGB) else { return .controlAccentColor }
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return NSColor(calibratedHue: hue,
                       saturation: max(0.55, saturation),
                       brightness: min(0.85, max(0.48, brightness)),
                       alpha: 1)
    }()
}
