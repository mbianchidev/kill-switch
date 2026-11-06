#if KILLSWITCH_PERFORMANCE_PROBE
import AppKit
import Darwin
import Foundation
import SwiftUI
import SystemMetricsCore

// This entry point is compiled only into the separately built, non-interactive probe.
@MainActor
enum PerformanceProbe {
    static func run(arguments: [String]) -> Int32 {
        guard arguments.count == 3,
              ["background", "dashboard", "cpu", "memory", "energy"].contains(arguments[0]),
              let duration = Double(arguments[1]), (3...600).contains(duration),
              let count = Int(arguments[2]), (1...5_000).contains(count) else {
            fputs("Usage: performance-probe background|dashboard|cpu|memory|energy SECONDS(3...600) PROCESSES(1...5000)\n", stderr)
            return 2
        }
        let scenario = arguments[0]
        NSApplication.shared.setActivationPolicy(.prohibited)
        let monitor = ResourceMonitor()
        monitor.showAllUsers = true
        let now = Date()
        for index in 0..<51 {
            monitor.publishPerformanceSample(fixture(
                date: now.addingTimeInterval(Double(index - 50) * 6), count: count, step: index
            ))
        }
        let view: NSHostingView<AnyView>?
        if scenario == "background" {
            view = nil
        } else {
            let root: AnyView
            if scenario == "dashboard" {
                root = AnyView(ContentView(resourceMonitor: monitor, startsServices: false))
            } else {
                let metric: ResourceMetric = scenario == "memory" ? .memory : scenario == "energy" ? .energy : .cpu
                root = AnyView(ResourcesTab(monitor: monitor, initialMetric: metric))
            }
            let hosting = NSHostingView(rootView: AnyView(root.preferredColorScheme(.dark)))
            hosting.setFrameSize(NSSize(width: 1_280, height: 900))
            view = hosting
        }
        let start = Date()
        var nextSample = start
        var step = 51
        while Date().timeIntervalSince(start) < duration {
            if Date() >= nextSample {
                monitor.publishPerformanceSample(fixture(date: Date(), count: count, step: step))
                step += 1
                if let view {
                    view.layoutSubtreeIfNeeded()
                    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                        fputs("Performance probe could not create its offscreen rendering surface.\n", stderr)
                        return 1
                    }
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                }
                nextSample = nextSample.addingTimeInterval(6)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return 0
    }

    private static func fixture(date: Date, count: Int, step: Int) -> ResourceSnapshot {
        let processes = (0..<count).map { index in
            ResourceProcess(
                identity: ActivityProcessIdentity(
                    bootSession: "synthetic-benchmark-boot", pid: Int32(100_000 + index), startTime: UInt64(index + 1)
                ),
                pid: Int32(100_000 + index), name: "Synthetic worker \(index)", user: "synthetic-user",
                cpu: Double((index + step) % 100) / 10, cpuTimeSeconds: Double(index + step),
                threads: 4, idleWakeUps: UInt64(index), kind: "Apple", gpu: nil, gpuTimeSeconds: nil,
                memoryBytes: UInt64(index % 50 + 1) * 1_048_576, openFileCount: 12,
                power: Double(index % 5), power12Hour: nil, appNap: nil, preventsSleep: false,
                diskReadBytes: UInt64(index + step) * 4_096, diskWrittenBytes: UInt64(index + step) * 2_048,
                diskSampledAt: date, networkSampledAt: date,
                receivedBytes: UInt64(index + step) * 1_024, sentBytes: UInt64(index + step) * 512,
                receivedPackets: UInt64(index + step), sentPackets: UInt64(index + step), icon: nil
            )
        }
        let descriptors = processes.compactMap { process in
            process.identity.map { ActivityProcessDescriptor(identity: $0, name: process.name, user: process.user) }
        }
        return ResourceSnapshot(
            date: date, processes: processes, processInventory: ActivityProcessInventory(processes: descriptors),
            cpu: CPUResourceSummary(
                userPercent: Double(step % 30 + 10), systemPercent: 8, idlePercent: Double(82 - step % 30),
                processCount: count, runningCount: 3, threadCount: count * 4
            ),
            memory: MemoryResourceSummary(
                physicalBytes: 16 * 1_073_741_824, usedBytes: 8 * 1_073_741_824,
                appBytes: 5 * 1_073_741_824, cachedBytes: 2 * 1_073_741_824, wiredBytes: 1_073_741_824,
                compressedBytes: 1_073_741_824, swapUsedBytes: 0, pressurePercent: 30
            ),
            disk: DiskResourceSummary(
                capacity: DiskCapacity(totalBytes: 512 * 1_073_741_824, freeBytes: 256 * 1_073_741_824),
                reads: 100, readBytes: 4_096_000, writes: 50, writtenBytes: 2_048_000,
                readsPerSecond: 10, readBytesPerSecond: 40_960, writesPerSecond: 5, writtenBytesPerSecond: 20_480
            ),
            network: NetworkResourceSummary(
                receivedPackets: 100, receivedBytes: 1_024_000, sentPackets: 50, sentBytes: 512_000,
                receivedPacketsPerSecond: 10, receivedBytesPerSecond: 10_240, sentPacketsPerSecond: 5,
                sentBytesPerSecond: 5_120
            ),
            battery: BatteryResourceSummary(source: "AC Power", chargePercent: 80, status: "charging", timeRemaining: nil),
            sampledEnergy: true, warnings: []
        )
    }
}
#endif
