import AppKit
import SwiftUI
import SystemMetricsCore

/// Startup disk usage shown at the top of the menu-bar menu. Capacity is read only when the menu
/// opens; the last reading stays visible while a new one loads.
@MainActor
final class StorageMenuModel: ObservableObject {
    @Published private(set) var volume: SystemVolume?
    @Published private(set) var hasRead = false
    private var isReading = false

    func refresh() {
        guard !isReading else { return }
        isReading = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let volume = SystemDetailsReader.startupVolume()
            DispatchQueue.main.async {
                guard let self else { return }
                self.volume = volume
                self.hasRead = true
                self.isReading = false
            }
        }
    }

#if KILLSWITCH_PERFORMANCE_PROBE
    /// In-memory fixture for probe renders; nothing is read.
    func publishPerformanceFixture(_ volume: SystemVolume?) {
        self.volume = volume
        hasRead = true
    }
#endif

    static func percent(_ fraction: Double) -> Int {
        Int((min(max(fraction, 0), 1) * 100).rounded())
    }

    /// `309.50 GB of 494.38 GB used · 184.88 GB free`, or nil when the capacity is unknown.
    static func detail(for volume: SystemVolume?) -> String? {
        guard let volume, let used = volume.usedBytes, let total = volume.totalBytes, volume.usedFraction != nil else { return nil }
        return "\(formatBytes(used)) of \(formatBytes(total)) used · \(formatBytes(total - used)) free"
    }
}

struct StorageMenuView: View {
    static let size = NSSize(width: 280, height: 62)

    @ObservedObject var model: StorageMenuModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Label(model.volume?.name ?? "Startup disk", systemImage: "internaldrive")
                    .font(.system(size: 13))
                Spacer(minLength: 8)
                if let fraction = model.volume?.usedFraction {
                    Text(verbatim: "\(StorageMenuModel.percent(fraction))%")
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                }
            }
            if let fraction = model.volume?.usedFraction, let detail = StorageMenuModel.detail(for: model.volume) {
                StorageBar(fraction: fraction)
                Text(detail)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            } else {
                Text(model.hasRead ? "Startup disk capacity is unavailable." : "Reading startup disk…")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }
}

/// A horizontal bar filled to the used share; orange above 90%.
private struct StorageBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.15))
                Capsule()
                    .fill(fraction > 0.9 ? Color.orange : Color(nsColor: .controlAccentColor))
                    .frame(width: fraction > 0 ? max(geometry.size.height, geometry.size.width * min(fraction, 1)) : 0)
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

enum StorageMenuItem {
    /// A non-selectable menu item hosting the storage view; create one per menu.
    static func make(model: StorageMenuModel) -> NSMenuItem {
        let item = NSMenuItem()
        let host = NSHostingView(rootView: StorageMenuView(model: model))
        host.frame = NSRect(origin: .zero, size: StorageMenuView.size)
        item.view = host
        return item
    }
}
