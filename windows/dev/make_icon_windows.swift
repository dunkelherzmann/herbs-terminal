// Draws Herb's Terminal's Windows icon in the style of the stock Windows terminal icons: a dark window with a
// lighter title bar and the "> HT_" prompt, drawn with the same strokes as the Mac icon. Writes
// windows/Resources/HerbsTerminal.ico (16 to 256 px, PNG-compressed entries).
//
//   swift windows/dev/make_icon_windows.swift
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let canvas: CGFloat = 256

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

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

/// The icon at `pixels` px. Small sizes get a heavier prompt and no shadow, so they stay crisp.
func draw(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: canvas, height: canvas)
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    // Top-left origin, like the Mac script's flipped image.
    let flip = NSAffineTransform()
    flip.translateX(by: 0, yBy: canvas)
    flip.scaleX(by: 1, yBy: -1)
    flip.concat()

    let small = pixels <= 32
    let tile = NSRect(x: 12, y: 24, width: 232, height: 208)
    let radius: CGFloat = small ? 20 : 26
    let shape = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)

    if !small {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = color(0x000000, 0.35)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.set()
        color(0x1B1B1B).setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    // The screen: dark, a little lighter at the top. Then the title bar.
    NSGradient(colorsAndLocations: (color(0x2C2C2C), 0), (color(0x1A1A1A), 1))!.draw(in: tile, angle: -90)
    let bar = NSRect(x: tile.minX, y: tile.minY, width: tile.width, height: small ? 44 : 38)
    NSGradient(colorsAndLocations: (color(0x4C4C4C), 0), (color(0x3E3E3E), 1))!.draw(in: bar, angle: -90)
    color(0x000000, 0.35).setFill()
    NSRect(x: tile.minX, y: bar.maxY, width: tile.width, height: small ? 4 : 2).fill()
    NSGraphicsContext.restoreGraphicsState()

    // The prompt, "> HT_", centered in the screen below the title bar. Laid out like the Mac icon's (x 212-834,
    // y 278-466 at 1024 px), scaled to fit.
    NSGraphicsContext.saveGraphicsState()
    let screenMiddle = NSPoint(x: tile.midX, y: (bar.maxY + tile.maxY) / 2 + 2)
    let scale: CGFloat = small ? 0.30 : 0.29
    let place = NSAffineTransform()
    place.translateX(by: screenMiddle.x, yBy: screenMiddle.y)
    place.scale(by: scale)
    place.translateX(by: -(212 + 834) / 2, yBy: -(278 + 466) / 2)
    place.concat()
    let weight: CGFloat = small ? 52 : 38
    let top: CGFloat = 296, bottom: CGFloat = 448, middle = (top + bottom) / 2
    let chevron = stroke([[NSPoint(x: 230, y: top + 6), NSPoint(x: 340, y: middle), NSPoint(x: 230, y: bottom - 6)]], width: weight)
    let letterH = stroke([[NSPoint(x: 406, y: top), NSPoint(x: 406, y: bottom)],
                          [NSPoint(x: 516, y: top), NSPoint(x: 516, y: bottom)],
                          [NSPoint(x: 406, y: middle), NSPoint(x: 516, y: middle)]], width: weight)
    let letterT = stroke([[NSPoint(x: 568, y: top), NSPoint(x: 684, y: top)],
                          [NSPoint(x: 626, y: top), NSPoint(x: 626, y: bottom)]], width: weight)
    color(0xF3F3F3).setStroke()
    [chevron, letterH, letterT].forEach { $0.stroke() }
    color(0xF3F3F3).setFill()
    let cursorHeight: CGFloat = small ? 40 : 28
    NSBezierPath(roundedRect: NSRect(x: 722, y: bottom - cursorHeight + 4, width: 112, height: cursorHeight), xRadius: 8, yRadius: 8).fill()
    NSGraphicsContext.restoreGraphicsState()

    // A thin light edge, as Windows 11 icons have.
    color(0xFFFFFF, small ? 0.10 : 0.14).setStroke()
    let edge = NSBezierPath(roundedRect: tile.insetBy(dx: 1, dy: 1), xRadius: radius - 1, yRadius: radius - 1)
    edge.lineWidth = small ? 4 : 2
    edge.stroke()

    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// An .ico file: ICONDIR, one ICONDIRENTRY per size, then each image as PNG (Windows Vista and later read these).
let sizes = [16, 20, 24, 32, 40, 48, 64, 256]
let images = sizes.map { draw(pixels: $0) }
var ico = Data()
func append16(_ value: Int) { ico.append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)]) }
func append32(_ value: Int) { append16(value & 0xFFFF); append16(value >> 16 & 0xFFFF) }
append16(0); append16(1); append16(sizes.count)
var offset = 6 + 16 * sizes.count
for (size, image) in zip(sizes, images) {
    ico.append(UInt8(size >= 256 ? 0 : size)); ico.append(UInt8(size >= 256 ? 0 : size))
    ico.append(0); ico.append(0)
    append16(1); append16(32)
    append32(image.count); append32(offset)
    offset += image.count
}
images.forEach { ico.append($0) }

let folder = root.appendingPathComponent("windows/Resources")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
try ico.write(to: folder.appendingPathComponent("HerbsTerminal.ico"))
print("Wrote windows/Resources/HerbsTerminal.ico (\(sizes.map(String.init).joined(separator: ", ")) px)")
