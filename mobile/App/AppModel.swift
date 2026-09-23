import Foundation
import Observation
import SkipFuse
import ZeronClient

/// App-wide state: the host link plus the workspace mirrored from it.
@Observable @MainActor
final class AppModel {
    let connection = Connection()
    let workspace = Workspace()
    private(set) var endpoint: Endpoint?

    init() {
        if ProcessInfo.processInfo.environment["ZERON_DEMO"] != nil {
            connect(.demo)
        } else if let saved = Endpoint.load() {
            connect(saved)
        }
    }

    func connect(_ endpoint: Endpoint) {
        self.endpoint = endpoint
        if endpoint.isDemo {
            connection.connect(endpoint) { _ in DemoHost() }
        } else {
            endpoint.save()
            connection.connect(endpoint)
        }
        workspace.start(connection)
    }

    func signOut() {
        workspace.stop()
        connection.disconnect()
        if endpoint?.isDemo == false {
            Endpoint.forget()
        }
        endpoint = nil
    }
}
