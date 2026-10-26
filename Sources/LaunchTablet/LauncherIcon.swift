import AppKit

/// 用原生绘图生成应用图标，保持任意分辨率清晰；同一份绘图用于 Dock 和 .icns 打包。
enum LauncherIcon {
    static func image(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            draw(in: rect)
            return true
        }
    }

    private static func draw(in rect: NSRect) {
        let size = rect.width
        let background = NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.055, dy: size * 0.055), xRadius: size * 0.21, yRadius: size * 0.21)
        NSGradient(starting: NSColor(calibratedRed: 0.31, green: 0.35, blue: 0.91, alpha: 1), ending: NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.35, alpha: 1))?.draw(in: background, angle: -55)
        let colors: [NSColor] = [.systemPink, .systemOrange, .systemYellow, .systemPurple, .white, .systemGreen, .systemIndigo, .systemBlue, .systemTeal]
        let tile = size * 0.155
        let gap = size * 0.058
        let left = (size - tile * 3 - gap * 2) / 2
        for row in 0..<3 {
            for column in 0..<3 {
                let frame = NSRect(x: left + CGFloat(column) * (tile + gap), y: left + CGFloat(2 - row) * (tile + gap), width: tile, height: tile)
                let path = NSBezierPath(roundedRect: frame, xRadius: size * 0.039, yRadius: size * 0.039)
                let color = colors[row * 3 + column]
                NSGradient(starting: color.blended(withFraction: 0.23, of: .white) ?? color, ending: color)?.draw(in: path, angle: -90)
            }
        }
    }

    static func export(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = size * scale
                guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                      let context = NSGraphicsContext(bitmapImageRep: bitmap) else { continue }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
                context.flushGraphics()
                NSGraphicsContext.restoreGraphicsState()
                let suffix = scale == 2 ? "@2x" : ""
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    try png.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
                }
            }
        }
    }
}
