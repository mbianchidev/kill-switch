import Foundation
import DevCleanupCore

enum KillSwitchCLI {
    private struct KilledProcessResponse: Encodable {
        let pid: Int32
        let command: String
        let runtime: String
        let ageHours: Double
    }

    private struct CleanupResponse: Encodable {
        let version: String
        let autoKillEnabled: Bool
        let candidateCount: Int
        let killedCount: Int
        let killedProcesses: [KilledProcessResponse]
    }

    private struct ErrorEnvelope: Encodable {
        let error: ErrorResponse
    }

    private struct ErrorResponse: Encodable {
        let code: String
        let message: String
    }

    static func run(arguments: [String]) -> Int32 {
        do {
            let command = try DevCleanupCLIParser.parse(arguments)
            let preferences = DevCleanupPreferences()

            switch command {
            case .status:
                try write(
                    DevCleanupPortsResponse(
                        version: AppVersion.current,
                        settings: preferences.load()
                    )
                )
            case .syncPorts(let source, let ports):
                let settings = try preferences.setIntegrationPorts(source: source, ports: ports)
                try write(
                    DevCleanupPortsResponse(version: AppVersion.current, settings: settings)
                )
            case .cleanup:
                let settings = preferences.load()
                let result = try DevCleanupService.live().cleanup(configuration: settings.configuration)
                try write(
                    CleanupResponse(
                        version: AppVersion.current,
                        autoKillEnabled: settings.autoKillEnabled,
                        candidateCount: result.candidateCount,
                        killedCount: result.killed.count,
                        killedProcesses: result.killed.map {
                            KilledProcessResponse(
                                pid: $0.pid,
                                command: $0.command,
                                runtime: $0.runtime,
                                ageHours: $0.ageHours
                            )
                        }
                    )
                )
            }
            return 0
        } catch let error as DevCleanupCLIParseError {
            writeError(code: "invalid_arguments", message: error.localizedDescription)
            return 2
        } catch let error as DevCleanupPreferenceError {
            let code = error == .persistenceFailed ? "persistence_failure" : "invalid_arguments"
            writeError(code: code, message: error.localizedDescription)
            return error == .persistenceFailed ? 1 : 2
        } catch {
            writeError(code: "runtime_failure", message: error.localizedDescription)
            return 1
        }
    }

    private static func write<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    private static func writeError(code: String, message: String) {
        let response = ErrorEnvelope(error: ErrorResponse(code: code, message: message))
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(response)
            FileHandle.standardError.write(data)
            FileHandle.standardError.write(Data([0x0A]))
        } catch {
            fputs("{\"error\":{\"code\":\"runtime_failure\",\"message\":\"Could not encode error response.\"}}\n", stderr)
        }
    }
}
