import AppKit
import DiskCleanupCore
import SwiftUI

final class DiskCleanupMonitor: ObservableObject {
    @Published private(set) var category: DiskCleanupCategory = .largestFiles
    @Published private(set) var items: [DiskCleanupItem] = []
    @Published private(set) var navigationStack: [URL] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isTrashing = false
    @Published private(set) var progress: DiskCleanupProgress?
    @Published private(set) var scannedEntryCount = 0
    @Published private(set) var skippedItemCount = 0
    @Published private(set) var permissionDeniedCount = 0
    @Published private(set) var excludedCloudItemCount = 0
    @Published private(set) var lastScan: Date?
    @Published private(set) var errorMessage: String?
    @Published private(set) var statusMessage: String?
    @Published var selectedIDs: Set<String> = []

    private let service: DiskCleanupService
    private let workQueue = DispatchQueue(label: "DiskCleanupMonitor.work", qos: .utility)
    private var cancellationToken: DiskCleanupCancellationToken?
    private var generation = 0
    private var hasStarted = false

    init(service: DiskCleanupService = DiskCleanupService()) {
        self.service = service
    }

    var currentDirectory: URL? { navigationStack.last }

    var selectedItems: [DiskCleanupItem] {
        items.filter { selectedIDs.contains($0.id) }
    }

    func start(category: DiskCleanupCategory) {
        if !hasStarted {
            hasStarted = true
            selectCategory(category)
        } else if items.isEmpty && !isScanning {
            scanCurrentLocation()
        }
    }

    func selectCategory(_ newCategory: DiskCleanupCategory) {
        guard !isTrashing else { return }
        category = newCategory
        selectedIDs.removeAll()
        if newCategory == .largestFiles {
            navigationStack = []
        } else {
            navigationStack = [service.rootURL(for: newCategory)]
        }
        scanCurrentLocation()
    }

    func scanCurrentLocation() {
        guard !isTrashing else { return }
        beginScan(
            category: category,
            directory: category == .largestFiles ? nil : currentDirectory
        )
    }

    func openDirectory(_ item: DiskCleanupItem) {
        guard item.kind == .directory,
              category != .largestFiles,
              !isScanning,
              !isTrashing else {
            return
        }
        navigationStack.append(item.url)
        selectedIDs.removeAll()
        beginScan(category: category, directory: item.url)
    }

    func navigate(to index: Int) {
        guard category != .largestFiles,
              navigationStack.indices.contains(index),
              !isScanning,
              !isTrashing else {
            return
        }
        navigationStack = Array(navigationStack.prefix(index + 1))
        selectedIDs.removeAll()
        beginScan(category: category, directory: navigationStack.last)
    }

    func cancelScan() {
        cancellationToken?.cancel()
        cancellationToken = nil
        generation += 1
        isScanning = false
        progress = nil
    }

    func toggleSelection(_ item: DiskCleanupItem) {
        guard item.canTrash else { return }
        if selectedIDs.contains(item.id) {
            selectedIDs.remove(item.id)
        } else {
            selectedIDs.insert(item.id)
        }
    }

    func setSelection(_ selected: Bool, for items: [DiskCleanupItem]) {
        let ids = Set(items.filter(\.canTrash).map(\.id))
        if selected {
            selectedIDs.formUnion(ids)
        } else {
            selectedIDs.subtract(ids)
        }
    }

