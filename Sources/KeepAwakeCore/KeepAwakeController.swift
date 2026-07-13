import Foundation
import IOKit.pwr_mgt
import os

public enum KeepAwakeDuration: Int, CaseIterable, Sendable {
    case indefinitely = 0
    case fiveMinutes = 300
    case tenMinutes = 600
    case fifteenMinutes = 900
    case thirtyMinutes = 1_800
    case oneHour = 3_600
    case twoHours = 7_200
    case fiveHours = 18_000

    public var seconds: TimeInterval? {
        self == .indefinitely ? nil : TimeInterval(rawValue)
    }

    public var label: String {
        switch self {
        case .indefinitely: "Indefinitely"
        case .fiveMinutes: "5 minutes"
        case .tenMinutes: "10 minutes"
        case .fifteenMinutes: "15 minutes"
        case .thirtyMinutes: "30 minutes"
        case .oneHour: "1 hour"
        case .twoHours: "2 hours"
        case .fiveHours: "5 hours"
        }
    }
}

public struct KeepAwakeError: LocalizedError, Equatable {
    public let operation: String
    public let code: Int32

    public init(operation: String, code: Int32) {
        self.operation = operation
        self.code = code
    }

    public var errorDescription: String? {
        "Could not keep this Mac awake (\(operation) failed with code \(code))."
    }
}

public struct PowerAssertionDriver {
    public typealias AssertionID = UInt32
    public typealias Acquire = (_ type: CFString, _ reason: CFString) throws -> AssertionID
    public typealias Release = (_ id: AssertionID) -> Int32

    let acquire: Acquire
    let release: Release

    public init(acquire: @escaping Acquire, release: @escaping Release) {
        self.acquire = acquire
        self.release = release
    }

    public static let live = PowerAssertionDriver(
        acquire: { type, reason in
            var assertionID = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                type,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason,
                &assertionID
            )
            guard result == kIOReturnSuccess else {
                throw KeepAwakeError(operation: "power assertion", code: result)
            }
            return assertionID
        },
        release: { assertionID in
            IOPMAssertionRelease(assertionID)
        }
    )
}

public protocol KeepAwakeCancellation {
    func cancel()
}

private final class DispatchWorkItemCancellation: KeepAwakeCancellation {
    private let workItem: DispatchWorkItem

    init(workItem: DispatchWorkItem) {
        self.workItem = workItem
    }

    func cancel() {
        workItem.cancel()
    }
}

@MainActor
public final class KeepAwakeController {
    public typealias Schedule = @MainActor (
        _ delay: TimeInterval,
        _ action: @escaping @MainActor () -> Void
    ) -> KeepAwakeCancellation

    public var onStateChange: ((KeepAwakeDuration?) -> Void)?
    public private(set) var activeDuration: KeepAwakeDuration?

    private let driver: PowerAssertionDriver
    private let schedule: Schedule
    private var assertionIDs: [PowerAssertionDriver.AssertionID] = []
    private var expiryCancellation: KeepAwakeCancellation?
    private var generation = 0
    private let logger = Logger(subsystem: "com.killswitch.app", category: "keep-awake")

    public convenience init(driver: PowerAssertionDriver = .live) {
        self.init(driver: driver, schedule: KeepAwakeController.mainQueueSchedule)
    }

    public init(driver: PowerAssertionDriver, schedule: @escaping Schedule) {
        self.driver = driver
        self.schedule = schedule
    }

    public func activate(for duration: KeepAwakeDuration) throws {
        deactivate()

        let reason = "KillSwitch is keeping this Mac awake" as CFString
        var acquired: [PowerAssertionDriver.AssertionID] = []

        do {
            acquired.append(try driver.acquire(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                reason
            ))
            acquired.append(try driver.acquire(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                reason
            ))
        } catch {
            release(acquired)
            throw error
        }

        assertionIDs = acquired
        activeDuration = duration
        generation += 1
        let activationGeneration = generation

        if let seconds = duration.seconds {
            expiryCancellation = schedule(seconds) { [weak self] in
                guard let self, self.generation == activationGeneration else { return }
                self.deactivate()
            }
        }

        logger.info("Keep awake activated for \(duration.label, privacy: .public)")
        onStateChange?(duration)
    }

    public func deactivate() {
        generation += 1
        expiryCancellation?.cancel()
        expiryCancellation = nil

        let wasActive = activeDuration != nil
        release(assertionIDs)
        assertionIDs.removeAll()
        activeDuration = nil

        if wasActive {
            logger.info("Keep awake deactivated")
            onStateChange?(nil)
        }
    }

    private func release(_ ids: [PowerAssertionDriver.AssertionID]) {
        for id in ids {
            let result = driver.release(id)
            if result != kIOReturnSuccess {
                logger.error("Failed to release power assertion \(id) with code \(result)")
            }
        }
    }

    private static func mainQueueSchedule(
        delay: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) -> KeepAwakeCancellation {
        let workItem = DispatchWorkItem {
            Task { @MainActor in
                action()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        return DispatchWorkItemCancellation(workItem: workItem)
    }
}
