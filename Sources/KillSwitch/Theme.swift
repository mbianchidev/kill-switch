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
