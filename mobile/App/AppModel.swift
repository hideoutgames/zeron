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
        if let saved = Endpoint.load() {
            connect(saved)
        }
    }

    func connect(_ endpoint: Endpoint) {
        endpoint.save()
        self.endpoint = endpoint
        connection.connect(endpoint)
        workspace.start(connection)
    }

    func signOut() {
        workspace.stop()
        connection.disconnect()
        Endpoint.forget()
        endpoint = nil
    }
}