    func moveToTrash(_ requestedItems: [DiskCleanupItem]) {
        let safeItems = requestedItems.filter(\.canTrash)
        guard !safeItems.isEmpty, !isScanning, !isTrashing else { return }

        isTrashing = true
        errorMessage = nil
        statusMessage = nil
        let requestCategory = category

        workQueue.async { [weak self] in
            guard let self else { return }
            let result = self.service.moveToTrash(safeItems, category: requestCategory)
            DispatchQueue.main.async {
                let movedIDs = Set(result.movedItems.map(\.id))
                self.items.removeAll { movedIDs.contains($0.id) }
                self.selectedIDs.subtract(movedIDs)
                self.isTrashing = false

                if !result.movedItems.isEmpty {
                    let bytes = result.movedItems.reduce(UInt64(0)) { $0 + $1.sizeBytes }
                    self.statusMessage = "Moved \(result.movedItems.count) item(s) (\(formatBytes(bytes))) to Trash."
                }

                if !result.failures.isEmpty {
                    let details = result.failures
                        .map { "\($0.item.url.path): \($0.message)" }
                        .joined(separator: "\n")
                    fputs("KillSwitch disk cleanup failed:\n\(details)\n", stderr)
                    self.errorMessage = result.failures.count == 1
                        ? result.failures[0].message
                        : "\(result.failures.count) items could not be moved to Trash. \(result.failures[0].message)"
                }
            }
        }
    }

    func abbreviatedPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        let home = service.homeDirectory.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }

    func rootLabel(for url: URL) -> String {
        if url.standardizedFileURL == service.homeDirectory {
            return "Home"
        }
        if url.standardizedFileURL == service.temporaryDirectory {
            return "Temporary"
        }
        if url.standardizedFileURL == service.cachesDirectory {
            return "Caches"
        }
        return url.lastPathComponent
    }

    func openFullDiskAccessSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        ), NSWorkspace.shared.open(url) else {
            errorMessage = "Could not open Full Disk Access settings."
            return
        }
    }

    private func beginScan(
        category scanCategory: DiskCleanupCategory,
        directory: URL?
    ) {
        guard !isTrashing else { return }
        cancellationToken?.cancel()
        generation += 1
        let scanGeneration = generation
        let token = DiskCleanupCancellationToken()
        cancellationToken = token
        isScanning = true
        items = []
        progress = nil
        scannedEntryCount = 0
        skippedItemCount = 0
        permissionDeniedCount = 0
        excludedCloudItemCount = 0
        errorMessage = nil
        statusMessage = nil
        selectedIDs.removeAll()

        workQueue.async { [weak self] in
            guard let self else { return }
            do {
                let result = try self.service.scan(
                    category: scanCategory,
                    directory: directory,
                    cancellationToken: token,
                    progress: { [weak self] progress in
                        DispatchQueue.main.async {
                            guard let self, self.generation == scanGeneration else { return }
                            self.progress = progress
                            self.scannedEntryCount = progress.scannedEntryCount
                        }
                    }
                )
                DispatchQueue.main.async {
                    guard self.generation == scanGeneration else { return }
                    self.items = result.items
                    self.scannedEntryCount = result.scannedEntryCount
                    self.skippedItemCount = result.skippedItemCount
                    self.permissionDeniedCount = result.permissionDeniedCount
                    self.excludedCloudItemCount = result.excludedCloudItemCount
                    self.lastScan = Date()
                    self.isScanning = false
                    self.progress = nil
                    self.cancellationToken = nil
                }
            } catch DiskCleanupError.cancelled {
                DispatchQueue.main.async {
                    guard self.generation == scanGeneration else { return }
                    self.isScanning = false
                    self.progress = nil
                    self.cancellationToken = nil
                }
            } catch {
                fputs("KillSwitch disk scan failed: \(error.localizedDescription)\n", stderr)
                DispatchQueue.main.async {
                    guard self.generation == scanGeneration else { return }
                    self.errorMessage = error.localizedDescription
                    self.isScanning = false
                    self.progress = nil
                    self.cancellationToken = nil
                }
            }
        }
    }
}

