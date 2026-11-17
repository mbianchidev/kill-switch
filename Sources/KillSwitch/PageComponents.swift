import AppKit
import SwiftUI

/// Standard page header: icon, title, one-line explanation, and trailing actions.
struct PageHeader<Trailing: View>: View {
    let page: MainTab
    let subtitle: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: page.icon)
                .foregroundColor(page.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(page.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.45))
                    .lineLimit(2)
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.2))
    }
}

struct StatusBadge: View {
    let title: String
    let color: Color
    var systemImage: String?

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).accessibilityHidden(true)
            }
            Text(title).lineLimit(1)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundColor(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.14)))
    }
}

/// A full-width warning or status line with an optional dismiss button.
struct NoticeBanner: View {
    let message: String
    var systemImage = "exclamationmark.triangle.fill"
    var color: Color = .orange
    var dismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundColor(color)
                .accessibilityHidden(true)
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.85))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let dismiss {
                Button(action: dismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .foregroundColor(.white.opacity(0.6))
                    .help("Dismiss")
                    .accessibilityLabel("Dismiss message")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.12)))
    }
}

/// A centered explanation for pages without data.
struct EmptyPageMessage: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 30))
                .foregroundColor(.white.opacity(0.35))
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(0.8))
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

func revealInFinder(_ path: String) -> Bool {
    guard FileManager.default.fileExists(atPath: path) else { return false }
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    return true
}
