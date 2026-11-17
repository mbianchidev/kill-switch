import AppKit
import SystemMetricsCore

/// The menu-bar icon: the KillSwitch bolt and, when the startup volume's capacity is known, a
/// thin vertical gauge filled from the bottom to its used share. It is a template image, so the
/// menu bar draws it in the right color for light, dark, and highlighted states.
enum StatusItemIcon {
    static let height: CGFloat = 18
    private static let gaugeWidth: CGFloat = 5
    private static let gaugeHeight: CGFloat = 13
    private static let spacing: CGFloat = 2.5

    static func image(usedFraction: Double?) -> NSImage {
        let symbol = NSImage(systemSymbolName: "bolt.slash", accessibilityDescription: nil)
        let symbolSize = symbol?.size ?? NSSize(width: 16, height: 16)
        let fraction = usedFraction.map { min(max($0, 0), 1) }
        let width = ceil(symbolSize.width + (fraction == nil ? 0 : spacing + gaugeWidth))
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            symbol?.draw(in: NSRect(x: 0, y: (height - symbolSize.height) / 2, width: symbolSize.width, height: symbolSize.height))
            guard let fraction else { return true }
            let outline = NSRect(x: symbolSize.width + spacing, y: (height - gaugeHeight) / 2, width: gaugeWidth, height: gaugeHeight)
            NSColor.black.set()
            let border = NSBezierPath(roundedRect: outline.insetBy(dx: 0.5, dy: 0.5), xRadius: 1.5, yRadius: 1.5)
            border.lineWidth = 1
            border.stroke()
            // No gap between border and fill: a sub-point gap blurs on 1x displays and makes a
            // nearly full gauge read as hollow.
            let inner = outline.insetBy(dx: 1, dy: 1)
            NSBezierPath(rect: NSRect(x: inner.minX, y: inner.minY, width: inner.width, height: inner.height * fraction)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = fraction.map { "KillSwitch, startup disk \(percent($0))% full" } ?? "KillSwitch"
        return image
    }

    static func percent(_ fraction: Double) -> Int {
        Int((min(max(fraction, 0), 1) * 100).rounded())
    }

    /// The status item's tooltip; an unreadable capacity is reported, never estimated.
    static func toolTip(for volume: SystemVolume?) -> String {
        guard let volume, let used = volume.usedBytes, let total = volume.totalBytes, let fraction = volume.usedFraction else {
            return "KillSwitch\nStartup disk capacity is unavailable."
        }
        return "KillSwitch\n\(volume.name): \(formatBytes(used)) of \(formatBytes(total)) used (\(percent(fraction))%)"
    }
}
