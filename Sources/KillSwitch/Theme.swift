import SwiftUI

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
