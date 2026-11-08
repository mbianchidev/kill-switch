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

func makeGradient(_ colors: [NSColor]) throws -> CGGradient {
    guard let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: colors.map(\.cgColor) as CFArray,
        locations: nil
    ) else {
        throw IconError.generation("Could not create the app icon's color gradient.")
    }
    return gradient
}

func fillGradient(_ path: CGPath, gradient: CGGradient, in context: CGContext) {
    context.saveGState()
    defer { context.restoreGState() }
    context.addPath(path)
    context.clip()
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 260, y: 820),
        end: CGPoint(x: 730, y: 200),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
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
    let drawing = context.cgContext
    drawing.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    drawing.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    drawing.setShouldAntialias(true)

    let tile = CGPath(
        roundedRect: CGRect(x: 72, y: 72, width: 880, height: 880),
        cornerWidth: 196, cornerHeight: 196, transform: nil
    )
    let surface = try makeGradient([
        NSColor(calibratedRed: 0.22, green: 0.15, blue: 0.32, alpha: 1),
        NSColor(calibratedRed: 0.08, green: 0.065, blue: 0.13, alpha: 1),
        NSColor(calibratedRed: 0.12, green: 0.08, blue: 0.22, alpha: 1)
    ])
    fillGradient(tile, gradient: surface, in: drawing)

    if pixels >= 64 {
        drawing.saveGState()
        drawing.addPath(tile)
        drawing.clip()
        let light = try makeGradient([
            NSColor(calibratedRed: 0.65, green: 0.40, blue: 0.94, alpha: 0.20),
            NSColor(calibratedRed: 0.65, green: 0.40, blue: 0.94, alpha: 0)
        ])
        drawing.drawRadialGradient(
            light, startCenter: CGPoint(x: 480, y: 800), startRadius: 0,
            endCenter: CGPoint(x: 480, y: 800), endRadius: 520, options: []
        )
        drawing.restoreGState()
        drawing.addPath(tile)
        drawing.setLineWidth(2)
        drawing.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.16).cgColor)
        drawing.strokePath()
    }

    let circuit = CGMutablePath()
    circuit.addArc(
        center: CGPoint(x: 512, y: 502), radius: 237,
        startAngle: 140 * .pi / 180, endAngle: 400 * .pi / 180, clockwise: false
    )
    let ring = circuit.copy(strokingWithWidth: 76, lineCap: .round, lineJoin: .round, miterLimit: 10)
    let violet = try makeGradient([
        NSColor(calibratedRed: 0.81, green: 0.69, blue: 1, alpha: 1),
        NSColor(calibratedRed: 0.60, green: 0.36, blue: 0.91, alpha: 1),
        NSColor(calibratedRed: 0.41, green: 0.22, blue: 0.69, alpha: 1)
    ])
    if pixels >= 64 {
        drawing.saveGState()
        drawing.addPath(tile)
        drawing.clip()
        let scale = CGFloat(pixels) / 1024
        drawing.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 18 * scale,
                          color: NSColor(calibratedWhite: 0, alpha: 0.50).cgColor)
        drawing.addPath(ring)
        drawing.setFillColor(NSColor(calibratedRed: 0.31, green: 0.16, blue: 0.50, alpha: 1).cgColor)
        drawing.fillPath()
        drawing.restoreGState()
    }
    fillGradient(ring, gradient: violet, in: drawing)

    let bolt = CGMutablePath()
    bolt.move(to: CGPoint(x: 564, y: 808))
    for point in [
        CGPoint(x: 365, y: 497), CGPoint(x: 496, y: 497),
        CGPoint(x: 456, y: 252), CGPoint(x: 663, y: 565),
        CGPoint(x: 536, y: 565)
    ] {
        bolt.addLine(to: point)
    }
    bolt.closeSubpath()
    let cut = CGMutablePath()
    cut.move(to: CGPoint(x: 340, y: 449))
    cut.addLine(to: CGPoint(x: 690, y: 608))
    let interruption = cut.copy(strokingWithWidth: 50, lineCap: .butt, lineJoin: .miter, miterLimit: 10)
    let mask = CGMutablePath()
    mask.addRect(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    mask.addPath(interruption)

    drawing.saveGState()
    drawing.addPath(bolt)
    drawing.clip()
    // Subtract the interruption from the bolt rather than painting a second glyph.
    drawing.addPath(mask)
    drawing.clip(using: .evenOdd)
    let porcelain = try makeGradient([
        NSColor(calibratedRed: 1, green: 0.98, blue: 1, alpha: 1),
        NSColor(calibratedRed: 0.88, green: 0.82, blue: 0.97, alpha: 1)
    ])
    drawing.drawLinearGradient(
        porcelain, start: CGPoint(x: 440, y: 800), end: CGPoint(x: 610, y: 250),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    drawing.restoreGState()

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
