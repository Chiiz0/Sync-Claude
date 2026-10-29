import AppKit
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = size * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let w = CGFloat(px)
        let box = NSRect(x: w * 0.08, y: w * 0.08, width: w * 0.84, height: w * 0.84)
        let shape = NSBezierPath(roundedRect: box, xRadius: w * 0.19, yRadius: w * 0.19)
        NSGradient(starting: NSColor(red: 0.86, green: 0.48, blue: 0.34, alpha: 1), ending: NSColor(red: 0.64, green: 0.27, blue: 0.19, alpha: 1))!.draw(in: shape, angle: -90)
        let symbol = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)!.withSymbolConfiguration(.init(pointSize: w * 0.5, weight: .medium))!
        symbol.lockFocus(); NSColor.white.set(); NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop); symbol.unlockFocus()
        symbol.draw(in: NSRect(x: w * 0.23, y: w * 0.23, width: w * 0.54, height: w * 0.54))
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        try rep.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name))
    }
}
