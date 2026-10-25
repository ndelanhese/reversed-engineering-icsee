// Original geometric artwork. Regenerate with: swift Tools/GenerateIcon.swift
import AppKit
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let assets = root.appendingPathComponent("Assets")
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: 1024, height: 1024).fill(using: .copy)
let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 202, yRadius: 202)
NSGradient(starting: NSColor(calibratedRed: 0.035, green: 0.07, blue: 0.15, alpha: 1),
    ending: NSColor(calibratedRed: 0.09, green: 0.22, blue: 0.39, alpha: 1))!.draw(in: tile, angle: 90)

func disk(_ rect: NSRect, color: NSColor) {
    color.setFill()
    NSBezierPath(ovalIn: rect).fill()
}
disk(NSRect(x: 245, y: 245, width: 534, height: 534), color: NSColor(calibratedWhite: 0.98, alpha: 1))
disk(NSRect(x: 276, y: 276, width: 472, height: 472), color: NSColor(calibratedRed: 0.10, green: 0.35, blue: 0.60, alpha: 1))
let lens = NSBezierPath(ovalIn: NSRect(x: 326, y: 326, width: 372, height: 372))
NSGradient(starting: NSColor(calibratedRed: 0.10, green: 0.74, blue: 0.91, alpha: 1),
    ending: NSColor(calibratedRed: 0.07, green: 0.22, blue: 0.56, alpha: 1))!.draw(in: lens, angle: -45)
disk(NSRect(x: 412, y: 412, width: 200, height: 200), color: NSColor(calibratedRed: 0.025, green: 0.10, blue: 0.23, alpha: 1))
disk(NSRect(x: 453, y: 527, width: 46, height: 46), color: NSColor(calibratedWhite: 1, alpha: 0.78))

// A single return arrow around the lens makes the reverse-engineering mark readable at small sizes.
let arc = NSBezierPath()
arc.appendArc(withCenter: NSPoint(x: 512, y: 512), radius: 340, startAngle: 35, endAngle: 155)
arc.lineWidth = 45
arc.lineCapStyle = .round
NSColor(calibratedRed: 0.37, green: 0.86, blue: 0.98, alpha: 1).setStroke()
arc.stroke()
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 173, y: 602))
arrow.line(to: NSPoint(x: 199, y: 748))
arrow.line(to: NSPoint(x: 301, y: 643))
arrow.close()
NSColor(calibratedRed: 0.37, green: 0.86, blue: 0.98, alpha: 1).setFill()
arrow.fill()
disk(NSRect(x: 740, y: 209, width: 92, height: 92), color: NSColor(calibratedRed: 0.035, green: 0.10, blue: 0.19, alpha: 1))
disk(NSRect(x: 756, y: 225, width: 60, height: 60), color: NSColor(calibratedRed: 0.34, green: 0.91, blue: 0.66, alpha: 1))
NSGraphicsContext.restoreGraphicsState()
let png = assets.appendingPathComponent("AppIcon.png")
try bitmap.representation(using: .png, properties: [:])!.write(to: png)

let iconset = root.appendingPathComponent(".build/AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
func run(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
}
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try run("/usr/bin/sips", ["-z", String(size * scale), String(size * scale), png.path,
            "--out", iconset.appendingPathComponent(name).path])
    }
}
try run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", assets.appendingPathComponent("AppIcon.icns").path])
print("Generated original AppIcon.png and AppIcon.icns")
