import SwiftUI
import ZeronClient
import ZeronGenerated

struct ChatListView: View {
    @Environment(AppModel.self) var app

    var body: some View {
        List {
            ForEach(sections, id: \.space?.id) { section in
                Section(section.space?.title ?? "") {
                    ForEach(section.chats, id: \.id) { chat in
                        NavigationLink(value: chat.id) {
                            ChatRow(chat: chat, indicator: app.workspace.indicator(for: chat))
                        }
                    }
                }
            }
        }
        .overlay {
            if !app.workspace.loaded {
                ConnectionBadge(status: app.connection.status)
                    .scaleEffect(2)
            }
        }
        .navigationTitle("Sessions")
        .navigationDestination(for: String.self) { chatId in
            ChatView(chatId: chatId)
        }
        .toolbar {
            Menu {
                Button(role: .destructive, action: app.signOut) {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            } label: {
                ConnectionBadge(status: app.connection.status)
            }
        }
    }

    private struct ChatSection {
        let space: Space?
        let chats: [Chat]
    }

    private var sections: [ChatSection] {
        let grouped = app.workspace.spaces.map { space in
            ChatSection(space: space, chats: app.workspace.chats(in: space))
        }
        let loose = app.workspace.chats(in: nil).filter { $0.spaceId == nil }
        return (grouped + [ChatSection(space: nil, chats: loose)]).filter { !$0.chats.isEmpty }
    }
}

struct ChatRow: View {
    let chat: Chat
    let indicator: ChatIndicator

    var body: some View {
        HStack(spacing: 12) {
            IndicatorDot(indicator: indicator)
            VStack(alignment: .leading, spacing: 2) {
                Text(chat.displayTitle)
                    .lineLimit(1)
                if let preview = chat.lastMessagePreview, !preview.isEmpty {
                    Text(preview)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if let branch = chat.branch {
                Text(branch)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

struct IndicatorDot: View {
    let indicator: ChatIndicator

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .accessibilityLabel(label)
    }

    private var color: Color {
        switch indicator {
        case .working: .blue
        case .awaitingInput: .orange
        case .errored: .red
        case .completed: .green
        case .idle: .clear
        }
    }

    private var label: String {
        switch indicator {
        case .working: "Working"
        case .awaitingInput: "Needs input"
        case .errored: "Failed"
        case .completed: "Unread"
        case .idle: ""
        }
    }
}

extension Chat {
    var displayTitle: String {
        title.flatMap { $0.isEmpty ? nil : $0 } ?? cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Untitled"
    }
}

extension Space {
    var title: String {
        name ?? URL(fileURLWithPath: path).lastPathComponent
    }
}
