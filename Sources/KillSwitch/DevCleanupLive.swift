import Foundation
import DevCleanupCore

extension DevCleanupService {
    static func live(username: String = NSUserName()) -> DevCleanupService {
        DevCleanupService(
            username: username,
            processProvider: {
                try ProcessSampler.fetchDetailedThrowing().map {
                    DevCleanupProcess(
                        pid: $0.pid,
                        user: $0.user,
                        elapsedSeconds: $0.etimeSeconds,
                        command: $0.command
                    )
                }
            },
            listeningPortsProvider: {
                try ProcessSampler.listeningPortsThrowing()
            },
            terminator: {
                ProcessSampler.terminate(pid: $0)
            }
        )
    }
}
