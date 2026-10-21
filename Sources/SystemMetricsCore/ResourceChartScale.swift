import Foundation

public struct ResourceChartScale: Equatable, Sendable {
    public let maximum: Double
    public let divisor: Double
    public let unit: String

    public var ticks: [Double] {
        [0, maximum / 2, maximum]
    }

    public init(metric: ResourceMetricKind, maximumValue: Double) {
        let minimum: Double
        switch metric {
        case .cpu, .memory:
            maximum = 100
            divisor = 1
            unit = "%"
            return
        case .energy:
            divisor = 1
            unit = "pts"
            minimum = 10
        case .disk, .network:
            let units: [(name: String, divisor: Double)] = [
                ("B/s", 1),
                ("KB/s", 1_024),
                ("MB/s", 1_048_576),
                ("GB/s", 1_073_741_824),
                ("TB/s", 1_099_511_627_776)
            ]
            let selected = units.last { maximumValue >= $0.divisor } ?? units[0]
            divisor = selected.divisor
            unit = selected.name
            minimum = 1_024
        }

        let target = max(minimum, maximumValue * 1.1) / divisor
        let magnitude = pow(10, floor(log10(target)))
        let step = [1.0, 2, 5, 10].first { $0 * magnitude >= target } ?? 10
        maximum = step * magnitude * divisor
    }

    public func label(for value: Double, locale: Locale = .current) -> String {
        let number = (value / divisor).formatted(
            .number
                .grouping(.never)
                .precision(.fractionLength(0...1))
                .locale(locale)
        )
        return unit == "%" ? "\(number)%" : "\(number) \(unit)"
    }
}
