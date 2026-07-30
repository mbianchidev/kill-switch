import AppKit
import DiskCleanupCore
import SwiftUI

// The monitor shares this immutable service across scan workers and its serial Trash worker.
private final class DiskCleanupServiceBox: @unchecked Sendable {
    let service: DiskCleanupService

    init(_ service: DiskCleanupService) {
        self.service = service
    }
}

@MainActor
final class DiskCleanupMonitor: ObservableObject {
    @Published private(set) var category: DiskCleanupCategory = .largestFiles
    @Published private(set) var isTrashing = false

    private let serviceBox: DiskCleanupServiceBox
    private let scanQueue: OperationQueue
    private let trashQueue = DispatchQueue(label: "DiskCleanupMonitor.trash", qos: .utility)
    private var scanStates: [ScanKey: ScanState] = [:]
    private var navigationByCategory: [DiskCleanupCategory: [URL]] = [:]
    private var filesystemMutationGeneration = 0
    private var hasStarted = false

    init(service: DiskCleanupService = DiskCleanupService()) {
        serviceBox = DiskCleanupServiceBox(service)
        let scanQueue = OperationQueue()
        scanQueue.name = "DiskCleanupMonitor.scan"
        scanQueue.qualityOfService = .utility
        scanQueue.maxConcurrentOperationCount = 2
        self.scanQueue = scanQueue
    }

    private var service: DiskCleanupService { serviceBox.service }

    var items: [DiskCleanupItem] { currentState?.items ?? [] }
    var navigationStack: [URL] {
        guard category != .largestFiles else { return [] }
        return navigationByCategory[category] ?? [service.rootURL(for: category)]
    }
    var currentDirectory: URL? { navigationStack.last }
    var isScanning: Bool { currentState?.isScanning ?? false }
    var progress: DiskCleanupProgress? { currentState?.progress }
    var scannedEntryCount: Int { currentState?.scannedEntryCount ?? 0 }
    var skippedItemCount: Int { currentState?.skippedItemCount ?? 0 }
    var permissionDeniedCount: Int { currentState?.permissionDeniedCount ?? 0 }
    var excludedCloudItemCount: Int { currentState?.excludedCloudItemCount ?? 0 }
    var lastScan: Date? { currentState?.lastScan }
    var errorMessage: String? { currentState?.errorMessage }
    var statusMessage: String? { currentState?.statusMessage }
    var selectedIDs: Set<String> { currentState?.selectedIDs ?? [] }

    var selectedItems: [DiskCleanupItem] {
        items.filter { selectedIDs.contains($0.id) }
    }

    func start() {
        if !hasStarted {
            hasStarted = true
            initializeNavigation(for: category)
        }
        scanCurrentLocationIfNeeded()
    }

    func selectCategory(_ newCategory: DiskCleanupCategory) {
        guard !isTrashing else { return }
        initializeNavigation(for: newCategory)
        category = newCategory
        scanCurrentLocationIfNeeded()
    }

    func scanCurrentLocation() {
        guard !isTrashing else { return }
        beginScan(for: currentScanKey)
    }

    func openDirectory(_ item: DiskCleanupItem) {
        guard item.kind == .directory,
              category != .largestFiles,
              !isTrashing else {
            return
        }
        objectWillChange.send()
        navigationByCategory[category, default: [service.rootURL(for: category)]].append(
            item.url.standardizedFileURL
        )
        scanCurrentLocationIfNeeded()
    }

    func navigate(to index: Int) {
        guard category != .largestFiles,
              navigationStack.indices.contains(index),
              !isTrashing else {
            return
        }
        objectWillChange.send()
        navigationByCategory[category] = Array(navigationStack.prefix(index + 1))
        scanCurrentLocationIfNeeded()
    }

    func cancelScan() {
        let key = currentScanKey
        guard var state = scanStates[key], state.isScanning else { return }
        state.cancellationToken?.cancel()
        state.cancellationToken = nil
        state.requestID = nil
        state.requestMutationGeneration = nil
        state.isScanning = false
        state.progress = nil
        state.statusMessage = "Scan cancelled."
        setState(state, for: key)
    }

