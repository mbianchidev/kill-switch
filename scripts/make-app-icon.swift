import AppKit
import Foundation

enum IconError: LocalizedError {
    case generation(String)

    var errorDescription: String? {
        switch self {
        case .generation(let message): return message
        }
    }
}

func renderIcon(pixels: Int, to destination: URL) throws {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw IconError.generation("Could not create a \(pixels)-pixel app icon.")
    }

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)

    NSColor(calibratedRed: 0.19, green: 0.12, blue: 0.29, alpha: 1).setFill()
    NSBezierPath(
        roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880),
        xRadius: 196,
        yRadius: 196
    ).fill()

    guard let symbol = NSImage(systemSymbolName: "bolt.slash", accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.white])) else {
        throw IconError.generation("The KillSwitch bolt symbol is unavailable.")
    }
    symbol.draw(in: NSRect(x: 242, y: 202, width: 540, height: 620))

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw IconError.generation("Could not encode the \(pixels)-pixel app icon.")
    }
    try png.write(to: destination)
}

do {
    guard CommandLine.arguments.count == 2 else {
        throw IconError.generation("Usage: swift scripts/make-app-icon.swift <output.iconset>")
    }
    let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for points in [16, 32, 128, 256, 512] {
        try renderIcon(
            pixels: points,
            to: output.appendingPathComponent("icon_\(points)x\(points).png")
        )
        try renderIcon(
            pixels: points * 2,
            to: output.appendingPathComponent("icon_\(points)x\(points)@2x.png")
        )
    }
} catch {
    fputs("App icon generation failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
