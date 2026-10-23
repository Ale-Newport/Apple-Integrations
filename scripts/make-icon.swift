#!/usr/bin/env swift
// Generates the app icon (PNG sizes + Contents.json) into the asset catalog.
// Usage: swift scripts/make-icon.swift [output-appiconset-dir]
import AppKit

let outputDirectory = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "App/Resources/Assets.xcassets/AppIcon.appiconset"

func render(pixels: Int) -> Data {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("cannot create bitmap") }
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let s = CGFloat(pixels)

    // macOS icon grid: the squircle fills 80% of the canvas, centred.
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.2237, yRadius: rect.width * 0.2237)

    // Soft drop shadow.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = s * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.set()
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Background gradient: deep indigo to electric blue.
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.40, green: 0.25, blue: 0.95, alpha: 1),
        NSColor(calibratedRed: 0.13, green: 0.45, blue: 0.98, alpha: 1),
        NSColor(calibratedRed: 0.07, green: 0.74, blue: 0.95, alpha: 1),
    ], atLocations: [0, 0.55, 1], colorSpace: .deviceRGB)!
    gradient.draw(in: path, angle: -58)

    // Subtle top highlight.
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    let highlight = NSGradient(colors: [NSColor.white.withAlphaComponent(0.28), NSColor.white.withAlphaComponent(0)])!
    highlight.draw(in: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // White sparkles glyph.
    let configuration = NSImage.SymbolConfiguration(pointSize: rect.width * 0.5, weight: .semibold)
    if let symbol = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
        let size = symbol.size
        let tinted = NSImage(size: size, flipped: false) { bounds in
            symbol.draw(in: bounds)
            NSColor.white.set()
            bounds.fill(using: .sourceAtop)
            return true
        }
        let target = NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = NSColor(calibratedRed: 0.05, green: 0.1, blue: 0.5, alpha: 0.45)
        glow.shadowBlurRadius = s * 0.025
        glow.shadowOffset = NSSize(width: 0, height: -s * 0.01)
        glow.set()
        tinted.draw(in: target)
        NSGraphicsContext.restoreGraphicsState()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let entries: [(points: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
try FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)

var images: [[String: String]] = []
for entry in entries {
    let pixels = entry.points * entry.scale
    let name = "icon_\(entry.points)x\(entry.points)@\(entry.scale)x.png"
    try render(pixels: pixels).write(to: URL(fileURLWithPath: outputDirectory).appendingPathComponent(name))
    images.append(["filename": name, "idiom": "mac", "scale": "\(entry.scale)x", "size": "\(entry.points)x\(entry.points)"])
}

let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: URL(fileURLWithPath: outputDirectory).appendingPathComponent("Contents.json"))
print("Wrote \(entries.count) icons to \(outputDirectory)")