    func toggleSelection(_ item: DiskCleanupItem) {
        guard item.canTrash, !isTrashing else { return }
        let key = currentScanKey
        var state = state(for: key)
        if state.selectedIDs.contains(item.id) {
            state.selectedIDs.remove(item.id)
        } else {
            state.selectedIDs.insert(item.id)
        }
        setState(state, for: key)
    }

    func setSelection(_ selected: Bool, for items: [DiskCleanupItem]) {
        guard !isTrashing else { return }
        let ids = Set(items.filter(\.canTrash).map(\.id))
        let key = currentScanKey
        var state = state(for: key)
        if selected {
            state.selectedIDs.formUnion(ids)
        } else {
            state.selectedIDs.subtract(ids)
        }
        setState(state, for: key)
    }

    func clearSelection() {
        let key = currentScanKey
        var state = state(for: key)
        guard !state.selectedIDs.isEmpty else { return }
        state.selectedIDs.removeAll()
        setState(state, for: key)
    }

    func moveToTrash(_ requestedItems: [DiskCleanupItem]) {
        let safeItems = requestedItems.filter(\.canTrash)
        guard !safeItems.isEmpty, !isScanning, !isTrashing else { return }

        isTrashing = true
        let requestKey = currentScanKey
        var requestState = state(for: requestKey)
        requestState.errorMessage = nil
        requestState.statusMessage = nil
        setState(requestState, for: requestKey)
        let requestCategory = category
        let serviceBox = serviceBox

        trashQueue.async { [weak self] in
            let result = serviceBox.service.moveToTrash(
                safeItems,
                category: requestCategory
            )
            DispatchQueue.main.async {
                self?.finishTrash(result, requestKey: requestKey)
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
            var state = state(for: currentScanKey)
            state.errorMessage = "Could not open Full Disk Access settings."
            setState(state, for: currentScanKey)
            return
        }
    }

    private var currentScanKey: ScanKey {
        ScanKey(
            category: category,
            directory: category == .largestFiles
                ? service.rootURL(for: category)
                : currentDirectory ?? service.rootURL(for: category)
        )
    }

    private var currentState: ScanState? {
        scanStates[currentScanKey]
    }

    private func initializeNavigation(for category: DiskCleanupCategory) {
        guard category != .largestFiles, navigationByCategory[category] == nil else { return }
        navigationByCategory[category] = [service.rootURL(for: category)]
    }

    private func scanCurrentLocationIfNeeded() {
        let key = currentScanKey
        let currentState = scanStates[key]
        guard currentState?.isScanning != true else { return }
        guard currentState?.lastScan == nil || currentState?.requiresRefresh == true else { return }
        beginScan(for: key)
    }

    private func beginScan(for key: ScanKey) {
        guard !isTrashing else { return }
        var state = state(for: key)
        guard !state.isScanning else { return }

        let requestID = UUID()
        let token = DiskCleanupCancellationToken()
        state.requestID = requestID
        state.cancellationToken = token
        state.isScanning = true
        state.progress = nil
        state.scannedEntryCount = 0
        state.errorMessage = nil
        state.statusMessage = nil
        state.requestMutationGeneration = filesystemMutationGeneration
        setState(state, for: key)

        let serviceBox = serviceBox
        scanQueue.addOperation { [weak self] in
            do {
                let result = try serviceBox.service.scan(
                    category: key.category,
                    directory: key.category == .largestFiles ? nil : key.directory,
                    cancellationToken: token,
                    progress: { [weak self] progress in
                        DispatchQueue.main.async {
                            self?.receiveProgress(
                                progress,
                                for: key,
                                requestID: requestID
                            )
                        }
                    }
                )
                DispatchQueue.main.async {
                    self?.finishScan(result, for: key, requestID: requestID)
                }
            } catch DiskCleanupError.cancelled {
                DispatchQueue.main.async {
                    self?.finishCancelledScan(for: key, requestID: requestID)
                }
            } catch {
                fputs("KillSwitch disk scan failed: \(error.localizedDescription)\n", stderr)
                DispatchQueue.main.async {
                    self?.finishScan(
                        with: error,
                        for: key,
                        requestID: requestID
                    )
                }
            }
        }
    }

    private func receiveProgress(
        _ progress: DiskCleanupProgress,
        for key: ScanKey,
        requestID: UUID
    ) {
        guard var state = scanStates[key], state.requestID == requestID else { return }
        state.progress = progress
        state.scannedEntryCount = progress.scannedEntryCount
        setState(state, for: key)
    }

    private func finishScan(
        _ result: DiskCleanupScanResult,
        for key: ScanKey,
        requestID: UUID
    ) {
        guard var state = scanStates[key], state.requestID == requestID else { return }
        guard state.requestMutationGeneration == filesystemMutationGeneration else {
            state.isScanning = false
            state.progress = nil
            state.cancellationToken = nil
            state.requestID = nil
            state.requestMutationGeneration = nil
            state.requiresRefresh = true
            setState(state, for: key)
            beginScan(for: key)
            return
        }

        let isRescan = state.lastScan != nil
        let delta = DiskCleanupScanDelta(
            previousItems: state.items,
            currentItems: result.items
        )
        state.items = delta.applying(to: state.items)

        var currentItemsByID: [String: DiskCleanupItem] = [:]
        for item in state.items {
            currentItemsByID[item.id] = item
        }
        state.selectedIDs = Set(state.selectedIDs.filter { id in
            currentItemsByID[id]?.canTrash == true
        })
        state.scannedEntryCount = result.scannedEntryCount
        state.skippedItemCount = result.skippedItemCount
        state.permissionDeniedCount = result.permissionDeniedCount
        state.excludedCloudItemCount = result.excludedCloudItemCount
        state.lastScan = Date()
        state.isScanning = false
        state.progress = nil
        state.cancellationToken = nil
        state.requestID = nil
        state.requestMutationGeneration = nil
        state.requiresRefresh = false
        state.errorMessage = nil
        state.statusMessage = isRescan ? rescanStatus(for: delta) : nil
        setState(state, for: key)
    }

    private func finishCancelledScan(for key: ScanKey, requestID: UUID) {
        guard var state = scanStates[key], state.requestID == requestID else { return }
        state.isScanning = false
        state.progress = nil
        state.cancellationToken = nil
        state.requestID = nil
        state.requestMutationGeneration = nil
        setState(state, for: key)
    }

    private func finishScan(
        with error: Error,
        for key: ScanKey,
        requestID: UUID
    ) {
        guard var state = scanStates[key], state.requestID == requestID else { return }
        state.errorMessage = error.localizedDescription
        state.isScanning = false
        state.progress = nil
        state.cancellationToken = nil
        state.requestID = nil
        state.requestMutationGeneration = nil
        setState(state, for: key)
    }

    private func finishTrash(
        _ result: DiskCleanupTrashResult,
        requestKey: ScanKey
    ) {
        if !result.movedItems.isEmpty {
            reconcileCaches(afterMoving: result.movedItems)
        }

        var requestState = state(for: requestKey)
        if !result.movedItems.isEmpty {
            let bytes = result.movedItems.reduce(UInt64(0)) { $0 + $1.sizeBytes }
            requestState.statusMessage =
                "Moved \(result.movedItems.count) item(s) (\(formatBytes(bytes))) to Trash."
        }

        if !result.failures.isEmpty {
            let details = result.failures
                .map { "\($0.item.url.path): \($0.message)" }
                .joined(separator: "\n")
            fputs("KillSwitch disk cleanup failed:\n\(details)\n", stderr)
            requestState.errorMessage = result.failures.count == 1
                ? result.failures[0].message
                : "\(result.failures.count) items could not be moved to Trash. \(result.failures[0].message)"
        }
        scanStates[requestKey] = requestState
        isTrashing = false
    }

    private func reconcileCaches(afterMoving movedItems: [DiskCleanupItem]) {
        let previousMutationGeneration = filesystemMutationGeneration
        filesystemMutationGeneration += 1
        objectWillChange.send()

        let movedDirectories = movedItems.filter { $0.kind == .directory }
        for key in Array(scanStates.keys) {
            guard var state = scanStates[key] else { continue }

            if movedDirectories.contains(where: {
                Self.isDescendantOrEqual(key.directory, of: $0.url)
            }) {
                state.cancellationToken?.cancel()
                scanStates.removeValue(forKey: key)
                continue
            }

            guard movedItems.contains(where: { scan(key, includes: $0.url) }) else {
                if state.isScanning,
                   state.requestMutationGeneration == previousMutationGeneration {
                    state.requestMutationGeneration = filesystemMutationGeneration
                    scanStates[key] = state
                }
                continue
            }

            state.items = reconciledItems(state.items, removing: movedItems)
            state.selectedIDs = Set(state.selectedIDs.filter { id in
                let selectedURL = URL(fileURLWithPath: id)
                return !movedItems.contains {
                    Self.isDescendantOrEqual(selectedURL, of: $0.url)
                }
            })
            state.requiresRefresh = true
            scanStates[key] = state
        }

        for category in Array(navigationByCategory.keys) {
            guard let stack = navigationByCategory[category],
                  let affectedIndex = stack.firstIndex(where: { url in
                      movedDirectories.contains {
                          Self.isDescendantOrEqual(url, of: $0.url)
                      }
                  }) else {
                continue
            }
            navigationByCategory[category] = Array(stack.prefix(max(1, affectedIndex)))
        }
    }

    private func reconciledItems(
        _ items: [DiskCleanupItem],
        removing movedItems: [DiskCleanupItem]
    ) -> [DiskCleanupItem] {
        items.compactMap { item in
            if movedItems.contains(where: {
                Self.isDescendantOrEqual(item.url, of: $0.url)
            }) {
                return nil
            }

            let descendants = movedItems.filter {
                Self.isDescendantOrEqual($0.url, of: item.url)
            }
            guard !descendants.isEmpty else { return item }

            let removedBytes = descendants.reduce(UInt64(0)) { $0 + $1.sizeBytes }
            let removedFiles = descendants.reduce(0) {
                $0 + ($1.kind == .file ? 1 : $1.fileCount)
            }
            return DiskCleanupItem(
                url: item.url,
                name: item.name,
                kind: item.kind,
                sizeBytes: item.sizeBytes > removedBytes ? item.sizeBytes - removedBytes : 0,
                fileCount: max(0, item.fileCount - removedFiles),
                modificationDate: item.modificationDate,
                protectionReason: item.protectionReason
            )
        }
    }

    private func scan(_ key: ScanKey, includes url: URL) -> Bool {
        guard Self.isDescendantOrEqual(url, of: key.directory) else { return false }
        guard key.category == .largestFiles || key.category == .largeFolders else {
            return true
        }

        let library = service.homeDirectory.appendingPathComponent("Library", isDirectory: true)
        let trash = service.homeDirectory.appendingPathComponent(".Trash", isDirectory: true)
        return !Self.isDescendantOrEqual(url, of: library)
            && !Self.isDescendantOrEqual(url, of: trash)
    }

    private func rescanStatus(for delta: DiskCleanupScanDelta) -> String {
        guard !delta.isEmpty else { return "Rescan found no changes." }
        var changes: [String] = []
        if !delta.addedItems.isEmpty {
            changes.append("\(delta.addedItems.count) added")
        }
        if !delta.updatedItems.isEmpty {
            changes.append("\(delta.updatedItems.count) updated")
        }
        if !delta.removedItems.isEmpty {
            changes.append("\(delta.removedItems.count) removed")
        }
        return "Rescan applied " + changes.joined(separator: ", ") + "."
    }

    private func state(for key: ScanKey) -> ScanState {
        scanStates[key] ?? ScanState()
    }

    private func setState(_ state: ScanState, for key: ScanKey) {
        objectWillChange.send()
        scanStates[key] = state
    }

    private static func isDescendantOrEqual(_ candidate: URL, of root: URL) -> Bool {
        candidate.standardizedFileURL.pathComponents.starts(
            with: root.standardizedFileURL.pathComponents
        )
    }

    private struct ScanKey: Hashable, Sendable {
        let category: DiskCleanupCategory
        let directory: URL

        init(category: DiskCleanupCategory, directory: URL) {
            self.category = category
            self.directory = directory.standardizedFileURL
        }
    }

    private struct ScanState {
        var items: [DiskCleanupItem] = []
        var selectedIDs: Set<String> = []
        var isScanning = false
        var progress: DiskCleanupProgress?
        var scannedEntryCount = 0
        var skippedItemCount = 0
        var permissionDeniedCount = 0
        var excludedCloudItemCount = 0
        var lastScan: Date?
        var errorMessage: String?
        var statusMessage: String?
        var requestID: UUID?
        var requestMutationGeneration: Int?
        var cancellationToken: DiskCleanupCancellationToken?
        var requiresRefresh = false
    }
}

struct DiskCleanupTab: View {
    @ObservedObject var monitor: DiskCleanupMonitor
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
        .onAppear { monitor.start() }
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
                    Text(monitor.category.description)
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

