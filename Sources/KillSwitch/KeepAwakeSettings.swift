import Combine
import Foundation
import KeepAwakeCore
import os

@MainActor
final class KeepAwakeManager: ObservableObject {
    static let shared = KeepAwakeManager()

    @Published private(set) var activeDuration: KeepAwakeDuration?
    @Published private(set) var activeMode: KeepAwakeMode?
    @Published private(set) var errorMessage: String?

    @Published var preferredDuration: KeepAwakeDuration {
        didSet { KeepAwakeDefaults.set(preferredDuration.rawValue, .preferredDuration) }
    }

    @Published var keepDisplayAwake: Bool {
        didSet { KeepAwakeDefaults.set(keepDisplayAwake, .keepDisplayAwake) }
    }

    @Published var activateOnLaunch: Bool {
        didSet { KeepAwakeDefaults.set(activateOnLaunch, .activateOnLaunch) }
    }

    var onStateChange: ((KeepAwakeDuration?) -> Void)?

    var preferredMode: KeepAwakeMode {
        keepDisplayAwake ? .systemAndDisplay : .systemOnly
    }

    private let controller: KeepAwakeController
    private let logger = Logger(subsystem: "com.killswitch.app", category: "keep-awake-settings")

    private init() {
        controller = KeepAwakeController()

        let storedDuration = KeepAwakeDefaults.int(
            .preferredDuration,
            default: KeepAwakeDuration.indefinitely.rawValue
        )
        preferredDuration = KeepAwakeDuration(rawValue: storedDuration) ?? .indefinitely
        keepDisplayAwake = KeepAwakeDefaults.bool(.keepDisplayAwake, default: true)
        activateOnLaunch = KeepAwakeDefaults.bool(.activateOnLaunch, default: false)

        controller.onStateChange = { [weak self] duration in
            guard let self else { return }
            activeDuration = duration
            activeMode = controller.activeMode
            onStateChange?(duration)
        }
    }

    @discardableResult
    func activate(for duration: KeepAwakeDuration) -> Bool {
        errorMessage = nil
        do {
            try controller.activate(for: duration, mode: preferredMode)
            return true
        } catch {
            let message = error.localizedDescription
            errorMessage = message
            logger.error("Keep awake activation failed: \(message, privacy: .public)")
            return false
        }
    }

    @discardableResult
    func activatePreferred() -> Bool {
        activate(for: preferredDuration)
    }

    @discardableResult
    func activatePreferredOnLaunch() -> Bool {
        guard activateOnLaunch else { return true }
        return activatePreferred()
    }

    func deactivate() {
        errorMessage = nil
        controller.deactivate()
    }

    func resetToDefaults() {
        preferredDuration = .indefinitely
        keepDisplayAwake = true
        activateOnLaunch = false
        errorMessage = nil
    }
}

private enum KeepAwakeDefaults {
    enum Key: String {
        case preferredDuration = "keepawake.preferredDuration"
        case keepDisplayAwake = "keepawake.keepDisplayAwake"
        case activateOnLaunch = "keepawake.activateOnLaunch"
    }

    static func set(_ value: Bool, _ key: Key) {
        UserDefaults.standard.set(value, forKey: key.rawValue)
    }

    static func set(_ value: Int, _ key: Key) {
        UserDefaults.standard.set(value, forKey: key.rawValue)
    }

    static func bool(_ key: Key, default fallback: Bool) -> Bool {
        guard UserDefaults.standard.object(forKey: key.rawValue) != nil else { return fallback }
        return UserDefaults.standard.bool(forKey: key.rawValue)
    }

    static func int(_ key: Key, default fallback: Int) -> Int {
        guard UserDefaults.standard.object(forKey: key.rawValue) != nil else { return fallback }
        return UserDefaults.standard.integer(forKey: key.rawValue)
    }
}
