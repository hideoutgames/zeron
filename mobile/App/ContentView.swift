import SwiftUI
import ZeronClient

/// Phones push into a chat; wide screens (iPad, Android tablets) keep the session list beside it.
struct ContentView: View {
    @Environment(AppModel.self) var app
    @Environment(\.horizontalSizeClass) var sizeClass
    @State var selection: String?

    var body: some View {
        if app.endpoint == nil {
            ConnectView()
        } else if sizeClass == .regular {
            HStack(spacing: 0) {
                NavigationStack {
                    ChatListView(selection: $selection)
                }
                .frame(width: 320)
                Divider()
                NavigationStack {
                    if let selection {
                        ChatView(chatId: selection).id(selection)
                    } else {
                        Theme.bg
                    }
                }
            }
            .background(Theme.bg)
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
            case .connecting: ProgressView()
            case .unauthorized: Image(glyph: "lock.slash").foregroundStyle(Theme.danger)
            default: Circle().fill(status == .connected ? Theme.completed : Theme.faint).frame(width: 8, height: 8)
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