            Picker("Cleanup view", selection: categorySelection) {
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
            if monitor.category == .largestFiles {
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
                    Text(searchText.isEmpty ? monitor.category.emptyMessage : "No matching items")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.82))
                    Text(searchText.isEmpty ? monitor.category.emptyDetail : "Try a different file or folder name.")
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
                                canNavigate: item.kind == .directory && monitor.category != .largestFiles,
                                isScanning: monitor.isScanning,
                                isTrashing: monitor.isTrashing,
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
            .disabled(selectableVisibleItems.isEmpty || monitor.isTrashing)
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
                    monitor.clearSelection()
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

    private var categorySelection: Binding<DiskCleanupCategory> {
        Binding(
            get: { monitor.category },
            set: { category in
                searchText = ""
                monitor.selectCategory(category)
            }
        )
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
        switch monitor.category {
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
    let isScanning: Bool
    let isTrashing: Bool
    let onToggleSelection: () -> Void
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onTrash: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            selectionControl
                .frame(width: 22)

            Button(action: performPrimaryAction) {
                HStack(spacing: 10) {
                    Image(systemName: itemIcon)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(
                            item.kind == .file ? Theme.diskCleanupBar : Theme.diskCleanupAccent
                        )
                        .frame(width: 22)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Text(item.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if canNavigate {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundColor(Theme.diskCleanupAccent.opacity(0.7))
                            }
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)

                        Text(path)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.white.opacity(0.36))
                            .lineLimit(1)
                            .truncationMode(.middle)
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
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isTrashing)
            .help(primaryActionHelp)
            .accessibilityLabel(primaryActionLabel)
            .contextMenu {
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.url.path, forType: .string)
                }
            }

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
                .disabled(isScanning || isTrashing)
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
    }

    @ViewBuilder
    private var selectionControl: some View {
        if item.canTrash {
            Button(action: onToggleSelection) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundColor(isSelected ? Theme.diskCleanupAccent : .white.opacity(0.34))
            }
            .buttonStyle(.plain)
            .disabled(isTrashing)
            .accessibilityLabel(isSelected ? "Deselect \(item.name)" : "Select \(item.name)")
        } else {
            Image(systemName: "square")
                .foregroundColor(.white.opacity(0.12))
                .help(item.protectionReason ?? "Protected")
                .accessibilityHidden(true)
        }
    }

    private func performPrimaryAction() {
        if canNavigate {
            onOpen()
        } else if item.canTrash {
            onToggleSelection()
        } else {
            onReveal()
        }
    }

    private var primaryActionLabel: String {
        if canNavigate {
            return "Open \(item.name)"
        }
        if item.canTrash {
            return isSelected ? "Deselect \(item.name)" : "Select \(item.name)"
        }
        return "Reveal \(item.name) in Finder"
    }

    private var primaryActionHelp: String {
        if canNavigate {
            return "Open folder"
        }
        if item.canTrash {
            return isSelected ? "Deselect item" : "Select item"
        }
        return "Reveal in Finder"
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
