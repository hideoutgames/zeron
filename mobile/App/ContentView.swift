import SwiftUI
import ZeronClient

struct ContentView: View {
    @Environment(AppModel.self) var app

    var body: some View {
        if app.endpoint == nil {
            ConnectView()
        } else {
            NavigationStack {
                ChatListView()
            }
        }
    }
}

/// A single glyph summarising the host link. Sits in toolbars.
struct ConnectionBadge: View {
    let status: Connection.Status

    var body: some View {
        Group {
            switch status {
            case .connected: Image(systemName: "bolt.horizontal.fill").foregroundStyle(.green)
            case .connecting: ProgressView()
            case .disconnected: Image(systemName: "bolt.horizontal").foregroundStyle(.secondary)
            case .unauthorized: Image(systemName: "lock.slash").foregroundStyle(.red)
            }
        }
        .accessibilityLabel(Text(label))
    }

    private var label: String {
        switch status {
        case .connected: "Connected"
        case .connecting: "Connecting"
        case .disconnected: "Disconnected"
        case .unauthorized: "Unauthorized"
        }
    }
}
