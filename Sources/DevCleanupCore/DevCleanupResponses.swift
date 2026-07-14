public struct DevCleanupPortsResponse: Encodable, Equatable {
    public let autoKillEnabled: Bool
    public let effectivePorts: [Int]
    public let integrationPorts: [String: [Int]]
    public let userPorts: [Int]
    public let version: String

    public init(version: String, settings: DevCleanupSettings) {
        autoKillEnabled = settings.autoKillEnabled
        effectivePorts = settings.effectivePorts
        integrationPorts = settings.integrationPorts
        userPorts = settings.userPorts
        self.version = version
    }
}
