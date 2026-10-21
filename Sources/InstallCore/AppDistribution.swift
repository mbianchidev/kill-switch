import Foundation

public enum AppDistribution: Equatable {
    case appBundle
    case standalone

    public init(bundleURL: URL) {
        self = bundleURL.pathExtension.lowercased() == "app" ? .appBundle : .standalone
    }

    public var assetName: String {
        self == .appBundle ? "KillSwitch.dmg" : "KillSwitch"
    }

    public var checksumAssetName: String {
        "\(assetName).sha256"
    }

    public var supportsInPlaceUpdates: Bool {
        self == .standalone
    }
}
