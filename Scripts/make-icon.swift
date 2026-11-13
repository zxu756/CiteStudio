#!/usr/bin/env swift
import AppKit
import Foundation

let outIconset = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: outIconset, withIntermediateDirectories: true)

let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png")
]

for (px, filename) in sizes {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: px,
        pixelsHigh: px,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let rect = NSRect(x: 0, y: 0, width: px, height: px)
    let pad = CGFloat(px) * 0.08
    let card = rect.insetBy(dx: pad, dy: pad)
    let radius = CGFloat(px) * 0.21

    // Oxford Archival Vellum background with Oxford Navy spine & Burgundy wax seal
    let bgPath = NSBezierPath(roundedRect: card, xRadius: radius, yRadius: radius)
    NSColor(calibratedRed: 0.980, green: 0.973, blue: 0.953, alpha: 1.0).setFill()
    bgPath.fill()

    NSColor(calibratedRed: 0.875, green: 0.859, blue: 0.816, alpha: 1.0).setStroke()
    bgPath.lineWidth = max(1.0, CGFloat(px) * 0.015)
    bgPath.stroke()

    // Left Oxford Navy bookbinding spine
    let spineRect = NSRect(x: card.minX, y: card.minY, width: card.width * 0.22, height: card.height)
    NSGraphicsContext.current?.cgContext.saveGState()
    bgPath.addClip()
    NSColor(calibratedRed: 0.106, green: 0.286, blue: 0.502, alpha: 1.0).setFill()
    spineRect.fill()
    NSGraphicsContext.current?.cgContext.restoreGState()

    // Manuscript horizontal lines
    NSColor(calibratedRed: 0.10, green: 0.09, blue: 0.08, alpha: 0.72).setStroke()
    for i in 0..<4 {
        let y = card.minY + card.height * (0.68 - CGFloat(i) * 0.12)
        let line = NSBezierPath()
        line.move(to: NSPoint(x: card.minX + card.width * 0.32, y: y))
        line.line(to: NSPoint(x: card.minX + card.width * (i == 3 ? 0.66 : 0.84), y: y))
        line.lineWidth = max(1.0, CGFloat(px) * 0.026)
        line.lineCapStyle = .round
        line.stroke()
    }

    // Forest Green verified seal dot
    let sealSize = card.width * 0.20
    let sealRect = NSRect(
        x: card.maxX - sealSize - card.width * 0.12,
        y: card.minY + card.height * 0.14,
        width: sealSize,
        height: sealSize
    )
    NSColor(calibratedRed: 0.114, green: 0.420, blue: 0.282, alpha: 1.0).setFill()
    NSBezierPath(ovalIn: sealRect).fill()

    NSGraphicsContext.restoreGraphicsState()
    let png = rep.representation(using: .png, properties: [:])!
    try png.write(to: outIconset.appendingPathComponent(filename))
}
