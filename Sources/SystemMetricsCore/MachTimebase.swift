import Darwin
import Foundation

public struct MachTimebase: Equatable, Sendable {
    public let numerator: UInt32
    public let denominator: UInt32

    public init(numerator: UInt32, denominator: UInt32) throws {
        guard numerator > 0, denominator > 0 else { throw MachTimebaseError.invalidRatio }
        self.numerator = numerator
        self.denominator = denominator
    }

    public func seconds(ticks: UInt64) -> Double {
        Double(ticks) * Double(numerator) / Double(denominator) / 1_000_000_000
    }

    public static func current() throws -> MachTimebase { try cached.get() }

    private static let cached: Result<MachTimebase, Error> = Result {
        var info = mach_timebase_info_data_t()
        let status = mach_timebase_info(&info)
        guard status == KERN_SUCCESS else { throw MachTimebaseError.unavailable(status) }
        return try MachTimebase(numerator: info.numer, denominator: info.denom)
    }
}

public enum MachTimebaseError: LocalizedError {
    case invalidRatio
    case unavailable(kern_return_t)

    public var errorDescription: String? {
        switch self {
        case .invalidRatio: return "The Mach clock reported an invalid timebase."
        case .unavailable(let status): return "The Mach clock timebase is unavailable (status \(status))."
        }
    }
}
