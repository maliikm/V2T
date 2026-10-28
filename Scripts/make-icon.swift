import AppKit

// A reproducible text mark, rendered at every native macOS icon size.
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let bounds = NSRect(x: 0, y: 0, width: pixels, height: pixels)
        NSColor.clear.setFill()
        bounds.fill()
        let inset = CGFloat(pixels) * 0.06
        let tile = bounds.insetBy(dx: inset, dy: inset)
        NSColor(srgbRed: 0.10, green: 0.13, blue: 0.19, alpha: 1).setFill()
        NSBezierPath(roundedRect: tile, xRadius: CGFloat(pixels) * 0.19, yRadius: CGFloat(pixels) * 0.19).fill()
        let text = "V2T" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: CGFloat(pixels) * 0.34, weight: .bold),
            .foregroundColor: NSColor.white,
            .kern: -CGFloat(pixels) * 0.012,
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: (CGFloat(pixels) - size.width) / 2,
                              y: (CGFloat(pixels) - size.height) / 2), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            fatalError("Could not render app icon")
        }
        let suffix = scale == 2 ? "@2x" : ""
        try png.write(to: output.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
