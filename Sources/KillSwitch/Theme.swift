import SwiftUI

enum SamplingIntervals {
    static let standard: [(label: String, seconds: Int)] = [
        ("30s", 30),
        ("1m", 60),
        ("5m", 300),
        ("10m", 600),
        ("15m", 900),
        ("30m", 1_800),
        ("60m", 3_600)
    ]
}

/// Shared visual styling so every tab keeps the dark, translucent look.
enum Theme {
    static let background = LinearGradient(
        colors: [
            Color(red: 0.15, green: 0.1, blue: 0.25),
            Color(red: 0.2, green: 0.12, blue: 0.3)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let panel = Color.black.opacity(0.22)
    static let raisedPanel = Color.white.opacity(0.055)
    static let border = Color.white.opacity(0.1)
    static let cpuUser = Color(red: 0.30, green: 0.79, blue: 0.94)
    static let cpuSystem = Color(red: 1.0, green: 0.42, blue: 0.42)
    static let memory = Color(red: 0.39, green: 0.82, blue: 0.59)
    static let energy = Color(red: 0.97, green: 0.79, blue: 0.28)
    static let diskOccupied = Color(red: 0.70, green: 0.50, blue: 0.96)
    static let screenTime = Color(red: 0.42, green: 0.87, blue: 0.48)
    static let inbound = Color(red: 0.39, green: 0.68, blue: 1.0)
    static let outbound = Color(red: 1.0, green: 0.47, blue: 0.57)
}

/// A small red "kill" button reused across tabs.
struct KillButton: View {
    let pid: Int32
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 16))
                .foregroundColor(.red.opacity(0.7))
        }
        .buttonStyle(.plain)
        .help("Kill process \(pid)")
    }
}

func formatMemory(_ mb: Double) -> String {
    if mb >= 1024 {
        return String(format: "%.1f GB", mb / 1024)
    }
    return String(format: "%.1f MB", mb)
}

func formatBytes(_ bytes: UInt64) -> String {
    let value = Double(bytes)
    switch value {
    case 1_099_511_627_776...:
        return String(format: "%.2f TB", value / 1_099_511_627_776)
    case 1_073_741_824...:
        return String(format: "%.2f GB", value / 1_073_741_824)
    case 1_048_576...:
        return String(format: "%.1f MB", value / 1_048_576)
    case 1_024...:
        return String(format: "%.0f KB", value / 1_024)
    default:
        return "\(bytes) bytes"
    }
}

func formatByteRate(_ bytesPerSecond: Double?) -> String {
    guard let bytesPerSecond else { return "—" }
    return "\(formatBytes(UInt64(max(0, bytesPerSecond))))/s"
}

func formatNumber(_ value: UInt64) -> String {
    value.formatted(.number.grouping(.automatic))
}

func formatRate(_ value: Double?) -> String {
    guard let value else { return "—" }
    return String(format: "%.0f/s", value)
}

func formatDuration(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded()))
    let days = total / 86_400
    let hours = (total % 86_400) / 3_600
    let minutes = (total % 3_600) / 60
    let remainingSeconds = total % 60

    if days > 0 {
        return String(format: "%d-%02d:%02d:%02d", days, hours, minutes, remainingSeconds)
    }
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
    }
    return String(format: "%d:%02d", minutes, remainingSeconds)
}

/// A wrapping layout that places each subview at its own ideal size, flowing
/// left-to-right and wrapping to a new line when the row runs out of width.
///
/// Unlike `LazyVGrid(.adaptive:)`, every item keeps its intrinsic width, so
/// chips stay fully readable instead of being squeezed into uniform columns
/// that truncate their labels.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        arrange(maxWidth: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        for placement in arrange(maxWidth: bounds.width, subviews: subviews).placements {
            subviews[placement.index].place(
                at: CGPoint(x: bounds.minX + placement.point.x, y: bounds.minY + placement.point.y),
                anchor: .topLeading,
                proposal: ProposedViewSize(placement.size)
            )
        }
    }

    private struct Placement { let index: Int; let point: CGPoint; let size: CGSize }
    private struct Arrangement { let placements: [Placement]; let size: CGSize }

    private func arrange(maxWidth: CGFloat, subviews: Subviews) -> Arrangement {
        let limit = maxWidth.isFinite ? maxWidth : .greatestFiniteMagnitude
        var placements: [Placement] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0

        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > limit {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            placements.append(Placement(index: index, point: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }

        let width = maxWidth.isFinite ? maxWidth : widest
        return Arrangement(placements: placements, size: CGSize(width: width, height: y + rowHeight))
    }
}