struct DiskCleanupTab: View {
    @StateObject private var monitor = DiskCleanupMonitor()
    @State private var selectedCategory: DiskCleanupCategory = .largestFiles
    @State private var searchText = ""
    @State private var pendingTrashItems: [DiskCleanupItem] = []
    @State private var showTrashConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            notices
            browserToolbar
            Divider()
            itemBrowser
            Divider()
            actionBar
        }
        .background(Theme.background)
        .onAppear { monitor.start(category: selectedCategory) }
        .onDisappear { monitor.cancelScan() }
        .onChange(of: selectedCategory) { newCategory in
            searchText = ""
            monitor.selectCategory(newCategory)
        }
        .alert(trashAlertTitle, isPresented: $showTrashConfirmation) {
            Button("Cancel", role: .cancel) {
                pendingTrashItems = []
            }
            Button("Move to Trash", role: .destructive) {
                let items = pendingTrashItems
                pendingTrashItems = []
                monitor.moveToTrash(items)
            }
        } message: {
            Text(trashAlertMessage)
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Theme.diskCleanupAccent.opacity(0.16))
                    Image(systemName: "internaldrive")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Theme.diskCleanupAccent)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Disk cleanup")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text(selectedCategory.description)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.45))
                }

                Spacer()

                if monitor.isScanning {
                    Button {
                        monitor.cancelScan()
                    } label: {
                        Label("Cancel scan", systemImage: "xmark")
                    }
                    .buttonStyle(.borderless)
                } else {
                    Button {
                        monitor.scanCurrentLocation()
                    } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(monitor.isTrashing)
                }
            }

            Picker("Cleanup view", selection: $selectedCategory) {
                ForEach(DiskCleanupCategory.allCases, id: \.self) { category in
                    Label(category.label, systemImage: category.systemImage)
                        .tag(category)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .disabled(monitor.isTrashing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.panel)
    }

    @ViewBuilder
    private var notices: some View {
        if monitor.permissionDeniedCount > 0 {
            HStack(spacing: 10) {
                Image(systemName: "lock.trianglebadge.exclamationmark.fill")
                    .foregroundColor(.orange)
                Text("\(monitor.permissionDeniedCount) protected location(s) could not be scanned.")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.8))
                Spacer()
                Button("Full Disk Access settings") {
                    monitor.openFullDiskAccessSettings()
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.1))
        }

        if monitor.excludedCloudItemCount > 0 {
            noticeLine(
                icon: "icloud.slash",
                color: Theme.diskCleanupAccent,
                text: "\(monitor.excludedCloudItemCount) iCloud item(s) excluded to avoid deleting synced data."
            )
        }

        if let error = monitor.errorMessage {
            noticeLine(
                icon: "exclamationmark.triangle.fill",
                color: .red,
                text: error
            )
        } else if let status = monitor.statusMessage {
            noticeLine(
                icon: "checkmark.circle.fill",
                color: .green,
                text: status
            )
        }
    }

    private var browserToolbar: some View {
        HStack(spacing: 12) {
            if selectedCategory == .largestFiles {
                Label("Largest individual files in your home folders", systemImage: "arrow.down.to.line")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.72))
            } else {
                breadcrumb
            }

            Spacer()

            if monitor.isScanning {
                ProgressView()
                    .controlSize(.small)
                Text(scanProgressText)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.42))
                    .lineLimit(1)
                    .frame(maxWidth: 230, alignment: .trailing)
            } else {
                Text("\(visibleItems.count) items - \(formatBytes(visibleBytes))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.42))
            }

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.white.opacity(0.38))
                TextField("Filter items", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(.white)
                    .frame(width: 170)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.black.opacity(0.2))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border))
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Color.black.opacity(0.12))
    }

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(Array(monitor.navigationStack.enumerated()), id: \.offset) { index, url in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.white.opacity(0.25))
                    }
                    Button {
                        monitor.navigate(to: index)
                    } label: {
                        Text(index == 0 ? monitor.rootLabel(for: url) : url.lastPathComponent)
                            .font(.system(size: 11, weight: index == monitor.navigationStack.count - 1 ? .semibold : .regular))
                            .foregroundColor(index == monitor.navigationStack.count - 1 ? .white : Theme.diskCleanupAccent)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .disabled(
                        index == monitor.navigationStack.count - 1
                            || monitor.isScanning
                            || monitor.isTrashing
                    )
                }
            }
        }
        .frame(maxWidth: 440, alignment: .leading)
    }

    @ViewBuilder
    private var itemBrowser: some View {
        if visibleItems.isEmpty {
            VStack(spacing: 12) {
                if monitor.isScanning {
                    ProgressView()
                        .controlSize(.large)
                    Text("Mapping storage...")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.82))
                    Text(scanProgressText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.42))
                } else {
                    Image(systemName: searchText.isEmpty ? "sparkles" : "magnifyingglass")
                        .font(.system(size: 26, weight: .light))
                        .foregroundColor(Theme.diskCleanupAccent.opacity(0.8))
                    Text(searchText.isEmpty ? selectedCategory.emptyMessage : "No matching items")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.82))
                    Text(searchText.isEmpty ? selectedCategory.emptyDetail : "Try a different file or folder name.")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.07))
        } else {
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(visibleItems) { item in
                            DiskCleanupRow(
                                item: item,
                                path: monitor.abbreviatedPath(item.url),
                                sizeRatio: maximumVisibleSize == 0
                                    ? 0
                                    : Double(item.sizeBytes) / Double(maximumVisibleSize),
                                isSelected: monitor.selectedIDs.contains(item.id),
                                canNavigate: item.kind == .directory && selectedCategory != .largestFiles,
                                isBusy: monitor.isScanning || monitor.isTrashing,
                                onToggleSelection: { monitor.toggleSelection(item) },
                                onOpen: { monitor.openDirectory(item) },
                                onReveal: {
                                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                                },
                                onTrash: { requestTrash([item]) }
                            )
                        }
                    } header: {
                        tableHeader
                    }
                }
                .frame(minWidth: 960, alignment: .leading)
            }
            .background(Color.black.opacity(0.07))
        }
    }

    private var tableHeader: some View {
        HStack(spacing: 10) {
            Button {
                monitor.setSelection(!allVisibleSelected, for: visibleItems)
            } label: {
                Image(systemName: allVisibleSelected ? "checkmark.square.fill" : "square")
                    .foregroundColor(allVisibleSelected ? Theme.diskCleanupAccent : .white.opacity(0.35))
            }
            .buttonStyle(.plain)
            .help(allVisibleSelected ? "Deselect all visible items" : "Select all visible items")
            .accessibilityLabel(
                allVisibleSelected ? "Deselect all visible items" : "Select all visible items"
            )
            .disabled(selectableVisibleItems.isEmpty || monitor.isScanning || monitor.isTrashing)
            .frame(width: 22)

            Text("ITEM")
                .frame(minWidth: 430, maxWidth: .infinity, alignment: .leading)
            Text("CONTENTS")
                .frame(width: 90, alignment: .leading)
            Text("MODIFIED")
                .frame(width: 130, alignment: .leading)
            Text("SPACE USED")
                .frame(width: 100, alignment: .trailing)
            Color.clear.frame(width: 58)
        }
        .font(.system(size: 9, weight: .bold))
        .tracking(0.9)
        .foregroundColor(.white.opacity(0.38))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.panel)
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            if monitor.selectedItems.isEmpty {
                Text("Select files or folders to move them to the macOS Trash.")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
            } else {
                Text("\(monitor.selectedItems.count) selected - \(formatBytes(selectedBytes))")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.75))
                Button("Clear") {
                    monitor.selectedIDs.removeAll()
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
            }

            Spacer()

            if let lastScan = monitor.lastScan {
                Text("Scanned \(lastScan.formatted(date: .omitted, time: .standard))")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.3))
            }

            Button {
                requestTrash(monitor.selectedItems)
            } label: {
                Label(
                    monitor.isTrashing ? "Moving..." : "Move selected to Trash",
                    systemImage: "trash"
                )
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.diskCleanupAction)
            .disabled(
                monitor.selectedItems.isEmpty
                    || monitor.isScanning
                    || monitor.isTrashing
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.panel)
    }

    private func noticeLine(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(color)
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.8))
                .textSelection(.enabled)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(color.opacity(0.09))
    }

    private func requestTrash(_ items: [DiskCleanupItem]) {
        let safeItems = items.filter(\.canTrash)
        guard !safeItems.isEmpty else { return }
        pendingTrashItems = safeItems
        showTrashConfirmation = true
    }

    private var visibleItems: [DiskCleanupItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return monitor.items }
        return monitor.items.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || monitor.abbreviatedPath($0.url).localizedCaseInsensitiveContains(query)
        }
    }

    private var selectableVisibleItems: [DiskCleanupItem] {
        visibleItems.filter(\.canTrash)
    }

    private var allVisibleSelected: Bool {
        !selectableVisibleItems.isEmpty
            && selectableVisibleItems.allSatisfy { monitor.selectedIDs.contains($0.id) }
    }

    private var visibleBytes: UInt64 {
        visibleItems.reduce(UInt64(0)) { $0 + $1.sizeBytes }
    }

    private var selectedBytes: UInt64 {
        monitor.selectedItems.reduce(UInt64(0)) { $0 + $1.sizeBytes }
    }

    private var maximumVisibleSize: UInt64 {
        visibleItems.map(\.sizeBytes).max() ?? 0
    }

    private var scanProgressText: String {
        guard let progress = monitor.progress else {
            return "\(monitor.scannedEntryCount) entries scanned"
        }
        return "\(progress.scannedEntryCount) - \(monitor.abbreviatedPath(progress.currentURL))"
    }

    private var trashAlertTitle: String {
        if pendingTrashItems.count == 1, let item = pendingTrashItems.first {
            return "Move \"\(item.name)\" to Trash?"
        }
        return "Move \(pendingTrashItems.count) items to Trash?"
    }

    private var trashAlertMessage: String {
        let size = pendingTrashItems.reduce(UInt64(0)) { $0 + $1.sizeBytes }
        let recovery = "They use \(formatBytes(size)) and remain recoverable until the Trash is emptied."
        switch selectedCategory {
        case .temporary, .caches:
            return "\(recovery) Running apps may recreate or currently use some of this data."
        case .largestFiles, .largeFolders:
            return "\(recovery) Review personal files and project folders carefully before continuing."
        }
    }
}

