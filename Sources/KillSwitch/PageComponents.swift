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

func revealPathInFinder(_ path: String) -> Bool {
    guard FileManager.default.fileExists(atPath: path) else { return false }
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    return true
}

/// Process IDs are identifiers, so they are never grouped like quantities: 65134, not 65.134.
/// SwiftUI formats integers interpolated into a localized `Text` literal, so pass this string instead.
func pidString(_ pid: Int32) -> String { String(pid) }

/// Copies an identifying value, such as a process name or PID, when its text is clicked.
/// A simultaneous gesture keeps row selection and enclosing actions working, and a brief
/// "Copied" badge confirms the copy without adding a separate control. An empty value, such as a
/// missing endpoint, adds no copy action and keeps any placeholder help.
private struct CopyOnClick: ViewModifier {
    let value: String
    let label: String
    let emptyHelp: String?
    @State private var feedback: String?
    @State private var revision = 0
    @Environment(\.allowsLiveOperations) private var allowsOperations

    func body(content: Content) -> some View {
        if value.isEmpty {
            if let emptyHelp { content.help(Text(verbatim: emptyHelp)) } else { content }
        } else {
            copyable(content)
        }
    }

    private func copyable(_ content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { copy() })
            .overlay(alignment: .leading) {
                if let feedback {
                    Text(verbatim: feedback)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(feedback == "Copied" ? Theme.accent.opacity(0.9) : Color.red.opacity(0.9)))
                        .fixedSize()
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .help(Text(verbatim: "Click to copy the \(label): \(value)"))
            .accessibilityAction(named: Text(verbatim: "Copy \(label)")) { copy() }
            .task(id: revision) {
                guard feedback != nil else { return }
                do { try await Task.sleep(nanoseconds: 1_200_000_000) } catch { return }
                withAnimation(.easeOut(duration: 0.2)) { feedback = nil }
            }
    }

    private func copy() {
        guard allowsOperations, !value.isEmpty else { return }
        NSPasteboard.general.clearContents()
        let copied = NSPasteboard.general.setString(value, forType: .string)
        if !copied {
            fputs("KillSwitch could not copy the \(label) to the clipboard.\n", stderr)
        }
        withAnimation(.easeIn(duration: 0.1)) { feedback = copied ? "Copied" : "Copy failed" }
        revision += 1
    }
}

extension View {
    func copyOnClick(_ value: String, label: String, emptyHelp: String? = nil) -> some View {
        modifier(CopyOnClick(value: value, label: label, emptyHelp: emptyHelp))
    }

    func copyProcessName(_ name: String) -> some View {
        copyOnClick(name, label: "process name")
    }

    func copyPID(_ pid: Int32) -> some View {
        copyOnClick(pidString(pid), label: "PID")
    }
}
