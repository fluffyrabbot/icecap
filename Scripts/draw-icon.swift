// Draws icecap's application icon into Resources/AppIcon.icns.
// Usage: swift Scripts/draw-icon.swift
// The icon follows the macOS layout grid: a rounded square 824 points wide, centred on a
// 1,024-point canvas, showing a mountain whose peak is capped with ice.
import AppKit

let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
    NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
}

/// Draws the icon in a 1,024-point coordinate space, origin bottom left.
func drawIcon() {
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.shadowBlurRadius = 20
    shadow.set()
    color(40, 90, 160).setFill()
    tilePath.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    tilePath.addClip()
    NSGradient(starting: color(120, 190, 245), ending: color(30, 70, 150))!
        .draw(in: tile, angle: -90)

    // The mountain.
    let peak = NSPoint(x: 512, y: 720)
    let mountain = NSBezierPath()
    mountain.move(to: NSPoint(x: 60, y: 200))
    mountain.line(to: NSPoint(x: 330, y: 500))
    mountain.line(to: NSPoint(x: 400, y: 450))
    mountain.line(to: peak)
    mountain.line(to: NSPoint(x: 700, y: 520))
    mountain.line(to: NSPoint(x: 760, y: 560))
    mountain.line(to: NSPoint(x: 964, y: 200))
    mountain.line(to: NSPoint(x: 964, y: 60))
    mountain.line(to: NSPoint(x: 60, y: 60))
    mountain.close()
    NSGradient(starting: color(60, 80, 120), ending: color(25, 35, 65))!
        .draw(in: mountain, angle: -90)

    // The ice cap: the mountain above a jagged snow line.
    NSGraphicsContext.saveGraphicsState()
    mountain.addClip()
    let cap = NSBezierPath()
    cap.move(to: NSPoint(x: 380, y: 520))
    cap.line(to: NSPoint(x: 458, y: 530))
    cap.line(to: NSPoint(x: 490, y: 590))
    cap.line(to: NSPoint(x: 530, y: 548))
    cap.line(to: NSPoint(x: 568, y: 600))
    cap.line(to: NSPoint(x: 600, y: 560))
    cap.line(to: NSPoint(x: 660, y: 580))
    cap.line(to: NSPoint(x: 660, y: 760))
    cap.line(to: NSPoint(x: 380, y: 760))
    cap.close()
    NSGradient(starting: .white, ending: color(205, 230, 250))!.draw(in: cap, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()
}

func writeImage(pixels: Int, name: String) throws {
    let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    representation.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
    let scale = CGFloat(pixels) / 1024
    NSGraphicsContext.current!.cgContext.scaleBy(x: scale, y: scale)
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    try representation.representation(using: .png, properties: [:])!
        .write(to: iconset.appendingPathComponent(name))
}

for points in [16, 32, 128, 256, 512] {
    try writeImage(pixels: points, name: "icon_\(points)x\(points).png")
    try writeImage(pixels: points * 2, name: "icon_\(points)x\(points)@2x.png")
}

let output = repository.appendingPathComponent("Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["--convert", "icns", "--output", output.path, iconset.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
try writeImage(pixels: 1024, name: "preview.png")
print(output.path)
print(iconset.appendingPathComponent("preview.png").path)