private struct DiskCleanupRow: View {
    let item: DiskCleanupItem
    let path: String
    let sizeRatio: Double
    let isSelected: Bool
    let canNavigate: Bool
    let isBusy: Bool
    let onToggleSelection: () -> Void
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onTrash: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            selectionControl
                .frame(width: 22)

            Image(systemName: itemIcon)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(item.kind == .file ? Theme.diskCleanupBar : Theme.diskCleanupAccent)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                if canNavigate {
                    Button(action: onOpen) {
                        HStack(spacing: 5) {
                            Text(item.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(Theme.diskCleanupAccent.opacity(0.7))
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .disabled(isBusy)
                } else {
                    Text(item.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Text(path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.36))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .frame(minWidth: 388, maxWidth: .infinity, alignment: .leading)

            Text(contentsLabel)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.48))
                .frame(width: 90, alignment: .leading)

            Text(item.modificationDate?.formatted(date: .abbreviated, time: .omitted) ?? "-")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.45))
                .frame(width: 130, alignment: .leading)

            Text(formatBytes(item.sizeBytes))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.82))
                .frame(width: 100, alignment: .trailing)

            Button(action: onReveal) {
                Image(systemName: "finder")
            }
            .buttonStyle(.plain)
            .foregroundColor(.white.opacity(0.5))
            .help("Reveal in Finder")
            .accessibilityLabel("Reveal \(item.name) in Finder")
            .frame(width: 24)

            if item.canTrash {
                Button(action: onTrash) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundColor(Theme.diskCleanupAction.opacity(0.85))
                .help("Move to Trash")
                .accessibilityLabel("Move \(item.name) to Trash")
                .disabled(isBusy)
                .frame(width: 24)
            } else {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.32))
                    .help(item.protectionReason ?? "Protected")
                    .accessibilityLabel(item.protectionReason ?? "Protected item")
                    .frame(width: 24)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(alignment: .leading) {
            GeometryReader { proxy in
                RoundedRectangle(cornerRadius: 4)
                    .fill(Theme.diskCleanupBar.opacity(isSelected ? 0.22 : 0.11))
                    .frame(width: max(0, proxy.size.width * CGFloat(sizeRatio)))
            }
        }
        .background(isSelected ? Color.white.opacity(0.045) : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.045))
                .frame(height: 1)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var selectionControl: some View {
        if item.canTrash {
            Button(action: onToggleSelection) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundColor(isSelected ? Theme.diskCleanupAccent : .white.opacity(0.34))
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .accessibilityLabel(isSelected ? "Deselect \(item.name)" : "Select \(item.name)")
        } else {
            Image(systemName: "square")
                .foregroundColor(.white.opacity(0.12))
                .help(item.protectionReason ?? "Protected")
                .accessibilityHidden(true)
        }
    }

    private var contentsLabel: String {
        switch item.kind {
        case .file:
            let ext = item.url.pathExtension.uppercased()
            return ext.isEmpty ? "FILE" : ext
        case .directory:
            return item.fileCount == 1 ? "1 file" : "\(item.fileCount) files"
        case .package:
            return item.fileCount == 1 ? "PACKAGE" : "\(item.fileCount) files"
        }
    }

    private var itemIcon: String {
        if item.kind == .directory { return "folder.fill" }
        if item.kind == .package { return "shippingbox.fill" }
        switch item.url.pathExtension.lowercased() {
        case "dmg", "iso", "pkg", "zip", "gz", "bz2", "xz", "7z", "rar":
            return "archivebox.fill"
        case "mov", "mp4", "mkv", "avi", "webm":
            return "film.fill"
        case "jpg", "jpeg", "png", "gif", "heic", "tiff", "raw":
            return "photo.fill"
        case "swift", "js", "ts", "tsx", "jsx", "py", "rs", "go", "java":
            return "chevron.left.forwardslash.chevron.right"
        default:
            return "doc.fill"
        }
    }
}

