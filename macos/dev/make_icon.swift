// Draws Herb's Terminal's app icon in the style of the macOS Terminal icon: a dark glass tile with a centered
// prompt that reads "> HT_". Writes macos/Assets/HerbsTerminal.png (1024 px) and macos/Assets/HerbsTerminal.icns.
//
//   swift macos/dev/make_icon.swift
import AppKit

let size: CGFloat = 1024
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// A rounded stroke, the weight of the prompt's chevron.
func stroke(_ points: [[NSPoint]], width: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    for line in points {
        path.move(to: line[0])
        line.dropFirst().forEach(path.line(to:))
    }
    path.lineWidth = width
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    return path
}

let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

    // Soft shadow under the tile.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x000000, 0.4)
    shadow.shadowBlurRadius = 30
    shadow.shadowOffset = NSSize(width: 0, height: 14)
    shadow.set()
    color(0x111113).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    // Near-black glass, a touch lighter at the top.
    NSGradient(colorsAndLocations: (color(0x2B2B2F), 0), (color(0x18181B), 0.45), (color(0x0C0C0E), 1))!
        .draw(in: tile, angle: 90)
    NSGraphicsContext.restoreGraphicsState()

    // The prompt: a chevron, "HT" in the same rounded strokes, and the cursor, all in one color. It is laid out
    // from x 212 to 834 and y 278 to 466, then moved to the middle of the tile.
    NSGraphicsContext.saveGraphicsState()
    let centering = NSAffineTransform()
    centering.translateX(by: 512 - (212 + 834) / 2, yBy: 512 - (278 + 466) / 2)
    centering.concat()
    let weight: CGFloat = 36
    let top: CGFloat = 296, bottom: CGFloat = 448, middle = (top + bottom) / 2
    let chevron = stroke([[NSPoint(x: 230, y: top + 6), NSPoint(x: 340, y: middle), NSPoint(x: 230, y: bottom - 6)]], width: weight)
    let letterH = stroke([[NSPoint(x: 406, y: top), NSPoint(x: 406, y: bottom)],
                          [NSPoint(x: 516, y: top), NSPoint(x: 516, y: bottom)],
                          [NSPoint(x: 406, y: middle), NSPoint(x: 516, y: middle)]], width: weight)
    let letterT = stroke([[NSPoint(x: 568, y: top), NSPoint(x: 684, y: top)],
                          [NSPoint(x: 626, y: top), NSPoint(x: 626, y: bottom)]], width: weight)
    NSGraphicsContext.saveGraphicsState()
    let lift = NSShadow()
    lift.shadowColor = color(0x000000, 0.45)
    lift.shadowBlurRadius = 6
    lift.shadowOffset = NSSize(width: 0, height: 3)
    lift.set()
    color(0xF5F5F7).setStroke()
    [chevron, letterH, letterT].forEach { $0.stroke() }
    // The cursor, after "HT".
    color(0xF5F5F7).setFill()
    NSBezierPath(roundedRect: NSRect(x: 722, y: bottom - 22, width: 112, height: 26), xRadius: 8, yRadius: 8).fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()

    // The glass edge: bright along the top, fading down the sides.
    NSGraphicsContext.saveGraphicsState()
    let rim = NSBezierPath(roundedRect: tile.insetBy(dx: 2, dy: 2), xRadius: 183, yRadius: 183)
    rim.lineWidth = 4
    let ring = rim.copy() as! NSBezierPath
    ring.lineWidth = 4
    let outline = NSBezierPath(cgPath: ring.cgPath.copy(strokingWithWidth: 4, lineCap: .round, lineJoin: .round, miterLimit: 1))
    outline.addClip()
    NSGradient(colorsAndLocations: (color(0xFFFFFF, 0.55), 0), (color(0xFFFFFF, 0.12), 0.35), (color(0xFFFFFF, 0.05), 0.7),
               (color(0xFFFFFF, 0.18), 1))!.draw(in: tile, angle: 90)
    NSGraphicsContext.restoreGraphicsState()
    return true
}

func png(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let assets = root.appendingPathComponent("Assets")
try png(1024).write(to: assets.appendingPathComponent("HerbsTerminal.png"))
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("HerbsTerminal-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", assets.appendingPathComponent("HerbsTerminal.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(iconutil.terminationStatus == 0 ? "Wrote macos/Assets/HerbsTerminal.png and macos/Assets/HerbsTerminal.icns" : "iconutil failed")