private extension DiskCleanupCategory {
    var label: String {
        switch self {
        case .largestFiles: return "Largest files"
        case .temporary: return "Temporary"
        case .caches: return "Caches"
        case .largeFolders: return "Large folders"
        }
    }

    var systemImage: String {
        switch self {
        case .largestFiles: return "arrow.down.to.line"
        case .temporary: return "clock.arrow.circlepath"
        case .caches: return "shippingbox.fill"
        case .largeFolders: return "folder.fill"
        }
    }

    var description: String {
        switch self {
        case .largestFiles:
            return "Find the biggest individual files first."
        case .temporary:
            return "Inspect this Mac user's temporary working data."
        case .caches:
            return "Browse app caches and reclaimable support data."
        case .largeFolders:
            return "Open large home folders and clean them item by item."
        }
    }

    var emptyMessage: String {
        switch self {
        case .largestFiles: return "No large files found"
        case .temporary: return "No temporary items found"
        case .caches: return "No cache items found"
        case .largeFolders: return "No folders found"
        }
    }

    var emptyDetail: String {
        switch self {
        case .largestFiles:
            return "Protected, hidden, and iCloud-synced files are excluded."
        case .temporary:
            return "The current user temporary directory is empty."
        case .caches:
            return "The user cache directory is empty."
        case .largeFolders:
            return "No visible home-folder items are available to browse."
        }
    }
}
